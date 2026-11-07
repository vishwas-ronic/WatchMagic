import Foundation
import WatchKit

/// `WKExtendedRuntimeSession` lifecycle (physical-therapy background mode) so
/// motion keeps streaming while the wrist is lowered (spec 1.2.6).
@MainActor
final class RuntimeSession: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {

    enum State: Equatable {
        case idle
        case starting
        case running
        case ended(String)

        var isEnded: Bool { if case .ended = self { return true } else { return false } }

        var displayName: String {
            switch self {
            case .idle: return "Idle"
            case .starting: return "Starting"
            case .running: return "Running"
            case .ended(let why): return "Ended (\(why))"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var expirationDate: Date?
    @Published private(set) var restartCount = 0

    private var session: WKExtendedRuntimeSession?
    /// One automatic restart per user-initiated start.
    private var autoRestartAvailable = true

    /// Starts a session unless one is already starting/running.
    /// `userInitiated` (Aim screen appearing, "tap to resume", the App Intent)
    /// re-enables the one automatic restart on expiry.
    func start(userInitiated: Bool = true) {
        if userInitiated { autoRestartAvailable = true }
        // One session at a time: a pending (.notStarted) one is still ours.
        if let s = session, s.state != .invalid { return }
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        session = s
        state = .starting
        s.start()
    }

    func stop() {
        session?.invalidate()
        session = nil
        state = .idle
        expirationDate = nil
    }

    // MARK: - WKExtendedRuntimeSessionDelegate

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        let expires = extendedRuntimeSession.expirationDate
        let id = ObjectIdentifier(extendedRuntimeSession)
        onMain { [weak self] in
            guard let self, let s = self.session, ObjectIdentifier(s) == id else { return }
            self.state = .running
            self.expirationDate = expires
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // Nothing to save; the restart happens on invalidation.
    }

    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        let id = ObjectIdentifier(extendedRuntimeSession)
        let message = error?.localizedDescription
        onMain { [weak self] in
            guard let self, let s = self.session, ObjectIdentifier(s) == id else { return }
            self.session = nil
            self.expirationDate = nil
            switch reason {
            case .none:
                self.state = .idle
            case .sessionInProgress:
                // Another session of ours is already running.
                self.state = .running
            case .expired:
                if self.autoRestartAvailable, WKApplication.shared().applicationState == .active {
                    self.autoRestartAvailable = false
                    self.restartCount += 1
                    self.start(userInitiated: false)
                } else {
                    self.state = .ended("expired")
                }
            case .resignedFrontmost:
                self.state = .ended("app left foreground")
            case .suppressedBySystem:
                self.state = .ended("suppressed by system")
            case .error:
                self.state = .ended(message ?? "error")
            @unknown default:
                self.state = .ended("unknown")
            }
        }
    }
}
