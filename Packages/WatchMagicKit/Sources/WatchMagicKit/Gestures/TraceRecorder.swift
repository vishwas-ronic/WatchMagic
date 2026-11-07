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

    public func remaining(at t: TimeInterval) -> TimeInterval {
        guard let start else { return duration }
        return max(0, duration - (t - start))
    }
}
