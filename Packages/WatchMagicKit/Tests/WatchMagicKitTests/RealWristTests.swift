import XCTest
@testable import WatchMagicKit

/// Regression tests on real Apple Watch Ultra recordings (left wrist, crown
/// right, 50 Hz) from the phone-guided training session, plus the lock /
/// tolerance changes made from the same session's diagnostics.
final class RealWristTests: XCTestCase {

    private func fixture(_ name: String) throws -> [MotionSample] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"))
        return try MotionCSV.decode(String(contentsOf: url, encoding: .utf8))
    }

    func testRealTwistsAreAllDetected() throws {
        let samples = try fixture("real_twist5")
        for s in [GestureSensitivity.medium, .high] {
            let g = GestureDetector.detectAll(samples, pointingSign: 1, sensitivity: s)
            XCTAssertEqual(g.filter { $0.gesture == .twist }.count, 5, "@\(s): \(g.map(\.gesture))")
        }
    }

    func testEverydayMovementProducesNoTwist() throws {
        let samples = try fixture("real_everyday30s")
        for s in [GestureSensitivity.low, .medium] {
            let g = GestureDetector.detectAll(samples, pointingSign: 1, sensitivity: s)
            XCTAssertEqual(g.filter { $0.gesture == .twist }.count, 0, "@\(s): \(g)")
        }
    }

    func testLockKeepsWiderToleranceThanAcquire() {
        let id = UUID()
        // Pointing 20° off the device (rotate +x by 20° about z).
        let a = 20.0 * .pi / 180
        let pointing = Vector3(cos(a), sin(a), 0)
        let c = [TargetCandidate(id: id, direction: Vector3(1, 0, 0))]
        let s = Settings()
        XCTAssertEqual(TargetResolver.resolve(pointing: pointing, candidates: c, settings: s), .none)
        XCTAssertEqual(TargetResolver.resolve(pointing: pointing, candidates: c, settings: s, keepingLock: true).ids, [id])
    }

    func testV1ConfigOnOldDefaultToleranceIsMigrated() throws {
        let v1 = #"{"version":1,"settings":{"aimToleranceDeg":12}}"#
        let cfg = try AppConfig.fromJSON(Data(v1.utf8))
        XCTAssertEqual(cfg.settings.aimToleranceDeg, 15)
        XCTAssertEqual(cfg.version, AppConfig.currentVersion)
        // A user-chosen value is kept.
        let custom = try AppConfig.fromJSON(Data(#"{"version":1,"settings":{"aimToleranceDeg":20}}"#.utf8))
        XCTAssertEqual(custom.settings.aimToleranceDeg, 20)
    }

    func testCeilingFanPitchCanLock() {
        let id = UUID()
        let d = AimLockDetector()
        var events: [AimLockEvent] = []
        var t = 0.0
        while t < 0.5 {
            if let e = d.update(time: t, pitchDeg: 63, angularSpeed: 0.1, resolution: .locked(id: id, angleDeg: 3)) { events.append(e) }
            t += 0.02
        }
        XCTAssertEqual(events.first, .locked(id))
    }
}

extension RealWristTests {
    /// Live use: one-way snaps whose return is slow/small still count, once.
    func testTwistWithoutReturnFiresOnceAndSwallowsSlowReturn() {
        var g = TraceGenerator.twist()
        g.rollPulses = [Pulse(start: 1.0, duration: 0.2, amplitude: 14),
                        Pulse(start: 1.2, duration: 0.6, amplitude: -3)]
        XCTAssertEqual(GestureDetector.detectAll(g.generate(), pointingSign: 1, sensitivity: .high).map(\.gesture), [.twist])
        // A strong return right after must not toggle a second time.
        g.rollPulses = [Pulse(start: 1.0, duration: 0.18, amplitude: 15),
                        Pulse(start: 1.18, duration: 0.3, amplitude: -12)]
        XCTAssertEqual(GestureDetector.detectAll(g.generate(), pointingSign: 1, sensitivity: .high).map(\.gesture), [.twist])
    }
}

extension RealWristTests {
    /// Live log 11:43:24–25: twist toggled, the arm coming down 0.8 s later was
    /// a second "twist". After an acted gesture the twist must be re-armed by
    /// holding steady on the target again.
    func testTwistNeedsReAimAfterAGesture() {
        let id = UUID()
        let d = AimLockDetector()
        var t = 0.0
        func step(_ speed: Double, _ pitch: Double = 10, onTarget: Bool = true) {
            d.update(time: t, pitchDeg: pitch, angularSpeed: speed,
                     resolution: onTarget ? .locked(id: id, angleDeg: 3) : .none)
            t += 0.02
        }
        while t < 0.4 { step(0.1) }
        XCTAssertTrue(d.isLocked)
        XCTAssertTrue(d.twistArmed)
        d.noteGesture(at: t)
        XCTAssertFalse(d.twistArmed)
        // Arm moving (fast) for 0.5 s: still not armed.
        let end = t + 0.5
        while t < end { step(3.0, -20) }
        XCTAssertFalse(d.twistArmed)
        // Steady on target again for 0.35 s: armed.
        let end2 = t + 0.35
        while t < end2 { step(0.1) }
        XCTAssertTrue(d.twistArmed)
    }
}
