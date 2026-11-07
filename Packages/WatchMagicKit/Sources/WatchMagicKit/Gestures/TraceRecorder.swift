import Foundation

/// Collects `duration` seconds of samples (Sensor Probe → Record). Writing the
/// CSV (`MotionCSV.encode`) and sending it stay in the app.
public struct TraceRecorder: Sendable {
    public let duration: TimeInterval
    public private(set) var samples: [MotionSample] = []
    private var start: TimeInterval?

    public init(duration: TimeInterval) {
        self.duration = duration
        samples.reserveCapacity(Int(duration * 110))
    }

    /// Appends a sample; returns true when the recording is complete.
    public mutating func append(_ s: MotionSample) -> Bool {
        if start == nil { start = s.t }
        samples.append(s)
        return s.t - start! >= duration
    }

    /// Default gap after which a recording counts as stalled (app suspended).
    public static let maxGap: TimeInterval = 1

    /// Timestamp of the last sample, if any.
    public var lastSampleTime: TimeInterval? { samples.last?.t }

    /// True if a sample at `t` comes more than `maxGap` after the previous one
    /// (motion stopped, e.g. the app was suspended): the recording should end.
    public func isStalled(at t: TimeInterval, maxGap: TimeInterval = TraceRecorder.maxGap) -> Bool {
        guard let last = lastSampleTime else { return false }
        return t - last > maxGap
    }

    public func remaining(at t: TimeInterval) -> TimeInterval {
        guard let start else { return duration }
        return max(0, duration - (t - start))
    }
}
