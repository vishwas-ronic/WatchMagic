import Foundation

/// Computes each device's reference direction (world frame, unit vector) as
/// seen from the room's seat (spec 1.2.2):
/// - the taught vector, if present;
/// - else `(coordinates − seat)` rotated about +z by the room's compass offset.
///
/// The compass offset (degrees, CCW about +z, room frame → world frame) is
/// derived from every taught device that also has coordinates:
/// `offset = yaw(taught) − yaw(coordinates − seat)`, circular mean over devices.
/// Without a derivable offset (no such device, or no seat), coordinates-only
/// devices get no direction and are excluded from targeting.
public struct ReferenceDirections: Equatable, Sendable {
    /// Device ID → unit direction, for every device that has one.
    public var directions: [UUID: Vector3]
    /// The derived compass offset, if any (for UI display).
    public var compassOffsetDeg: Double?
    /// Candidates in the room's device order (only devices with a direction).
    public var candidates: [TargetCandidate]

    public init(room: Room, devices allDevices: [ControlledDevice]) {
        let byID = Dictionary(allDevices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let devices = room.deviceIDs.compactMap { byID[$0] }
        let offset = Self.compassOffsetDeg(room: room, devices: devices)

        var dirs: [UUID: Vector3] = [:]
        var cands: [TargetCandidate] = []
        for d in devices {
            var dir: Vector3?
            if let t = d.taughtVector, !t.isZero {
                dir = t.normalized
            } else if let c = d.coordinates, let seat = room.seat, let off = offset {
                let rel = c - seat
                if !rel.isZero { dir = rel.normalized.rotatedAboutZ(deg: off) }
            }
            if let dir {
                dirs[d.id] = dir
                cands.append(TargetCandidate(id: d.id, direction: dir))
            }
        }
        directions = dirs
        compassOffsetDeg = offset
        candidates = cands
    }

    /// Room-frame → world-frame yaw offset (deg, (−180, 180]) from taught devices
    /// that also have coordinates; nil if none (or no seat).
    public static func compassOffsetDeg(room: Room, devices: [ControlledDevice]) -> Double? {
        guard let seat = room.seat else { return nil }
        var offsets: [Double] = []
        for d in devices {
            guard let t = d.taughtVector, let c = d.coordinates else { continue }
            let rel = c - seat
            // Yaw is meaningless for (near-)vertical vectors.
            guard hypot(rel.x, rel.y) > 1e-6, hypot(t.x, t.y) > 1e-6 else { continue }
            offsets.append(Angle.normalizedDeg(t.yawDeg - rel.yawDeg))
        }
        return Angle.circularMeanDeg(offsets).map(Angle.normalizedDeg)
    }

    /// The zero-gesture anchor: `room.anchorDeviceID` if it has a direction,
    /// else the first taught device in room order. nil if neither exists.
    public static func anchor(room: Room, devices: [ControlledDevice]) -> TargetCandidate? {
        let refs = ReferenceDirections(room: room, devices: devices)
        if let a = room.anchorDeviceID, let dir = refs.directions[a] {
            return TargetCandidate(id: a, direction: dir)
        }
        let byID = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in room.deviceIDs {
            if let d = byID[id], d.taughtVector != nil, let dir = refs.directions[id] {
                return TargetCandidate(id: id, direction: dir)
            }
        }
        return nil
    }
}
