import Foundation
import HealthKit

/// "Always listening": keeps WatchMagic running in the background with no
/// time limit by holding an indoor `HKWorkoutSession`, so pointing + twist
/// works whenever the watch is on the wrist — watch face up, no tap needed.
///
/// No `HKLiveWorkoutBuilder` is attached, so nothing is saved to Health or
/// Fitness. The trade-off is battery: a workout session keeps the sensors
/// (incl. heart rate) running. Turned off in iPhone Settings → Always listening,
/// in which case the 1-hour `RuntimeSession` is used instead.
@MainActor
final class AlwaysOnSession: NSObject, ObservableObject {
    enum State: Equatable {
        case off
        case starting
        case running
        case failed(String)

        var displayName: String {
            switch self {
            case .off: return "Off"
            case .starting: return "Starting"
            case .running: return "Running"
            case .failed(let why): return "Failed (\(why))"
            }
        }
    }

    @Published private(set) var state: State = .off
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    /// Automatic restarts after the system ended the session (reset on each explicit start).
    private var restarts = 0

    var isActive: Bool { state == .starting || state == .running }

    /// Starts the workout session unless one is already starting / running.
    func start() {
        guard !isActive else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            state = .failed("HealthKit unavailable")
            return
        }
        state = .starting
        restarts = 0
        Task { await begin() }
    }

    func stop() {
        session?.end()
        session = nil
        state = .off
        Diag.event("always_on", ["state": "off"])
    }

    private func begin() async {
        do {
            // Starting a workout session requires permission to share workouts
            // (asked once; nothing is actually written).
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
            let config = HKWorkoutConfiguration()
            config.activityType = .other
            config.locationType = .indoor
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            s.delegate = self
            session = s
            s.startActivity(with: Date())
        } catch {
            state = .failed(error.localizedDescription)
            Diag.event("always_on", ["state": "failed", "error": error.localizedDescription])
        }
    }

    fileprivate func sessionChanged(_ s: HKWorkoutSession, to newState: HKWorkoutSessionState) {
        guard s === session else { return }
        switch newState {
        case .running:
            state = .running
            Diag.event("always_on", ["state": "running"])
        case .ended, .stopped:
            session = nil
            Diag.event("always_on", ["state": "ended", "restarts": restarts])
            // The system ended it (e.g. another workout app): try to come back.
            if state != .off, restarts < 3 {
                restarts += 1
                state = .starting
                Task { await begin() }
            } else if state != .off {
                state = .failed("ended")
            }
        default:
            break
        }
    }

    fileprivate func sessionFailed(_ s: HKWorkoutSession, error: Error) {
        guard s === session else { return }
        state = .failed(error.localizedDescription)
        Diag.event("always_on", ["state": "failed", "error": error.localizedDescription])
    }
}

extension AlwaysOnSession: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in self.sessionChanged(workoutSession, to: toState) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.sessionFailed(workoutSession, error: error) }
    }
}
