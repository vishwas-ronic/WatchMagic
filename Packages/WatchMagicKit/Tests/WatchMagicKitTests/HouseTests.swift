import XCTest
@testable import WatchMagicKit

/// House model, room → house alignment (handedness!), house-wide compass
/// offset, north bearing and the layout payload.
///
/// The alignment tests build a physical "truth" independent of
/// `HouseAlignment`'s formulas: physical coordinates P = (east, north, up),
/// right-handed; the house frame (x = plan right, y = plan down, z = up,
/// LEFT-handed) and each room frame (right-handed, arbitrary yaw/origin) are
/// both defined from P.
final class HouseTests: XCTestCase {

    // MARK: Fixture

    private func fixture() throws -> HouseModel {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "house_fixture", withExtension: "json", subdirectory: "Fixtures"))
        return try HouseModel.fromJSON(Data(contentsOf: url))
    }

    func testDecodesTrimmedRealHouseTolerantly() throws {
        let h = try fixture()
        XCTAssertEqual(h.schemaVersion, "1.1")
        XCTAssertEqual(h.spaces.map(\.id), ["G-3", "G-2", "F-2"]) // malformed "BROKEN" skipped
        XCTAssertEqual(h.floors.map(\.id), ["ground", "first"])
        XCTAssertEqual(h.walls.count, 2)
        let g3 = try XCTUnwrap(h.space(id: "G-3"))
        XCTAssertEqual(g3.displayName, "Drawing Room")
        XCTAssertEqual(g3.poly.count, 26)
        XCTAssertEqual(PlanPolygon.signedArea(g3.poly), 16.67, accuracy: 0.01) // positive as stored
        XCTAssertEqual(h.floorLevel(of: try XCTUnwrap(h.space(id: "F-2"))), 3.3, accuracy: 1e-12)
        XCTAssertEqual(h.spacesByFloor.map(\.floorID), ["ground", "first"])
        XCTAssertEqual(h.spaces(onFloor: "ground").map(\.id), ["G-3", "G-2"])
        XCTAssertEqual(h.floor(id: "first")?.clearHeight ?? 0, 3.048, accuracy: 1e-9)
        XCTAssertTrue(PlanPolygon.contains(g3.poly, PlanPoint(2, 19)))
        XCTAssertFalse(PlanPolygon.contains(g3.poly, PlanPoint(5, 19)))
    }

    func testMinimalAndOddJSONStillDecodes() throws {
        let h = try HouseModel.fromJSON(Data(#"{"schema_version": 1.2, "spaces": [{"id": "X", "poly": [[0,0],[1,0],[1,1]]}, 7]}"#.utf8))
        XCTAssertEqual(h.schemaVersion, "1.2")
        XCTAssertEqual(h.spaces.map(\.id), ["X"])
        XCTAssertEqual(h.floorLevel(of: h.spaces[0]), 0)
        XCTAssertTrue(h.floors.isEmpty && h.walls.isEmpty)
    }

    func testRoomNameSuggestion() throws {
        let h = try fixture()
        XCTAssertEqual(h.suggestedSpace(forRoomName: "Drawing room")?.id, "G-3")
        XCTAssertEqual(h.suggestedSpace(forRoomName: "Master Bedroom ")?.id, "F-2")
        XCTAssertEqual(h.suggestedSpace(forRoomName: "Study Room")?.id, "G-2")
        XCTAssertNil(h.suggestedSpace(forRoomName: "Garage"))
        XCTAssertEqual(HouseModel.nameSimilarity("Bedroom 01", "bedroom 1"), 1)
    }

    func testCornersCollapseDrawingChamfers() throws {
        let g3 = try XCTUnwrap(try fixture().space(id: "G-3"))
        let corners = PlanPolygon.corners(g3.poly)
        XCTAssertLessThan(corners.count, g3.poly.count)
        // (0.15, 17.175)–(0.025, 17.3) is a 0.18 m chamfer: the real corner is (0.025, 17.175).
        XCTAssertTrue(corners.contains { $0.distance(to: PlanPoint(0.025, 17.175)) < 0.01 }, "\(corners)")
        let (i, j) = try XCTUnwrap(PlanPolygon.farthestPair(corners))
        XCTAssertGreaterThan(corners[i].distance(to: corners[j]), 4.5)
    }

    // MARK: Physical truth

    /// House frame from physical ENU: +y (plan down) at `bearing` clockwise from
    /// true north, +x = 90° counter-clockwise from +y seen from above (the
    /// house frame is left-handed), origin `origin` (house (0,0) in ENU).
    private struct HouseTruth {
        var bearingDeg: Double
        var origin = Vector3(-3, -20, 0)
        var hy: Vector3 { let b = bearingDeg * .pi / 180; return Vector3(sin(b), cos(b), 0) }
        var hx: Vector3 { Vector3(-hy.y, hy.x, 0) }
        func house(_ p: Vector3) -> Vector3 {
            let d = p - origin
            return Vector3(d.dot(hx), d.dot(hy), p.z)
        }
        func physical(_ h: Vector3) -> Vector3 { origin + hx * h.x + hy * h.y + Vector3(0, 0, h.z) }
    }

    /// Right-handed room frame: rotate ENU by `yawDeg` about up, origin at `origin` (ENU).
    private struct RoomTruth {
        var yawDeg: Double
        var origin: Vector3
        func room(_ p: Vector3) -> Vector3 { (p - origin).rotatedAboutZ(deg: yawDeg) }
        func roomDir(_ v: Vector3) -> Vector3 { v.rotatedAboutZ(deg: yawDeg) }
    }

    /// World frame (watch): x = magnetic north, y = west, z = up; declination East-positive.
    private func world(_ v: Vector3, declinationDeg: Double) -> Vector3 {
        let d = declinationDeg * .pi / 180
        let magN = Vector3(sin(d), cos(d), 0), magW = Vector3(-cos(d), sin(d), 0)
        return Vector3(v.dot(magN), v.dot(magW), v.z)
    }

    private func assertEqual(_ a: Vector3, _ b: Vector3, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "\(a) vs \(b)", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "\(a) vs \(b)", file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, "\(a) vs \(b)", file: file, line: line)
    }

    private let house = HouseTruth(bearingDeg: 355)
    private let roomA = RoomTruth(yawDeg: 37, origin: Vector3(1.0, -1.5, 1.3))   // phone ~1.3 m above floor at start
    private let roomB = RoomTruth(yawDeg: -128, origin: Vector3(5.0, 2.0, 1.1))

    /// Marks two G-3 corners in `room` (floor level, optional per-mark error) and solves.
    private func align(_ room: RoomTruth, space: HouseModel.Space, floorLevel: Double = 0,
                       markError: (Vector3, Vector3) = (.zero, .zero), cornerB: PlanPoint? = nil) throws -> HouseAlignment {
        let corners = PlanPolygon.corners(space.poly)
        let (i, j) = try XCTUnwrap(PlanPolygon.farthestPair(corners))
        let a = corners[i], b = corners[j]
        let markB = cornerB ?? b
        let ra = room.room(house.physical(Vector3(a.x, a.y, floorLevel))) + markError.0
        let rb = room.room(house.physical(Vector3(markB.x, markB.y, floorLevel))) + markError.1
        return try XCTUnwrap(HouseAlignment.solve(spaceID: space.id, roomCorners: (ra, rb),
                                                  houseCorners: (a, b), floorLevel: floorLevel))
    }

    // MARK: Alignment

    func testAlignmentRecoversHousePositionsAndRoundTrips() throws {
        let g3 = try XCTUnwrap(try fixture().space(id: "G-3"))
        let al = try align(roomA, space: g3)
        XCTAssertEqual(al.fitErrorM, 0, accuracy: 1e-9)
        XCTAssertFalse(al.fitIsPoor)
        for h in [Vector3(2.0, 19.0, 2.4), Vector3(0.5, 17.6, 0.3), Vector3(4.1, 20.3, 3.0)] {
            let r = roomA.room(house.physical(h))
            assertEqual(al.housePoint(fromRoom: r), h)
            assertEqual(al.roomPoint(fromHouse: al.housePoint(fromRoom: r)), r)
            XCTAssertTrue(PlanPolygon.contains(g3.poly, PlanPoint(al.housePoint(fromRoom: r).x, al.housePoint(fromRoom: r).y)))
        }
        // The room frame's floor was at z = −1.3: zOffset lifts it to the storey level.
        XCTAssertEqual(al.zOffset, 1.3, accuracy: 1e-9)
    }

    func testFirstFloorZIsAboveGroundLevel() throws {
        let f2 = try XCTUnwrap(try fixture().space(id: "F-2"))
        let al = try align(roomB, space: f2, floorLevel: 3.3)
        let ceilingLight = Vector3(7, 18.8, 3.3 + 2.9)
        assertEqual(al.housePoint(fromRoom: roomB.room(house.physical(ceilingLight))), ceilingLight)
    }

    func testReflectionKeepsPhysicalSides() throws {
        // The room frame is right-handed, the house frame left-handed: the 2-D
        // cross product of mapped axes flips sign, and a point physically to the
        // user's RIGHT stays to their right (in house plan terms, right of
        // forward f is (−f.y, f.x) because y points down the plan).
        let g3 = try XCTUnwrap(try fixture().space(id: "G-3"))
        let al = try align(roomA, space: g3)
        let ex = al.houseDirection(fromRoom: .unitX), ey = al.houseDirection(fromRoom: .unitY)
        XCTAssertEqual(ex.x * ey.y - ex.y * ey.x, -1, accuracy: 1e-9)
        XCTAssertEqual(al.houseDirection(fromRoom: .unitZ).z, 1, accuracy: 1e-12)

        // User at the seat facing a device; a second point 1 m to their right.
        let seatH = Vector3(1.0, 18.0, 1.2), deviceH = Vector3(3.5, 19.5, 1.2)
        let seatP = house.physical(seatH), deviceP = house.physical(deviceH)
        let f = (deviceP - seatP).normalized
        let rightP = seatP + Vector3(f.y, -f.x, 0) // right of forward in right-handed ENU
        let rightRoom = roomA.room(rightP)
        let seatRoom = roomA.room(seatP), deviceRoom = roomA.room(deviceP)
        // Right in the room frame (right-handed): (f.y, −f.x).
        let fr = (deviceRoom - seatRoom).normalized, rr = rightRoom - seatRoom
        assertEqual(rr, Vector3(fr.y, -fr.x, 0))
        // Mapped to the house: right of forward is (−f.y, f.x).
        let fh = (al.housePoint(fromRoom: deviceRoom) - al.housePoint(fromRoom: seatRoom)).normalized
        let rh = al.housePoint(fromRoom: rightRoom) - al.housePoint(fromRoom: seatRoom)
        assertEqual(rh, Vector3(-fh.y, fh.x, 0))
        assertEqual(al.housePoint(fromRoom: rightRoom), house.house(rightP))

        // A proper rotation (no reflection) through the same two corners
        // mirrors the room across the A–B line: a point 1.5 m off that line
        // lands ~3 m from where it really is.
        let corners = PlanPolygon.corners(g3.poly)
        let (i, j) = try XCTUnwrap(PlanPolygon.farthestPair(corners))
        let a = corners[i], b = corners[j]
        let ab = b - a, len = a.distance(to: b)
        let offLine = Vector3((a.x + b.x) / 2 - ab.y / len * 1.5, (a.y + b.y) / 2 + ab.x / len * 1.5, 1)
        let ra = roomA.room(house.physical(Vector3(a.x, a.y, 0))), rb = roomA.room(house.physical(Vector3(b.x, b.y, 0)))
        let theta = atan2(ab.y, ab.x) - atan2(rb.y - ra.y, rb.x - ra.x)
        func naive(_ r: Vector3) -> PlanPoint {
            let c = cos(theta), s = sin(theta)
            let m = PlanPoint((ra.x + rb.x) / 2, (ra.y + rb.y) / 2)
            let d = PlanPoint(r.x - m.x, r.y - m.y)
            return PlanPoint(c * d.x - s * d.y + (a.x + b.x) / 2, s * d.x + c * d.y + (a.y + b.y) / 2)
        }
        let offRoom = roomA.room(house.physical(offLine))
        XCTAssertEqual(naive(offRoom).distance(to: PlanPoint(offLine.x, offLine.y)), 3, accuracy: 1e-6)
        let good = al.housePoint(fromRoom: offRoom)
        XCTAssertEqual(PlanPoint(good.x, good.y).distance(to: PlanPoint(offLine.x, offLine.y)), 0, accuracy: 1e-9)
    }

    func testFitErrorFlagsWrongCornerOrBadMark() throws {
        let g3 = try XCTUnwrap(try fixture().space(id: "G-3"))
        // 5 cm mark error: fine.
        let ok = try align(roomA, space: g3, markError: (Vector3(0.03, -0.04, 0), Vector3(-0.02, 0.05, 0.01)))
        XCTAssertLessThan(ok.fitErrorM, 0.1)
        XCTAssertFalse(ok.fitIsPoor)
        // Marked a different corner than the one chosen on the outline.
        let corners = PlanPolygon.corners(g3.poly)
        let (i, j) = try XCTUnwrap(PlanPolygon.farthestPair(corners))
        let wrong = try XCTUnwrap(corners.indices.filter { $0 != i && $0 != j }
            .map { corners[$0] }
            .max { abs($0.distance(to: corners[i]) - corners[j].distance(to: corners[i])) <
                   abs($1.distance(to: corners[i]) - corners[j].distance(to: corners[i])) })
        let bad = try align(roomA, space: g3, cornerB: wrong)
        XCTAssertGreaterThan(bad.fitErrorM, HouseAlignment.fitWarningM)
        XCTAssertTrue(bad.fitIsPoor)
        // Marks too close together.
        XCTAssertNil(HouseAlignment.solve(spaceID: "G-3", roomCorners: (.zero, Vector3(0.2, 0, 0)),
                                          houseCorners: (PlanPoint(0, 0), PlanPoint(3, 0)), floorLevel: 0))
    }

    func testAlignmentCodableAndRoomTolerance() throws {
        let al = HouseAlignment(spaceID: "G-3", rotationDeg: 12.5, translation: PlanPoint(1, 2), zOffset: 1.3,
                                fitErrorM: 0.04, houseCorners: [PlanPoint(0, 0), PlanPoint(3, 4)])
        let room = Room(name: "Drawing", seat: Vector3(1, 2, 0), houseSpaceID: "G-3", houseAlignment: al)
        let back = try JSONDecoder().decode(Room.self, from: JSONEncoder().encode(room))
        XCTAssertEqual(back, room)
        XCTAssertEqual(back.houseAlignmentIfValid, al)
        // Old configs (no house keys) and a malformed alignment both decode.
        let old = try JSONDecoder().decode(Room.self, from: Data(#"{"name":"Old","deviceIDs":[]}"#.utf8))
        XCTAssertNil(old.houseSpaceID); XCTAssertNil(old.houseAlignment)
        let bad = try JSONDecoder().decode(Room.self, from: Data(#"{"name":"B","houseSpaceID":"G-3","houseAlignment":{"spaceID":5}}"#.utf8))
        XCTAssertEqual(bad.houseSpaceID, "G-3"); XCTAssertNil(bad.houseAlignment)
        // Alignment for another space is ignored.
        var moved = room; moved.houseSpaceID = "G-2"
        XCTAssertNil(moved.houseAlignmentIfValid)
    }

    // MARK: House-wide offset + north bearing

    private let dA = UUID(), dA2 = UUID(), dB1 = UUID(), dB2 = UUID(), dC = UUID()
    private let rA = UUID(), rB = UUID(), rC = UUID()

    /// Room A (G-3) has one taught + placed device; room B (F-2) has placed
    /// devices only; room C is not aligned. Taught vectors = true world
    /// directions with `pitchError` added (the user's pointing habit).
    private func houseConfig(declinationDeg: Double = 1, pitchError: Double = 0) throws -> AppConfig {
        let h = try fixture()
        let g3 = try XCTUnwrap(h.space(id: "G-3")), f2 = try XCTUnwrap(h.space(id: "F-2"))
        let alA = try align(roomA, space: g3), alB = try align(roomB, space: f2, floorLevel: 3.3)

        let seatAH = Vector3(1.0, 18.0, 1.2), lampAH = Vector3(3.8, 20.2, 2.9)
        let seatAP = house.physical(seatAH), lampAP = house.physical(lampAH)
        let trueDir = world((lampAP - seatAP).normalized, declinationDeg: declinationDeg)
        let taught = Vector3(yawDeg: trueDir.yawDeg, pitchDeg: trueDir.pitchDeg + pitchError)

        let seatBH = Vector3(6.0, 20.0, 3.3 + 1.1)
        let devA = ControlledDevice(id: dA, entityID: "light.drawing_lamp", name: "Lamp", kind: .dimmableLight,
                                    coordinates: roomA.room(lampAP), taughtVector: taught,
                                    mount: .ceiling, coordinatesSource: .lidar)
        let devA2 = ControlledDevice(id: dA2, entityID: "switch.drawing_tv", name: "TV", kind: .switch,
                                     coordinates: roomA.room(house.physical(Vector3(0.3, 19.5, 0.9))))
        let devB1 = ControlledDevice(id: dB1, entityID: "fan.master", name: "Fan", kind: .fan,
                                     coordinates: roomB.room(house.physical(Vector3(7.0, 18.8, 3.3 + 3.0))),
                                     mount: .ceiling, coordinatesSource: .lidar)
        let devB2 = ControlledDevice(id: dB2, entityID: "light.master_wall", name: "Wall", kind: .onOffLight,
                                     coordinates: roomB.room(house.physical(Vector3(9.7, 17.5, 3.3 + 1.8))),
                                     coordinatesSource: .lidar)
        let devC = ControlledDevice(id: dC, entityID: "light.kitchen", name: "Kitchen", kind: .onOffLight,
                                    coordinates: Vector3(1, 1, 2))
        return AppConfig(rooms: [
            Room(id: rA, name: "Drawing room", haAreaID: "drawing_room", seat: roomA.room(seatAP), deviceIDs: [dA, dA2],
                 houseSpaceID: "G-3", houseAlignment: alA),
            Room(id: rB, name: "Master bedroom", seat: roomB.room(house.physical(seatBH)), deviceIDs: [dB1, dB2],
                 houseSpaceID: "F-2", houseAlignment: alB),
            Room(id: rC, name: "Kitchen", seat: .zero, deviceIDs: [dC]),
        ], devices: [devA, devA2, devB1, devB2, devC])
    }

    func testNorthBearingFromOneTaughtDevice() throws {
        let cfg = try houseConfig(declinationDeg: 1)
        let cal = HouseCalibration(config: cfg)
        XCTAssertEqual(try XCTUnwrap(cal.northBearingDeg(declinationDeg: 1)), 355, accuracy: 1e-6)
        XCTAssertEqual(HouseCalibration.defaultDeclinationDeg, 1.0)
        // Declination is a plain additive term.
        XCTAssertEqual(try XCTUnwrap(cal.northBearingDeg(declinationDeg: 0)), 354, accuracy: 1e-6)
        // No taught device in an aligned room → no bearing.
        var unaligned = cfg
        unaligned.rooms[0].houseAlignment = nil
        XCTAssertNil(HouseCalibration(config: unaligned).northBearingDeg())
    }

    func testNorthBearingAcrossTheZeroWrap() throws {
        let h = HouseTruth(bearingDeg: 3)
        let room = RoomTruth(yawDeg: 200, origin: Vector3(0, 0, 1))
        let al = try XCTUnwrap(HouseAlignment.solve(
            spaceID: "S", roomCorners: (room.room(h.physical(Vector3(0, 0, 0))), room.room(h.physical(Vector3(4, 3, 0)))),
            houseCorners: (PlanPoint(0, 0), PlanPoint(4, 3)), floorLevel: 0))
        let seat = h.physical(Vector3(1, 1, 1.2)), dev = h.physical(Vector3(3, 2.5, 2.5))
        let d = UUID()
        let cfg = AppConfig(rooms: [Room(name: "R", seat: room.room(seat), deviceIDs: [d], houseSpaceID: "S", houseAlignment: al)],
                            devices: [ControlledDevice(id: d, entityID: "light.x", name: "X", kind: .onOffLight,
                                                       coordinates: room.room(dev), taughtVector: world((dev - seat).normalized, declinationDeg: -2))])
        XCTAssertEqual(try XCTUnwrap(HouseCalibration(config: cfg).northBearingDeg(declinationDeg: -2)), 3, accuracy: 1e-6)
    }

    func testHouseWideOffsetMakesOtherAlignedRoomsAimable() throws {
        let cfg = try houseConfig(declinationDeg: 1, pitchError: 5)
        let roomB = try XCTUnwrap(cfg.room(id: rB))
        // Without the house fallback, room B (no taught device) has no directions.
        XCTAssertTrue(ReferenceDirections(room: roomB, devices: cfg.devices).candidates.isEmpty)

        let refs = ReferenceDirections(room: roomB, config: cfg)
        XCTAssertEqual(refs.compassOffsetSource, .house)
        XCTAssertEqual(refs.candidates.count, 2)
        XCTAssertEqual(try XCTUnwrap(refs.pitchBiasDeg), 5, accuracy: 1e-6) // house-wide pitch bias
        let seatP = house.physical(Vector3(6.0, 20.0, 4.4))
        for (id, h) in [(dB1, Vector3(7.0, 18.8, 6.3)), (dB2, Vector3(9.7, 17.5, 5.1))] {
            let truth = world((house.physical(h) - seatP).normalized, declinationDeg: 1)
            let dir = try XCTUnwrap(refs.directions[id])
            XCTAssertEqual(dir.yawDeg, truth.yawDeg, accuracy: 1e-6)
            XCTAssertEqual(dir.pitchDeg, truth.pitchDeg + 5, accuracy: 1e-6)
        }
        // The room's own offset wins where it exists.
        XCTAssertEqual(ReferenceDirections(room: try XCTUnwrap(cfg.room(id: rA)), config: cfg).compassOffsetSource, .room)
        // Coordinates-only TV in room A (same room as the taught lamp) is also right.
        let tvTruth = world((house.physical(Vector3(0.3, 19.5, 0.9)) - house.physical(Vector3(1.0, 18.0, 1.2))).normalized, declinationDeg: 1)
        let tv = try XCTUnwrap(ReferenceDirections(room: try XCTUnwrap(cfg.room(id: rA)), config: cfg).directions[dA2])
        XCTAssertEqual(tv.yawDeg, tvTruth.yawDeg, accuracy: 1e-6)
        // Unaligned room C gets nothing from the house.
        let refsC = ReferenceDirections(room: try XCTUnwrap(cfg.room(id: rC)), config: cfg)
        XCTAssertNil(refsC.compassOffsetDeg)
        XCTAssertTrue(refsC.candidates.isEmpty)
        // Anchor fallback uses the house offset too (no taught device in B → nil anchor, but no crash).
        XCTAssertNil(ReferenceDirections.anchor(room: roomB, devices: cfg.devices, house: HouseCalibration(config: cfg)))
        let anchored = Room(id: rB, name: "B", seat: roomB.seat, deviceIDs: roomB.deviceIDs, anchorDeviceID: dB1,
                            houseSpaceID: "F-2", houseAlignment: roomB.houseAlignment)
        XCTAssertEqual(ReferenceDirections.anchor(room: anchored, devices: cfg.devices, house: HouseCalibration(config: cfg))?.id, dB1)
    }

    // MARK: Placement merge with alignment + mount

    func testPlacementMergesAlignmentWithFrameRule() throws {
        let al = HouseAlignment(spaceID: "G-3", rotationDeg: 10, translation: PlanPoint(1, 1), zOffset: 1.3)
        let al2 = HouseAlignment(spaceID: "G-3", rotationDeg: 20, translation: PlanPoint(1, 1), zOffset: 1.3)
        let d = UUID(), e = UUID(), r = UUID()
        let base = AppConfig(rooms: [Room(id: r, name: "R", seat: .zero, deviceIDs: [d, e], houseSpaceID: "G-3", houseAlignment: al)],
                             devices: [ControlledDevice(id: d, entityID: "light.d", name: "D", kind: .onOffLight, coordinates: Vector3(1, 1, 1)),
                                       ControlledDevice(id: e, entityID: "light.e", name: "E", kind: .onOffLight, coordinates: Vector3(2, 2, 2))])

        // Same frame, nothing marked: keeps the alignment; placed device gets lidar + mount.
        var c1 = base
        XCTAssertTrue(RoomPlacement(roomID: r, seat: nil, devicePositions: [d: Vector3(1, 2, 3)], sameFrame: true,
                                    deviceMounts: [d: .ceiling]).apply(to: &c1))
        XCTAssertEqual(c1.rooms[0].houseAlignment, al)
        XCTAssertEqual(c1.device(id: d)?.coordinatesSource, .lidar)
        XCTAssertEqual(c1.device(id: d)?.mount, .ceiling)
        XCTAssertNil(c1.device(id: e)?.coordinatesSource)

        // Same frame, re-marked: replaced.
        var c2 = base
        RoomPlacement(roomID: r, seat: nil, devicePositions: [:], sameFrame: true, houseAlignment: al2).apply(to: &c2)
        XCTAssertEqual(c2.rooms[0].houseAlignment, al2)

        // Fresh frame without marks: the old alignment is cleared (wrong frame).
        var c3 = base
        let fresh = RoomPlacement(roomID: r, seat: .zero, devicePositions: [d: Vector3(1, 2, 3)], sameFrame: false)
        XCTAssertTrue(fresh.clearsHouseAlignment(in: c3))
        fresh.apply(to: &c3)
        XCTAssertNil(c3.rooms[0].houseAlignment)
        XCTAssertNil(c3.device(id: e)?.coordinates)

        // Fresh frame with marks: the new one.
        var c4 = base
        RoomPlacement(roomID: r, seat: .zero, devicePositions: [:], sameFrame: false, houseAlignment: al2).apply(to: &c4)
        XCTAssertEqual(c4.rooms[0].houseAlignment, al2)
    }

    func testMountClassification() {
        XCTAssertEqual(DeviceMount.classify(normal: Vector3(0, 0, -1), heightAboveFloor: 2.8), .ceiling)
        XCTAssertEqual(DeviceMount.classify(normal: Vector3(0.1, 0.2, -0.95), heightAboveFloor: nil), .ceiling)
        XCTAssertEqual(DeviceMount.classify(normal: Vector3(1, 0, 0), heightAboveFloor: 1.5), .wall)
        XCTAssertEqual(DeviceMount.classify(normal: Vector3(0, -0.9, 0.3), heightAboveFloor: 0.1), .wall)
        XCTAssertEqual(DeviceMount.classify(normal: Vector3(0, 0, 1), heightAboveFloor: 0.05), .floor)
        XCTAssertEqual(DeviceMount.classify(normal: Vector3(0, 0, 1), heightAboveFloor: 0.75), .table)
        XCTAssertEqual(DeviceMount.classify(normal: Vector3(0, 0, 1), heightAboveFloor: nil), .table)
        XCTAssertEqual(DeviceMount.classify(normal: .zero, heightAboveFloor: nil), .wall)
    }

    // MARK: Layout payload

    func testLayoutBodyShapeDeletesAndValidation() throws {
        var cfg = try houseConfig(declinationDeg: 1)
        // An out-of-range device and a bad entity ID in aligned room A: skipped, not fatal.
        let far = UUID(), bad = UUID()
        cfg.devices.append(ControlledDevice(id: far, entityID: "light.far", name: "Far", kind: .onOffLight,
                                            coordinates: Vector3(0, 0, 40)))
        cfg.devices.append(ControlledDevice(id: bad, entityID: "Light.Bad Name", name: "Bad", kind: .onOffLight,
                                            coordinates: Vector3(0, 0, 0)))
        cfg.rooms[0].deviceIDs += [far, bad]
        let now = Date(timeIntervalSince1970: 1_794_000_000.123)
        let build = HouseLayout.build(config: cfg, previousEntityIDs: ["light.gone", "light.drawing_lamp", "bad id"],
                                      previousSeatIDs: ["seat-dead0000"], now: now)

        XCTAssertEqual(build.devices.map(\.entityID), ["fan.master", "light.drawing_lamp", "light.master_wall", "switch.drawing_tv"])
        XCTAssertEqual(build.seats.map(\.id).sorted(),
                       [HouseLayout.seatID(for: rA), HouseLayout.seatID(for: rB)].sorted())
        XCTAssertEqual(HouseLayout.seatID(for: rA), "seat-" + rA.uuidString.prefix(8).lowercased())
        XCTAssertEqual(build.deletedEntityIDs, ["light.gone"])  // still-present lamp not deleted; invalid id dropped
        XCTAssertEqual(build.deletedSeatIDs, ["seat-dead0000"])
        XCTAssertEqual(Set(build.skipped.map(\.id)), ["light.far", "Light.Bad Name"])
        XCTAssertTrue(build.skipped.contains { $0.id == "light.far" && $0.reason.contains("out of range") })
        XCTAssertEqual(try XCTUnwrap(build.northBearingDeg), 355, accuracy: 1e-6)

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: build.bodyData()) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["state", "attributes"])
        let state = try XCTUnwrap(obj["state"] as? String)
        XCTAssertTrue(state.hasSuffix(".123Z"), state) // ms precision → changes every post
        let attrs = try XCTUnwrap(obj["attributes"] as? [String: Any])
        XCTAssertEqual(Set(attrs.keys), ["schema", "devices", "seats", "north_bearing_deg"])
        XCTAssertEqual(attrs["schema"] as? String, "watchmagic-layout/1")
        let devs = try XCTUnwrap(attrs["devices"] as? [[String: Any]])
        let lamp = try XCTUnwrap(devs.first { $0["entity_id"] as? String == "light.drawing_lamp" })
        XCTAssertEqual(Set(lamp.keys), ["entity_id", "pos", "space_id", "ha_area_id", "label", "mount", "source", "updated"])
        XCTAssertEqual(lamp["space_id"] as? String, "G-3")
        XCTAssertEqual(lamp["ha_area_id"] as? String, "drawing_room")
        XCTAssertEqual(lamp["label"] as? String, "Lamp")
        XCTAssertEqual(lamp["mount"] as? String, "ceiling")
        XCTAssertEqual(lamp["source"] as? String, "lidar")
        XCTAssertEqual(lamp["updated"] as? String, state)
        let pos = try XCTUnwrap(lamp["pos"] as? [Double])
        XCTAssertEqual(pos.count, 3)
        XCTAssertEqual(pos[0], 3.8, accuracy: 0.0006); XCTAssertEqual(pos[1], 20.2, accuracy: 0.0006); XCTAssertEqual(pos[2], 2.9, accuracy: 0.0006)
        let tv = try XCTUnwrap(devs.first { $0["entity_id"] as? String == "switch.drawing_tv" })
        XCTAssertEqual(tv["mount"] as? String, "wall")     // unknown → wall
        XCTAssertEqual(tv["source"] as? String, "manual")
        XCTAssertEqual(tv["ha_area_id"] as? String, "drawing_room")
        let fan = try XCTUnwrap(devs.first { $0["entity_id"] as? String == "fan.master" })
        XCTAssertNil(fan["ha_area_id"])                    // room B has none
        XCTAssertEqual(try XCTUnwrap(fan["pos"] as? [Double])[2], 6.3, accuracy: 0.0006) // first floor: 3.3 + 3.0
        let del = try XCTUnwrap(devs.first { $0["entity_id"] as? String == "light.gone" })
        XCTAssertEqual(Set(del.keys), ["entity_id", "delete"])
        XCTAssertEqual(del["delete"] as? Bool, true)
        let seats = try XCTUnwrap(attrs["seats"] as? [[String: Any]])
        let seatA = try XCTUnwrap(seats.first { $0["id"] as? String == HouseLayout.seatID(for: rA) })
        XCTAssertEqual(Set(seatA.keys), ["id", "pos", "space_id", "label"])
        XCTAssertEqual(seatA["label"] as? String, "Drawing room")
        XCTAssertTrue(seats.contains { $0["id"] as? String == "seat-dead0000" && $0["delete"] as? Bool == true })
        XCTAssertFalse(String(decoding: try build.bodyData(), as: UTF8.self).lowercased().contains("token"))
        XCTAssertTrue(build.summary.hasPrefix("Sent 4 devices, 2 seats to the 3D view · removed 2 · skipped 2"), build.summary)
    }

    func testLayoutRangeAndIDRules() {
        XCTAssertNil(HouseLayout.invalidReason(pos: Vector3(-5, 32, 12)))
        XCTAssertNotNil(HouseLayout.invalidReason(pos: Vector3(-5.01, 0, 0)))
        XCTAssertNotNil(HouseLayout.invalidReason(pos: Vector3(0, 32.5, 0)))
        XCTAssertNotNil(HouseLayout.invalidReason(pos: Vector3(0, 0, .nan)))
        XCTAssertTrue(HouseLayout.isValidSeatID("seat-selftest"))
        XCTAssertFalse(HouseLayout.isValidSeatID(String(repeating: "a", count: 41)))
        XCTAssertFalse(HouseLayout.isValidSeatID("seat 1"))
        XCTAssertTrue(HouseLayout.isValidEntityID("switch.watchmagic_selftest"))
        XCTAssertFalse(HouseLayout.isValidEntityID("switch"))
        // Nothing aligned, nothing pushed before → empty.
        XCTAssertTrue(HouseLayout.build(config: AppConfig()).isEmpty)
        // Only deletions is not empty.
        XCTAssertFalse(HouseLayout.build(config: AppConfig(), previousEntityIDs: ["light.x"]).isEmpty)
    }

    // MARK: Real-HA self-test bodies (opt-in)

    /// `WATCHMAGIC_SELFTEST_OUT=<dir> swift test --filter testWriteSelfTestBodies`
    /// writes `selftest-add.json` / `selftest-delete.json` for a curl round trip.
    func testWriteSelfTestBodies() throws {
        let g3 = try XCTUnwrap(try fixture().space(id: "G-3"))
        let pos = Vector3(2.0, 19.0, 1.2)
        XCTAssertTrue(PlanPolygon.contains(g3.poly, PlanPoint(pos.x, pos.y)))
        let add = HouseLayout.Build(
            state: HouseLayout.isoString(Date()),
            devices: [.init(entityID: "switch.watchmagic_selftest", pos: pos, spaceID: "G-3", label: "WatchMagic self-test",
                            mount: .wall, source: "manual", updated: HouseLayout.isoString(Date()))],
            seats: [.init(id: "seat-selftest", pos: Vector3(1.0, 18.0, 1.1), spaceID: "G-3", label: "WatchMagic self-test")])
        let del = HouseLayout.Build(state: HouseLayout.isoString(Date().addingTimeInterval(1)),
                                    deletedEntityIDs: ["switch.watchmagic_selftest"], deletedSeatIDs: ["seat-selftest"])
        XCTAssertNil(HouseLayout.invalidReason(pos: pos))
        guard let dir = ProcessInfo.processInfo.environment["WATCHMAGIC_SELFTEST_OUT"] else { return }
        try add.bodyData().write(to: URL(fileURLWithPath: dir).appendingPathComponent("selftest-add.json"))
        try del.bodyData().write(to: URL(fileURLWithPath: dir).appendingPathComponent("selftest-delete.json"))
    }
}

final class HouseClientTests: XCTestCase {
    private func client() -> HAClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return HAClient(baseURL: URL(string: "http://ha.test:8123/")!, token: "tok", session: URLSession(configuration: cfg))
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testHouseModelGETAndDecode() async throws {
        StubURLProtocol.handler = { _, _ in
            (200, Data(#"{"schema_version":"1.1","floors":[{"id":"ground","z":0}],"spaces":[{"id":"G-3","name":"Drawing Room","floor":"ground","z":0,"poly":[[0,0],[4,0],[4,3]],"poly_render":[[9,9]]}]}"#.utf8))
        }
        let h = try await client().houseModel()
        XCTAssertEqual(h.spaces.first?.id, "G-3")
        XCTAssertEqual(h.spaces.first?.poly.count, 3) // poly, not poly_render
        let c = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(c.request.httpMethod, "GET")
        XCTAssertEqual(c.request.url?.absoluteString, "http://ha.test:8123/local/house3d/house.json")
    }

    func testHouseModel404IsClearError() async {
        StubURLProtocol.handler = { _, _ in (404, Data("404: Not Found".utf8)) }
        do {
            _ = try await client().houseModel()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? HAError, .noHouseModel)
            XCTAssertEqual((error as? HAError)?.errorDescription, "No house3d model on HA")
        }
    }

    func testPostLayout() async throws {
        StubURLProtocol.handler = { _, _ in (201, Data(#"{"entity_id":"sensor.watchmagic_layout","state":"x"}"#.utf8)) }
        let body = try HouseLayout.Build(state: "2026-11-07T10:00:00.000Z", deletedEntityIDs: ["light.a"]).bodyData()
        try await client().postLayout(body)
        let c = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(c.request.httpMethod, "POST")
        XCTAssertEqual(c.request.url?.absoluteString, "http://ha.test:8123/api/states/sensor.watchmagic_layout")
        XCTAssertEqual(c.request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(c.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(c.body, body)
    }
}
