import Foundation

/// Learns each device's pointing direction from use: whenever a twist acts
/// on a locked device, the direction the forearm held while locked is a
/// confirmed "this is where I point for that device". The device's reference
/// moves part-way towards it and is saved as its taught vector, which also
/// refines the room's compass offset / pitch bias for every other device.
public enum AimLearning {
    /// Fraction of the way the reference moves towards each confirmed pointing.
    public static let weight = 0.35
    /// Pointings further than this from the reference are not learned from
    /// (wrong device, or a bad lock), degrees.
    public static let maxCorrectionDeg = 25.0

    /// The new reference, or nil if `observed` is too far off (or degenerate).
    public static func blend(reference: Vector3, observed: Vector3, weight: Double = weight) -> Vector3? {
        guard !reference.isZero, !observed.isZero else { return nil }
        let r = reference.normalized, o = observed.normalized
        guard r.angle(to: o) <= maxCorrectionDeg else { return nil }
        let v = r * (1 - weight) + o * weight
        return v.isZero ? nil : v.normalized
    }
}

/// Running mean of unit pointing vectors (e.g. while steady on a lock).
public struct PointingAverage: Sendable, Equatable {
    public private(set) var sum = Vector3(0, 0, 0)
    public private(set) var count = 0

    public init() {}

    public mutating func add(_ v: Vector3) {
        guard !v.isZero else { return }
        sum = sum + v.normalized
        count += 1
    }

    public mutating func reset() { self = PointingAverage() }

    public var mean: Vector3? { count == 0 || sum.isZero ? nil : sum.normalized }
}
