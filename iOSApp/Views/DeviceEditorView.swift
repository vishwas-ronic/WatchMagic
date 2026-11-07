import SwiftUI
import WatchMagicKit

struct DeviceEditorView: View {
    let deviceID: UUID
    let roomID: UUID
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var didLoad = false
    /// Entity state fetched live when the import cache lacks it (for dimmability).
    @State private var fetchedState: EntityState?
    @State private var confirmClear = false

    private var device: ControlledDevice? { store.config.device(id: deviceID) }

    private var entityState: EntityState? {
        guard let device else { return nil }
        return store.importCache?.state(for: device.entityID) ?? fetchedState
    }

    /// The kind inferred from the domain and supported_color_modes.
    private var inferredKind: DeviceKind? {
        guard let device else { return nil }
        return DeviceKind.infer(entityID: device.entityID, supportedColorModes: entityState?.supportedColorModes)
    }

    var body: some View {
        Group {
            if let device {
                form(device)
            } else {
                ContentUnavailableView("Device removed", systemImage: "square.dashed")
            }
        }
        .navigationTitle(device?.name ?? "Device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didLoad, let device else { return }
            didLoad = true
            name = device.name
        }
        .onDisappear(perform: commitName)
        .task { await fetchStateIfNeeded() }
    }

    private func form(_ device: ControlledDevice) -> some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit(commitName)
                    .submitLabel(.done)
                LabeledContent("Entity", value: device.entityID)
                    .font(.callout)
                if let s = entityState {
                    LabeledContent("State", value: s.state)
                }
            }

            Section {
                Picker("Type", selection: Binding(
                    get: { device.kind },
                    set: { k in
                        store.updateDevice(device.id) {
                            $0.kind = k
                            $0.kindOverridden = (k != inferredKind)
                        }
                    }
                )) {
                    ForEach(DeviceKind.allCases, id: \.self) { k in
                        Label(k.displayName, systemImage: k.symbolName).tag(k)
                    }
                }
                if let inferred = inferredKind {
                    LabeledContent("Inferred", value: inferred.displayName)
                        .foregroundStyle(.secondary)
                    if device.kind != inferred || device.kindOverridden {
                        Button("Reset to inferred type") {
                            store.updateDevice(device.id) {
                                $0.kind = inferred
                                $0.kindOverridden = false
                            }
                        }
                    }
                }
            } header: {
                Text("Type")
            } footer: {
                if device.domain == "light" && entityState == nil {
                    Text("Import from Home Assistant to detect whether this light is dimmable.")
                }
            }

            Section {
                OptionalVectorField(value: device.coordinates) { v in
                    store.updateDevice(device.id) { $0.coordinates = v }
                }
            } header: {
                Text("Coordinates (m)")
            } footer: {
                Text("Optional. Position in the same frame as the room's seat. “Place devices with camera” in the room replaces typed coordinates.")
            }

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    CalibrationBadge(status: device.calibrationStatus)
                }
                if let t = device.taughtVector {
                    LabeledContent("Taught direction",
                                   value: String(format: "heading %.0f°, pitch %.0f°", t.compassHeadingDeg, t.pitchDeg))
                    Button("Clear taught vector", role: .destructive) { confirmClear = true }
                }
            } header: {
                Text("Calibration")
            } footer: {
                Text("Teach this device on the watch (Teach mode) while sitting in your usual seat.")
            }

            Section {
                Button("Remove from room", role: .destructive) {
                    store.removeDevice(device.id, fromRoom: roomID)
                    dismiss()
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
        .confirmationDialog("Clear the taught direction?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { store.setTaughtVector(nil, forDevice: device.id) }
        } message: {
            Text("The device will fall back to its coordinates, if any.")
        }
    }

    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let device, !n.isEmpty, n != device.name else { return }
        store.updateDevice(device.id) { $0.name = n }
    }

    private func fetchStateIfNeeded() async {
        guard let device, store.importCache?.state(for: device.entityID) == nil,
              fetchedState == nil, let client = store.makeClient() else { return }
        fetchedState = try? await client.entityState(device.entityID)
    }
}
