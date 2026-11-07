import XCTest
@testable import WatchMagicKit

final class RollKnobTests: XCTestCase {

    /// Device-frame gravity for a horizontal forearm (p = +x) rolled by `deg`
    /// about p: the device turns +θ, so gravity turns −θ in the device frame.
    private func gravity(rolledBy deg: Double) -> Vector3 {
        let a = deg * .pi / 180
        return Vector3(0, -sin(a), -cos(a))
    }

    /// Feeds a roll profile at 50 Hz; returns (time, event) pairs.
    private func run(_ knob: inout RollKnob, wristIsLeft: Bool, from t0: Double = 0, duration: Double,
                     speed: Double = 0.2, roll: (Double) -> Double) -> [(Double, RollKnob.Event)] {
        var out: [(Double, RollKnob.Event)] = []
        var t = t0
        while t < t0 + duration {
            if let e = knob.update(t: t, gravity: gravity(rolledBy: roll(t)), pointingSign: 1,
                                   wristIsLeft: wristIsLeft, angularSpeed: speed) {
                out.append((t, e))
            }
            t += 0.02
        }
        return out
    }

    func testRightWristPalmUpStepsUpRepeatedlyThenReleases() {
        var k = RollKnob()
        k.setBaseline(gravity: gravity(rolledBy: 0), pointingSign: 1)
        // Right arm: supination = +roll. Hold +40° for 2 s.
        let ev = run(&k, wristIsLeft: false, duration: 2) { _ in 40 }
        let steps = ev.compactMap { if case .step(let s) = $0.1 { return s } else { return nil } }
        XCTAssertEqual(steps.first, 1)
        // First at 0.4 s, then every 0.6 s → 0.4, 1.0, 1.6.
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(ev.first!.0, 0.4, accuracy: 0.03)
        let back = run(&k, wristIsLeft: false, from: 2, duration: 0.5) { _ in 5 }
        XCTAssertEqual(back.map(\.1), [.released])
        XCTAssertFalse(k.isEngaged)
    }

    func testLeftWristIsMirrored() {
        var k = RollKnob()
        k.setBaseline(gravity: gravity(rolledBy: 0), pointingSign: 1)
        // Left arm: supination = −roll (the user's real twists were −roll = palm up).
        let up = run(&k, wristIsLeft: true, duration: 0.6) { _ in -40 }
        XCTAssertEqual(up.first?.1, .step(1))
        var k2 = RollKnob()
        k2.setBaseline(gravity: gravity(rolledBy: 0), pointingSign: 1)
        let down = run(&k2, wristIsLeft: true, duration: 0.6) { _ in 40 }
        XCTAssertEqual(down.first?.1, .step(-1))
    }

    func testFastSnapDoesNotEngage() {
        var k = RollKnob()
        k.setBaseline(gravity: gravity(rolledBy: 0), pointingSign: 1)
        let ev = run(&k, wristIsLeft: false, duration: 1, speed: 12) { _ in 80 }
        XCTAssertTrue(ev.isEmpty)
    }

    func testSmallRollOrShortHoldDoesNothing() {
        var k = RollKnob()
        k.setBaseline(gravity: gravity(rolledBy: 0), pointingSign: 1)
        XCTAssertTrue(run(&k, wristIsLeft: false, duration: 2) { _ in 20 }.isEmpty)
        XCTAssertTrue(run(&k, wristIsLeft: false, from: 2, duration: 0.3) { _ in 45 }.isEmpty)
    }

    func testAfterResetARotatedRestingWristBecomesTheBaseline() {
        var k = RollKnob()
        k.reset()
        // Wrist left at 40° after a snap: settles → new baseline, no stepping.
        let ev = run(&k, wristIsLeft: false, duration: 2) { _ in 40 }
        XCTAssertTrue(ev.isEmpty)
        XCTAssertEqual(k.angleDeg ?? 99, 0, accuracy: 0.5)
    }

    func testRealTwistsDoNotEngageTheKnob() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "real_twist5", withExtension: "csv", subdirectory: "Fixtures"))
        let samples = try MotionCSV.decode(String(contentsOf: url, encoding: .utf8))
        var k = RollKnob()
        var steps = 0
        for s in samples {
            let speed = s.rotationRate.norm
            if case .step = k.update(t: s.t, gravity: s.gravity, pointingSign: 1, wristIsLeft: true, angularSpeed: speed) {
                steps += 1
            }
        }
        XCTAssertEqual(steps, 0)
    }
}

final class AimLearningTests: XCTestCase {
    func testBlendMovesPartWayAndRejectsFarOff() {
        let r = Vector3(1, 0, 0)
        let a = 10.0 * .pi / 180
        let o = Vector3(cos(a), sin(a), 0)
        let n = try! XCTUnwrap(AimLearning.blend(reference: r, observed: o))
        XCTAssertEqual(r.angle(to: n), 3.5, accuracy: 0.3)
        let far = Vector3(cos(0.6), sin(0.6), 0) // ~34°
        XCTAssertNil(AimLearning.blend(reference: r, observed: far))
    }

    func testRepeatedConfirmationsConverge() {
        var r = Vector3(1, 0, 0)
        let a = 12.0 * .pi / 180
        let o = Vector3(cos(a), sin(a), 0)
        for _ in 0..<6 { r = AimLearning.blend(reference: r, observed: o)! }
        XCTAssertLessThan(r.angle(to: o), 1.0)
    }

    func testPointingAverage() {
        var p = PointingAverage()
        XCTAssertNil(p.mean)
        p.add(Vector3(1, 0, 0)); p.add(Vector3(0, 1, 0))
        XCTAssertEqual(p.mean!.angle(to: Vector3(1, 1, 0)), 0, accuracy: 1e-6)
    }
}

extension RollKnobTests {
    /// Live log: turning the wrist to look at the watch (~90–140°) sent 13 steps.
    func testLookingAtTheWatchDoesNotStep() {
        var k = RollKnob()
        k.setBaseline(gravity: Vector3(0, 0, -1), pointingSign: 1)
        var t = 0.0, steps = 0
        while t < 3 {
            let a = 95.0 * .pi / 180
            if case .step = k.update(t: t, gravity: Vector3(0, -sin(a), -cos(a)), pointingSign: 1,
                                     wristIsLeft: true, angularSpeed: 0.2) { steps += 1 }
            t += 0.02
        }
        XCTAssertEqual(steps, 0)
    }
}
