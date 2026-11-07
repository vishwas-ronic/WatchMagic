import XCTest
@testable import WatchMagicKit

/// URLProtocol stub: tests set `handler`, which receives the request (with the
/// body read back from the stream) and returns a response or throws.
final class StubURLProtocol: URLProtocol {
    struct Captured {
        var request: URLRequest
        var body: Data?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest, Data?) throws -> (Int, Data))?
    nonisolated(unsafe) private static var _captured: [Captured] = []

    static var handler: ((URLRequest, Data?) throws -> (Int, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; _captured = []; lock.unlock() }
    }
    static var captured: [Captured] {
        lock.lock(); defer { lock.unlock() }; return _captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        Self.lock.lock()
        Self._captured.append(Captured(request: request, body: body))
        let h = Self._handler
        Self.lock.unlock()
        do {
            guard let h else { throw URLError(.unknown) }
            let (status, data) = try h(request, body)
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func readAll(_ s: InputStream) -> Data {
        s.open(); defer { s.close() }
        var d = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            d.append(buf, count: n)
        }
        return d
    }
}

final class HAClientTests: XCTestCase {

    private let base = URL(string: "http://ha.test:8123")!
    private let token = "test-token-123"

    private func client(timeout: TimeInterval = 3) -> HAClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return HAClient(baseURL: base, token: token, session: URLSession(configuration: cfg), timeout: timeout)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    private func bodyObject(_ d: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(d)) as? [String: Any])
    }

    private func assertCommon(_ c: StubURLProtocol.Captured, method: String, path: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.request.httpMethod, method, file: file, line: line)
        XCTAssertEqual(c.request.url?.absoluteString, "http://ha.test:8123" + path, file: file, line: line)
        XCTAssertEqual(c.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-123", file: file, line: line)
        XCTAssertEqual(c.request.timeoutInterval, 3, file: file, line: line)
        if method == "POST" {
            XCTAssertEqual(c.request.value(forHTTPHeaderField: "Content-Type"), "application/json", file: file, line: line)
        }
    }

    private func assertThrows(_ expected: HAError, _ op: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await op()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let e as HAError {
            XCTAssertEqual(e, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: - Service calls

    private let lightResponse = #"[{"entity_id":"light.lamp","state":"on","attributes":{"brightness":153,"friendly_name":"Lamp","supported_color_modes":["brightness"]},"last_changed":"2026-11-07T10:00:00.123456+00:00"}]"#

    func testCallServiceLightTurnOnWithBrightnessStep() async throws {
        StubURLProtocol.handler = { _, _ in (200, self.json(self.lightResponse)) }
        let call = ServiceCall(domain: "light", service: "turn_on", entityID: "light.lamp", data: ["brightness_step_pct": .int(20)])
        let states = try await client().callService(call)

        let c = try XCTUnwrap(StubURLProtocol.captured.first)
        assertCommon(c, method: "POST", path: "/api/services/light/turn_on")
        let body = try bodyObject(c.body)
        XCTAssertEqual(Set(body.keys), ["entity_id", "brightness_step_pct"])
        XCTAssertEqual(body["entity_id"] as? String, "light.lamp")
        XCTAssertEqual(body["brightness_step_pct"] as? Int, 20)

        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].brightness, 153)
        XCTAssertEqual(states[0].friendlyName, "Lamp")
        XCTAssertTrue(states[0].isOn)
        XCTAssertNotNil(states[0].lastChangedDate)
    }

    func testCallServiceFanIncreaseSpeed() async throws {
        StubURLProtocol.handler = { _, _ in (200, self.json("[]")) }
        let call = ServiceCall(domain: "fan", service: "increase_speed", entityID: "fan.ceiling", data: ["percentage_step": .int(25)])
        let states = try await client().callService(call)
        XCTAssertEqual(states, [])
        let c = try XCTUnwrap(StubURLProtocol.captured.first)
        assertCommon(c, method: "POST", path: "/api/services/fan/increase_speed")
        let body = try bodyObject(c.body)
        XCTAssertEqual(body["entity_id"] as? String, "fan.ceiling")
        XCTAssertEqual(body["percentage_step"] as? Int, 25)
    }

    func testCallServiceToggleFromActionMapper() async throws {
        StubURLProtocol.handler = { _, _ in (200, self.json("[]")) }
        let dev = ControlledDevice(entityID: "switch.plug", name: "Plug", kind: .switch)
        let call = try XCTUnwrap(ActionMapper.map(gesture: .twist, device: dev, state: nil, settings: Settings()))
        try await client().callService(call)
        let c = try XCTUnwrap(StubURLProtocol.captured.first)
        assertCommon(c, method: "POST", path: "/api/services/homeassistant/toggle")
        let body = try bodyObject(c.body)
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body["entity_id"] as? String, "switch.plug")
    }

    func testBaseURLWithTrailingSlash() async throws {
        StubURLProtocol.handler = { _, _ in (200, self.json(#"{"message":"API running."}"#)) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let c = HAClient(baseURL: URL(string: "http://ha.test:8123/")!, token: token, session: URLSession(configuration: cfg))
        _ = try await c.ping()
        XCTAssertEqual(StubURLProtocol.captured.first?.request.url?.absoluteString, "http://ha.test:8123/api/")
    }

    // MARK: - Reads

    func testPing() async throws {
        StubURLProtocol.handler = { _, _ in (200, self.json(#"{"message":"API running."}"#)) }
        let msg = try await client().ping()
        XCTAssertEqual(msg, "API running.")
        assertCommon(try XCTUnwrap(StubURLProtocol.captured.first), method: "GET", path: "/api/")
    }

    func testControllableStatesFiltersDomains() async throws {
        StubURLProtocol.handler = { _, _ in
            (200, self.json(#"""
            [{"entity_id":"sensor.temp","state":"21","attributes":{}},
             {"entity_id":"switch.plug","state":"off","attributes":{"friendly_name":"Plug"}},
             {"entity_id":"light.lamp","state":"on","attributes":{"brightness":200,"supported_color_modes":["color_temp"]}},
             {"entity_id":"fan.ceiling","state":"on","attributes":{"percentage":33,"percentage_step":33.333333333333336}},
             {"entity_id":"automation.x","state":"on","attributes":{}}]
            """#))
        }
        let states = try await client().controllableStates()
        XCTAssertEqual(states.map(\.entityID), ["fan.ceiling", "light.lamp", "switch.plug"])
        XCTAssertEqual(states[0].percentage, 33)
        XCTAssertEqual(states[0].percentageStep ?? 0, 33.333, accuracy: 0.001)
        XCTAssertEqual(states[1].supportedColorModes, ["color_temp"])
        assertCommon(try XCTUnwrap(StubURLProtocol.captured.first), method: "GET", path: "/api/states")
    }

    func testEntityState() async throws {
        StubURLProtocol.handler = { _, _ in (200, self.json(#"{"entity_id":"light.lamp","state":"off","attributes":{"friendly_name":"Lamp"}}"#)) }
        let s = try await client().entityState("light.lamp")
        XCTAssertFalse(s.isOn)
        XCTAssertEqual(s.displayName, "Lamp")
        assertCommon(try XCTUnwrap(StubURLProtocol.captured.first), method: "GET", path: "/api/states/light.lamp")
    }

    func testAreasParsingAndTemplateBody() async throws {
        StubURLProtocol.handler = { _, _ in
            (200, Data(#"[{"id":"bedroom","name":"Bed \"room\"","entities":["light.bed","sensor.x"]},{"id":"office","name":"Office","entities":[]}]"#.utf8))
        }
        let areas = try await client().areas()
        XCTAssertEqual(areas, [HAArea(id: "bedroom", name: #"Bed "room""#, entityIDs: ["light.bed"]),
                               HAArea(id: "office", name: "Office", entityIDs: [])])
        let c = try XCTUnwrap(StubURLProtocol.captured.first)
        assertCommon(c, method: "POST", path: "/api/template")
        let template = try XCTUnwrap(try bodyObject(c.body)["template"] as? String)
        XCTAssertEqual(template, HAClient.areasTemplate)
        // The Jinja string literal must contain an escaped backslash so the regex is ^(light|fan|switch)\.
        XCTAssertTrue(template.contains(#"select("match","^(light|fan|switch)\\.")"#))
        XCTAssertTrue(template.contains("area_name(a)|tojson"))
    }

    func testRenderTemplate() async throws {
        StubURLProtocol.handler = { _, _ in (200, Data("hello 3".utf8)) }
        let out = try await client().renderTemplate("hello {{ 1 + 2 }}")
        XCTAssertEqual(out, "hello 3")
        XCTAssertEqual(try bodyObject(StubURLProtocol.captured.first?.body)["template"] as? String, "hello {{ 1 + 2 }}")
    }

    // MARK: - Errors

    func testUnauthorized() async {
        StubURLProtocol.handler = { _, _ in (401, Data("401: Unauthorized".utf8)) }
        await assertThrows(.unauthorized) { _ = try await self.client().ping() }
        XCTAssertEqual(HAError.unauthorized.localizedDescription, "401 – token invalid")
        XCTAssertFalse(HAError.unauthorized.isNetworkError)
    }

    func testTimeout() async {
        StubURLProtocol.handler = { _, _ in throw URLError(.timedOut) }
        await assertThrows(.timeout) {
            try await self.client().callService(ServiceCall(domain: "light", service: "turn_on", entityID: "light.lamp"))
        }
        XCTAssertTrue(HAError.timeout.isNetworkError)
        XCTAssertEqual(HAError.timeout.errorDescription, "HA timed out")
    }

    func testConnectionRefusedIsUnreachableNetworkError() async {
        for code in [URLError.Code.cannotConnectToHost, .notConnectedToInternet, .cannotFindHost, .networkConnectionLost] {
            StubURLProtocol.handler = { _, _ in throw URLError(code) }
            do {
                _ = try await client().states()
                XCTFail("expected error")
            } catch let e as HAError {
                guard case .unreachable = e else { return XCTFail("\(code): got \(e)") }
                XCTAssertTrue(e.isNetworkError)
                XCTAssertEqual(e.errorDescription, "HA unreachable")
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func testNonJSON200IsInvalidResponse() async {
        StubURLProtocol.handler = { _, _ in (200, Data("<html>proxy login</html>".utf8)) }
        await assertThrows(.invalidResponse) { _ = try await self.client().ping() }
        await assertThrows(.invalidResponse) {
            try await self.client().callService(ServiceCall(domain: "light", service: "turn_on", entityID: "light.lamp"))
        }
        await assertThrows(.invalidResponse) { _ = try await self.client().areas() }
        XCTAssertEqual(HAError.invalidResponse.errorDescription, "Unexpected response from HA")
    }

    func testOtherHTTPStatus() async {
        StubURLProtocol.handler = { _, _ in (500, Data("boom".utf8)) }
        await assertThrows(.http(status: 500, body: "boom")) { _ = try await self.client().states() }
        XCTAssertEqual(HAError.http(status: 500, body: "").errorDescription, "HTTP 500")
        XCTAssertFalse(HAError.http(status: 500, body: "").isNetworkError)
    }

    // MARK: - Live (opt-in, read-only)

    /// Runs only with WATCHMAGIC_HA_TOKEN set. READ-ONLY: never calls services.
    func testLiveReadOnly() async throws {
        guard let token = ProcessInfo.processInfo.environment["WATCHMAGIC_HA_TOKEN"], !token.isEmpty else {
            throw XCTSkip("set WATCHMAGIC_HA_TOKEN to run against http://homeassistant.local:8123")
        }
        let url = URL(string: ProcessInfo.processInfo.environment["WATCHMAGIC_HA_URL"] ?? "http://homeassistant.local:8123")!
        let live = HAClient(baseURL: url, token: token, timeout: 5)
        let msg = try await live.ping()
        XCTAssertFalse(msg.isEmpty)
        let states = try await live.controllableStates()
        XCTAssertTrue(states.allSatisfy { HAClient.controllableDomains.contains($0.domain) })
        let areas = try await live.areas()
        print("LIVE: ping=\(msg) controllable=\(states.count) areas=\(areas.map { "\($0.name)(\($0.entityIDs.count))" })")
        // No bad-token probe here: repeated failed logins can trigger HA's ip_ban.
    }
}
