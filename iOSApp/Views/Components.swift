import SwiftUI
import UIKit
import WatchMagicKit

// MARK: - OptionalVectorField

/// Three decimal fields for an optional (x, y, z) position in metres.
/// All empty = nil. Values are committed as soon as all three parse (or all are
/// cleared); a partial entry is flagged and not committed.
struct OptionalVectorField: View {
    let value: Vector3?
    let onCommit: (Vector3?) -> Void

    @State private var x: String
    @State private var y: String
    @State private var z: String

    init(value: Vector3?, onCommit: @escaping (Vector3?) -> Void) {
        self.value = value
        self.onCommit = onCommit
        _x = State(initialValue: value.map { Self.format($0.x) } ?? "")
        _y = State(initialValue: value.map { Self.format($0.y) } ?? "")
        _z = State(initialValue: value.map { Self.format($0.z) } ?? "")
    }

    private enum Parsed: Equatable {
        case empty, vector(Vector3), invalid
    }

    private var parsed: Parsed {
        let parts = [x, y, z].map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.allSatisfy(\.isEmpty) { return .empty }
        let nums = parts.map { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard let a = nums[0], let b = nums[1], let c = nums[2],
              a.isFinite, b.isFinite, c.isFinite else { return .invalid }
        return .vector(Vector3(a, b, c))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                axisField("x", text: $x)
                axisField("y", text: $y)
                axisField("z", text: $z)
                if !(x.isEmpty && y.isEmpty && z.isEmpty) {
                    Button {
                        x = ""; y = ""; z = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear")
                }
            }
            if parsed == .invalid {
                Text("Enter x, y and z in metres, or leave all three empty.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onChange(of: x) { commitIfValid() }
        .onChange(of: y) { commitIfValid() }
        .onChange(of: z) { commitIfValid() }
        .onChange(of: value) { _, newValue in
            // External change (e.g. reset): resync the text unless it already matches.
            let current: Vector3? = { if case .vector(let v) = parsed { return v } else { return nil } }()
            if newValue != current, !(newValue == nil && parsed == .invalid) {
                x = newValue.map { Self.format($0.x) } ?? ""
                y = newValue.map { Self.format($0.y) } ?? ""
                z = newValue.map { Self.format($0.z) } ?? ""
            }
        }
    }

    private func axisField(_ axis: String, text: Binding<String>) -> some View {
        HStack(spacing: 2) {
            Text(axis).font(.caption.monospaced()).foregroundStyle(.secondary)
            TextField("–", text: text)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
        }
    }

    private func commitIfValid() {
        switch parsed {
        case .empty: if value != nil { onCommit(nil) }
        case .vector(let v): if value != v { onCommit(v) }
        case .invalid: break
        }
    }

    static func format(_ d: Double) -> String {
        String(format: "%g", d)
    }
}

// MARK: - Badges & icons

struct CalibrationBadge: View {
    let status: CalibrationStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .taught: return .green
        case .coordinatesOnly: return .orange
        case .notPlaced: return .secondary
        }
    }
}

extension DeviceKind {
    var symbolName: String {
        switch self {
        case .dimmableLight: return "lightbulb.max"
        case .onOffLight: return "lightbulb"
        case .switch: return "switch.2"
        case .fan: return "fan"
        }
    }
}

enum EntityDomain: String, CaseIterable, Identifiable {
    case all, light, fan, `switch`
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .light: return "Lights"
        case .fan: return "Fans"
        case .switch: return "Switches"
        }
    }
    func matches(_ entityID: String) -> Bool {
        self == .all || ControlledDevice.domain(of: entityID) == rawValue
    }
}

// MARK: - Keyboard

extension View {
    /// Adds a "Done" button above the keyboard (number pads have no return key).
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }
}

extension Double {
    /// "12", "1.5" — compact display for settings and angles.
    var compact: String { String(format: "%g", self) }
}
