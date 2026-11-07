import Foundation

/// Async Home Assistant REST client (spec 1.1.1, 1.2.5).
///
/// Every request carries `Authorization: Bearer <token>`; POSTs carry
/// `Content-Type: application/json`. Each request uses `timeout` (3 s default).
/// All failures are thrown as `HAError`.
public struct HAClient: Sendable {
    public let baseURL: URL
    public let token: String
    public let session: URLSession
    public let timeout: TimeInterval

    /// Domains WatchMagic controls.
    public static let controllableDomains: Set<String> = ["light", "fan", "switch"]

    /// Jinja template that renders all areas as JSON:
    /// `[{"id": "...", "name": "...", "entities": ["light.x", ...]}, ...]`
    /// (entities filtered to light/fan/switch). Verified against a real HA.
    public static let areasTemplate =
        #"[{% for a in areas() %}{"id":"{{a}}","name":{{ area_name(a)|tojson }},"entities":{{ area_entities(a)|select("match","^(light|fan|switch)\\.")|list|tojson }}}{% if not loop.last %},{% endif %}{% endfor %}]"#

    public init(baseURL: URL, token: String, session: URLSession = .shared, timeout: TimeInterval = 3) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.timeout = timeout
    }

    // MARK: - Endpoints

    /// `GET /api/` → the "message" string (e.g. "API running.").
    public func ping() async throws -> String {
        let data = try await send(makeRequest(path: "api/", method: "GET"))
        struct Msg: Decodable { let message: String }
        guard let m = try? JSONDecoder().decode(Msg.self, from: data) else { throw HAError.invalidResponse }
        return m.message
    }

    /// `GET /api/states` → all entity states.
    public func states() async throws -> [EntityState] {
        let data = try await send(makeRequest(path: "api/states", method: "GET"))
        return try decode([EntityState].self, from: data)
    }

    /// All light./fan./switch. states, sorted by entity ID.
    public func controllableStates() async throws -> [EntityState] {
        try await states()
            .filter { Self.controllableDomains.contains($0.domain) }
            .sorted { $0.entityID < $1.entityID }
    }

    /// `GET /api/states/<entity_id>`.
    public func entityState(_ entityID: String) async throws -> EntityState {
        let data = try await send(makeRequest(path: "api/states/\(entityID)", method: "GET"))
        return try decode(EntityState.self, from: data)
    }

    /// `POST /api/template {"template": ...}` → rendered text.
    public func renderTemplate(_ template: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["template": template])
        let data = try await send(makeRequest(path: "api/template", method: "POST", body: body))
        guard let s = String(data: data, encoding: .utf8) else { throw HAError.invalidResponse }
        return s
    }

    /// Areas with their light/fan/switch entities (via `areasTemplate`).
    public func areas() async throws -> [HAArea] {
        let rendered = try await renderTemplate(Self.areasTemplate)
        return try Self.parseAreas(rendered)
    }

    /// Parses the output of `areasTemplate`. Entity IDs are re-filtered to light/fan/switch.
    public static func parseAreas(_ rendered: String) throws -> [HAArea] {
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let areas = try? JSONDecoder().decode([HAArea].self, from: data) else {
            throw HAError.invalidResponse
        }
        return areas.map { a in
            HAArea(id: a.id, name: a.name,
                   entityIDs: a.entityIDs.filter { controllableDomains.contains(ControlledDevice.domain(of: $0)) })
        }
    }

    /// `POST /api/services/<domain>/<service>` with `call.body`.
    /// Returns the states HA reports as changed (may be empty).
    @discardableResult
    public func callService(_ call: ServiceCall) async throws -> [EntityState] {
        let data = try await send(makeRequest(path: call.path, method: "POST", body: try call.bodyData()))
        if data.isEmpty { return [] }
        return try decode([EntityState].self, from: data)
    }

    // MARK: - Plumbing

    /// Builds a request (exposed for tests / the phone relay).
    public func makeRequest(path: String, method: String, body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url(for: path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body ?? Data("{}".utf8)
        }
        return req
    }

    /// Joins `path` (no leading slash) onto `baseURL`, tolerating a trailing slash
    /// or a sub-path in the base URL.
    func url(for path: String) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/" + path) ?? baseURL.appendingPathComponent(path)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HAError.from(error)
        }
        guard let http = response as? HTTPURLResponse else { throw HAError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw HAError.unauthorized
        default:
            throw HAError.http(status: http.statusCode, body: String(decoding: data.prefix(500), as: UTF8.self))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HAError.invalidResponse
        }
    }
}
