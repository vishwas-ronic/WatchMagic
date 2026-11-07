import Foundation
import WatchConnectivity
import WatchMagicKit

/// Phone side of WatchConnectivity (spec 1.1.4, 1.2.4, 1.2.5, 1.2.7):
/// - pushes `ConfigContext` (config + token) with `updateApplicationContext`
///   on launch and after every change;
/// - receives taught vectors (`transferUserInfo`) and motion traces (`transferFile`);
/// - relays Home Assistant service calls for the watch (`sendMessage` + reply).
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
        let entityDomain = ControlledDevice.domain(of: call.entityID)
        guard HAClient.controllableDomains.contains(entityDomain),
              HAClient.controllableDomains.contains(call.domain) || call.domain == "homeassistant" else {
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

    // Messages without a reply handler: only a config request makes sense.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if SyncPayload.kind(of: message) == .config {
            Task { @MainActor in self.pushNow() }
        }
    }
}
