import Foundation

/// A motion gesture (spec 1.2.3).
public enum Gesture: String, Codable, CaseIterable, Sendable {
    /// Sharp upward rotation of the forearm tip (about its lateral axis).
    case flickUp
    /// The same, downward.
    case flickDown
    /// Sharp roll about the forearm axis and back (pronation then return).
    case twist

    public var displayName: String {
        switch self {
        case .flickUp: return "Flick up"
        case .flickDown: return "Flick down"
        case .twist: return "Twist"
        }
    }
}

/// A detected gesture with diagnostics.
public struct DetectedGesture: Equatable, Sendable {
    public var gesture: Gesture
    /// Peak |pitchRate| (flicks) or |rollRate| (twist) of the first lobe, rad/s.
    public var peakRate: Double
    /// Timestamp of the sample on which the gesture was emitted.
    public var t: TimeInterval

    public init(gesture: Gesture, peakRate: Double, t: TimeInterval) {
        self.gesture = gesture
        self.peakRate = peakRate
        self.t = t
    }
}

/// Rule-based gesture detector on gyroscope rotation-rate peaks.
///
/// Independent of wrist/crown mounting: it works on the forearm pitch rate and
/// roll rate from `MotionKinematics` (device frame, pointing = sign · x̂).
///
/// Rules (medium sensitivity; peak thresholds × `GestureSensitivity.thresholdScale`,
/// i.e. ×1.3 low, ×0.75 high):
/// - **Flick**: a pitch-rate lobe (consecutive samples of one sign with
///   |pitchRate| ≥ 3.5 rad/s) of at least 2 samples, whose peak |pitchRate| is
///   ≥ 1.5 × the peak |rollRate| in the same lobe, and which lasts ≤ 0.35 s
///   (longer = a big deliberate swing, not a flick). The FIRST qualifying
///   lobe's sign decides up/down; the gesture is emitted when the lobe ends
///   (|pitchRate| < 50 % of the threshold, or the sign flips), so the return
///   movement that follows is swallowed by the debounce.
/// - **Twist**: a roll-rate lobe with peak |rollRate| ≥ 12 rad/s and roll
///   dominating pitch (≥ 1.5×), followed within 0.5 s (from the end of that
///   lobe) by an opposite-sign roll ≥ 30 % of the first peak. Emitted when the
///   return crosses that level.
/// - **Debounce**: after a gesture, nothing is detected for 0.4 s AND until
///   the angular speed has dropped below 1.0 rad/s (quiet). A lobe that starts
///   during the refractory period is ignored entirely.
/// - Slow movements (arm raise ~1–2 rad/s, slow wrist rotation) never reach
///   the thresholds.
///
/// The detector knows nothing about aiming. Callers act on gestures only while
/// a target is locked and the gesture window is open (see
/// `AimLockDetector.target(forGestureAt:)`), and should call
/// `AimLockDetector.noteGesture(at:)` afterwards.
public final class GestureDetector {

    public struct Thresholds: Equatable, Sendable {
        /// Minimum peak |pitchRate| for a flick, rad/s.
        public var flickPeak: Double = 3.5
        /// Flick: peak pitch must be ≥ this × peak roll in the lobe.
        public var flickDominance: Double = 1.5
        /// Flick lobes longer than this are not flicks, s.
        public var flickMaxLobeDuration: TimeInterval = 0.35
        /// Minimum peak |rollRate| for the first twist lobe, rad/s.
        /// 12 (×0.75 high = 9): real twists measured 15–19 rad/s on the Ultra,
        /// everyday movement produced twist-shaped lobes of 4–12 rad/s.
        public var twistPeak: Double = 12.0
        /// Twist: peak roll must be ≥ this × peak pitch in the lobe.
        public var twistDominance: Double = 1.5
        /// Return lobe must reach this fraction of the first peak.
        /// 0.3: real returns measured 35–70 % of the first peak.
        public var twistReturnFraction: Double = 0.3
        /// …within this time after the first lobe ends, s.
        public var twistReturnWindow: TimeInterval = 0.5
        /// Twist first lobes longer than this are not twists, s.
        public var twistMaxLobeDuration: TimeInterval = 0.4
        /// Minimum samples above threshold in a lobe.
        public var minSamplesAboveThreshold: Int = 2
        /// No new gesture for this long after one, s.
        public var refractory: TimeInterval = 0.4
        /// …and until |ω| drops below this, rad/s.
        public var quietLevel: Double = 1.0
        /// A lobe ends when the rate falls below this fraction of its threshold.
        public var lobeEndFraction: Double = 0.5

        public init() {}

        /// Medium thresholds scaled for a sensitivity (peaks only).
        public static func forSensitivity(_ s: GestureSensitivity) -> Thresholds {
            var t = Thresholds()
            t.flickPeak *= s.thresholdScale
            t.twistPeak *= s.thresholdScale
            return t
        }
    }

    public var pointingSign: Double
    public var thresholds: Thresholds

    /// Kinematics of the last processed sample (for diagnostics UI).
    public private(set) var lastKinematics: MotionKinematics?
    /// The last gesture detected (for diagnostics UI).
    public private(set) var lastGesture: DetectedGesture?

    // Lobe tracking
    private struct Lobe {
        var sign: Double
        var start: TimeInterval
        var peak: Double        // peak |rate| along the lobe's own axis
        var peakOther: Double   // peak |rate| along the other axis
        var samples: Int
        var suppressed: Bool    // started during refractory → ignore
    }
    private var pitchLobe: Lobe?
    private var rollLobe: Lobe?
    /// Twist first lobe completed, waiting for the return.
    private var pendingTwist: (sign: Double, peak: Double, end: TimeInterval)?

    private var lastGestureTime: TimeInterval = -.infinity
    private var quietSinceGesture = true

    public init(pointingSign: Double, sensitivity: GestureSensitivity = .medium) {
        self.pointingSign = pointingSign
        self.thresholds = .forSensitivity(sensitivity)
    }

    public init(pointingSign: Double, thresholds: Thresholds) {
        self.pointingSign = pointingSign
        self.thresholds = thresholds
    }

    public func setSensitivity(_ s: GestureSensitivity) {
        thresholds = .forSensitivity(s)
    }

    public func reset() {
        pitchLobe = nil
        rollLobe = nil
        pendingTwist = nil
        lastGestureTime = -.infinity
        quietSinceGesture = true
        lastKinematics = nil
    }

    /// True while the debounce (refractory + quiet) blocks new gestures.
    public func isDebouncing(at t: TimeInterval) -> Bool {
        t - lastGestureTime < thresholds.refractory || !quietSinceGesture
    }

    /// Feed one sample; returns a gesture when one completes on this sample.
    @discardableResult
    public func process(_ sample: MotionSample) -> DetectedGesture? {
        let k = MotionKinematics(sample: sample, pointingSign: pointingSign)
        lastKinematics = k
        let t = sample.t
        let th = thresholds

        // Debounce bookkeeping.
        let inRefractory = t - lastGestureTime < th.refractory
        if !quietSinceGesture, !inRefractory, k.angularSpeed < th.quietLevel {
            quietSinceGesture = true
        }
        let blocked = inRefractory || !quietSinceGesture

        let pr = k.pitchRate, rr = k.rollRate
        var result: DetectedGesture?

        // --- Twist return check (pending first lobe) ---
        if let pend = pendingTwist {
            if t - pend.end > th.twistReturnWindow {
                pendingTwist = nil
            } else if !blocked, rr * pend.sign < 0, abs(rr) >= th.twistReturnFraction * pend.peak {
                pendingTwist = nil
                result = emit(.twist, peak: pend.peak, at: t)
            }
        }

        // --- Pitch lobe (flicks) ---
        if let ended = updateLobe(&pitchLobe, rate: pr, other: rr, threshold: th.flickPeak, t: t, blocked: blocked),
           result == nil, !ended.suppressed, pendingTwist == nil,
           ended.samples >= th.minSamplesAboveThreshold,
           t - ended.start <= th.flickMaxLobeDuration + 0.05,
           ended.peak >= th.flickDominance * ended.peakOther {
            result = emit(ended.sign > 0 ? .flickUp : .flickDown, peak: ended.peak, at: t)
        }

        // --- Roll lobe (twist first half) ---
        if let ended = updateLobe(&rollLobe, rate: rr, other: pr, threshold: th.twistPeak, t: t, blocked: blocked),
           result == nil, !ended.suppressed,
           ended.samples >= th.minSamplesAboveThreshold,
           t - ended.start <= th.twistMaxLobeDuration + 0.05,
           ended.peak >= th.twistDominance * ended.peakOther {
            pendingTwist = (ended.sign, ended.peak, t)
            // The return may already be under way on this very sample.
            if rr * ended.sign < 0, abs(rr) >= th.twistReturnFraction * ended.peak {
                pendingTwist = nil
                result = emit(.twist, peak: ended.peak, at: t)
            }
        }

        if result != nil {
            // A gesture ends every in-flight lobe (the return movement must not
            // become a second gesture).
            pitchLobe = nil
            rollLobe = nil
            pendingTwist = nil
        }
        return result
    }

    /// Runs a whole trace through a fresh detector.
    public static func detectAll(_ samples: [MotionSample], pointingSign: Double,
                                 sensitivity: GestureSensitivity = .medium) -> [DetectedGesture] {
        let d = GestureDetector(pointingSign: pointingSign, sensitivity: sensitivity)
        return samples.compactMap { d.process($0) }
    }

    // MARK: - Private

    /// Updates a lobe with the current rate. Returns the lobe when it ends on this sample.
    private func updateLobe(_ lobe: inout Lobe?, rate: Double, other: Double, threshold: Double,
                            t: TimeInterval, blocked: Bool) -> Lobe? {
        let mag = abs(rate)
        let sign: Double = rate >= 0 ? 1 : -1
        if var l = lobe {
            let ends = sign != l.sign || mag < threshold * thresholds.lobeEndFraction
            if ends {
                lobe = nil
                // A new lobe of the opposite sign may start right away.
                if sign != l.sign, mag >= threshold {
                    lobe = Lobe(sign: sign, start: t, peak: mag, peakOther: abs(other), samples: 1, suppressed: blocked)
                }
                return l
            }
            l.peak = max(l.peak, mag)
            l.peakOther = max(l.peakOther, abs(other))
            if mag >= threshold { l.samples += 1 }
            lobe = l
            return nil
        }
        if mag >= threshold {
            lobe = Lobe(sign: sign, start: t, peak: mag, peakOther: abs(other), samples: 1, suppressed: blocked)
        }
        return nil
    }

    private func emit(_ g: Gesture, peak: Double, at t: TimeInterval) -> DetectedGesture {
        lastGestureTime = t
        quietSinceGesture = false
        let d = DetectedGesture(gesture: g, peakRate: peak, t: t)
        lastGesture = d
        return d
    }
}
