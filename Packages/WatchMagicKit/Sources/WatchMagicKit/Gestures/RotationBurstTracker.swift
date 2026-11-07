import Foundation

/// A burst of strong wrist rotation (|ω| above a threshold), summarised for
/// the diagnostic log whether or not a gesture fired — so sub-threshold
/// flicks show up.
public struct RotationBurst: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    /// Max |pitchRate| (flick axis), rad/s.
    public var maxPitchRate: Double
    /// Max |rollRate| (twist axis), rad/s.
    public var maxRollRate: Double
    /// Max |ω|, rad/s.
    public var maxSpeed: Double
    public var samples: Int
    /// A gesture was detected during the burst.
    public var gestureFired: Bool
    /// Bursts not reported since the previous reported one (rate limit).
    public var suppressedBefore: Int

    public var duration: TimeInterval { end - start }
}

/// Groups samples with |ω| > `threshold` into bursts. A burst ends after
/// `quietTime` below the threshold (or when it exceeds `maxDuration`).
/// Reported bursts are at least `minInterval` apart; the others are counted
/// in the next report's `suppressedBefore`.
public struct RotationBurstTracker: Sendable {
    public var threshold: Double
    public var quietTime: TimeInterval
    public var maxDuration: TimeInterval
    public var minInterval: TimeInterval

    private var current: RotationBurst?
    private var lastAbove: TimeInterval = 0
    private var lastReported: TimeInterval = -.infinity
    private var suppressed = 0

    public init(threshold: Double = 1.5, quietTime: TimeInterval = 0.15,
                maxDuration: TimeInterval = 2, minInterval: TimeInterval = 0.5) {
        self.threshold = threshold
        self.quietTime = quietTime
        self.maxDuration = maxDuration
        self.minInterval = minInterval
    }

    /// Feed one sample's kinematics; returns a finished burst to report, if any.
    public mutating func process(t: TimeInterval, pitchRate: Double, rollRate: Double, speed: Double) -> RotationBurst? {
        if speed > threshold {
            lastAbove = t
            if var b = current {
                b.end = t
                b.maxPitchRate = max(b.maxPitchRate, abs(pitchRate))
                b.maxRollRate = max(b.maxRollRate, abs(rollRate))
                b.maxSpeed = max(b.maxSpeed, speed)
                b.samples += 1
                current = b
                if t - b.start >= maxDuration { return finish() }
            } else {
                current = RotationBurst(start: t, end: t, maxPitchRate: abs(pitchRate), maxRollRate: abs(rollRate),
                                        maxSpeed: speed, samples: 1, gestureFired: false, suppressedBefore: 0)
            }
            return nil
        }
        if current != nil, t - lastAbove >= quietTime { return finish() }
        return nil
    }

    /// Marks the current burst (if any) as having produced a gesture.
    public mutating func noteGesture() {
        current?.gestureFired = true
    }

    private mutating func finish() -> RotationBurst? {
        guard var b = current else { return nil }
        current = nil
        guard b.start - lastReported >= minInterval else {
            suppressed += 1
            return nil
        }
        lastReported = b.start
        b.suppressedBefore = suppressed
        suppressed = 0
        return b
    }
}
