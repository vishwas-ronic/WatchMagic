import XCTest
@testable import WatchMagicKit

final class TargetResolverTests: XCTestCase {

    private let a = UUID(), b = UUID(), c = UUID()

    private func cands(_ yaws: [(UUID, Double)], pitch: Double = 0) -> [TargetCandidate] {
        yaws.map { TargetCandidate(id: $0.0, direction: Vector3(yawDeg: $0.1, pitchDeg: pitch)) }
    }

    // MARK: Resolution

    func testPicksTheRightDevice() {
        let cs = cands([(a, 0), (b, 40), (c, -40)])
        let r = TargetResolver.resolve(pointing: Vector3(yawDeg: 38, pitchDeg: 3), candidates: cs, toleranceDeg: 12, marginDeg: 5)
        guard case .locked(let id, let angle) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(id, b)
        XCTAssertLessThan(angle, 5)
        XCTAssertEqual(TargetResolver.resolve(pointing: Vector3(yawDeg: -45, pitchDeg: 0), candidates: cs, settings: Settings()).ids, [c])
    }

    func testNoneBeyondTolerance() {
        let cs = cands([(a, 0), (b, 40)])
        XCTAssertEqual(TargetResolver.resolve(pointing: Vector3(yawDeg: 20, pitchDeg: 0), candidates: cs, toleranceDeg: 12, marginDeg: 5), .none)
        XCTAssertEqual(TargetResolver.resolve(pointing: Vector3(yawDeg: 0, pitchDeg: 13), candidates: cs, toleranceDeg: 12, marginDeg: 5), .none)
        XCTAssertEqual(TargetResolver.resolve(pointing: .unitX, candidates: [], toleranceDeg: 12, marginDeg: 5), .none)
    }

    func testAmbiguousWithinMargin() {
        let cs = cands([(a, 0), (b, 8), (c, 60)])
        let r = TargetResolver.resolve(pointing: Vector3(yawDeg: 3, pitchDeg: 0), candidates: cs, toleranceDeg: 12, marginDeg: 5)
        XCTAssertEqual(r, .ambiguous([a, b]))
        // closer to b → b first
        XCTAssertEqual(TargetResolver.resolve(pointing: Vector3(yawDeg: 5, pitchDeg: 0), candidates: cs, toleranceDeg: 12, marginDeg: 5),
                       .ambiguous([b, a]))
    }

    func testLockedWhenRunnerUpBeyondMargin() {
        // best 2°, runner-up 8° → difference 6 ≥ 5 → locked
        let cs = cands([(a, 0), (b, 10)])
        XCTAssertEqual(TargetResolver.resolve(pointing: Vector3(yawDeg: 2, pitchDeg: 0), candidates: cs, toleranceDeg: 12, marginDeg: 5).ids, [a])
    }

    func testSingleCandidateWithinToleranceLocks() {
        let r = TargetResolver.resolve(pointing: Vector3(yawDeg: 10, pitchDeg: 0), candidates: cands([(a, 0)]), toleranceDeg: 12, marginDeg: 5)
        XCTAssertEqual(r.ids, [a])
    }

    // MARK: Reference directions

    func testTaughtVectorOverridesCoordinates() {
        // Coordinates say north-east-ish, taught says due west.
        let taught = Vector3(yawDeg: 90, pitchDeg: 0)
        let d1 = ControlledDevice(id: a, entityID: "light.a", name: "A", kind: .dimmableLight,
                                  coordinates: Vector3(3, 0, 0), taughtVector: taught)
        let room = Room(name: "R", seat: .zero, deviceIDs: [a])
        let refs = ReferenceDirections(room: room, devices: [d1])
        XCTAssertEqual(refs.directions[a]!.angle(to: taught), 0, accuracy: 1e-9)
        let r = TargetResolver.resolve(pointing: taught, candidates: refs.candidates, toleranceDeg: 12, marginDeg: 5)
        XCTAssertEqual(r.ids, [a])
    }

    func testCompassOffsetFromOneTaughtDeviceAppliedToCoordsOnlyDevice() {
        // Room frame: seat at (1, 1, 0). Device A at (4, 1, 0) → room yaw 0°.
        // On the watch, A was taught at world yaw 30° → offset = +30°.
        // Device B at (1, 4, 1) → room yaw 90°, pitch atan(1/3) → world yaw 120°.
        let seat = Vector3(1, 1, 0)
        let devA = ControlledDevice(id: a, entityID: "light.a", name: "A", kind: .dimmableLight,
                                    coordinates: Vector3(4, 1, 0), taughtVector: Vector3(yawDeg: 30, pitchDeg: 0))
        let devB = ControlledDevice(id: b, entityID: "fan.b", name: "B", kind: .fan, coordinates: Vector3(1, 4, 1))
        let devC = ControlledDevice(id: c, entityID: "switch.c", name: "C", kind: .switch) // not placed
        let room = Room(name: "R", seat: seat, deviceIDs: [a, b, c])
        let refs = ReferenceDirections(room: room, devices: [devA, devB, devC])

        XCTAssertEqual(try XCTUnwrap(refs.compassOffsetDeg), 30, accuracy: 1e-9)
        let dirB = try! XCTUnwrap(refs.directions[b])
        XCTAssertEqual(dirB.yawDeg, 120, accuracy: 1e-9)
        XCTAssertEqual(dirB.pitchDeg, atan(1.0 / 3) * 180 / .pi, accuracy: 1e-9)
        XCTAssertNil(refs.directions[c])
        XCTAssertEqual(refs.candidates.map(\.id), [a, b])

        XCTAssertEqual(TargetResolver.resolve(pointing: Vector3(yawDeg: 118, pitchDeg: 15), candidates: refs.candidates, settings: Settings()).ids, [b])
    }

    func testCompassOffsetIsCircularMeanOfSeveralTaughtDevices() {
        let seat = Vector3.zero
        let d1 = ControlledDevice(id: a, entityID: "light.a", name: "A", kind: .onOffLight,
                                  coordinates: Vector3(1, 0, 0), taughtVector: Vector3(yawDeg: 178, pitchDeg: 0))   // offset 178
        let d2 = ControlledDevice(id: b, entityID: "light.b", name: "B", kind: .onOffLight,
                                  coordinates: Vector3(0, 1, 0), taughtVector: Vector3(yawDeg: -88, pitchDeg: 0))   // offset −178
        let room = Room(name: "R", seat: seat, deviceIDs: [a, b])
        let off = try! XCTUnwrap(ReferenceDirections.compassOffsetDeg(room: room, devices: [d1, d2]))
        XCTAssertEqual(abs(off), 180, accuracy: 1e-6) // not 0, which a naive mean would give
    }

    func testCoordsOnlyDevicesExcludedWithoutOffset() {
        let d1 = ControlledDevice(id: a, entityID: "light.a", name: "A", kind: .onOffLight, coordinates: Vector3(1, 0, 0))
        let room = Room(name: "R", seat: .zero, deviceIDs: [a])
        let refs = ReferenceDirections(room: room, devices: [d1])
        XCTAssertNil(refs.compassOffsetDeg)
        XCTAssertTrue(refs.candidates.isEmpty)
    }

    func testAnchorFallsBackToFirstTaughtDevice() {
        let d1 = ControlledDevice(id: a, entityID: "light.a", name: "A", kind: .onOffLight, coordinates: Vector3(1, 0, 0))
        let d2 = ControlledDevice(id: b, entityID: "light.b", name: "B", kind: .onOffLight, taughtVector: Vector3(yawDeg: 45, pitchDeg: 0))
        var room = Room(name: "R", seat: .zero, deviceIDs: [a, b])
        XCTAssertEqual(ReferenceDirections.anchor(room: room, devices: [d1, d2])?.id, b)
        room.anchorDeviceID = a // has no direction (no offset) → falls back
        XCTAssertEqual(ReferenceDirections.anchor(room: room, devices: [d1, d2])?.id, b)
    }

    // MARK: Zero gesture / vector math

    func testYawCorrection() {
        let measured = Vector3(yawDeg: 170, pitchDeg: 5)
        let reference = Vector3(yawDeg: -170, pitchDeg: 5)
        let corr = TargetResolver.yawCorrection(measured: measured, reference: reference)
        XCTAssertEqual(corr, 20, accuracy: 1e-9)
        XCTAssertEqual(measured.rotatedAboutZ(deg: corr).angle(to: reference), 0, accuracy: 1e-6)
    }

    func testVectorYawPitchRoundTripAndCompass() {
        let v = Vector3(yawDeg: -60, pitchDeg: 20)
        XCTAssertEqual(v.yawDeg, -60, accuracy: 1e-9)
        XCTAssertEqual(v.pitchDeg, 20, accuracy: 1e-9)
        XCTAssertEqual(v.norm, 1, accuracy: 1e-12)
        XCTAssertEqual(Vector3(yawDeg: 90, pitchDeg: 0).compassHeadingDeg, 270, accuracy: 1e-9) // +y = west
        XCTAssertEqual(Vector3.unitX.angle(to: .unitY), 90, accuracy: 1e-9)
        XCTAssertEqual(Vector3.unitX.cross(.unitY), .unitZ)
    }

    // MARK: Forearm geometry

    func testWorldPointingFromCoreMotionStyleMatrix() {
        // Device yawed 90° (x-axis points west). Reference→device matrix = Rz(90)ᵀ.
        let rz = [[0.0, -1, 0], [1, 0, 0], [0, 0, 1]]          // device→world
        let refToDev = [[0.0, 1, 0], [-1, 0, 0], [0, 0, 1]]    // its transpose (assumed CMRotationMatrix layout)
        XCTAssertEqual(ForearmGeometry.worldPointing(rotationMatrix: refToDev, sign: 1).angle(to: .unitY), 0, accuracy: 1e-9)
        XCTAssertEqual(ForearmGeometry.worldPointing(rotationMatrix: refToDev, sign: -1).angle(to: -Vector3.unitY), 0, accuracy: 1e-9)
        XCTAssertEqual(ForearmGeometry.worldPointing(rotationMatrix: rz, sign: 1, convention: .deviceToReference).angle(to: .unitY), 0, accuracy: 1e-9)
        // Quaternion path agrees.
        XCTAssertEqual(ForearmGeometry.worldPointing(deviceToWorld: Quaternion(rotationMatrix: rz), sign: 1).angle(to: .unitY), 0, accuracy: 1e-9)
    }

    func testRotationConventionDetection() {
        // Device pitched up 30° about its y-axis: device→world = Ry(−30°).
        let t = 30.0 * .pi / 180
        let devToWorld = [[cos(t), 0, -sin(t)], [0, 1, 0], [sin(t), 0, cos(t)]]
        let worldToDev = [[cos(t), 0, sin(t)], [0, 1, 0], [-sin(t), 0, cos(t)]]
        // Gravity in device frame = worldToDev · (0,0,−1)
        let g = Vector3(-worldToDev[0][2], -worldToDev[1][2], -worldToDev[2][2])
        XCTAssertEqual(RotationConvention.detect(rotationMatrix: worldToDev, gravity: g), .referenceToDevice)
        XCTAssertEqual(RotationConvention.detect(rotationMatrix: devToWorld, gravity: g), .deviceToReference)
        // Flat watch → undecidable
        XCTAssertNil(RotationConvention.detect(rotationMatrix: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], gravity: Vector3(0, 0, -1)))
        // Pointing pitch from either convention is +30°.
        XCTAssertEqual(ForearmGeometry.worldPointing(rotationMatrix: worldToDev, sign: 1).pitchDeg, 30, accuracy: 1e-9)
    }
}
