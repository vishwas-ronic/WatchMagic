import Foundation

/// Maps a gesture on a device to a Home Assistant service call (spec 1.2.3).
///
/// | Gesture    | Light (dimmable)                                      | On/off light / Switch | Fan                                   |
/// |------------|-------------------------------------------------------|-----------------------|---------------------------------------|
/// | Flick up   | off → light.turn_on; on → light.turn_on brightness_step_pct:+step | <domain>.turn_on | off → fan.turn_on; on → fan.increase_speed |
/// | Flick down | on → light.turn_on brightness_step_pct:−step; at min → light.turn_off | <domain>.turn_off | on → fan.decrease_speed; at min → fan.turn_off |
/// | Twist      | homeassistant.toggle                                  | homeassistant.toggle  | homeassistant.toggle                  |
///
/// Rules:
/// - "At the minimum → off" only when `settings.flickDownAtMinimumTurnsOff`;
///   with the setting off the step-down call is sent (HA clamps), never turn_off.
/// - Dimmable light at minimum: brightness ≤ step% of 255 (stepping down would reach ≤ 0).
///   Fan at minimum: percentage ≤ step, step = settings.fanStepPct ?? entity percentage_step ?? 100/3.
///   A fan that is on but reports no percentage counts as "at minimum".
/// - Flick down on a dimmable light / fan that is off → nil (nothing to do).
/// - `fan.increase_speed` / `decrease_speed` carry `percentage_step` only when
///   `settings.fanStepPct` is set; otherwise HA uses the entity's own step.
/// - Domain safety: the kind may be overridden, but a service the entity's
///   domain lacks is never emitted. Dimmable behaviour needs domain `light`,
///   fan behaviour needs domain `fan`; anything else falls back to
///   `<domain>.turn_on` / `<domain>.turn_off`.
/// - Unknown state (nil, "unavailable", "unknown"): flick up → `<domain>.turn_on`,
///   flick down → `<domain>.turn_off` (no relative steps without a known state).
public enum ActionMapper {

    /// The behaviour actually used after the domain-safety check.
    public enum Behavior: Equatable, Sendable {
        case dimmableLight
        case fan
        case onOff(domain: String)
    }

    public static func behavior(kind: DeviceKind, domain: String) -> Behavior {
        switch (kind, domain) {
        case (.dimmableLight, "light"): return .dimmableLight
        case (.fan, "fan"): return .fan
        case (_, "light"), (_, "fan"), (_, "switch"): return .onOff(domain: domain)
        default: return .onOff(domain: "homeassistant") // out-of-scope domains: generic services
        }
    }

    public static func map(
        gesture: Gesture,
        device: ControlledDevice,
        state: EntityState?,
        settings: Settings
    ) -> ServiceCall? {
        let entity = device.entityID
        if gesture == .twist {
            return ServiceCall(domain: "homeassistant", service: "toggle", entityID: entity)
        }

        let behavior = behavior(kind: device.kind, domain: device.domain)
        let known = state.map(\.isKnownOnOff) ?? false
        let isOn = state?.isOn ?? false

        // Without a known on/off state, never send relative steps.
        if !known {
            let d: String
            switch behavior {
            case .dimmableLight: d = "light"
            case .fan: d = "fan"
            case .onOff(let dom): d = dom
            }
            return ServiceCall(domain: d, service: gesture == .flickUp ? "turn_on" : "turn_off", entityID: entity)
        }

        switch behavior {
        case .onOff(let domain):
            return ServiceCall(domain: domain, service: gesture == .flickUp ? "turn_on" : "turn_off", entityID: entity)

        case .dimmableLight:
            let step = max(1, settings.brightnessStepPct)
            if gesture == .flickUp {
                if !isOn { return ServiceCall(domain: "light", service: "turn_on", entityID: entity) }
                return ServiceCall(domain: "light", service: "turn_on", entityID: entity,
                                   data: ["brightness_step_pct": .number(step)])
            }
            // flick down
            guard isOn else { return nil }
            let atMinimum: Bool = {
                guard let b = state?.brightness else { return false }
                return Double(b) <= step / 100 * 255
            }()
            if atMinimum && settings.flickDownAtMinimumTurnsOff {
                return ServiceCall(domain: "light", service: "turn_off", entityID: entity)
            }
            return ServiceCall(domain: "light", service: "turn_on", entityID: entity,
                               data: ["brightness_step_pct": .number(-step)])

        case .fan:
            var stepData: [String: JSONValue] = [:]
            if let s = settings.fanStepPct { stepData["percentage_step"] = .number(s) }
            if gesture == .flickUp {
                if !isOn { return ServiceCall(domain: "fan", service: "turn_on", entityID: entity) }
                return ServiceCall(domain: "fan", service: "increase_speed", entityID: entity, data: stepData)
            }
            guard isOn else { return nil }
            let step = settings.fanStepPct ?? state?.percentageStep ?? (100.0 / 3)
            let atMinimum: Bool = {
                guard let p = state?.percentage else { return true }
                return p <= step + 1e-6
            }()
            if atMinimum && settings.flickDownAtMinimumTurnsOff {
                return ServiceCall(domain: "fan", service: "turn_off", entityID: entity)
            }
            return ServiceCall(domain: "fan", service: "decrease_speed", entityID: entity, data: stepData)
        }
    }
}
