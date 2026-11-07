import XCTest
@testable import WatchMagicKit

final class PlacementTests: XCTestCase {

    private func assertEqual(_ a: Vector3, _ b: Vector3, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }

    // MARK: ARKit → room frame

    func testARKitAxesMapToRoomAxes() {
        assertEqual(ARFrameConversion.roomPoint(fromARKit: Vector3(0, 0, -1)), Vector3(0, 1, 0)) // forward → +y
        assertEqual(ARFrameConversion.roomPoint(fromARKit: Vector3(0, 1, 0)), Vector3(0, 0, 1))  // up → +z
        assertEqual(ARFrameConversion.roomPoint(fromARKit: Vector3(1, 0, 0)), Vector3(1, 0, 0))  // right → +x
    }

    func testARKitConversionPreservesHandednessAndRoundTrips() {
        let pairs = [(Vector3(1, 0, 0), Vector3(0, 1, 0)),
                     (Vector3(0.3, -1.2, 2), Vector3(-0.7, 0.4, 1.1))]
        for (a, b) in pairs {
            let lhs = ARFrameConversion.roomPoint(fromARKit: a.cross(b))
            let rhs = ARFrameConversion.roomPoint(fromARKit: a).cross(ARFrameConversion.roomPoint(fromARKit: b))
            assertEqual(lhs, rhs)
            assertEqual(ARFrameConversion.arkitPoint(fromRoom: ARFrameConversion.roomPoint(fromARKit: a)), a)
        }
        // Lengths and angles preserved.
        let p = Vector3(0.5, 1.5, -2)
        XCTAssertEqual(ARFrameConversion.roomPoint(fromARKit: p).norm, p.norm, accuracy: 1e-12)
    }

    // MARK: Pitch bias

    private let a = UUID(), b = UUID(), c = UUID()

    func testPitchBiasFromOneTaughtDeviceAppliedToCoordsOnlyDevice() throws {
        // Seat (0,0,1). A at (3,0,1.5): room yaw 0°, pitch atan(0.5/3).
        // Taught at world yaw 30°, pitch 7° above the geometric line → offset 30°, bias +7°.
        let seat = Vector3(0, 0, 1)
        let pitchA = atan(0.5 / 3) * 180 / .pi
        let devA = ControlledDevice(id: a, entityID: "light.a", name: "A", kind: .dimmableLight,
                                    coordinates: Vector3(3, 0, 1.5), taughtVector: Vector3(yawDeg: 30, pitchDeg: pitchA + 7))
        let devB = ControlledDevice(id: b, entityID: "fan.b", name: "B", kind: .fan, coordinates: Vector3(0, 3, 2))
        let room = Room(name: "R", seat: seat, deviceIDs: [a, b])
        let refs = ReferenceDirections(room: room, devices: [devA, devB])

        XCTAssertEqual(try XCTUnwrap(refs.compassOffsetDeg), 30, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(refs.pitchBiasDeg), 7, accuracy: 1e-9)
        let dirB = try XCTUnwrap(refs.directions[b])
        XCTAssertEqual(dirB.yawDeg, 120, accuracy: 1e-9)
        XCTAssertEqual(dirB.pitchDeg, atan(1.0 / 3) * 180 / .pi + 7, accuracy: 1e-9)
        XCTAssertEqual(dirB.norm, 1, accuracy: 1e-12)
    }

    func testNoPitchBiasWithoutTaughtDevice() {
        let devA = ControlledDevice(id: a, entityID: "light.a", name: "A", kind: .onOffLight, coordinates: Vector3(3, 0, 2))
        let devB = ControlledDevice(id: b, entityID: "light.b", name: "B", kind: .onOffLight, taughtVector: Vector3(yawDeg: 10, pitchDeg: 30)) // taught, no coords
        let room = Room(name: "R", seat: .zero, deviceIDs: [a, b])
        XCTAssertNil(ReferenceDirections.pitchBiasDeg(room: room, devices: [devA, devB]))
        let refs = ReferenceDirections(room: room, devices: [devA, devB])
        XCTAssertNil(refs.pitchBiasDeg)
        XCTAssertNil(refs.directions[a])
    }

    func testPitchBiasIsClamped() throws {
        let devA = ControlledDevice(id: a, entityID: "light.a", name: "A", kind: .onOffLight,
                                    coordinates: Vector3(3, 0, 0), taughtVector: Vector3(yawDeg: 0, pitchDeg: 35))
        let devB = ControlledDevice(id: b, entityID: "light.b", name: "B", kind: .onOffLight, coordinates: Vector3(0, 3, 0))
        let room = Room(name: "R", seat: .zero, deviceIDs: [a, b])
        let refs = ReferenceDirections(room: room, devices: [devA, devB])
        XCTAssertEqual(try XCTUnwrap(refs.pitchBiasDeg), ReferenceDirections.maxPitchBiasDeg, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(refs.directions[b]).pitchDeg, 20, accuracy: 1e-9)

        let devC = ControlledDevice(id: c, entityID: "light.c", name: "C", kind: .onOffLight,
                                    coordinates: Vector3(3, 0, 0), taughtVector: Vector3(yawDeg: 0, pitchDeg: -40))
        XCTAssertEqual(try XCTUnwrap(ReferenceDirections.pitchBiasDeg(room: room, devices: [devC])), -20, accuracy: 1e-9)
    }

    func testPitchBiasIsMeanOverTaughtPlacedDevices() throws {
        let devA = ControlledDevice(id: a, entityID: "light.a", name: "A", kind: .onOffLight,
                                    coordinates: Vector3(3, 0, 0), taughtVector: Vector3(yawDeg: 0, pitchDeg: 4))
        let devB = ControlledDevice(id: b, entityID: "light.b", name: "B", kind: .onOffLight,
                                    coordinates: Vector3(0, 3, 0), taughtVector: Vector3(yawDeg: 90, pitchDeg: 8))
        let room = Room(name: "R", seat: .zero, deviceIDs: [a, b])
        XCTAssertEqual(try XCTUnwrap(ReferenceDirections.pitchBiasDeg(room: room, devices: [devA, devB])), 6, accuracy: 1e-9)
    }

    // MARK: Placement merge (frame consistency)

    private func fixture() -> (AppConfig, roomID: UUID, other: UUID) {
        let d1 = ControlledDevice(id: a, entityID: "light.a", name: "A", kind: .onOffLight, coordinates: Vector3(1, 1, 1),
                                  taughtVector: Vector3(yawDeg: 10, pitchDeg: 0))
        let d2 = ControlledDevice(id: b, entityID: "light.b", name: "B", kind: .onOffLight, coordinates: Vector3(2, 2, 2))
        let d3 = ControlledDevice(id: c, entityID: "light.c", name: "C", kind: .onOffLight)
        let otherDev = ControlledDevice(entityID: "light.x", name: "X", kind: .onOffLight, coordinates: Vector3(9, 9, 9))
        let room = Room(name: "R", seat: Vector3(0, 0, 1), deviceIDs: [a, b, c])
        let other = Room(name: "O", seat: .zero, deviceIDs: [otherDev.id])
        return (AppConfig(rooms: [room, other], devices: [d1, d2, d3, otherDev]), room.id, otherDev.id)
    }

    func testFreshFramePlacementClearsUnplacedCoordinates() throws {
        var (config, roomID, otherID) = fixture()
        let p = RoomPlacement(roomID: roomID, seat: Vector3(0.5, 0.5, 1.2),
                              devicePositions: [c: Vector3(3, 0, 2)], sameFrame: false)
        XCTAssertEqual(Set(p.staleDeviceIDs(in: config)), [a, b])
        XCTAssertTrue(p.apply(to: &config))
        XCTAssertEqual(config.room(id: roomID)?.seat, Vector3(0.5, 0.5, 1.2))
        XCTAssertNil(config.device(id: a)?.coordinates)
        XCTAssertNil(config.device(id: b)?.coordinates)
        XCTAssertEqual(config.device(id: c)?.coordinates, Vector3(3, 0, 2))
        XCTAssertNotNil(config.device(id: a)?.taughtVector) // taught vectors untouched
        XCTAssertEqual(config.device(id: otherID)?.coordinates, Vector3(9, 9, 9)) // other rooms untouched
    }

    func testFreshFrameRequiresSeatFromThisSession() {
        var (config, roomID, _) = fixture()
        let before = config
        let p = RoomPlacement(roomID: roomID, seat: nil, devicePositions: [a: Vector3(1, 2, 3)], sameFrame: false)
        XCTAssertFalse(p.canSave(in: config))
        XCTAssertFalse(p.apply(to: &config))
        XCTAssertEqual(config, before)
    }

    func testSameFramePlacementKeepsOthersAndSeat() {
        var (config, roomID, _) = fixture()
        let p = RoomPlacement(roomID: roomID, seat: nil, devicePositions: [b: Vector3(4, 4, 4)], sameFrame: true)
        XCTAssertTrue(p.staleDeviceIDs(in: config).isEmpty)
        XCTAssertTrue(p.apply(to: &config))
        XCTAssertEqual(config.room(id: roomID)?.seat, Vector3(0, 0, 1))
        XCTAssertEqual(config.device(id: a)?.coordinates, Vector3(1, 1, 1))
        XCTAssertEqual(config.device(id: b)?.coordinates, Vector3(4, 4, 4))
        XCTAssertNil(config.device(id: c)?.coordinates)
    }
}
