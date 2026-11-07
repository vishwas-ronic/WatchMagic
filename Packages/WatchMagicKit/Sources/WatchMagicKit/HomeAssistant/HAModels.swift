import Foundation

// MARK: - JSONValue

/// A small Codable JSON value, used for entity attribute bags and service-call data.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// A number: `.int` when `d` is integral (so it encodes as `20`, not `20.0`), else `.double`.
    public static func number(_ d: Double) -> JSONValue {
        if d.rounded() == d, abs(d) < 1e15 { return .int(Int(d)) }
        return .double(d)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d.rounded())
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Converts to a Foundation object suitable for JSONSerialization.
    public var foundationObject: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map(\.foundationObject)
        case .object(let o): return o.mapValues(\.foundationObject)
        case .null: return NSNull()
        }
    }
}

// MARK: - EntityState

/// A Home Assistant entity state (`GET /api/states[/<id>]`, service-call responses).
public struct EntityState: Codable, Equatable, Sendable, Identifiable {
    public var entityID: String
    /// Raw state string: "on", "off", "unavailable", "unknown", …
    public var state: String
    public var attributes: [String: JSONValue]
    /// ISO-8601 string as sent by HA.
    public var lastChanged: String?

    public var id: String { entityID }

    public init(entityID: String, state: String, attributes: [String: JSONValue] = [:], lastChanged: String? = nil) {
        self.entityID = entityID
        self.state = state
        self.attributes = attributes
        self.lastChanged = lastChanged
    }

    private enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case state
        case attributes
        case lastChanged = "last_changed"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try c.decode(String.self, forKey: .entityID)
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? "unknown"
        attributes = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .attributes)) ?? [:]
        lastChanged = try? c.decodeIfPresent(String.self, forKey: .lastChanged)
    }

    public var domain: String { ControlledDevice.domain(of: entityID) }

    /// True only if `state == "on"`.
    public var isOn: Bool { state == "on" }
    /// True for "on" or "off"; false for "unavailable" / "unknown" / anything else.
    public var isKnownOnOff: Bool { state == "on" || state == "off" }

    public var friendlyName: String? { attributes["friendly_name"]?.stringValue }
    /// Light brightness 0–255 (nil when off or not dimmable).
    public var brightness: Int? { attributes["brightness"]?.intValue }
    /// Brightness as a percentage 0–100 (derived from `brightness`).
    public var brightnessPct: Double? { brightness.map { Double($0) * 100 / 255 } }
    /// Fan speed percentage 0–100.
    public var percentage: Double? { attributes["percentage"]?.doubleValue }
    /// Fan's own speed step, percent.
    public var percentageStep: Double? { attributes["percentage_step"]?.doubleValue }
    public var supportedColorModes: [String]? {
        attributes["supported_color_modes"]?.arrayValue?.compactMap(\.stringValue)
    }

    /// Name for display: friendly name, else the entity ID.
    public var displayName: String { friendlyName ?? entityID }

    public var lastChangedDate: Date? {
        guard let s = lastChanged else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - ServiceCall

/// A Home Assistant service call: `POST /api/services/<domain>/<service>`
/// with body `data + {"entity_id": entityID}`. Codable so the watch can send
/// it to the phone for relay.
public struct ServiceCall: Codable, Equatable, Hashable, Sendable {
    public var domain: String
    public var service: String
    public var entityID: String
    public var data: [String: JSONValue]

    public init(domain: String, service: String, entityID: String, data: [String: JSONValue] = [:]) {
        self.domain = domain
        self.service = service
        self.entityID = entityID
        self.data = data
    }

    /// API path, e.g. "api/services/light/turn_on" (no leading slash).
    public var path: String { "api/services/\(domain)/\(service)" }

    /// The JSON body as a dictionary: `data` plus "entity_id".
    public var body: [String: JSONValue] {
        var b = data
        b["entity_id"] = .string(entityID)
        return b
    }

    /// JSON-encoded body (sorted keys).
    public func bodyData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(body)
    }

    /// e.g. "light.turn_on" — handy for logs/UI.
    public var serviceName: String { "\(domain).\(service)" }
}

// MARK: - HAArea

/// A Home Assistant area with its light/fan/switch entities.
public struct HAArea: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var entityIDs: [String]

    public init(id: String, name: String, entityIDs: [String]) {
        self.id = id
        self.name = name
        self.entityIDs = entityIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case entityIDs = "entities"
    }
}

// MARK: - HAError

/// Errors from `HAClient`, with short user-facing messages.
public enum HAError: Error, LocalizedError, Equatable, Sendable {
    /// HTTP 401 — the token is wrong or revoked.
    case unauthorized
    /// The request exceeded the timeout (3 s by default).
    case timeout
    /// Network-level failure (host not found, connection refused, offline…). Detail is for logs.
    case unreachable(String)
    /// Any other non-2xx status.
    case http(status: Int, body: String)
    /// A 2xx response that was not the expected JSON.
    case invalidResponse
    /// `GET /local/house3d/house.json` returned 404.
    case noHouseModel

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "401 – token invalid"
        case .timeout: return "HA timed out"
        case .unreachable: return "HA unreachable"
        case .http(let status, _): return "HTTP \(status)"
        case .invalidResponse: return "Unexpected response from HA"
        case .noHouseModel: return "No house3d model on HA"
        }
    }

    /// True for timeout / unreachable: the watch should retry via the phone relay.
    public var isNetworkError: Bool {
        switch self {
        case .timeout, .unreachable: return true
        default: return false
        }
    }

    /// Maps any error thrown by URLSession to an HAError.
    public static func from(_ error: Error) -> HAError {
        if let e = error as? HAError { return e }
        if let u = error as? URLError {
            if u.code == .timedOut { return .timeout }
            return .unreachable("\(u.code.rawValue): \(u.localizedDescription)")
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorTimedOut { return .timeout }
            return .unreachable("\(ns.code): \(ns.localizedDescription)")
        }
        return .unreachable(error.localizedDescription)
    }
}
