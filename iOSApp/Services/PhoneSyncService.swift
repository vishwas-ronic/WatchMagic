import Foundation
import WatchConnectivity
import WatchMagicKit

/// Phone side of WatchConnectivity (spec 1.1.4, 1.2.4, 1.2.5, 1.2.7):
/// - pushes `ConfigContext` (config + token) with `updateApplicationContext`
///   on launch and after every change;
/// - receives taught vectors (`transferUserInfo`) and motion traces (`transferFile`);
/// - relays Home Assistant service calls and state fetches for the watch (`sendMessage` + reply).
///
/// WCSessionDelegate callbacks arrive on a background queue; they are
/// `nonisolated` and hop to the main actor for any state access.
@MainActor
final class PhoneSyncService: NSObject, ObservableObject {
    @Published private(set) var isSupported = WCSession.isSupported()
    @Published private(set) var isActivated = false
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false
    /// When the config was last handed to WatchConnectivity.
    @Published private(set) var lastSyncedAt: Date?
    /// Why the last push failed / could not happen (nil when fine).
    @Published private(set) var lastError: String?
    /// Last taught-vector or trace received from the watch.
    @Published private(set) var lastReceivedAt: Date?
    /// Latest gesture-training progress from the watch.
    @Published private(set) var lastTrainingStatus: TrainingStatus?

    private weak var store: ConfigStore?
    private weak var traceStore: TraceStore?
    private var pendingPush = false
    private var pushTask: Task<Void, Never>?

    private static let lastSyncedKey = "lastSyncedAt"

    init(store: ConfigStore, traceStore: TraceStore) {
        self.store = store
        self.traceStore = traceStore
        super.init()
        if let t = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Double {
            lastSyncedAt = Date(timeIntervalSince1970: t)
        }
        store.onChange = { [weak self] in self?.schedulePush() }
        pendingPush = true // push once on launch
        activate()
    }

    func activate() {
        guard WCSession.isSupported() else {
            lastError = "WatchConnectivity is not supported on this device"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Push

    /// Coalesces bursts of changes (e.g. typing coordinates) into one push.
    func schedulePush() {
        pendingPush = true
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.pushNow()
        }
    }

    /// Pushes the full config + token to the watch now (if possible).
    func pushNow() {
        pushTask?.cancel()
        pushTask = nil
        guard let store, WCSession.isSupported() else { return }
        let session = WCSession.default
        refreshStatus(from: session)
        guard session.activationState == .activated else {
            pendingPush = true
            lastError = "Connecting to the watch…"
            return
        }
        guard session.isPaired else {
            pendingPush = true
            lastError = "No Apple Watch paired"
            return
        }
        guard session.isWatchAppInstalled else {
            pendingPush = true
            lastError = "WatchMagic is not installed on the watch"
            return
        }
        let context = ConfigContext(config: store.config, token: store.token, sentAt: Date())
        do {
            try session.updateApplicationContext(context.dictionary())
            pendingPush = false
            lastSyncedAt = context.sentAt
            lastError = nil
            UserDefaults.standard.set(context.sentAt.timeIntervalSince1970, forKey: Self.lastSyncedKey)
        } catch {
            pendingPush = true
            lastError = "Sync failed: \(error.localizedDescription)"
        }
    }

    private func refreshStatus(from session: WCSession) {
        isActivated = session.activationState == .activated
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }

    private func sessionStateChanged() {
        refreshStatus(from: WCSession.default)
        if pendingPush || lastSyncedAt == nil { pushNow() }
    }

    // MARK: - Incoming

    private func apply(_ update: TaughtVectorUpdate) {
        lastReceivedAt = Date()
        // ConfigStore.update → save → onChange → re-push to the watch.
        store?.setTaughtVector(update.vector, forDevice: update.deviceID)
    }

    /// Performs a relayed HA call off the main actor.
    nonisolated static func performRelay(_ request: RelayRequest, client: HAClient?) async -> RelayResponse {
        guard let client else { return RelayResponse(errorMessage: "Phone has no Home Assistant token") }
        let call = request.call
        // Only the services WatchMagic itself emits, on entities it controls.
        guard request.isAllowed else {
            return RelayResponse(errorMessage: "Relay refused \(call.serviceName)")
        }
        do {
            var states = try await client.callService(call)
            if !states.contains(where: { $0.entityID == call.entityID }),
               let fresh = try? await client.entityState(call.entityID) {
                states.append(fresh)
            }
            return RelayResponse(states: states)
        } catch {
            return RelayResponse(errorMessage: HAError.from(error).errorDescription ?? "HA error")
        }
    }

    /// Performs a relayed state fetch (`GET /api/states/<id>`) off the main actor.
    nonisolated static func performStateRelay(_ request: RelayStateRequest, client: HAClient?) async -> RelayResponse {
        guard let client else { return RelayResponse(errorMessage: "Phone has no Home Assistant token") }
        // Only light./fan./switch. entities with a plain object id.
        guard request.isAllowed else { return RelayResponse(errorMessage: "Relay refused state of \(request.entityID)") }
        do {
            return RelayResponse(states: [try await client.entityState(request.entityID)])
        } catch {
            return RelayResponse(errorMessage: HAError.from(error).errorDescription ?? "HA error")
        }
    }

    nonisolated static func replyDictionary(_ response: RelayResponse) -> [String: Any] {
        if let d = try? response.dictionary() { return d }
        // Encoding a RelayResponse cannot realistically fail; still always reply something.
        return [SyncPayload.Keys.kind: SyncPayload.Kind.relayResponse.rawValue]
    }
}

// MARK: - WCSessionDelegate

extension PhoneSyncService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            if let message { self.lastError = "Watch session: \(message)" }
            self.sessionStateChanged()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in self.refreshStatus(from: WCSession.default) }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switching watches: reactivate for the new one, then push again.
        Task { @MainActor in
            self.pendingPush = true
            WCSession.default.activate()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.sessionStateChanged() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.sessionStateChanged() }
    }

    // Taught vectors (transferUserInfo).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard SyncPayload.kind(of: userInfo) == .taughtVector,
              let update = try? TaughtVectorUpdate(dictionary: userInfo) else { return }
        Task { @MainActor in self.apply(update) }
    }

    // Motion traces (transferFile). The file must be moved before returning.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        if let kind = SyncPayload.kind(of: metadata), kind != .trace { return }
        let name = metadata[SyncPayload.Keys.fileName] as? String
        let imported = (try? TraceStore.importFile(at: file.fileURL, preferredName: name)) != nil
        Task { @MainActor in
            self.lastReceivedAt = Date()
            if !imported { self.lastError = "Could not save a trace from the watch" }
            self.traceStore?.refresh()
        }
    }

    // Relay requests (sendMessage with reply). The reply handler is always called.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        switch SyncPayload.kind(of: message) {
        case .relayRequest:
            let request: RelayRequest
            do {
                request = try RelayRequest(dictionary: message)
            } catch {
                replyHandler(Self.replyDictionary(RelayResponse(errorMessage: "Bad relay request")))
                return
            }
            Task { @MainActor in
                let client = self.store?.makeClient()
                let response = await Self.performRelay(request, client: client)
                replyHandler(Self.replyDictionary(response))
            }
        case .relayStateRequest:
            let request: RelayStateRequest
            do {
                request = try RelayStateRequest(dictionary: message)
            } catch {
                replyHandler(Self.replyDictionary(RelayResponse(errorMessage: "Bad relay request")))
                return
            }
            Task { @MainActor in
                let client = self.store?.makeClient()
                let response = await Self.performStateRelay(request, client: client)
                replyHandler(Self.replyDictionary(response))
            }
        case .config:
            // Watch asks for a fresh config: push it and also return it directly.
            Task { @MainActor in
                self.pushNow()
                if let store = self.store,
                   let dict = try? ConfigContext(config: store.config, token: store.token).dictionary() {
                    replyHandler(dict)
                } else {
                    replyHandler(Self.replyDictionary(RelayResponse(errorMessage: "No config")))
                }
            }
        default:
            replyHandler(Self.replyDictionary(RelayResponse(errorMessage: "Unsupported message")))
        }
    }

    // Messages without a reply handler: a config request, or training progress.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        switch SyncPayload.kind(of: message) {
        case .config:
            Task { @MainActor in self.pushNow() }
        case .trainingStatus:
            if let st = try? TrainingStatus(dictionary: message) {
                Task { @MainActor in self.lastTrainingStatus = st }
            }
        default:
            break
        }
    }

    // MARK: - Gesture training (phone guides, watch records)

    enum TrainingSendError: LocalizedError {
        case watchUnreachable
        case badReply
        case timeout
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .watchUnreachable: return "Open WatchMagic on your watch (keep it on the Aim screen)"
            case .badReply: return "Unexpected reply from the watch"
            case .timeout: return "The watch didn't answer"
            case .failed(let m): return m
            }
        }
    }

    var isWatchReachable: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    /// Asks the watch to record one training set; returns its `.accepted` status.
    func startTraining(_ start: TrainingStart, timeout: TimeInterval = 5) async throws -> TrainingStatus {
        guard isWatchReachable else { throw TrainingSendError.watchUnreachable }
        let dict = try start.dictionary()
        let status: TrainingStatus = try await withCheckedThrowingContinuation { cont in
            let once = TrainingOnce(cont)
            WCSession.default.sendMessage(dict, replyHandler: { reply in
                if let st = try? TrainingStatus(dictionary: reply) { once.resume(.success(st)) }
                else { once.resume(.failure(TrainingSendError.badReply)) }
            }, errorHandler: { error in
                once.resume(.failure(error))
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(.failure(TrainingSendError.timeout)) }
        }
        if status.phase == .failed { throw TrainingSendError.failed(status.message ?? "The watch couldn't start recording") }
        return status
    }

    func cancelTraining(sessionID: UUID) {
        guard isWatchReachable, let dict = try? TrainingCancel(sessionID: sessionID).dictionary() else { return }
        WCSession.default.sendMessage(dict, replyHandler: nil, errorHandler: nil)
    }
}

/// Resumes a continuation once (reply, error or timeout — whichever is first).
private final class TrainingOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<TrainingStatus, Error>?
    private let lock = NSLock()

    init(_ c: CheckedContinuation<TrainingStatus, Error>) { continuation = c }

    func resume(_ result: Result<TrainingStatus, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
