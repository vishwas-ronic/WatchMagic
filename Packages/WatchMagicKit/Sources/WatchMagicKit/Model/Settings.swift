import Foundation

/// Gesture sensitivity. Scales the gesture detector's rate thresholds.
public enum GestureSensitivity: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    /// Multiplier applied to the detector's peak-rate thresholds
    /// (low = harder to trigger, high = easier).
    public var thresholdScale: Double {
        switch self {
        case .low: return 1.3
        case .medium: return 1.0
        case .high: return 0.75
        }
    }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// Global tuning settings (spec 1.1.3). Decoding tolerates missing keys.
public struct Settings: Codable, Equatable, Sendable {
    /// Brightness change per flick, percent (light `brightness_step_pct`).
    public var brightnessStepPct: Double
    /// Fan speed change per flick, percent. nil = use the entity's own
    /// `percentage_step` (the `percentage_step` parameter is then omitted).
    public var fanStepPct: Double?
    /// Max angle (deg) between pointing and a device's direction to accept it.
    public var aimToleranceDeg: Double
    /// Best device must beat the runner-up by at least this many degrees.
    public var ambiguityMarginDeg: Double
    /// How long (ms) the arm must be steady on a target before locking.
    public var aimHoldMs: Double
    /// Gesture window (s) after lock / after each gesture.
    public var gestureWindowS: Double
    public var sensitivity: GestureSensitivity
    /// Flick down at the minimum brightness/speed turns the device off.
    public var flickDownAtMinimumTurnsOff: Bool

    public init(
        brightnessStepPct: Double = 20,
        fanStepPct: Double? = nil,
        aimToleranceDeg: Double = 12,
        ambiguityMarginDeg: Double = 5,
        aimHoldMs: Double = 300,
        gestureWindowS: Double = 1.5,
        sensitivity: GestureSensitivity = .medium,
        flickDownAtMinimumTurnsOff: Bool = true
    ) {
        self.brightnessStepPct = brightnessStepPct
        self.fanStepPct = fanStepPct
        self.aimToleranceDeg = aimToleranceDeg
        self.ambiguityMarginDeg = ambiguityMarginDeg
        self.aimHoldMs = aimHoldMs
        self.gestureWindowS = gestureWindowS
        self.sensitivity = sensitivity
        self.flickDownAtMinimumTurnsOff = flickDownAtMinimumTurnsOff
    }

    public static let `default` = Settings()

    private enum CodingKeys: String, CodingKey {
        case brightnessStepPct, fanStepPct, aimToleranceDeg, ambiguityMarginDeg,
             aimHoldMs, gestureWindowS, sensitivity, flickDownAtMinimumTurnsOff
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        brightnessStepPct = try c.decodeIfPresent(Double.self, forKey: .brightnessStepPct) ?? d.brightnessStepPct
        fanStepPct = try c.decodeIfPresent(Double.self, forKey: .fanStepPct)
        aimToleranceDeg = try c.decodeIfPresent(Double.self, forKey: .aimToleranceDeg) ?? d.aimToleranceDeg
        ambiguityMarginDeg = try c.decodeIfPresent(Double.self, forKey: .ambiguityMarginDeg) ?? d.ambiguityMarginDeg
        aimHoldMs = try c.decodeIfPresent(Double.self, forKey: .aimHoldMs) ?? d.aimHoldMs
        gestureWindowS = try c.decodeIfPresent(Double.self, forKey: .gestureWindowS) ?? d.gestureWindowS
        // Unknown sensitivity strings fall back to the default instead of failing.
        if let raw = try? c.decodeIfPresent(String.self, forKey: .sensitivity),
           let s = GestureSensitivity(rawValue: raw) {
            sensitivity = s
        } else {
            sensitivity = d.sensitivity
        }
        flickDownAtMinimumTurnsOff = try c.decodeIfPresent(Bool.self, forKey: .flickDownAtMinimumTurnsOff) ?? d.flickDownAtMinimumTurnsOff
    }
}
