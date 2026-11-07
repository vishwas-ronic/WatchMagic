import Foundation

/// House-wide yaw calibration and the house's true-north bearing.
///
/// Every room aligned to HA's house model (`Room.houseAlignmentIfValid`) has a
/// known `θ_room` with `yaw_house = θ_room − yaw_room` (see `HouseAlignment`),
/// and a taught + placed device in it gives a room → world offset sample
/// `off = yaw_world − yaw_room`. Combining them, for ANY horizontal direction:
///
///     yaw_world = K − yaw_house,   K = θ_room + off   (the same for every room)
///
/// because the house frame is fixed. `K` is the circular mean over all such
/// devices in all aligned rooms. An aligned room without its own taught +
/// placed device then gets `offset = K − θ_room`.
///
/// World frame (see `Vector3.swift`): x = magnetic north, y = west, z = up,
/// yaw CCW from magnetic north, so compass heading = −yaw. House +y (plan
/// down) has `yaw_house = 90°`, hence:
///
///     north_bearing_deg = normalise₀…₃₆₀( 90° − K + declination )
///
/// = bearing of house +y, clockwise from TRUE north. `declination` is the
/// magnetic declination (degrees, East positive: true = magnetic + declination).
/// This assumes taught vectors are compass-referenced (CoreMotion
/// xMagneticNorthZVertical or the compass-anchored fallback), not zero-gesture.
public struct HouseCalibration: Equatable, Sendable {
    /// Magnetic declination at the house (28.396° N, 76.956° E), degrees East.
    /// WMM2025 gives about +1.0° E there for 2026 (it changes by ~+0.05°/yr);
    /// refine from NOAA's calculator if needed.
    public static let defaultDeclinationDeg = 1.0

    public static let none = HouseCalibration(yawConstantDeg: nil, pitchBiasDeg: nil, alignments: [:])

    /// K (deg, (−180, 180]); nil without a taught + placed device in an aligned room.
    public var yawConstantDeg: Double?
    /// House-wide pitch bias (deg, clamped): mean over taught + placed devices
    /// in every room with a seat (pitch doesn't depend on alignment).
    public var pitchBiasDeg: Double?
    /// Room ID → valid alignment.
    public var alignments: [UUID: HouseAlignment]

    public init(yawConstantDeg: Double?, pitchBiasDeg: Double?, alignments: [UUID: HouseAlignment]) {
        self.yawConstantDeg = yawConstantDeg
        self.pitchBiasDeg = pitchBiasDeg
        self.alignments = alignments
    }

    public init(config: AppConfig) {
        var kSamples: [Double] = []
        var pitchSamples: [Double] = []
        var aligned: [UUID: HouseAlignment] = [:]
        for room in config.rooms {
            let devices = config.devices(in: room)
            pitchSamples += ReferenceDirections.pitchSamplesDeg(room: room, devices: devices)
            guard let a = room.houseAlignmentIfValid else { continue }
            aligned[room.id] = a
            kSamples += ReferenceDirections.offsetSamplesDeg(room: room, devices: devices)
                .map { Angle.normalizedDeg($0 + a.rotationDeg) }
        }
        self.init(yawConstantDeg: Angle.circularMeanDeg(kSamples).map(Angle.normalizedDeg),
                  pitchBiasDeg: ReferenceDirections.clampedMeanPitch(pitchSamples),
                  alignments: aligned)
    }

    /// Room → world offset for an aligned room (`K − θ_room`), or nil.
    public func compassOffsetDeg(for room: Room) -> Double? {
        guard let k = yawConstantDeg, let a = alignments[room.id] ?? room.houseAlignmentIfValid else { return nil }
        return Angle.normalizedDeg(k - a.rotationDeg)
    }

    /// Bearing of house +y (plan down), degrees clockwise from TRUE north, [0, 360).
    public func northBearingDeg(declinationDeg: Double = HouseCalibration.defaultDeclinationDeg) -> Double? {
        guard let k = yawConstantDeg else { return nil }
        var b = (90 - k + declinationDeg).truncatingRemainder(dividingBy: 360)
        if b < 0 { b += 360 }
        return b
    }
}
