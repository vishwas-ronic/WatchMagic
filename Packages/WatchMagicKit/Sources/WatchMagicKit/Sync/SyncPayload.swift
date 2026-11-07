import Foundation

/// Encoding/decoding of everything sent over WatchConnectivity, as
/// property-list-safe dictionaries (`[String: Any]` with String / Data / Double
/// values only). Structured payloads travel as JSON `Data`.
///
/// | Payload              | WCSession API                          | `kind`             |
/// |----------------------|----------------------------------------|--------------------|
/// | ConfigContext        | updateApplicationContext (phone→watch) | "config"           |
/// | TaughtVectorUpdate   | transferUserInfo (watch→phone)         | "taughtVector"     |
/// | RelayRequest         | sendMessage (watch→phone)              | "relayRequest"     |
/// | RelayResponse        | sendMessage reply (phone→watch)        | "relayResponse"    |
/// | motion trace CSV     | transferFile (watch→phone), metadata `SyncPayload.traceMetadata(...)` | "trace" |
public enum SyncPayload {

    public enum Keys {
        public static let kind = "kind"
        public static let config = "config"          // Data: AppConfig JSON
        public static let token = "token"            // String
        public static let sentAt = "sentAt"          // Double: timeIntervalSince1970
        public static let payload = "payload"        // Data: JSON of the payload struct
        public static let fileName = "fileName"      // String (trace metadata)
    }

    public enum Kind: String, Sendable, CaseIterable {
        case config
        case taughtVector
        case relayRequest
        case relayResponse
        case trace
    }

    public enum SyncError: Error, Equatable, LocalizedError {
        case wrongKind(expected: String, found: String?)
        case missingField(String)
        case undecodable(String)

        public var errorDescription: String? {
            switch self {
            case .wrongKind(let e, let f): return "Sync payload kind \(f ?? "nil"), expected \(e)"
            case .missingField(let k): return "Sync payload missing \(k)"
            case .undecodable(let what): return "Sync payload \(what) could not be decoded"
            }
        }
    }

    /// The `kind` of any dictionary received over WatchConnectivity.
    public static func kind(of dict: [String: Any]) -> Kind? {
        (dict[Keys.kind] as? String).flatMap(Kind.init(rawValue:))
    }

    /// transferFile metadata for a motion trace.
    public static func traceMetadata(fileName: String) -> [String: Any] {
        [Keys.kind: Kind.trace.rawValue, Keys.fileName: fileName]
    }

    // MARK: - helpers

    static func checkKind(_ dict: [String: Any], _ expected: Kind) throws {
        let found = dict[Keys.kind] as? String
        guard found == expected.rawValue else { throw SyncError.wrongKind(expected: expected.rawValue, found: found) }
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(value)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, _ dict: [String: Any], key: String) throws -> T {
        guard let data = dict[key] as? Data else { throw SyncError.missingField(key) }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw SyncError.undecodable(key) }
    }
}

// MARK: - ConfigContext (applicationContext)

/// Full config + token, pushed phone → watch with `updateApplicationContext`.
public struct ConfigContext: Equatable, Sendable {
    public var config: AppConfig
    public var token: String
    public var sentAt: Date

    public init(config: AppConfig, token: String, sentAt: Date = Date()) {
        self.config = config
        self.token = token
        self.sentAt = sentAt
    }

    public func dictionary() throws -> [String: Any] {
        [
            SyncPayload.Keys.kind: SyncPayload.Kind.config.rawValue,
            SyncPayload.Keys.config: try config.jsonData(),
            SyncPayload.Keys.token: token,
            SyncPayload.Keys.sentAt: sentAt.timeIntervalSince1970,
        ]
    }

    public init(dictionary d: [String: Any]) throws {
        try SyncPayload.checkKind(d, .config)
        config = try SyncPayload.decodeJSON(AppConfig.self, d, key: SyncPayload.Keys.config)
        guard let token = d[SyncPayload.Keys.token] as? String else { throw SyncPayload.SyncError.missingField(SyncPayload.Keys.token) }
        self.token = token
        let ts = d[SyncPayload.Keys.sentAt] as? Double ?? 0
        sentAt = Date(timeIntervalSince1970: ts)
    }
}

// MARK: - TaughtVectorUpdate (userInfo)

/// A taught vector recorded on the watch, sent with `transferUserInfo`. nil vector = clear.
public struct TaughtVectorUpdate: Codable, Equatable, Sendable {
    public var deviceID: UUID
    public var roomID: UUID
    public var vector: Vector3?

    public init(deviceID: UUID, roomID: UUID, vector: Vector3?) {
        self.deviceID = deviceID
        self.roomID = roomID
        self.vector = vector
    }

    public func dictionary() throws -> [String: Any] {
        [SyncPayload.Keys.kind: SyncPayload.Kind.taughtVector.rawValue,
         SyncPayload.Keys.payload: try SyncPayload.encodeJSON(self)]
    }

    public init(dictionary d: [String: Any]) throws {
        try SyncPayload.checkKind(d, .taughtVector)
        self = try SyncPayload.decodeJSON(TaughtVectorUpdate.self, d, key: SyncPayload.Keys.payload)
    }
}

// MARK: - Relay (sendMessage + reply)

/// Watch → phone: "please make this HA call for me".
public struct RelayRequest: Codable, Equatable, Sendable {
    public var call: ServiceCall

    public init(call: ServiceCall) { self.call = call }

    public func dictionary() throws -> [String: Any] {
        [SyncPayload.Keys.kind: SyncPayload.Kind.relayRequest.rawValue,
         SyncPayload.Keys.payload: try SyncPayload.encodeJSON(self)]
    }

    public init(dictionary d: [String: Any]) throws {
        try SyncPayload.checkKind(d, .relayRequest)
        self = try SyncPayload.decodeJSON(RelayRequest.self, d, key: SyncPayload.Keys.payload)
    }
}

/// Phone → watch reply: the resulting states, or a user-facing error message
/// (e.g. `HAError.errorDescription`).
public struct RelayResponse: Codable, Equatable, Sendable {
    public var states: [EntityState]?
    public var errorMessage: String?

    public init(states: [EntityState]? = nil, errorMessage: String? = nil) {
        self.states = states
        self.errorMessage = errorMessage
    }

    public var isSuccess: Bool { errorMessage == nil }

    public func dictionary() throws -> [String: Any] {
        [SyncPayload.Keys.kind: SyncPayload.Kind.relayResponse.rawValue,
         SyncPayload.Keys.payload: try SyncPayload.encodeJSON(self)]
    }

    public init(dictionary d: [String: Any]) throws {
        try SyncPayload.checkKind(d, .relayResponse)
        self = try SyncPayload.decodeJSON(RelayResponse.self, d, key: SyncPayload.Keys.payload)
    }
}
