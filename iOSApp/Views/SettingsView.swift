import SwiftUI
import WatchMagicKit

struct SettingsView: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var traces: TraceStore

    @State private var confirmReset = false

    private var s: Settings { store.config.settings }

    private func binding<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(
            get: { store.config.settings[keyPath: keyPath] },
            set: { v in store.updateSettings { $0[keyPath: keyPath] = v } }
        )
    }

    var body: some View {
        Form {
            Section {
                Stepper(value: binding(\.brightnessStepPct), in: 5...50, step: 5) {
                    LabeledContent("Brightness step", value: "\(s.brightnessStepPct.compact)%")
                }
                Toggle("Fan step: entity default", isOn: Binding(
                    get: { s.fanStepPct == nil },
                    set: { useDefault in store.updateSettings { $0.fanStepPct = useDefault ? nil : 10 } }
                ))
                if let fan = s.fanStepPct {
                    Stepper(value: Binding(
                        get: { fan },
                        set: { v in store.updateSettings { $0.fanStepPct = v } }
                    ), in: 5...50, step: 5) {
                        LabeledContent("Fan step", value: "\(fan.compact)%")
                    }
                }
                Toggle("Flick down at minimum turns off", isOn: binding(\.flickDownAtMinimumTurnsOff))
                Toggle("Always listening on the watch", isOn: binding(\.alwaysListening))
            } header: {
                Text("Actions")
            } footer: {
                Text("With \"entity default\", each fan uses its own percentage_step.")
            }

            Section {
                Stepper(value: binding(\.aimToleranceDeg), in: 3...30, step: 1) {
                    LabeledContent("Aim tolerance", value: "\(s.aimToleranceDeg.compact)°")
                }
                Stepper(value: binding(\.ambiguityMarginDeg), in: 1...15, step: 1) {
                    LabeledContent("Ambiguity margin", value: "\(s.ambiguityMarginDeg.compact)°")
                }
                Stepper(value: binding(\.aimHoldMs), in: 100...1500, step: 50) {
                    LabeledContent("Aim-hold time", value: "\(s.aimHoldMs.compact) ms")
                }
                Stepper(value: binding(\.gestureWindowS), in: 0.5...5, step: 0.25) {
                    LabeledContent("Gesture window", value: "\(s.gestureWindowS.compact) s")
                }
            } header: {
                Text("Aiming")
            }

            Section {
                Picker("Sensitivity", selection: binding(\.sensitivity)) {
                    ForEach(GestureSensitivity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Gesture sensitivity")
            } footer: {
                Text("Low needs sharper flicks (fewer false triggers); high reacts to gentler ones.")
            }

            Section {
                Button("Reset to defaults", role: .destructive) { confirmReset = true }
                    .disabled(s == Settings())
            }

            HouseSettingsSection()

            Section {
                NavigationLink {
                    GestureTrainingView()
                } label: {
                    Label("Train gestures", systemImage: "hand.point.up.left.and.text")
                }
            } footer: {
                Text("Records labelled flicks and twists on the watch (guided from here) for a trained gesture model.")
            }

            trainingSection

            tracesSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { traces.refresh() }
        .confirmationDialog("Reset all tuning settings to their defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { store.resetSettings() }
        }
    }

    private var trainingSection: some View {
        Section {
            if traces.training.isEmpty {
                Text("No training data yet. Use Train gestures.")
                    .foregroundStyle(.secondary)
            }
            ForEach(traces.training) { file in
                fileRow(file)
            }
            .onDelete { offsets in
                traces.delete(offsets.map { traces.training[$0] })
            }
            if traces.training.count > 1 {
                ShareLink(items: traces.training.map(\.url)) {
                    Label("Share all training data", systemImage: "square.and.arrow.up.on.square")
                }
            }
        } header: {
            Text("Training data")
        } footer: {
            Text("train-<label>-<time>.csv from the watch (comment header: label, cue times, wrist, rate). Swipe to delete.")
        }
    }

    private func fileRow(_ file: TraceStore.TraceFile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Text("\(file.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: file.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
        }
    }

    private var tracesSection: some View {
        Section {
            if traces.traces.isEmpty {
                Text("No traces yet. Record one on the watch: Sensor Probe → Record.")
                    .foregroundStyle(.secondary)
            }
            ForEach(traces.traces) { file in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Text("\(file.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: file.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onDelete { offsets in
                traces.delete(offsets.map { traces.traces[$0] })
            }
            if traces.traces.count > 1 {
                ShareLink(items: traces.traces.map(\.url)) {
                    Label("Share all traces", systemImage: "square.and.arrow.up.on.square")
                }
            }
        } header: {
            Text("Motion traces")
        } footer: {
            Text("CSV traces recorded on the watch, for gesture test fixtures. Share via AirDrop or Files; swipe to delete.")
        }
    }
}
