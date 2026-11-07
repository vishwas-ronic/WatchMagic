import XCTest
@testable import WatchMagicKit

final class ActionMapperTests: XCTestCase {

    private let settings = Settings() // brightness step 20, fan step nil, min→off on
    private var settingsMinOffDisabled: Settings {
        var s = Settings(); s.flickDownAtMinimumTurnsOff = false; return s
    }

    private func device(_ entity: String, _ kind: DeviceKind) -> ControlledDevice {
        ControlledDevice(entityID: entity, name: entity, kind: kind)
    }
    private func state(_ entity: String, _ s: String, _ attrs: [String: JSONValue] = [:]) -> EntityState {
        EntityState(entityID: entity, state: s, attributes: attrs)
    }
    private func map(_ g: Gesture, _ d: ControlledDevice, _ st: EntityState?, _ s: Settings? = nil) -> ServiceCall? {
        ActionMapper.map(gesture: g, device: d, state: st, settings: s ?? settings)
    }
    private func assertCall(_ call: ServiceCall?, _ domain: String, _ service: String, _ entity: String,
                            _ data: [String: JSONValue] = [:], file: StaticString = #filePath, line: UInt = #line) {
        guard let call else { return XCTFail("expected \(domain).\(service), got nil", file: file, line: line) }
        XCTAssertEqual(call.serviceName, "\(domain).\(service)", file: file, line: line)
        XCTAssertEqual(call.entityID, entity, file: file, line: line)
        XCTAssertEqual(call.data, data, file: file, line: line)
        var body = data; body["entity_id"] = .string(entity)
        XCTAssertEqual(call.body, body, file: file, line: line)
    }

    // MARK: Dimmable light

    private let lamp = "light.lamp"
    private var dimmable: ControlledDevice { device(lamp, .dimmableLight) }

    func testDimmableFlickUpWhenOffTurnsOn() {
        assertCall(map(.flickUp, dimmable, state(lamp, "off")), "light", "turn_on", lamp)
    }

    func testDimmableFlickUpWhenOnStepsUp() {
        assertCall(map(.flickUp, dimmable, state(lamp, "on", ["brightness": .int(128)])),
                   "light", "turn_on", lamp, ["brightness_step_pct": .int(20)])
    }

    func testDimmableFlickDownWhenOnStepsDown() {
        assertCall(map(.flickDown, dimmable, state(lamp, "on", ["brightness": .int(200)])),
                   "light", "turn_on", lamp, ["brightness_step_pct": .int(-20)])
    }

    func testDimmableFlickDownAtMinimumTurnsOffWhenSettingOn() {
        // 20 % of 255 = 51 → at or below is "minimum"
        assertCall(map(.flickDown, dimmable, state(lamp, "on", ["brightness": .int(51)])), "light", "turn_off", lamp)
        assertCall(map(.flickDown, dimmable, state(lamp, "on", ["brightness": .int(10)])), "light", "turn_off", lamp)
        // just above minimum → still a step
        assertCall(map(.flickDown, dimmable, state(lamp, "on", ["brightness": .int(52)])),
                   "light", "turn_on", lamp, ["brightness_step_pct": .int(-20)])
    }

    func testDimmableFlickDownAtMinimumStepsWhenSettingOff() {
        assertCall(map(.flickDown, dimmable, state(lamp, "on", ["brightness": .int(10)]), settingsMinOffDisabled),
                   "light", "turn_on", lamp, ["brightness_step_pct": .int(-20)])
    }

    func testDimmableFlickDownWhenOffDoesNothing() {
        XCTAssertNil(map(.flickDown, dimmable, state(lamp, "off")))
    }

    func testDimmableTwistToggles() {
        assertCall(map(.twist, dimmable, state(lamp, "on")), "homeassistant", "toggle", lamp)
        assertCall(map(.twist, dimmable, state(lamp, "off")), "homeassistant", "toggle", lamp)
    }

    func testCustomBrightnessStep() {
        var s = Settings(); s.brightnessStepPct = 10
        assertCall(map(.flickUp, dimmable, state(lamp, "on", ["brightness": .int(100)]), s),
                   "light", "turn_on", lamp, ["brightness_step_pct": .int(10)])
        // 10 % of 255 = 25.5 → 25 is minimum, 26 is not
        assertCall(map(.flickDown, dimmable, state(lamp, "on", ["brightness": .int(25)]), s), "light", "turn_off", lamp)
        assertCall(map(.flickDown, dimmable, state(lamp, "on", ["brightness": .int(26)]), s),
                   "light", "turn_on", lamp, ["brightness_step_pct": .int(-10)])
    }

    // MARK: On/off light & switch

    func testOnOffLight() {
        let d = device("light.hall", .onOffLight)
        for st in ["on", "off"] {
            assertCall(map(.flickUp, d, state(d.entityID, st)), "light", "turn_on", "light.hall")
            assertCall(map(.flickDown, d, state(d.entityID, st)), "light", "turn_off", "light.hall")
            assertCall(map(.twist, d, state(d.entityID, st)), "homeassistant", "toggle", "light.hall")
        }
    }

    func testSwitch() {
        let d = device("switch.heater", .switch)
        for st in ["on", "off"] {
            assertCall(map(.flickUp, d, state(d.entityID, st)), "switch", "turn_on", "switch.heater")
            assertCall(map(.flickDown, d, state(d.entityID, st)), "switch", "turn_off", "switch.heater")
            assertCall(map(.twist, d, state(d.entityID, st)), "homeassistant", "toggle", "switch.heater")
        }
    }

    // MARK: Fan

    private let fanID = "fan.ceiling"
    private var fan: ControlledDevice { device(fanID, .fan) }

    func testFanFlickUpWhenOffTurnsOn() {
        assertCall(map(.flickUp, fan, state(fanID, "off")), "fan", "turn_on", fanID)
    }

    func testFanFlickUpWhenOnIncreasesSpeedWithoutStepByDefault() {
        assertCall(map(.flickUp, fan, state(fanID, "on", ["percentage": .int(33), "percentage_step": .double(33.333333333333336)])),
                   "fan", "increase_speed", fanID)
    }

    func testFanFlickUpWithConfiguredStep() {
        var s = Settings(); s.fanStepPct = 25
        assertCall(map(.flickUp, fan, state(fanID, "on", ["percentage": .int(50)]), s),
                   "fan", "increase_speed", fanID, ["percentage_step": .int(25)])
    }

    func testFanFlickDownWhenOnDecreasesSpeed() {
        assertCall(map(.flickDown, fan, state(fanID, "on", ["percentage": .int(67), "percentage_step": .double(33.333333333333336)])),
                   "fan", "decrease_speed", fanID)
        var s = Settings(); s.fanStepPct = 25
        assertCall(map(.flickDown, fan, state(fanID, "on", ["percentage": .int(75)]), s),
                   "fan", "decrease_speed", fanID, ["percentage_step": .int(25)])
    }

    func testFanFlickDownAtMinimumTurnsOffWhenSettingOn() {
        // entity step 33.3 → 33 % is the minimum speed
        assertCall(map(.flickDown, fan, state(fanID, "on", ["percentage": .int(33), "percentage_step": .double(33.333333333333336)])),
                   "fan", "turn_off", fanID)
        // configured step overrides the entity's
        var s = Settings(); s.fanStepPct = 10
        assertCall(map(.flickDown, fan, state(fanID, "on", ["percentage": .int(33), "percentage_step": .double(33.333333333333336)]), s),
                   "fan", "decrease_speed", fanID, ["percentage_step": .int(10)])
        // no entity step → default 100/3
        assertCall(map(.flickDown, fan, state(fanID, "on", ["percentage": .int(30)])), "fan", "turn_off", fanID)
    }

    func testFanFlickDownAtMinimumDecreasesWhenSettingOff() {
        assertCall(map(.flickDown, fan, state(fanID, "on", ["percentage": .int(33), "percentage_step": .double(33.333333333333336)]), settingsMinOffDisabled),
                   "fan", "decrease_speed", fanID)
    }

    func testFanFlickDownWhenOffDoesNothing() {
        XCTAssertNil(map(.flickDown, fan, state(fanID, "off")))
    }

    func testFanTwistToggles() {
        assertCall(map(.twist, fan, state(fanID, "on")), "homeassistant", "toggle", fanID)
    }

    // MARK: Unknown state

    func testUnknownStateUsesPlainOnOff() {
        assertCall(map(.flickUp, dimmable, nil), "light", "turn_on", lamp)
        assertCall(map(.flickDown, dimmable, nil), "light", "turn_off", lamp)
        assertCall(map(.flickDown, fan, state(fanID, "unavailable")), "fan", "turn_off", fanID)
        assertCall(map(.twist, fan, nil), "homeassistant", "toggle", fanID)
    }

    // MARK: Domain safety (kind overridden)

    func testFanOrDimmableKindOnSwitchDomainBehavesAsSwitch() {
        for kind in [DeviceKind.fan, .dimmableLight] {
            var d = device("switch.plug", kind); d.kindOverridden = true
            assertCall(map(.flickUp, d, state("switch.plug", "on")), "switch", "turn_on", "switch.plug")
            assertCall(map(.flickDown, d, state("switch.plug", "on")), "switch", "turn_off", "switch.plug")
            assertCall(map(.flickUp, d, state("switch.plug", "off")), "switch", "turn_on", "switch.plug")
        }
    }

    func testFanKindOnLightDomainBehavesAsOnOffLight() {
        let d = device("light.lamp", .fan)
        assertCall(map(.flickUp, d, state(lamp, "on", ["brightness": .int(100)])), "light", "turn_on", lamp)
        assertCall(map(.flickDown, d, state(lamp, "on", ["brightness": .int(100)])), "light", "turn_off", lamp)
    }

    func testDimmableKindOnFanDomainBehavesAsOnOffFan() {
        let d = device(fanID, .dimmableLight)
        assertCall(map(.flickUp, d, state(fanID, "on")), "fan", "turn_on", fanID)
        assertCall(map(.flickDown, d, state(fanID, "on")), "fan", "turn_off", fanID)
    }

    func testOnOffKindOnDimmableLightSendsNoStep() {
        let d = device(lamp, .onOffLight)
        assertCall(map(.flickUp, d, state(lamp, "on", ["brightness": .int(100)])), "light", "turn_on", lamp)
    }

    // MARK: Body encoding

    func testBodyJSONHasExactKeys() throws {
        let call = try XCTUnwrap(map(.flickDown, dimmable, state(lamp, "on", ["brightness": .int(200)])))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: call.bodyData()) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["entity_id", "brightness_step_pct"])
        XCTAssertEqual(obj["brightness_step_pct"] as? Int, -20)
        XCTAssertEqual(obj["entity_id"] as? String, lamp)
        XCTAssertEqual(String(decoding: try call.bodyData(), as: UTF8.self), #"{"brightness_step_pct":-20,"entity_id":"light.lamp"}"#)
    }

    // MARK: Kind inference

    func testKindInference() {
        XCTAssertEqual(DeviceKind.infer(entityID: "light.a", supportedColorModes: ["brightness"]), .dimmableLight)
        XCTAssertEqual(DeviceKind.infer(entityID: "light.a", supportedColorModes: ["onoff", "color_temp"]), .dimmableLight)
        XCTAssertEqual(DeviceKind.infer(entityID: "light.a", supportedColorModes: ["onoff"]), .onOffLight)
        XCTAssertEqual(DeviceKind.infer(entityID: "light.a", supportedColorModes: []), .onOffLight)
        XCTAssertEqual(DeviceKind.infer(entityID: "light.a", supportedColorModes: nil), .onOffLight)
        XCTAssertEqual(DeviceKind.infer(entityID: "fan.a", supportedColorModes: nil), .fan)
        XCTAssertEqual(DeviceKind.infer(entityID: "switch.a", supportedColorModes: nil), .switch)
        XCTAssertNil(DeviceKind.infer(entityID: "sensor.a", supportedColorModes: nil))
    }
}
