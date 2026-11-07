import XCTest
@testable import WatchMagicKit

final class GestureDetectorTests: XCTestCase {

    /// Left wrist + crown right (+1) and right wrist + crown left… rotated
    /// mounting (−1): the detector must behave identically.
    private let mountings: [Double] = [
        ForearmGeometry.pointingSign(wristIsLeft: true, crownIsRight: true),   // +1
        ForearmGeometry.pointingSign(wristIsLeft: true, crownIsRight: false),  // −1
    ]

    // MARK: - Fixture CSVs (Tests/WatchMagicKitTests/Fixtures, generated with sign +1)

    private func fixture(_ name: String) throws -> [MotionSample] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"),
                                "missing fixture \(name).csv")
        return try MotionCSV.decode(String(contentsOf: url, encoding: .utf8))
    }

    func testFixtureFlickUp() throws {
        let g = GestureDetector.detectAll(try fixture("flick_up"), pointingSign: 1)
        XCTAssertEqual(g.map(\.gesture), [.flickUp])
        XCTAssertGreaterThan(g.first?.peakRate ?? 0, 5)
    }

    func testFixtureFlickDown() throws {
        XCTAssertEqual(GestureDetector.detectAll(try fixture("flick_down"), pointingSign: 1).map(\.gesture), [.flickDown])
    }

    func testFixtureTwist() throws {
        XCTAssertEqual(GestureDetector.detectAll(try fixture("twist"), pointingSign: 1).map(\.gesture), [.twist])
    }

    func testFixtureSlowMovementsProduceNothing() throws {
        for name in ["slow_raise", "slow_rotate"] {
            for s in GestureSensitivity.allCases {
                let g = GestureDetector.detectAll(try fixture(name), pointingSign: 1, sensitivity: s)
                XCTAssertTrue(g.isEmpty, "\(name) @\(s): \(g)")
            }
        }
    }

    func testFixturesLoadAtAbout100Hz() throws {
        let s = try fixture("flick_up")
        XCTAssertGreaterThan(s.count, 200)
        let dt = (s.last!.t - s.first!.t) / Double(s.count - 1)
        XCTAssertEqual(dt, 0.01, accuracy: 0.001)
    }

    // MARK: - In-memory synthetic traces, both mountings

    func testFlicksAndTwistBothMountings() {
        for sign in mountings {
            XCTAssertEqual(GestureDetector.detectAll(TraceGenerator.flickUp(sign: sign).generate(), pointingSign: sign).map(\.gesture),
                           [.flickUp], "sign \(sign)")
            XCTAssertEqual(GestureDetector.detectAll(TraceGenerator.flickDown(sign: sign).generate(), pointingSign: sign).map(\.gesture),
                           [.flickDown], "sign \(sign)")
            XCTAssertEqual(GestureDetector.detectAll(TraceGenerator.twist(sign: sign).generate(), pointingSign: sign).map(\.gesture),
                           [.twist], "sign \(sign)")
        }
    }

    func testRightWristCrownLeftUsesPlusOne() {
        XCTAssertEqual(ForearmGeometry.pointingSign(wristIsLeft: false, crownIsRight: false), 1)
        XCTAssertEqual(ForearmGeometry.pointingSign(wristIsLeft: false, crownIsRight: true), -1)
    }

    func testReverseTwistDirectionAlsoDetected() {
        var g = TraceGenerator.twist()
        g.rollPulses = g.rollPulses.map { Pulse(start: $0.start, duration: $0.duration, amplitude: -$0.amplitude) }
        XCTAssertEqual(GestureDetector.detectAll(g.generate(), pointingSign: 1).map(\.gesture), [.twist])
    }

    func testWrongSignInvertsFlick() {
        // Sanity: feeding a −1-mounted trace with the wrong sign flips up/down,
        // proving the sign actually matters.
        let s = TraceGenerator.flickUp(sign: -1).generate()
        XCTAssertEqual(GestureDetector.detectAll(s, pointingSign: 1).map(\.gesture), [.flickDown])
    }

    func testSlowMovementsBothMountingsAllSensitivities() {
        for sign in mountings {
            for s in GestureSensitivity.allCases {
                XCTAssertTrue(GestureDetector.detectAll(TraceGenerator.slowRaise(sign: sign).generate(), pointingSign: sign, sensitivity: s).isEmpty)
                XCTAssertTrue(GestureDetector.detectAll(TraceGenerator.slowRotate(sign: sign).generate(), pointingSign: sign, sensitivity: s).isEmpty)
            }
        }
    }

    func testNoiseOnlyProducesNothing() {
        var g = TraceGenerator(duration: 5)
        g.gyroNoise = 0.15
        XCTAssertTrue(GestureDetector.detectAll(g.generate(), pointingSign: 1, sensitivity: .high).isEmpty)
    }

    func testAllSensitivitiesDetectStandardFlick() {
        for s in GestureSensitivity.allCases {
            XCTAssertEqual(GestureDetector.detectAll(TraceGenerator.flickUp().generate(), pointingSign: 1, sensitivity: s).map(\.gesture),
                           [.flickUp], "\(s)")
        }
    }

    func testWeakFlickOnlyDetectedAtHighSensitivity() {
        var g = TraceGenerator.flickUp()
        g.pitchPulses = [Pulse(start: 1, duration: 0.1, amplitude: 3.2), Pulse(start: 1.1, duration: 0.16, amplitude: -1.8)]
        let s = g.generate()
        XCTAssertTrue(GestureDetector.detectAll(s, pointingSign: 1, sensitivity: .medium).isEmpty)
        XCTAssertEqual(GestureDetector.detectAll(s, pointingSign: 1, sensitivity: .high).map(\.gesture), [.flickUp])
    }

    // MARK: - Debounce

    func testTwoFlicks100msApartGiveOneGesture() {
        var g = TraceGenerator.flickUp(duration: 3)
        // Second flick starts 100 ms after the first one's motion ends (t0 + 0.26).
        g.pitchPulses = TraceGenerator.flickUpPulses(1.0) + TraceGenerator.flickUpPulses(1.36)
        XCTAssertEqual(GestureDetector.detectAll(g.generate(), pointingSign: 1).map(\.gesture), [.flickUp])
    }

    func testTwoFlicksOneSecondApartGiveTwoGestures() {
        var g = TraceGenerator.flickUp(duration: 3.5)
        g.pitchPulses = TraceGenerator.flickUpPulses(1.0)
            + TraceGenerator.flickUpPulses(2.0).map { Pulse(start: $0.start, duration: $0.duration, amplitude: -$0.amplitude) }
        g.rollPulses = []
        XCTAssertEqual(GestureDetector.detectAll(g.generate(), pointingSign: 1).map(\.gesture), [.flickUp, .flickDown])
    }

    func testFlickLatencyIsShort() {
        let g = GestureDetector.detectAll(TraceGenerator.flickUp().generate(), pointingSign: 1)
        // Flick starts at 1.00 s and peaks at 1.05 s; detection should follow within ~100 ms of the start.
        XCTAssertLessThan(try XCTUnwrap(g.first).t, 1.12)
    }

    // MARK: - Kinematics & CSV

    func testKinematicsMountingIndependent() {
        var a = TraceGenerator.flickUp(sign: 1, seed: 9)
        a.gyroNoise = 0; a.gravityNoise = 0 // noise is added in the device frame, so it differs per mounting
        var b = a; b.sign = -1
        let sa = a.generate(), sb = b.generate()
        for (x, y) in zip(sa, sb) {
            let ka = MotionKinematics(sample: x, pointingSign: 1)
            let kb = MotionKinematics(sample: y, pointingSign: -1)
            XCTAssertEqual(ka.pitchDeg, kb.pitchDeg, accuracy: 1e-6)
            XCTAssertEqual(ka.pitchRate, kb.pitchRate, accuracy: 1e-6)
            XCTAssertEqual(ka.rollRate, kb.rollRate, accuracy: 1e-6)
        }
    }

    func testKinematicsPitchMatchesGenerator() {
        var g = TraceGenerator(duration: 0.5)
        g.pitch0Deg = 25
        g.gyroNoise = 0; g.gravityNoise = 0
        let k = MotionKinematics(sample: g.generate()[10], pointingSign: 1)
        XCTAssertEqual(k.pitchDeg, 25, accuracy: 0.01)
        XCTAssertEqual(k.pitchRate, 0, accuracy: 0.01)
    }

    func testCSVRoundTrip() throws {
        let samples = Array(TraceGenerator.twist().generate().prefix(50))
        let decoded = try MotionCSV.decode(MotionCSV.encode(samples))
        XCTAssertEqual(decoded.count, 50)
        for (a, b) in zip(samples, decoded) {
            XCTAssertEqual(a.t, b.t, accuracy: 1e-6)
            XCTAssertEqual(a.rotationRate.x, b.rotationRate.x, accuracy: 1e-6)
            XCTAssertEqual(a.gravity.z, b.gravity.z, accuracy: 1e-6)
            XCTAssertEqual(a.attitude.w, b.attitude.w, accuracy: 1e-6)
            XCTAssertNil(b.heading)
        }
    }

    func testCSVToleratesExtraColumnsReorderingAndComments() throws {
        let csv = """
        # recorded on Ultra
        qw,qx,qy,qz,t,rx,ry,rz,gx,gy,gz,heading,extra
        1,0,0,0,0.5,0.1,0.2,0.3,0,0,-1,123.5,foo

        """
        let s = try MotionCSV.decode(csv)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].t, 0.5)
        XCTAssertEqual(s[0].rotationRate, Vector3(0.1, 0.2, 0.3))
        XCTAssertEqual(s[0].heading, 123.5)
        XCTAssertThrowsError(try MotionCSV.decode("t,rx\n1,2\n"))
    }

    // MARK: - Fixture regeneration (opt-in)

    /// `WATCHMAGIC_REGEN_FIXTURES=1 swift test --filter testRegenerateFixtures`
    func testRegenerateFixtures() throws {
        guard ProcessInfo.processInfo.environment["WATCHMAGIC_REGEN_FIXTURES"] != nil else {
            throw XCTSkip("set WATCHMAGIC_REGEN_FIXTURES=1 to rewrite Fixtures/*.csv")
        }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let traces: [(String, TraceGenerator)] = [
            ("flick_up", .flickUp()), ("flick_down", .flickDown()), ("twist", .twist()),
            ("slow_raise", .slowRaise()), ("slow_rotate", .slowRotate()),
        ]
        for (name, gen) in traces {
            let header = "# synthetic \(name): TraceGenerator, pointing sign +1 (left wrist, crown right), 100 Hz, seeded noise; quaternion = device→world\n"
            try (header + MotionCSV.encode(gen.generate())).write(to: dir.appendingPathComponent("\(name).csv"), atomically: true, encoding: .utf8)
        }
    }
}

private extension TraceGenerator {
    static func flickUp(duration: Double) -> TraceGenerator {
        var g = TraceGenerator.flickUp()
        g.duration = duration
        return g
    }
}
