import Foundation

/// Computes each device's reference direction (world frame, unit vector) as
/// seen from the room's seat (spec 1.2.2):
/// - the taught vector, if present;
/// - else `(coordinates − seat)` rotated about +z by the room's compass offset,
///   with its elevation shifted by the room's pitch bias.
///
/// The compass offset (degrees, CCW about +z, room frame → world frame) is
/// derived from every taught device that also has coordinates:
/// `offset = yaw(taught) − yaw(coordinates − seat)`, circular mean over devices.
/// Without a derivable offset (no such device, or no seat), coordinates-only
/// devices get no direction and are excluded from targeting.
///
/// The pitch bias (degrees) corrects for forearm pointing not following the
/// true eye-line (people tend to point a few degrees low or high). It comes
/// from the same taught + placed devices:
/// `bias = mean(pitch(taught) − pitch(coordinates − seat))`, clamped to
/// ±`maxPitchBiasDeg`, and is added to the elevation of coordinate-derived
/// directions (yaw unchanged).
///
/// House-wide fallback (`HouseCalibration`): a room whose own offset can't be
/// derived (no taught + placed device) but which is aligned to HA's house
/// model gets its offset from the house: taught + placed devices in ANY
/// aligned room fix the yaw of the (fixed) house frame, so
/// `offset = K − θ_room` (see `HouseCalibration`). The room's own offset and
/// pitch bias always take precedence; the house pitch bias is the fallback.
public struct ReferenceDirections: Equatable, Sendable {
    public enum OffsetSource: String, Equatable, Sendable {
        /// From this room's taught + placed devices.
        case room
        /// From the house-wide calibration (room aligned to the house model).
        case house
    }

    /// Largest pitch bias applied, either way (degrees).
    public static let maxPitchBiasDeg = 20.0

    /// Device ID → unit direction, for every device that has one.
    public var directions: [UUID: Vector3]
    /// The derived compass offset, if any (for UI display).
    public var compassOffsetDeg: Double?
    /// Where `compassOffsetDeg` came from.
    public var compassOffsetSource: OffsetSource?
    /// The derived pitch bias (degrees, clamped), if any (for UI display).
    public var pitchBiasDeg: Double?
    /// Candidates in the room's device order (only devices with a direction).
    public var candidates: [TargetCandidate]

    /// Directions for `room`, with the house-wide fallback derived from `config`.
    public init(room: Room, config: AppConfig) {
        self.init(room: room, devices: config.devices, house: HouseCalibration(config: config))
    }

    public init(room: Room, devices allDevices: [ControlledDevice], house: HouseCalibration = .none) {
        let byID = Dictionary(allDevices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let devices = room.deviceIDs.compactMap { byID[$0] }
        var offset = Self.compassOffsetDeg(room: room, devices: devices)
        var source: OffsetSource? = offset == nil ? nil : .room
        if offset == nil, let h = house.compassOffsetDeg(for: room) {
            offset = h
            source = .house
        }
        let bias = Self.pitchBiasDeg(room: room, devices: devices) ?? house.pitchBiasDeg ?? 0

        var dirs: [UUID: Vector3] = [:]
        var cands: [TargetCandidate] = []
        for d in devices {
            var dir: Vector3?
            if let t = d.taughtVector, !t.isZero {
                dir = t.normalized
            } else if let c = d.coordinates, let seat = room.seat, let off = offset {
                let rel = c - seat
                if !rel.isZero {
                    let pitch = min(90, max(-90, rel.pitchDeg + bias))
                    dir = Vector3(yawDeg: rel.yawDeg + off, pitchDeg: pitch)
                }
            }
            if let dir {
                dirs[d.id] = dir
                cands.append(TargetCandidate(id: d.id, direction: dir))
            }
        }
        directions = dirs
        compassOffsetDeg = offset
        compassOffsetSource = source
        pitchBiasDeg = offset == nil ? nil : bias
        candidates = cands
    }

    /// Room-frame → world-frame yaw offset (deg, (−180, 180]) from taught devices
    /// that also have coordinates; nil if none (or no seat).
    public static func compassOffsetDeg(room: Room, devices: [ControlledDevice]) -> Double? {
        Angle.circularMeanDeg(offsetSamplesDeg(room: room, devices: devices)).map(Angle.normalizedDeg)
    }

    /// One offset sample per taught + placed device: yaw(taught) − yaw(coordinates − seat).
    static func offsetSamplesDeg(room: Room, devices: [ControlledDevice]) -> [Double] {
        guard let seat = room.seat else { return [] }
        var offsets: [Double] = []
        for d in devices {
            guard let t = d.taughtVector, let c = d.coordinates else { continue }
            let rel = c - seat
            // Yaw is meaningless for (near-)vertical vectors.
            guard hypot(rel.x, rel.y) > 1e-6, hypot(t.x, t.y) > 1e-6 else { continue }
            offsets.append(Angle.normalizedDeg(t.yawDeg - rel.yawDeg))
        }
        return offsets
    }

    /// Pitch bias (deg, clamped to ±`maxPitchBiasDeg`) from taught devices that
    /// also have coordinates: mean(pitch(taught) − pitch(coordinates − seat)).
    /// nil if there is no such device (or no seat).
    public static func pitchBiasDeg(room: Room, devices: [ControlledDevice]) -> Double? {
        clampedMeanPitch(pitchSamplesDeg(room: room, devices: devices))
    }

    static func pitchSamplesDeg(room: Room, devices: [ControlledDevice]) -> [Double] {
        guard let seat = room.seat else { return [] }
        var diffs: [Double] = []
        for d in devices {
            guard let t = d.taughtVector, !t.isZero, let c = d.coordinates else { continue }
            let rel = c - seat
            guard !rel.isZero else { continue }
            diffs.append(t.pitchDeg - rel.pitchDeg)
        }
        return diffs
    }

    static func clampedMeanPitch(_ diffs: [Double]) -> Double? {
        guard !diffs.isEmpty else { return nil }
        let mean = diffs.reduce(0, +) / Double(diffs.count)
        return min(maxPitchBiasDeg, max(-maxPitchBiasDeg, mean))
    }

    /// The zero-gesture anchor: `room.anchorDeviceID` if it has a direction,
    /// else the first taught device in room order. nil if neither exists.
    public static func anchor(room: Room, devices: [ControlledDevice],
                              house: HouseCalibration = .none) -> TargetCandidate? {
        let refs = ReferenceDirections(room: room, devices: devices, house: house)
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
