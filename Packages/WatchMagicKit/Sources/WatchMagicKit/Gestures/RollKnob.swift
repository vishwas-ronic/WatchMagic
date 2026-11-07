import Foundation

/// "Rotate and hold" brightness / fan-speed control while locked on a device.
///
/// The forearm is a knob: roll it slowly ≥ `engageDeg` away from where it was
/// when the lock settled and hold it there → one step right away, then one
/// every `repeatInterval` until it comes back within `releaseDeg`.
/// Palm up (supination) = up, palm down (pronation) = down, on either wrist.
///
/// The roll angle comes from gravity in the device frame (no gyro drift):
/// with `p` the forearm axis and `u` gravity's component perpendicular to it,
/// the device roll about `p` since the baseline is `−∠(u₀ → u)` about `p`
/// (gravity is fixed in the world, so in the device frame it turns the other
/// way). Verified against the integrated gyro roll on real Ultra twists.
///
/// A fast snap (the on/off twist) passes through these angles too fast to
/// engage (`maxEngageSpeed`). After a twist, call `reset()`: the baseline is
/// re-taken once the arm is steady again, so a wrist left rotated after a
/// snap doesn't start stepping.
public struct RollKnob: Sendable {

    public struct Configuration: Equatable, Sendable {
        /// Roll beyond this (from the baseline) engages, degrees.
        public var engageDeg: Double = 30
        /// Back within this disengages, degrees.
        public var releaseDeg: Double = 18
        /// Beyond this it's not a knob turn but turning the wrist to look at the
        /// watch (~90°, seen in the live log as 13 unintended steps): no steps.
        public var maxEngageDeg: Double = 75
        /// Must be held past `engageDeg` this long before the first step, s.
        public var holdBeforeFirstStep: TimeInterval = 0.4
        /// Then one step per this interval, s.
        public var repeatInterval: TimeInterval = 0.6
        /// Angular speed above which the hold doesn't count (a snap, not a hold), rad/s.
        public var maxEngageSpeed: Double = 2.0
        /// Baseline: arm steady below this speed…, rad/s
        public var settleSpeed: Double = 0.6
        /// …for this long, s.
        public var settleTime: TimeInterval = 0.3
        /// Gravity's component perpendicular to the forearm must be at least
        /// this (forearm not near vertical), else the roll angle is undefined.
        public var minPerpendicularGravity: Double = 0.2

        public init() {}
    }

    public enum Event: Equatable, Sendable {
        /// +1 = up (palm up), −1 = down (palm down).
        case step(Int)
        /// The knob let go (arm back near the baseline).
        case released
    }

    public var configuration: Configuration
    /// Current roll from the baseline, degrees (device roll about the forearm axis); nil without a baseline.
    public private(set) var angleDeg: Double?
    public private(set) var isEngaged = false
    /// Time the knob last stepped or released (callers suppress twists around it).
    public private(set) var lastActivity: TimeInterval = -.infinity

    private var baseline: Vector3?
    private var settledSince: TimeInterval?
    private var pastSince: TimeInterval?
    private var nextStepAt: TimeInterval = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Forget the baseline; it is re-taken once the arm is steady.
    public mutating func reset() {
        baseline = nil
        settledSince = nil
        pastSince = nil
        angleDeg = nil
        isEngaged = false
    }

    /// Take the baseline from this sample right away (e.g. at lock, which already required a steady arm).
    public mutating func setBaseline(gravity: Vector3, pointingSign: Double) {
        reset()
        baseline = Self.perpendicular(gravity, pointingSign: pointingSign, min: configuration.minPerpendicularGravity)
    }

    /// True while the knob is engaged or let go less than `seconds` ago.
    public func isActive(at t: TimeInterval, within seconds: TimeInterval) -> Bool {
        isEngaged || t - lastActivity < seconds
    }

    /// Feed one sample. `wristIsLeft` maps roll direction to palm up/down.
    public mutating func update(t: TimeInterval, gravity: Vector3, pointingSign: Double, wristIsLeft: Bool,
                                angularSpeed: Double) -> Event? {
        let c = configuration
        guard let u = Self.perpendicular(gravity, pointingSign: pointingSign, min: c.minPerpendicularGravity) else {
            angleDeg = nil
            pastSince = nil
            return disengage(at: t)
        }
        guard let u0 = baseline else {
            angleDeg = nil
            if angularSpeed < c.settleSpeed {
                if settledSince == nil { settledSince = t }
                if t - settledSince! >= c.settleTime { baseline = u }
            } else {
                settledSince = nil
            }
            return nil
        }
        let p = ForearmGeometry.devicePointing(sign: pointingSign)
        let roll = -atan2(p.dot(u0.cross(u)), u0.dot(u)) * 180 / .pi
        angleDeg = roll
        // Right arm: supination = +roll about p (clockwise seen from the elbow); left arm mirrored.
        let up = wristIsLeft ? -roll : roll

        if isEngaged {
            if abs(roll) < c.releaseDeg || abs(roll) > c.maxEngageDeg { return disengage(at: t) }
            if t >= nextStepAt, angularSpeed < c.maxEngageSpeed {
                nextStepAt = t + c.repeatInterval
                lastActivity = t
                return .step(up > 0 ? 1 : -1)
            }
            return nil
        }
        if abs(roll) >= c.engageDeg, abs(roll) <= c.maxEngageDeg, angularSpeed < c.maxEngageSpeed {
            if pastSince == nil { pastSince = t }
            if t - pastSince! >= c.holdBeforeFirstStep {
                isEngaged = true
                pastSince = nil
                nextStepAt = t + c.repeatInterval
                lastActivity = t
                return .step(up > 0 ? 1 : -1)
            }
        } else {
            pastSince = nil
        }
        return nil
    }

    private mutating func disengage(at t: TimeInterval) -> Event? {
        guard isEngaged else { return nil }
        isEngaged = false
        lastActivity = t
        return .released
    }

    /// Unit component of gravity perpendicular to the forearm axis (device frame), nil if too small.
    static func perpendicular(_ g: Vector3, pointingSign: Double, min: Double) -> Vector3? {
        let p = ForearmGeometry.devicePointing(sign: pointingSign)
        let perp = g - p * g.dot(p)
        guard perp.norm >= min * max(g.norm, 1e-9) else { return nil }
        return perp.normalized
    }
}
