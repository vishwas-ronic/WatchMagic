import Foundation

/// Lock events reported by `AimLockDetector.update`.
public enum AimLockEvent: Equatable, Sendable {
    /// A new lock was acquired; payload = selected device (closest one if ambiguous).
    case locked(UUID)
    /// The lock ended (arm dropped or moved off target).
    case unlocked
    /// Still locked (emitted on every update while locked).
    case stillLocked
}

/// The current lock. For an ambiguous lock, `candidates` holds every device
/// in the ambiguous set (closest first) and the Digital Crown moves `selectedIndex`.
public struct AimLock: Equatable, Sendable {
    public var candidates: [UUID]
    public var selectedIndex: Int
    /// When the lock was acquired.
    public var lockedAt: TimeInterval
    /// Start of the current gesture window (lock time, last gesture, or last re-arm).
    public var windowStart: TimeInterval

    public var selectedID: UUID { candidates[selectedIndex] }
    public var isAmbiguous: Bool { candidates.count > 1 }
}

/// Decides when the user is aiming at a target (spec 1.2.3 "Lock").
///
/// - **Acquire**: pointing pitch ∈ [−30°, +75°], angular speed < 0.6 rad/s
///   (steady), and the same resolution (same device, or the same ambiguous set)
///   continuously for `aimHold` (300 ms default).
/// - **Keep**: gesture spikes never drop the lock. The lock ends only if
///   (a) the arm drops: pitch < −45° continuously for 0.25 s, or
///   (b) the resolution does not include the locked device(s) for 0.4 s of
///       relatively steady time (angular speed < 1.5 rad/s), or for 1.2 s in
///       total regardless of speed.
///   Within 0.6 s after `noteGesture(at:)` neither (a) nor (b) accumulates.
/// - **Gesture window**: open for `gestureWindow` (1.5 s default) after the
///   lock, after each `noteGesture(at:)`, and it RE-ARMS whenever the user
///   holds steady on the locked target for `aimHold` again after it closed
///   (so a user who keeps aiming never has to drop the arm to re-lock).
/// - **Crown**: `selectNext()` / `selectPrevious()` cycle through an ambiguous set.
public final class AimLockDetector {

    public struct Configuration: Equatable, Sendable {
        public var aimHold: TimeInterval = 0.3
        public var gestureWindow: TimeInterval = 1.5
        public var minPitchDeg: Double = -30
        /// 75°: ceiling fans above the seat sit at ~60–65°.
        public var maxPitchDeg: Double = 75
        /// Angular speed below which the arm counts as steady, rad/s.
        public var steadySpeed: Double = 0.6
        /// Pitch below which the arm counts as dropped, deg.
        public var armDropPitchDeg: Double = -45
        /// How long the arm must stay dropped to unlock, s.
        public var armDropDuration: TimeInterval = 0.25
        /// Off-target steady time before unlocking, s.
        public var offTargetSteadyDuration: TimeInterval = 0.4
        /// Speed under which off-target time counts as "steady", rad/s.
        public var offTargetSteadySpeed: Double = 1.5
        /// Off-target total time before unlocking regardless of speed, s.
        public var offTargetMaxDuration: TimeInterval = 1.2
        /// After a gesture, unlock conditions are ignored for this long, s.
        public var gestureGrace: TimeInterval = 0.6

        public init() {}

        public init(settings: Settings) {
            self.init()
            aimHold = settings.aimHoldMs / 1000
            gestureWindow = settings.gestureWindowS
        }
    }

    public var configuration: Configuration
    public private(set) var lock: AimLock?
    /// One twist per aim: true on lock; false after a gesture is acted on;
    /// true again only after holding steady on the target for `aimHold`.
    /// (Live log: the arm coming down right after a twist was a second "twist"
    /// that toggled the light back.)
    public private(set) var twistArmed = false

    // Acquisition
    private var pendingKey: Set<UUID>?
    private var pendingOrder: [UUID] = []
    private var pendingSince: TimeInterval = 0
    // Unlock accounting
    private var droppedSince: TimeInterval?
    private var offTargetSince: TimeInterval?
    private var offTargetSteadyTime: TimeInterval = 0
    private var lastUpdate: TimeInterval?
    private var lastGestureAt: TimeInterval = -.infinity
    // Re-arm
    private var steadyOnTargetSince: TimeInterval?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public convenience init(settings: Settings) {
        self.init(configuration: Configuration(settings: settings))
    }

    public var isLocked: Bool { lock != nil }
    /// Selected device of the current lock.
    public var lockedID: UUID? { lock?.selectedID }

    public func reset() {
        lock = nil
        pendingKey = nil
        pendingOrder = []
        droppedSince = nil
        offTargetSince = nil
        offTargetSteadyTime = 0
        lastUpdate = nil
        lastGestureAt = -.infinity
        steadyOnTargetSince = nil
        twistArmed = false
    }

    /// Feed one motion update.
    /// - Returns: `.locked(id)` on acquiring, `.unlocked` on losing, `.stillLocked`
    ///   while locked, nil while searching.
    @discardableResult
    public func update(time t: TimeInterval, pitchDeg: Double, angularSpeed: Double,
                       resolution: Resolution) -> AimLockEvent? {
        let c = configuration
        let dt = lastUpdate.map { max(0, min(0.2, t - $0)) } ?? 0
        lastUpdate = t
        let steady = angularSpeed < c.steadySpeed
        let raised = pitchDeg >= c.minPitchDeg && pitchDeg <= c.maxPitchDeg

        if var l = lock {
            let inGrace = t - lastGestureAt < c.gestureGrace
            let onTarget = !Set(resolution.ids).isDisjoint(with: l.candidates)

            // (a) arm drop
            if pitchDeg < c.armDropPitchDeg && !inGrace {
                if droppedSince == nil { droppedSince = t }
                if t - droppedSince! >= c.armDropDuration { return unlock() }
            } else {
                droppedSince = nil
            }

            // (b) off target
            if onTarget {
                offTargetSince = nil
                offTargetSteadyTime = 0
            } else if !inGrace {
                if offTargetSince == nil { offTargetSince = t }
                if angularSpeed < c.offTargetSteadySpeed { offTargetSteadyTime += dt }
                if offTargetSteadyTime >= c.offTargetSteadyDuration
                    || t - offTargetSince! >= c.offTargetMaxDuration {
                    return unlock()
                }
            }

            // Re-arm the gesture window (and the twist) by holding steady on target again.
            if onTarget && steady && raised {
                if steadyOnTargetSince == nil { steadyOnTargetSince = t }
                if t - steadyOnTargetSince! >= c.aimHold {
                    twistArmed = true
                    if !isGestureWindowOpen(at: t) {
                        l.windowStart = t
                        lock = l
                    }
                }
            } else {
                steadyOnTargetSince = nil
            }
            return .stillLocked
        }

        // Searching.
        guard raised, steady, !resolution.isNone else {
            pendingKey = nil
            return nil
        }
        let key = Set(resolution.ids)
        if key != pendingKey {
            pendingKey = key
            pendingSince = t
        }
        pendingOrder = resolution.ids
        if t - pendingSince >= c.aimHold {
            let l = AimLock(candidates: pendingOrder, selectedIndex: 0, lockedAt: t, windowStart: t)
            lock = l
            pendingKey = nil
            droppedSince = nil
            offTargetSince = nil
            offTargetSteadyTime = 0
            steadyOnTargetSince = t
            twistArmed = true
            return .locked(l.selectedID)
        }
        return nil
    }

    /// Tell the detector a gesture was acted on: keeps the lock (grace period)
    /// and reopens the gesture window.
    public func noteGesture(at t: TimeInterval) {
        lastGestureAt = t
        twistArmed = false
        steadyOnTargetSince = nil
        guard var l = lock else { return }
        l.windowStart = t
        lock = l
        offTargetSince = nil
        offTargetSteadyTime = 0
        droppedSince = nil
    }

    /// True while locked and within `gestureWindow` of the window start.
    public func isGestureWindowOpen(at t: TimeInterval) -> Bool {
        guard let l = lock else { return false }
        return t - l.windowStart <= configuration.gestureWindow
    }

    /// Gesture gate: the device a gesture at time `t` should act on, or nil if
    /// gestures must be ignored (not locked, or window closed).
    public func target(forGestureAt t: TimeInterval) -> UUID? {
        isGestureWindowOpen(at: t) ? lock?.selectedID : nil
    }

    /// Crown: select the next device in an ambiguous lock (wraps). Returns the new selection.
    @discardableResult
    public func selectNext() -> UUID? { moveSelection(by: 1) }

    /// Crown: select the previous device in an ambiguous lock (wraps).
    @discardableResult
    public func selectPrevious() -> UUID? { moveSelection(by: -1) }

    private func moveSelection(by delta: Int) -> UUID? {
        guard var l = lock else { return nil }
        let n = l.candidates.count
        l.selectedIndex = ((l.selectedIndex + delta) % n + n) % n
        lock = l
        return l.selectedID
    }

    private func unlock() -> AimLockEvent {
        lock = nil
        pendingKey = nil
        droppedSince = nil
        offTargetSince = nil
        offTargetSteadyTime = 0
        steadyOnTargetSince = nil
        return .unlocked
    }
}
