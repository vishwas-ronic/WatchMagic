import XCTest
@testable import WatchMagicKit

final class AimLockDetectorTests: XCTestCase {
    private let a = UUID(), b = UUID()

    /// Feeds `duration` seconds at 100 Hz starting at `from`; returns the non-nil, non-stillLocked events.
    @discardableResult
    private func feed(_ d: AimLockDetector, from: Double, duration: Double, pitch: Double = 5,
                      speed: Double = 0.1, _ r: Resolution) -> [AimLockEvent] {
        var events: [AimLockEvent] = []
        var t = from
        while t < from + duration - 1e-9 {
            if let e = d.update(time: t, pitchDeg: pitch, angularSpeed: speed, resolution: r), e != .stillLocked {
                events.append(e)
            }
            t += 0.01
        }
        return events
    }

    func testLocksAfterAimHold() {
        let d = AimLockDetector(settings: Settings())
        XCTAssertEqual(feed(d, from: 0, duration: 0.25, .locked(id: a, angleDeg: 3)), [])
        XCTAssertEqual(feed(d, from: 0.25, duration: 0.1, .locked(id: a, angleDeg: 3)), [.locked(a)])
        XCTAssertTrue(d.isGestureWindowOpen(at: 0.4))
        XCTAssertEqual(d.target(forGestureAt: 0.4), a)
    }

    func testNoLockWhenMovingArmLoweredOrTargetChanges() {
        let d = AimLockDetector()
        XCTAssertEqual(feed(d, from: 0, duration: 1, speed: 1.0, .locked(id: a, angleDeg: 3)), [])   // not steady
        XCTAssertEqual(feed(d, from: 1, duration: 1, pitch: -50, .locked(id: a, angleDeg: 3)), [])   // arm down
        XCTAssertEqual(feed(d, from: 2, duration: 1, pitch: 80, .locked(id: a, angleDeg: 3)), [])    // too high
        XCTAssertEqual(feed(d, from: 3, duration: 1, .none), [])
        // alternating targets never hold for 300 ms
        for i in 0..<10 {
            XCTAssertEqual(feed(d, from: 4 + Double(i) * 0.2, duration: 0.2, .locked(id: i.isMultiple(of: 2) ? a : b, angleDeg: 3)), [])
        }
        XCTAssertFalse(d.isLocked)
    }

    func testGestureSpikeDoesNotDropLock() {
        let d = AimLockDetector()
        feed(d, from: 0, duration: 0.5, .locked(id: a, angleDeg: 3))
        XCTAssertTrue(d.isLocked)
        // 250 ms flick: fast, pitch swings, resolution lost
        XCTAssertEqual(feed(d, from: 0.5, duration: 0.25, pitch: 30, speed: 6, .none), [])
        d.noteGesture(at: 0.75)
        XCTAssertEqual(feed(d, from: 0.75, duration: 0.3, pitch: -10, speed: 2, .none), [])
        XCTAssertEqual(feed(d, from: 1.05, duration: 0.5, .locked(id: a, angleDeg: 2)), [])
        XCTAssertEqual(d.lockedID, a)
        XCTAssertTrue(d.isGestureWindowOpen(at: 2.0)) // reopened at 0.75 + 1.5 > 2.0
    }

    func testUnlocksWhenArmDrops() {
        let d = AimLockDetector()
        feed(d, from: 0, duration: 0.5, .locked(id: a, angleDeg: 3))
        XCTAssertEqual(feed(d, from: 0.5, duration: 0.2, pitch: -60, speed: 2, .none), [])
        XCTAssertEqual(feed(d, from: 0.7, duration: 0.2, pitch: -60, speed: 2, .none), [.unlocked])
        XCTAssertNil(d.target(forGestureAt: 1.0))
    }

    func testUnlocksWhenSteadyOnAnotherTarget() {
        let d = AimLockDetector()
        feed(d, from: 0, duration: 0.5, .locked(id: a, angleDeg: 3))
        let ev = feed(d, from: 0.5, duration: 1.0, .locked(id: b, angleDeg: 3))
        XCTAssertEqual(ev.first, .unlocked)
        XCTAssertEqual(ev.last, .locked(b)) // re-locks on b after a further aim-hold
    }

    func testGestureWindowClosesAndReArmsWhenHoldingSteady() {
        var cfg = AimLockDetector.Configuration()
        cfg.gestureWindow = 1.0
        let d = AimLockDetector(configuration: cfg)
        feed(d, from: 0, duration: 0.31, .locked(id: a, angleDeg: 3))
        XCTAssertTrue(d.isLocked)
        // Wobbly but on target: window closes after 1 s.
        feed(d, from: 0.31, duration: 1.2, speed: 0.9, .locked(id: a, angleDeg: 3))
        XCTAssertTrue(d.isLocked)
        XCTAssertFalse(d.isGestureWindowOpen(at: 1.5))
        XCTAssertNil(d.target(forGestureAt: 1.5))
        // Hold steady again for the aim-hold → window re-arms.
        feed(d, from: 1.51, duration: 0.35, .locked(id: a, angleDeg: 3))
        XCTAssertTrue(d.isGestureWindowOpen(at: 1.86))
    }

    func testAmbiguousLockAndCrownSelection() {
        let d = AimLockDetector()
        let ev = feed(d, from: 0, duration: 0.4, .ambiguous([a, b]))
        XCTAssertEqual(ev, [.locked(a)])
        XCTAssertTrue(d.lock?.isAmbiguous ?? false)
        XCTAssertEqual(d.selectNext(), b)
        XCTAssertEqual(d.target(forGestureAt: 0.5), b)
        XCTAssertEqual(d.selectNext(), a)  // wraps
        XCTAssertEqual(d.selectPrevious(), b)
        // Resolution flickering between the two (or to a single one of them) keeps the lock.
        XCTAssertEqual(feed(d, from: 0.4, duration: 1, .locked(id: a, angleDeg: 4)), [])
        XCTAssertEqual(d.lockedID, b)
    }
}

final class ModelAndSyncTests: XCTestCase {

    func testConfigDecodingToleratesMissingKeys() throws {
        let cfg = try AppConfig.fromJSON(Data("{}".utf8))
        XCTAssertEqual(cfg, AppConfig())
        XCTAssertEqual(cfg.haURL.absoluteString, "http://homeassistant.local:8123")
        XCTAssertEqual(cfg.settings.brightnessStepPct, 20)
        XCTAssertNil(cfg.settings.fanStepPct)
        XCTAssertEqual(cfg.settings.aimToleranceDeg, 15)
        XCTAssertFalse(cfg.settings.flicksEnabled)
        XCTAssertEqual(cfg.settings.ambiguityMarginDeg, 5)
        XCTAssertEqual(cfg.settings.aimHoldMs, 300)
        XCTAssertEqual(cfg.settings.gestureWindowS, 1.5)
        XCTAssertEqual(cfg.settings.sensitivity, .medium)
        XCTAssertTrue(cfg.settings.flickDownAtMinimumTurnsOff)

        let partial = #"""
        {"version":1,"futureField":{"x":1},"rooms":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Bed"}],
         "devices":[{"entityID":"light.lamp","name":"Lamp"}],"settings":{"brightnessStepPct":10,"sensitivity":"ludicrous"}}
        """#
        let p = try AppConfig.fromJSON(Data(partial.utf8))
        XCTAssertEqual(p.rooms.first?.deviceIDs, [])
        XCTAssertEqual(p.devices.first?.kind, .onOffLight)
        XCTAssertEqual(p.devices.first?.calibrationStatus, .notPlaced)
        XCTAssertEqual(p.settings.brightnessStepPct, 10)
        XCTAssertEqual(p.settings.sensitivity, .medium)
    }

    func testConfigRoundTripAndHelpers() throws {
        let dev = ControlledDevice(entityID: "fan.ceiling", name: "Fan", kind: .fan, kindOverridden: true,
                                   coordinates: Vector3(1, 2, 3))
        let room = Room(name: "Bedroom", haAreaID: "bedroom", seat: .zero, deviceIDs: [dev.id])
        var cfg = AppConfig(rooms: [room], devices: [dev], currentRoomID: room.id, settings: Settings(fanStepPct: 25))
        XCTAssertEqual(try AppConfig.fromJSON(cfg.jsonData()), cfg)
        XCTAssertEqual(cfg.currentRoom?.name, "Bedroom")
        XCTAssertEqual(cfg.devices(in: room).map(\.id), [dev.id])
        XCTAssertEqual(dev.domain, "fan")
        XCTAssertEqual(dev.calibrationStatus, .coordinatesOnly)
        XCTAssertTrue(cfg.setTaughtVector(Vector3(2, 0, 0), forDevice: dev.id))
        XCTAssertEqual(cfg.device(id: dev.id)?.taughtVector, Vector3(1, 0, 0))
        XCTAssertEqual(cfg.device(id: dev.id)?.calibrationStatus, .taught)
        XCTAssertFalse(cfg.setTaughtVector(nil, forDevice: UUID()))
    }

    func testConfigContextRoundTrip() throws {
        let cfg = AppConfig(rooms: [Room(name: "Office")])
        let ctx = ConfigContext(config: cfg, token: "abc", sentAt: Date(timeIntervalSince1970: 1_000))
        let dict = try ctx.dictionary()
        XCTAssertTrue(PropertyListSerialization.propertyList(dict, isValidFor: .binary))
        XCTAssertEqual(SyncPayload.kind(of: dict), .config)
        XCTAssertEqual(try ConfigContext(dictionary: dict), ctx)
        XCTAssertThrowsError(try ConfigContext(dictionary: ["kind": "config"]))
        XCTAssertThrowsError(try TaughtVectorUpdate(dictionary: dict))
    }

    func testTaughtVectorAndRelayRoundTrips() throws {
        let tv = TaughtVectorUpdate(deviceID: UUID(), roomID: UUID(), vector: Vector3(0, 1, 0))
        let tvDict = try tv.dictionary()
        XCTAssertTrue(PropertyListSerialization.propertyList(tvDict, isValidFor: .binary))
        XCTAssertEqual(try TaughtVectorUpdate(dictionary: tvDict), tv)
        let clear = TaughtVectorUpdate(deviceID: UUID(), roomID: UUID(), vector: nil)
        XCTAssertNil(try TaughtVectorUpdate(dictionary: clear.dictionary()).vector)

        let req = RelayRequest(call: ServiceCall(domain: "light", service: "turn_on", entityID: "light.a",
                                                 data: ["brightness_step_pct": .int(-20)]))
        let reqDict = try req.dictionary()
        XCTAssertEqual(SyncPayload.kind(of: reqDict), .relayRequest)
        XCTAssertEqual(try RelayRequest(dictionary: reqDict), req)

        let ok = RelayResponse(states: [EntityState(entityID: "light.a", state: "on", attributes: ["brightness": .int(10)])])
        XCTAssertEqual(try RelayResponse(dictionary: ok.dictionary()), ok)
        let fail = RelayResponse(errorMessage: HAError.unauthorized.errorDescription)
        let decoded = try RelayResponse(dictionary: fail.dictionary())
        XCTAssertFalse(decoded.isSuccess)
        XCTAssertEqual(decoded.errorMessage, "401 – token invalid")

        XCTAssertEqual(SyncPayload.kind(of: SyncPayload.traceMetadata(fileName: "t.csv")), .trace)
    }
}
