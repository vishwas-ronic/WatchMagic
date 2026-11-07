import XCTest
@testable import WatchMagicKit

// MARK: - Teach capture

final class TeachCaptureTests: XCTestCase {

    private var t = 0.0
    private let dt = 0.02 // 50 Hz

    /// Moves the arm once, then holds steady (cycling through `aims`) until the
    /// capture reports something other than progress.
    private func captureSample(_ tc: inout TeachCapture, aims: [Vector3]) -> TeachCapture.Event {
        t += dt
        _ = tc.process(t: t, pointing: aims[0], angularSpeed: 1.2) // re-aim movement
        for i in 0..<500 {
            t += dt
            let ev = tc.process(t: t, pointing: aims[i % aims.count], angularSpeed: 0.1)
            if case .progress = ev { continue }
            return ev
        }
        XCTFail("hold never completed")
        return .progress(samples: -1, hold: 0, needsReaim: false)
    }

    func testAcceptsThreeConsistentSamplesAndAverages() {
        var tc = TeachCapture()
        // Sample 1 jitters ±1° in yaw within its hold → its mean is yaw 10.
        let s1 = [Vector3(yawDeg: 9, pitchDeg: 5), Vector3(yawDeg: 11, pitchDeg: 5)]
        let s2 = [Vector3(yawDeg: 11.5, pitchDeg: 5)]
        let s3 = [Vector3(yawDeg: 12, pitchDeg: 6)]
        XCTAssertEqual(captureSample(&tc, aims: s1), .sampleCaptured(samples: 1))
        XCTAssertEqual(tc.samples[0].yawDeg, 10, accuracy: 0.05) // odd frame count → one extra 9° frame
        XCTAssertEqual(captureSample(&tc, aims: s2), .sampleCaptured(samples: 2))
        let ev = captureSample(&tc, aims: s3)
        guard case .finished(let v, let spread) = ev else { return XCTFail("\(ev)") }
        XCTAssertLessThanOrEqual(spread, TeachCapture.consistencyDeg)
        XCTAssertEqual(spread, TeachCapture.maxPairwiseAngleDeg(tc.samples), accuracy: 1e-9)
        XCTAssertEqual(v.norm, 1, accuracy: 1e-9)
        let expected = tc.samples.reduce(Vector3.zero, +).normalized
        XCTAssertLessThan(v.angle(to: expected), 1e-6)
        XCTAssertEqual(v.yawDeg, (10 + 11.5 + 12) / 3, accuracy: 0.05)
    }

    func testRejectsWhenOneSampleIsOffByMoreThan4Degrees() {
        var tc = TeachCapture()
        _ = captureSample(&tc, aims: [Vector3(yawDeg: 10, pitchDeg: 0)])
        _ = captureSample(&tc, aims: [Vector3(yawDeg: 11, pitchDeg: 0)])
        let ev = captureSample(&tc, aims: [Vector3(yawDeg: 15, pitchDeg: 0)])
        guard case .inconsistent(let spread) = ev else { return XCTFail("\(ev)") }
        XCTAssertEqual(spread, 5, accuracy: 0.01)
    }

    func testNoSampleWithoutReaimAndHoldTakesOneSecond() {
        var tc = TeachCapture()
        let v = Vector3(yawDeg: 0, pitchDeg: 0)
        for i in 1...150 { // 3 s steady, never moved
            XCTAssertEqual(tc.process(t: Double(i) * dt, pointing: v, angularSpeed: 0.1),
                           .progress(samples: 0, hold: 0, needsReaim: true))
        }
        _ = tc.process(t: 3.02, pointing: v, angularSpeed: 1.0)
        XCTAssertEqual(tc.process(t: 3.04, pointing: v, angularSpeed: 0.1), .progress(samples: 0, hold: 0, needsReaim: false))
        guard case .progress(_, let hold, _) = tc.process(t: 3.54, pointing: v, angularSpeed: 0.1) else { return XCTFail() }
        XCTAssertEqual(hold, 0.5, accuracy: 1e-6)
        XCTAssertEqual(tc.process(t: 4.04, pointing: v, angularSpeed: 0.1), .sampleCaptured(samples: 1))
    }

    func testEvaluateBoundary() {
        let a = Vector3(yawDeg: 0, pitchDeg: 0)
        if case .finished = TeachCapture.evaluate([a, Vector3(yawDeg: 3.9, pitchDeg: 0), a]) {} else { XCTFail() }
        if case .inconsistent = TeachCapture.evaluate([a, Vector3(yawDeg: 4.1, pitchDeg: 0), a]) {} else { XCTFail() }
    }
}

// MARK: - Zero gesture

final class ZeroHoldDetectorTests: XCTestCase {

    private let anchor = Vector3(yawDeg: 30, pitchDeg: 10)

    /// Optional movement at t=0, then a steady hold for `seconds` at 50 Hz.
    /// Returns the first correction (and its time), if any.
    private func run(move: Bool, raw: Vector3, armPitch: Double = 10, seconds: Double = 3,
                     anchor: Vector3? = nil) -> (correction: Double, t: Double)? {
        var z = ZeroHoldDetector()
        let a = anchor ?? self.anchor
        if move { _ = z.process(t: 0, rawPointing: raw, pitchDeg: armPitch, angularSpeed: 1.5, anchor: a) }
        var t = 0.0
        while t < seconds {
            t += 0.02
            if let c = z.process(t: t, rawPointing: raw, pitchDeg: armPitch, angularSpeed: 0.1, anchor: a).correctionDeg {
                return (c, t)
            }
        }
        return nil
    }

    func testFiresAfterMoveAndHold() throws {
        let r = try XCTUnwrap(run(move: true, raw: Vector3(yawDeg: -50, pitchDeg: 12)))
        XCTAssertEqual(r.correction, 80, accuracy: 1e-6) // 30 − (−50)
        XCTAssertEqual(r.t, 0.02 + ZeroHoldDetector.holdDuration, accuracy: 0.03)
        // Applying the correction to raw pointing lines it up with the anchor's yaw.
        XCTAssertEqual(Vector3(yawDeg: -50, pitchDeg: 12).rotatedAboutZ(deg: r.correction).yawDeg, 30, accuracy: 1e-6)
    }

    func testCorrectionWrapsAcross180() throws {
        let r = try XCTUnwrap(run(move: true, raw: Vector3(yawDeg: -170, pitchDeg: 10),
                                  anchor: Vector3(yawDeg: 170, pitchDeg: 10)))
        XCTAssertEqual(r.correction, -20, accuracy: 1e-6)
    }

    func testDoesNotFireWithoutPrecedingMovement() {
        XCTAssertNil(run(move: false, raw: Vector3(yawDeg: -50, pitchDeg: 12)))
    }

    func testDoesNotFireWhenPitchIsOffByMoreThan20Degrees() {
        XCTAssertNil(run(move: true, raw: Vector3(yawDeg: -50, pitchDeg: 31), armPitch: 31))
        XCTAssertNil(run(move: true, raw: Vector3(yawDeg: -50, pitchDeg: -11), armPitch: -11))
        XCTAssertNotNil(run(move: true, raw: Vector3(yawDeg: -50, pitchDeg: 29), armPitch: 29))
    }

    func testFiresOnceThenNeedsNewMovement() {
        var z = ZeroHoldDetector()
        let raw = Vector3(yawDeg: 0, pitchDeg: 10)
        _ = z.process(t: 0, rawPointing: raw, pitchDeg: 10, angularSpeed: 1.5, anchor: anchor)
        var fired = 0
        var t = 0.0
        while t < 6 {
            t += 0.02
            if z.process(t: t, rawPointing: raw, pitchDeg: 10, angularSpeed: 0.1, anchor: anchor).correctionDeg != nil { fired += 1 }
        }
        XCTAssertEqual(fired, 1)
    }
}

// MARK: - Heading anchor

final class HeadingAnchorTests: XCTestCase {

    private let level = Vector3(yawDeg: 40, pitchDeg: 0) // raw-frame top axis

    func testFirstReadingSetsOffset() {
        var a = HeadingAnchor()
        XCTAssertEqual(a.compassUpdate(headingDeg: 100, accuracyDeg: 10, deviceTop: level, angularSpeed: 0.1), .anchored)
        XCTAssertTrue(a.isAnchored)
        XCTAssertEqual(a.compassUpdates, 1)
        XCTAssertEqual(a.offsetDeg, -140, accuracy: 1e-9) // −100 − 40
        // The corrected top axis now has the compass heading.
        XCTAssertEqual(level.rotatedAboutZ(deg: a.offsetDeg).compassHeadingDeg, 100, accuracy: 1e-9)
    }

    func testBlendingConverges() {
        var a = HeadingAnchor()
        a.compassUpdate(headingDeg: 100, accuracyDeg: 10, deviceTop: level, angularSpeed: 0.1)
        XCTAssertEqual(a.compassUpdate(headingDeg: 110, accuracyDeg: 10, deviceTop: level, angularSpeed: 0.1), .blended)
        XCTAssertEqual(a.offsetDeg, -140.5, accuracy: 1e-9) // 5% of the way to −150
        for _ in 0..<300 { a.compassUpdate(headingDeg: 110, accuracyDeg: 10, deviceTop: level, angularSpeed: 0.1) }
        XCTAssertEqual(a.offsetDeg, -150, accuracy: 1e-3)
    }

    func testBlendTakesShortWayAcross180() {
        let top = Vector3(yawDeg: 0, pitchDeg: 0)
        var a = HeadingAnchor()
        a.compassUpdate(headingDeg: 185, accuracyDeg: 5, deviceTop: top, angularSpeed: 0)
        XCTAssertEqual(a.offsetDeg, 175, accuracy: 1e-9)
        a.compassUpdate(headingDeg: 175, accuracyDeg: 5, deviceTop: top, angularSpeed: 0) // target −175
        XCTAssertEqual(a.offsetDeg, 175.5, accuracy: 1e-9) // +10° the short way, not −350°
        for _ in 0..<300 { a.compassUpdate(headingDeg: 175, accuracyDeg: 5, deviceTop: top, angularSpeed: 0) }
        XCTAssertEqual(Angle.normalizedDeg(a.offsetDeg - -175), 0, accuracy: 1e-3)
        XCTAssertEqual(HeadingAnchor.blend(from: -179, to: 179, alpha: 0.5), 180, accuracy: 1e-9)
    }

    func testRejectsBadReadingsWithoutChangingState() {
        var a = HeadingAnchor()
        XCTAssertEqual(a.compassUpdate(headingDeg: 90, accuracyDeg: -1, deviceTop: level, angularSpeed: 0), .rejected(.invalidHeading))
        XCTAssertEqual(a.compassUpdate(headingDeg: 90, accuracyDeg: 25, deviceTop: level, angularSpeed: 0), .rejected(.poorAccuracy))
        XCTAssertEqual(a.compassUpdate(headingDeg: 90, accuracyDeg: 5, deviceTop: nil, angularSpeed: 0), .rejected(.noAttitude))
        XCTAssertEqual(a.compassUpdate(headingDeg: 90, accuracyDeg: 5, deviceTop: Vector3(yawDeg: 0, pitchDeg: 35), angularSpeed: 0),
                       .rejected(.topAxisTooTilted))
        XCTAssertEqual(a.compassUpdate(headingDeg: 90, accuracyDeg: 5, deviceTop: Vector3(yawDeg: 0, pitchDeg: -35), angularSpeed: 0),
                       .rejected(.topAxisTooTilted))
        XCTAssertEqual(a.compassUpdate(headingDeg: 90, accuracyDeg: 5, deviceTop: level, angularSpeed: 0.6), .rejected(.notSteady))
        XCTAssertEqual(a, HeadingAnchor())
        // Boundaries accepted: accuracy 20°, top 25° tilted.
        XCTAssertEqual(a.compassUpdate(headingDeg: 90, accuracyDeg: 20, deviceTop: Vector3(yawDeg: 0, pitchDeg: 25), angularSpeed: 0.4),
                       .anchored)
        // Rejected readings don't move an existing anchor either.
        let before = a.offsetDeg
        XCTAssertFalse(a.compassUpdate(headingDeg: 0, accuracyDeg: 30, deviceTop: level, angularSpeed: 0).accepted)
        XCTAssertEqual(a.offsetDeg, before)
    }

    func testSetResetAndTopAxis() {
        var a = HeadingAnchor()
        a.set(offsetDeg: 370)
        XCTAssertTrue(a.isAnchored)
        XCTAssertEqual(a.offsetDeg, 10, accuracy: 1e-9)
        a.reset()
        XCTAssertFalse(a.isAnchored)
        XCTAssertEqual(a.offsetDeg, 0)
        a.markAnchored()
        XCTAssertTrue(a.isAnchored)
        let identity = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
        XCTAssertEqual(HeadingAnchor.deviceTopAxis(rotationMatrix: identity), .unitY)
        XCTAssertEqual(HeadingAnchor.deviceTopAxis(rotationMatrix: []), .zero)
    }
}

// MARK: - Trace recorder

final class TraceRecorderTests: XCTestCase {
    func testStopsAfterDuration() {
        var r = TraceRecorder(duration: 1)
        XCTAssertEqual(r.remaining(at: 5), 1)
        var t = 10.0
        var done = false
        while !done {
            done = r.append(MotionSample(t: t, rotationRate: .zero, gravity: Vector3(0, 0, -1)))
            t += 0.02
        }
        XCTAssertEqual(r.samples.count, 51, accuracy: 1)
        XCTAssertEqual(r.remaining(at: 10.25), 0.75, accuracy: 1e-9)
    }
}

// MARK: - Relayed state fetch payload

final class RelayStatePayloadTests: XCTestCase {
    func testRelayStateRequestRoundTrip() throws {
        let req = RelayStateRequest(entityID: "fan.ceiling_1")
        let dict = try req.dictionary()
        XCTAssertTrue(PropertyListSerialization.propertyList(dict, isValidFor: .binary))
        XCTAssertEqual(SyncPayload.kind(of: dict), .relayStateRequest)
        XCTAssertEqual(try RelayStateRequest(dictionary: dict), req)
        // Not confusable with a service-call relay, in either direction.
        XCTAssertThrowsError(try RelayRequest(dictionary: dict))
        let callDict = try RelayRequest(call: ServiceCall(domain: "fan", service: "turn_on", entityID: "fan.ceiling_1")).dictionary()
        XCTAssertThrowsError(try RelayStateRequest(dictionary: callDict))

        let reply = RelayResponse(states: [EntityState(entityID: "fan.ceiling_1", state: "on", attributes: ["percentage": .int(33)])])
        XCTAssertEqual(try RelayResponse(dictionary: reply.dictionary()), reply)
    }

    func testOnlyControllableEntityIDsAllowed() {
        for ok in ["light.desk", "fan.ceiling_1", "switch.plug_2"] {
            XCTAssertTrue(RelayStateRequest(entityID: ok).isAllowed, ok)
        }
        for bad in ["lock.front_door", "sensor.temp", "light.", "light", "light.desk/../x", "light.a.b",
                    "Light.desk", "light.desk?x=1", "", "climate.hall"] {
            XCTAssertFalse(RelayStateRequest(entityID: bad).isAllowed, bad)
        }
    }

    func testRelayRequestAllowsOnlyMapperServices() {
        func req(_ d: String, _ s: String, _ e: String) -> RelayRequest {
            RelayRequest(call: ServiceCall(domain: d, service: s, entityID: e))
        }
        XCTAssertTrue(req("light", "turn_on", "light.lamp").isAllowed)
        XCTAssertTrue(req("fan", "increase_speed", "fan.papa_fan").isAllowed)
        XCTAssertTrue(req("homeassistant", "toggle", "switch.tv_lights").isAllowed)
        XCTAssertFalse(req("light", "../../config", "light.lamp").isAllowed)
        XCTAssertFalse(req("switch", "increase_speed", "switch.x").isAllowed)
        XCTAssertFalse(req("lock", "unlock", "lock.front").isAllowed)
        XCTAssertFalse(req("light", "turn_on", "lock.front").isAllowed)
        XCTAssertFalse(req("light", "turn_on", "light.a/../b").isAllowed)
        // Every call the mapper can produce must be relayable.
        let devices = [("light.l", DeviceKind.dimmableLight), ("light.o", .onOffLight), ("switch.s", .switch), ("fan.f", .fan)]
        for (id, kind) in devices {
            let dev = ControlledDevice(entityID: id, name: id, kind: kind)
            for g in [Gesture.flickUp, .flickDown, .twist] {
                for st in ["on", "off"] {
                    let state = EntityState(entityID: id, state: st, attributes: ["brightness": .int(200), "percentage": .int(50)])
                    if let call = ActionMapper.map(gesture: g, device: dev, state: state, settings: Settings()) {
                        XCTAssertTrue(RelayRequest(call: call).isAllowed, "\(call.serviceName) on \(id)")
                    }
                }
            }
        }
    }
}
