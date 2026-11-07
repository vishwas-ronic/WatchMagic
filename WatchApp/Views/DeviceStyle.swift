import SwiftUI
import WatchMagicKit

/// Display helpers for a controlled device (icon, state text).
enum DeviceStyle {
    static func symbol(for kind: DeviceKind, isOn: Bool) -> String {
        switch kind {
        case .dimmableLight, .onOffLight: return isOn ? "lightbulb.fill" : "lightbulb"
        case .switch: return isOn ? "switch.2" : "power"
        case .fan: return isOn ? "fan.fill" : "fan"
        }
    }

    static func stateText(_ state: EntityState?, kind: DeviceKind) -> String {
        guard let state else { return "—" }
        switch state.state {
        case "on":
            if kind == .dimmableLight, let pct = state.brightnessPct { return String(format: "On · %.0f%%", pct) }
            if kind == .fan, let pct = state.percentage { return String(format: "On · %.0f%%", pct) }
            return "On"
        case "off": return "Off"
        default: return state.state.capitalized
        }
    }

    static func color(_ state: EntityState?) -> Color {
        state?.isOn == true ? .yellow : .secondary
    }
}
