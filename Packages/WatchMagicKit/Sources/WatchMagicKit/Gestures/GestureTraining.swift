import Foundation

/// Labels for the gesture-training recordings (Create ML activity classifier data).
public enum TrainingLabel: String, CaseIterable, Codable, Sendable {
    case flickUp, flickDown, twist, none

    /// Big text on the watch.
    public var title: String {
        switch self {
        case .flickUp: return "Flick UP"
        case .flickDown: return "Flick DOWN"
        case .twist: return "TWIST"
        case .none: return "Move normally"
        }
    }

    /// What to do during the recording.
    public var instruction: String {
        switch self {
        case .flickUp, .flickDown, .twist:
            return "Point at a device as you would to control it. On each tap, \(title.lowercased()) once, then point again."
        case .none:
            return "Move normally for 60 s — type, drink, scroll, gesture while talking, raise/lower arm."
        }
    }

    /// Gesture sets get haptic cues; `none` doesn't.
    public var isCued: Bool { self != .none }
}

/// Timing of one training recording.
public struct TrainingPlan: Equatable, Sendable {
    public var cueCount = 10
    public var cueInterval: TimeInterval = 2.5
    /// Recording before the first cue.
    public var preRoll: TimeInterval = 1
    /// Recording after the last cue.
    public var postRoll: TimeInterval = 2
    /// Length of the uncued `none` recording.
    public var noneDuration: TimeInterval = 60

    public init() {}

    public static let standard = TrainingPlan()

    /// Cue times relative to the first sample (empty for `none`).
    public func cueOffsets(for label: TrainingLabel) -> [TimeInterval] {
        guard label.isCued else { return [] }
        return (0..<cueCount).map { preRoll + Double($0) * cueInterval }
    }

    /// Total recording length for `label`.
    public func duration(for label: TrainingLabel) -> TimeInterval {
        guard label.isCued, let last = cueOffsets(for: label).last else { return noneDuration }
        return last + postRoll
    }
}

/// Records one labelled training set: all samples from the first one until
/// `plan.duration(for:)`, emitting a `.cue` when each planned cue time is
/// reached (the watch plays a haptic then). Cue times are kept in the sample
/// timestamp base, so they line up with the CSV's `t` column.
public struct TrainingRecorder: Sendable {
    public enum Event: Equatable, Sendable {
        /// Cue `index` (0-based) of `total` is due now.
        case cue(index: Int, total: Int)
        case finished
    }

    public let label: TrainingLabel
    public let plan: TrainingPlan
    public private(set) var samples: [MotionSample] = []
    /// Sample timestamps at which the cues fired.
    public private(set) var cueTimes: [TimeInterval] = []
    public private(set) var isFinished = false
    private var start: TimeInterval?

    public init(label: TrainingLabel, plan: TrainingPlan = .standard) {
        self.label = label
        self.plan = plan
        samples.reserveCapacity(Int(plan.duration(for: label) * 110))
    }

    /// Appends a sample; returns the events it triggers (in order).
    public mutating func append(_ s: MotionSample) -> [Event] {
        guard !isFinished else { return [] }
        if start == nil { start = s.t }
        samples.append(s)
        var events: [Event] = []
        let offsets = plan.cueOffsets(for: label)
        let elapsed = s.t - start!
        while cueTimes.count < offsets.count, elapsed >= offsets[cueTimes.count] {
            cueTimes.append(s.t)
            events.append(.cue(index: cueTimes.count - 1, total: offsets.count))
        }
        if elapsed >= plan.duration(for: label) {
            isFinished = true
            events.append(.finished)
        }
        return events
    }

    public var lastSampleTime: TimeInterval? { samples.last?.t }

    public func remaining(at t: TimeInterval) -> TimeInterval {
        guard let start else { return plan.duration(for: label) }
        return max(0, plan.duration(for: label) - (t - start))
    }

    /// True if a sample at `t` comes more than `maxGap` after the previous one.
    public func isStalled(at t: TimeInterval, maxGap: TimeInterval = TraceRecorder.maxGap) -> Bool {
        guard let last = lastSampleTime else { return false }
        return t - last > maxGap
    }

    /// Mean sample rate of the recording (Hz), nil with < 2 samples.
    public var measuredRateHz: Double? {
        guard samples.count >= 2, let a = samples.first?.t, let b = samples.last?.t, b > a else { return nil }
        return Double(samples.count - 1) / (b - a)
    }

    /// The CSV with its comment header:
    ///
    ///     # label=flickUp
    ///     # cues=<t1>,<t2>,…            (same base as the t column)
    ///     # wrist=left crown=right sign=+1
    ///     # rate=50
    ///     # measured_rate=49.9
    ///     # samples=1276 complete=true
    ///     t,rx,ry,rz,gx,gy,gz,qx,qy,qz,qw,ax,ay,az[,heading]
    public func csv(wristIsLeft: Bool, crownIsRight: Bool, pointingSign: Double, requestedRateHz: Double) -> String {
        let cues = cueTimes.map { String(format: "%.6f", $0) }.joined(separator: ",")
        var comments = [
            "label=\(label.rawValue)",
            "cues=\(cues)",
            "wrist=\(wristIsLeft ? "left" : "right") crown=\(crownIsRight ? "right" : "left") sign=\(pointingSign >= 0 ? "+1" : "-1")",
            "rate=\(Int(requestedRateHz.rounded()))",
        ]
        if let m = measuredRateHz { comments.append(String(format: "measured_rate=%.1f", m)) }
        comments.append("samples=\(samples.count) complete=\(isFinished)")
        return MotionCSV.encode(samples, comments: comments)
    }

    /// `train-<label>-<yyyyMMdd-HHmmss>.csv` (local time).
    public static func fileName(label: TrainingLabel, date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "train-\(label.rawValue)-\(f.string(from: date)).csv"
    }

    /// The label of a `train-<label>-….csv` file name, nil for other files.
    public static func label(ofFileName name: String) -> TrainingLabel? {
        guard name.hasPrefix("train-") else { return nil }
        let rest = name.dropFirst("train-".count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return TrainingLabel(rawValue: String(rest[..<dash]))
    }

    /// True for training CSVs (routed to Documents/Training on the phone).
    public static func isTrainingFile(_ name: String) -> Bool { label(ofFileName: name) != nil }

    /// Parses `# key=value` comment lines of a training CSV (e.g. "label", "cues").
    public static func headerFields(of csv: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in csv.split(separator: "\n") {
            guard line.hasPrefix("#") else { break }
            for part in line.dropFirst().split(separator: " ") {
                let kv = part.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
            }
        }
        return out
    }
}
