import Foundation

/// Zero gesture (spec 1.2.1, step 3): with yaw still arbitrary, point at the
/// room's anchor device and hold steady for 1.5 s. Requires a movement first
/// (so merely reading the screen doesn't zero), the arm raised (pointing pitch
/// −30…60°), and a raw pointing pitch within 20° of the anchor's pitch (yaw is
/// unknown, pitch is not).
///
/// Platform-free: feed it one motion sample at a time.
public struct ZeroHoldDetector: Sendable {
    public static let holdDuration: TimeInterval = 1.5
    public static let steadySpeed = 0.5
    public static let armSpeed = 0.8
    public static let maxPitchDifferenceDeg = 20.0
    public static let raisedPitchRange: ClosedRange<Double> = -30...60

    private var armed = false
    private var holdStart: TimeInterval?
    private var sum = Vector3.zero

    public init() {}

    public mutating func reset() {
        armed = false
        holdStart = nil
    }

    /// Returns hold progress 0…1 and, when complete, the yaw correction to
    /// apply to RAW pointing (`TargetResolver.yawCorrection`). Fires once, then
    /// needs a new movement.
    /// - Parameters:
    ///   - rawPointing: forearm pointing in the (arbitrary-yaw) reference frame.
    ///   - pitchDeg: pointing pitch used for the "arm raised" check.
    ///   - angularSpeed: rad/s.
    ///   - anchor: the anchor device's reference direction (world frame).
    public mutating func process(t: TimeInterval, rawPointing: Vector3, pitchDeg: Double, angularSpeed: Double,
                                 anchor: Vector3) -> (progress: Double, correctionDeg: Double?) {
        if angularSpeed > Self.armSpeed { armed = true }
        let raised = Self.raisedPitchRange.contains(pitchDeg)
        let pitchMatches = abs(rawPointing.pitchDeg - anchor.pitchDeg) <= Self.maxPitchDifferenceDeg
        guard armed, raised, pitchMatches, angularSpeed < Self.steadySpeed, !rawPointing.isZero else {
            holdStart = nil
            return (0, nil)
        }
        if holdStart == nil {
            holdStart = t
            sum = .zero
        }
        sum = sum + rawPointing
        let elapsed = t - holdStart!
        guard elapsed >= Self.holdDuration else { return (elapsed / Self.holdDuration, nil) }
        let correction = TargetResolver.yawCorrection(measured: sum.normalized, reference: anchor)
        reset()
        return (1, correction)
    }
}
