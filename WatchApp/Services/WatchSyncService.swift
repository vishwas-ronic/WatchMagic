import Foundation
import WatchConnectivity
import WatchMagicKit

/// WatchConnectivity on the watch (spec 1.1.4, 1.2.4, 1.2.5, 1.2.7):
/// - receives `ConfigContext` (config + token) via the application context;
/// - persists the config (JSON in Application Support) and the token (Keychain);
/// - sends taught vectors (`transferUserInfo`) and keeps them as local
///   overrides until the phone echoes them back in a config;
/// - sends motion traces (`transferFile`);
/// - relays Home Assistant calls through the phone (`sendMessage` + reply).
///
/// Local taught-vector merge rule: every taught/cleared vector is recorded in
/// `pendingTaught[deviceID]` (persisted) and applied on top of every received
/// config. An override is dropped only when a received config already contains
/// the same value for that device (same vector within 0.5°, or both cleared),
/// or the device no longer exists. So a stale context that predates the teach
/// can't wipe it, and the phone remains the source of truth afterwards.
@MainActor
final class WatchSyncService: NSObject, ObservableObject, WCSessionDelegate {

    enum RelayError: LocalizedError {
        case phoneUnreachable
        case timeout
        case badReply

        var errorDescription: String? {
            switch self {
            case .phoneUnreachable: return "iPhone unreachable"
            case .timeout: return "iPhone relay timed out"
            case .badReply: return "Bad reply from iPhone"
            }
        }
    }

    /// Effective config: last received config + pending local taught overrides.
    @Published private(set) var config: AppConfig?
    @Published private(set) var hasToken = false
    @Published private(set) var lastConfigSentAt: Date?
    @Published private(set) var lastConfigReceivedAt: Date?
    @Published private(set) var activated = false
    @Published private(set) var isReachable = false
    @Published private(set) var isCompanionInstalled = false
    /// Device IDs whose taught vector the phone hasn't confirmed yet.
    @Published private(set) var pendingTaughtIDs: Set<UUID> = []
    @Published private(set) var traceStatus: String?
    @Published private(set) var lastError: String?

    /// Called after the effective config or token changes.
    var onConfigChange: ((AppConfig?, String?) -> Void)?

    /// Kept in memory for HAClient; never logged.
    private(set) var token: String?

    private var receivedConfig: AppConfig?
    private struct PendingTaught: Codable {
        var deviceID: UUID
        var roomID: UUID
        var vector: Vector3?
    }
    private var pending: [UUID: PendingTaught] = [:]
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    override init() {
        super.init()
        loadFromDisk()
    }

    func activate() {
        guard let s = session, s.delegate == nil else { return }
        s.delegate = self
        s.activate()
    }

    // MARK: - Taught vectors

    /// Saves a taught vector (nil = clear) locally and sends it to the phone.
    func setTaughtVector(_ vector: Vector3?, deviceID: UUID, roomID: UUID) {
        let p = PendingTaught(deviceID: deviceID, roomID: roomID, vector: vector?.normalized)
        pending[deviceID] = p
        savePending()
        recomputeEffective()
        send(p)
    }

    private func send(_ p: PendingTaught) {
        guard let s = session, s.activationState == .activated else { return } // resent on activation
        do {
            let dict = try TaughtVectorUpdate(deviceID: p.deviceID, roomID: p.roomID, vector: p.vector).dictionary()
            s.transferUserInfo(dict)
        } catch {
            lastError = "Could not encode taught vector"
        }
    }

    // MARK: - Traces

    /// Sends a motion trace file to the phone. The file is deleted once the
    /// transfer finishes.
    @discardableResult
    func sendTrace(at url: URL) -> Bool {
        guard let s = session, s.activationState == .activated else {
            traceStatus = "Not connected to iPhone"
            return false
        }
        s.transferFile(url, metadata: SyncPayload.traceMetadata(fileName: url.lastPathComponent))
        traceStatus = "Sending \(url.lastPathComponent)…"
        return true
    }

    // MARK: - Phone relay

    /// Asks the phone to make the Home Assistant call. Throws `RelayError`
    /// (unreachable/timeout) or returns the phone's `RelayResponse`.
    func relay(_ call: ServiceCall, timeout: TimeInterval = 3) async throws -> RelayResponse {
        guard let s = session, s.activationState == .activated, s.isReachable else {
            throw RelayError.phoneUnreachable
        }
        let message = try RelayRequest(call: call).dictionary()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RelayResponse, Error>) in
            let once = ResumeOnce(cont)
            s.sendMessage(message, replyHandler: { reply in
                if let r = try? RelayResponse(dictionary: reply) {
                    once.resume(.success(r))
                } else {
                    once.resume(.failure(RelayError.badReply))
                }
            }, errorHandler: { error in
                once.resume(.failure(error))
            })
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(RelayError.timeout))
            }
        }
    }

    // MARK: - Incoming config

    private func apply(_ ctx: ConfigContext) {
        receivedConfig = ctx.config
        lastConfigSentAt = ctx.sentAt
        lastConfigReceivedAt = Date()
        // Drop overrides the phone has confirmed (or whose device is gone).
        for (id, p) in pending {
            guard let device = ctx.config.device(id: id) else {
                pending[id] = nil
                continue
            }
            if Self.sameVector(device.taughtVector, p.vector) { pending[id] = nil }
        }
        savePending()
        saveConfig(ctx.config)
        if ctx.token != token {
            if ctx.token.isEmpty {
                Keychain.deleteToken()
                token = nil
            } else if Keychain.saveToken(ctx.token) {
                token = ctx.token
            } else {
                token = ctx.token // usable this run even if the Keychain write failed
                lastError = "Keychain write failed"
            }
        }
        hasToken = !(token ?? "").isEmpty
        recomputeEffective()
    }

    private static func sameVector(_ a: Vector3?, _ b: Vector3?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.angle(to: y) <= 0.5
        default: return false
        }
    }

    private func recomputeEffective() {
        if var c = receivedConfig {
            for p in pending.values { c.setTaughtVector(p.vector, forDevice: p.deviceID) }
            config = c
        } else {
            config = nil
        }
        pendingTaughtIDs = Set(pending.keys)
        onConfigChange?(config, token)
    }

    // MARK: - Persistence (Application Support; token in Keychain only)

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WatchMagic", isDirectory: true)
    }
    private static var configURL: URL { directory.appendingPathComponent("config.json") }
    private static var pendingURL: URL { directory.appendingPathComponent("pending-taught.json") }

    private func loadFromDisk() {
        if let data = try? Data(contentsOf: Self.configURL) {
            receivedConfig = try? AppConfig.fromJSON(data)
        }
        if let data = try? Data(contentsOf: Self.pendingURL),
           let list = try? JSONDecoder().decode([PendingTaught].self, from: data) {
            pending = Dictionary(list.map { ($0.deviceID, $0) }, uniquingKeysWith: { _, b in b })
        }
        token = Keychain.readToken()
        hasToken = !(token ?? "").isEmpty
        recomputeEffective()
    }

    private func saveConfig(_ c: AppConfig) {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try c.jsonData().write(to: Self.configURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            lastError = "Could not save config"
        }
    }

    private func savePending() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(pending.values))
            try data.write(to: Self.pendingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            lastError = "Could not save taught vectors"
        }
    }

    // MARK: - WCSessionDelegate (any queue → main)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let ctx = try? ConfigContext(dictionary: session.receivedApplicationContext)
        let activated = activationState == .activated
        let reachable = session.isReachable
        let installed = session.isCompanionAppInstalled
        let message = error?.localizedDescription
        onMain { [weak self] in
            guard let self else { return }
            self.activated = activated
            self.isReachable = reachable
            self.isCompanionInstalled = installed
            if let message { self.lastError = message }
            if let ctx, ctx.sentAt != self.lastConfigSentAt || self.receivedConfig == nil { self.apply(ctx) }
            // Re-send unconfirmed taught vectors (idempotent on the phone).
            if activated { for p in self.pending.values { self.send(p) } }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard SyncPayload.kind(of: applicationContext) == .config else { return }
        let ctx: ConfigContext
        do {
            ctx = try ConfigContext(dictionary: applicationContext)
        } catch {
            let message = error.localizedDescription
            onMain { [weak self] in self?.lastError = message }
            return
        }
        onMain { [weak self] in self?.apply(ctx) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        let installed = session.isCompanionAppInstalled
        onMain { [weak self] in
            self?.isReachable = reachable
            self?.isCompanionInstalled = installed
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard let error else { return }
        let message = "Taught vector not sent: \(error.localizedDescription)"
        onMain { [weak self] in self?.lastError = message }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        let name = url.lastPathComponent
        let message = error.map { "Trace failed: \($0.localizedDescription)" } ?? "Sent \(name) ✓"
        if error == nil { try? FileManager.default.removeItem(at: url) }
        onMain { [weak self] in self?.traceStatus = message }
    }
}

/// Resumes a continuation exactly once (reply, error or timeout — whichever is first).
private final class ResumeOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ c: CheckedContinuation<T, Error>) { continuation = c }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
