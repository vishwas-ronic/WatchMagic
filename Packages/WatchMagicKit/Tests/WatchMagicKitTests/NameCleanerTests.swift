import XCTest
@testable import WatchMagicKit

/// Cases taken from the real Home Assistant instance (friendly name, device name, room/area).
final class NameCleanerTests: XCTestCase {

    private func check(_ friendly: String, device: String?, rooms: [String], _ expected: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(NameCleaner.clean(friendlyName: friendly, deviceName: device, roomNames: rooms),
                       expected, file: file, line: line)
    }

    func testRoomAndDeviceRepeated() {
        check("Mummy Room Mummy Room Fan", device: "Mummy Room", rooms: ["Mummy Room"], "Fan")
        check("Mummy Room Mummy Room Fancy Light", device: "Mummy Room", rooms: ["Mummy Room"], "Fancy Light")
        check("Papa Room papa room  Tubelight", device: "Papa Room", rooms: ["Papa Room", "ubiquity"], "Tubelight")
        check("Massage Room massage Room Fan", device: "Massage Room", rooms: ["massage room"], "Fan")
        check("Meghna Room meghna Room Tubelight 1", device: "Meghna Room", rooms: ["Meghna Room"], "Tubelight 1")
        check("Basement Hall Basement Hall Fan Bed", device: "Basement Hall", rooms: ["Basement"], "Fan Bed")
        check("Dhairya Room TubeLight", device: "Dhairya Room", rooms: ["Dhairya Room"], "TubeLight")
    }

    func testSlugDeviceNames() {
        check("meghna_room_bed_lamp meghna room bed lamp", device: "meghna_room_bed_lamp", rooms: ["Meghna Room"], "Bed Lamp")
        check("meghna_fan Meghna room fan", device: "meghna_fan", rooms: ["Meghna Room"], "Fan")
        check("meghna_ir_blaster meghna-ir-blaster Blue LED", device: "meghna_ir_blaster", rooms: ["Meghna Room"], "Blue LED")
        check("cooler_plug Cooler Switch", device: "cooler_plug", rooms: ["golu_balcony"], "Cooler Switch")
        check("mummy room spray Mummy Room Spray", device: "mummy room spray", rooms: ["Mummy Room"], "Spray")
        check("basment_hall  side lights", device: "basment_hall", rooms: ["Basement"], "Side Lights")
        check("kitchen_extension  lights", device: "basment_hall", rooms: ["Basement"], "Kitchen Extension Lights")
    }

    func testGenericRemainderKeepsDeviceName() {
        check("Basement Stairs Light Board basement_stairs_light_board_relay_1",
              device: "Basement Stairs Light Board", rooms: ["ubiquity"], "Basement Stairs Light Board Relay 1")
        check("Basement Stairs Light Board basement_stairs_light_board Blue LED",
              device: "Basement Stairs Light Board", rooms: ["ubiquity"], "Blue LED")
        check("Balcony Line Leds balcony_line_leds LED", device: "Balcony Line Leds", rooms: ["ubiquity"], "Balcony Line Leds LED")
        check("Mandirlights mandirlights relay", device: "Mandirlights", rooms: ["Mandir"], "Mandirlights Relay")
        check("Shaurya Room Amp Switch Relay", device: "Shaurya Room Amp Switch", rooms: ["Shaurya Room"], "Amp Switch Relay")
        // Device named after the room: in that room just "Lights", elsewhere keep the device.
        check("Drawing Room Drawing Room lights", device: "Drawing Room", rooms: ["Drawing Room"], "Lights")
        check("Drawing Room Drawing Room lights", device: "Drawing Room", rooms: ["ubiquity"], "Drawing Room Lights")
        check("papa_room  lights", device: "Papa Room", rooms: ["Papa Room"], "Lights")
    }

    func testReorderedDeviceName() {
        check("Lobby Ground Floor ground Floor Lobby photo light", device: "Lobby Ground Floor", rooms: ["ubiquity"], "Photo Light")
        check("Lobby Ground Floor ground Floor Lobby lights", device: "Lobby Ground Floor", rooms: ["ubiquity"], "Lobby Ground Floor Lights")
        check("Lobby First Floor First Floor Lobby shoe rack light", device: "Lobby First Floor", rooms: ["Lobby FF"], "Shoe Rack Light")
    }

    func testSpaceInsensitiveRoomMatch() {
        check("Maindoor 2 Maindoor Parking Footlights", device: "Maindoor 2", rooms: ["Main Door"], "Parking Footlights")
        check("Maindoor 2 NumberPlate Light", device: "Maindoor 2", rooms: ["Main Door"], "NumberPlate Light")
        check("TerraceSwitch Terrace Diwali Lights", device: "TerraceSwitch", rooms: ["Terrace"], "Diwali Lights")
    }

    func testAlreadyCleanOrDeviceOnly() {
        check("Curtain Bulb", device: "Curtain Bulb", rooms: ["Meghna Room"], "Curtain Bulb")
        check("Diwali Lights", device: "Diwali Lights", rooms: ["Main Gate"], "Diwali Lights")
        check("papa fan LED", device: "papa room fan", rooms: ["Papa Room"], "Papa Fan LED")
        check("Grond floor lobby IR lamp", device: "Grond floor lobby", rooms: ["Lobby"], "IR Lamp")
        check("Mainbell Switch Bell", device: "Mainbell Switch", rooms: ["Main Door"], "Bell")
        check("Tapo: Cameras Control Pre-release", device: nil, rooms: [], "Tapo: Cameras Control Pre-release")
        check("Dining Light", device: nil, rooms: [], "Dining Light")
    }

    func testRoomOnlyNameIsNotEmptied() {
        // Nothing but the room name: keep it rather than returning "".
        check("Shaurya Room", device: nil, rooms: ["Shaurya Room"], "Shaurya Room")
    }

    func testRoomNameCleanup() {
        XCTAssertEqual(NameCleaner.cleanRoomName("golu_balcony"), "Golu Balcony")
        XCTAssertEqual(NameCleaner.cleanRoomName("massage room"), "Massage Room")
        XCTAssertEqual(NameCleaner.cleanRoomName("Lobby FF"), "Lobby FF")
    }

    func testParseDeviceNames() throws {
        let json = #"[{"e":"switch.a","d":"Mummy Room"},{"e":"light.b","d":null},{"e":"lock.c","d":"X"}]"#
        let names = try HAClient.parseDeviceNames(json)
        XCTAssertEqual(names, ["switch.a": "Mummy Room"])
    }
}
