import Foundation
import WatchMagicKit

// Small motion-queue state machines used by ControlEngine's pipeline.
// They only combine WatchMagicKit math with timing; all are value types fed
// one MotionFrame at a time on the motion queue.

/// Teach mode capture (spec 1.2.4): three samples, each the mean world
/// pointing vector over a 1 s steady hold; between samples (and before the
/// first) the arm must move (re-aim) so the samples are independent aims.
/// Saved if all three are within 4° of each other.
struct TeachCapture {
    static let samplesNeeded = 3
    static let holdDuration: TimeInterval = 1.0
    static let consistencyDeg = 4.0
    /// Steady = angular speed below this, rad/s.
    static let steadySpeed = 0.5
    /// Re-aim detected when angular speed exceeds this, rad/s.
    static let reaimSpeed = 0.8

    enum Event: Equatable, Sendable {
        /// `hold` 0…1 of the current steady hold; `needsReaim` = move the arm first.
        case progress(samples: Int, hold: Double, needsReaim: Bool)
        case sampleCaptured(samples: Int)
        case finished(vector: Vector3, spreadDeg: Double)
        case inconsistent(spreadDeg: Double)
    }

    private(set) var samples: [Vector3] = []
    private var needsReaim = true
    private var holdStart: TimeInterval?
    private var sum = Vector3.zero

    mutating func process(t: TimeInterval, pointing: Vector3, angularSpeed: Double) -> Event {
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

        var spread = 0.0
        for i in samples.indices {
            for j in samples.indices where j > i { spread = max(spread, samples[i].angle(to: samples[j])) }
        }
        if spread <= Self.consistencyDeg {
            let mean = samples.reduce(Vector3.zero, +).normalized
            return .finished(vector: mean, spreadDeg: spread)
        }
        return .inconsistent(spreadDeg: spread)
    }
}

/// Zero gesture (spec 1.2.1, step 3): with yaw still arbitrary, point at the
/// room's anchor device and hold steady for 1.5 s. Requires a movement first
/// (so merely reading the screen doesn't zero) and a pointing pitch within 20°
/// of the anchor's pitch (yaw is unknown, pitch is not).
struct ZeroHoldDetector {
    static let holdDuration: TimeInterval = 1.5
    static let steadySpeed = 0.5
    static let armSpeed = 0.8
    static let maxPitchDifferenceDeg = 20.0

    private var armed = false
    private var holdStart: TimeInterval?
    private var sum = Vector3.zero

    mutating func reset() {
        armed = false
        holdStart = nil
    }

    /// Returns hold progress 0…1 and, when complete, the yaw correction to
    /// apply to RAW pointing (`TargetResolver.yawCorrection`).
    mutating func process(t: TimeInterval, rawPointing: Vector3, pitchDeg: Double, angularSpeed: Double,
                          anchor: Vector3) -> (progress: Double, correctionDeg: Double?) {
        if angularSpeed > Self.armSpeed { armed = true }
        let raised = pitchDeg >= -30 && pitchDeg <= 60
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

/// Collects `duration` seconds of samples for Sensor Probe → Record.
struct TraceRecorder {
    let duration: TimeInterval
    private(set) var samples: [MotionSample] = []
    private var start: TimeInterval?

    init(duration: TimeInterval) {
        self.duration = duration
        samples.reserveCapacity(Int(duration * 110))
    }

    /// Appends a sample; returns true when the recording is complete.
    mutating func append(_ s: MotionSample) -> Bool {
        if start == nil { start = s.t }
        samples.append(s)
        return s.t - start! >= duration
    }

    func remaining(at t: TimeInterval) -> TimeInterval {
        guard let start else { return duration }
        return max(0, duration - (t - start))
    }
}
