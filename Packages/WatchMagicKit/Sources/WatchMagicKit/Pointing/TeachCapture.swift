import Foundation

/// Teach mode capture (spec 1.2.4): three samples, each the mean world
/// pointing vector over a 1 s steady hold; between samples (and before the
/// first) the arm must move (re-aim) so the samples are independent aims.
/// Saved if all three are within 4° of each other (max pairwise angle), as the
/// normalised mean of the three.
///
/// Platform-free: feed it one motion sample at a time (timestamp, world
/// pointing vector, angular speed).
public struct TeachCapture: Sendable {
    public static let samplesNeeded = 3
    public static let holdDuration: TimeInterval = 1.0
    public static let consistencyDeg = 4.0
    /// Steady = angular speed below this, rad/s.
    public static let steadySpeed = 0.5
    /// Re-aim detected when angular speed exceeds this, rad/s.
    public static let reaimSpeed = 0.8

    public enum Event: Equatable, Sendable {
        /// `hold` 0…1 of the current steady hold; `needsReaim` = move the arm first.
        case progress(samples: Int, hold: Double, needsReaim: Bool)
        case sampleCaptured(samples: Int)
        case finished(vector: Vector3, spreadDeg: Double)
        case inconsistent(spreadDeg: Double)
    }

    public private(set) var samples: [Vector3] = []
    private var needsReaim = true
    private var holdStart: TimeInterval?
    private var sum = Vector3.zero

    public init() {}

    public mutating func process(t: TimeInterval, pointing: Vector3, angularSpeed: Double) -> Event {
        if needsReaim {
            if angularSpeed > Self.reaimSpeed { needsReaim = false }
            return .progress(samples: samples.count, hold: 0, needsReaim: needsReaim)
        }
        guard angularSpeed < Self.steadySpeed, !pointing.isZero else {
            holdStart = nil
            return .progress(samples: samples.count, hold: 0, needsReaim: false)
        }
        if holdStart == nil {
            holdStart = t
            sum = .zero
        }
        sum = sum + pointing
        let elapsed = t - holdStart!
        guard elapsed >= Self.holdDuration else {
            return .progress(samples: samples.count, hold: elapsed / Self.holdDuration, needsReaim: false)
        }
        samples.append(sum.normalized)
        holdStart = nil
        needsReaim = true
        guard samples.count >= Self.samplesNeeded else { return .sampleCaptured(samples: samples.count) }
        return Self.evaluate(samples)
    }

    /// Consistency check + averaging of captured samples: `.finished` with the
    /// normalised mean when the largest pairwise angle is ≤ `consistencyDeg`,
    /// otherwise `.inconsistent`.
    public static func evaluate(_ samples: [Vector3]) -> Event {
        let spread = maxPairwiseAngleDeg(samples)
        if spread <= consistencyDeg {
            let mean = samples.reduce(Vector3.zero, +).normalized
            return .finished(vector: mean, spreadDeg: spread)
        }
        return .inconsistent(spreadDeg: spread)
    }

    /// Largest angle between any two of the vectors, degrees (0 for < 2 vectors).
    public static func maxPairwiseAngleDeg(_ vs: [Vector3]) -> Double {
        var spread = 0.0
        for i in vs.indices {
            for j in vs.indices where j > i { spread = max(spread, vs[i].angle(to: vs[j])) }
        }
        return spread
    }
}
