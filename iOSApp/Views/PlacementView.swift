import RealityKit
import SwiftUI
import WatchMagicKit

/// "Place devices with camera": full-screen AR. Aim the centre square at a
/// device and tap Place; sit in your seat and tap Set my seat; Save writes the
/// seat and device coordinates (room frame) in one config update.
struct PlacementView: View {
    let roomID: UUID

    @EnvironmentObject private var store: ConfigStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: PlacementSession

    @State private var selectedID: UUID?
    @State private var missHint: String?
    @State private var confirmStale = false
    @State private var confirmDiscard = false
    @State private var saving = false
    @State private var mapWarning: String?

    init(roomID: UUID, devices: [ControlledDevice], existingSeat: Vector3?) {
        self.roomID = roomID
        _session = StateObject(wrappedValue: PlacementSession(roomID: roomID, devices: devices, existingSeat: existingSeat))
    }

    private var room: Room? { store.config.room(id: roomID) }
    private var devices: [ControlledDevice] { room.map { store.config.devices(in: $0) } ?? [] }

    var body: some View {
        ZStack {
            ARViewContainer(arView: session.arView)
                .ignoresSafeArea()
            ReticleOverlay(active: session.hitDistance != nil)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 8) {
                topBar
                banners
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .statusBarHidden()
        .onAppear {
            session.start()
            if selectedID == nil { selectedID = nextUnplaced(after: nil) }
        }
        .onDisappear { session.stop() }
        .confirmationDialog(staleTitle, isPresented: $confirmStale, titleVisibility: .visible) {
            Button("Save and clear them", role: .destructive) { Task { await save() } }
            Button("Keep placing", role: .cancel) {}
        } message: {
            Text("\(staleNames). They were placed in an earlier session this one couldn't match, so their old positions would point the wrong way. Their coordinates will be cleared.")
        }
        .confirmationDialog("Discard this session's placements?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep placing", role: .cancel) {}
        }
        .alert("Placements saved", isPresented: Binding(get: { mapWarning != nil }, set: { if !$0 { mapWarning = nil } })) {
            Button("OK") { dismiss() }
        } message: {
            Text(mapWarning ?? "")
        }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack {
            Button {
                if session.hasChanges { confirmDiscard = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Cancel")
            Spacer()
            Text(room?.name ?? "Room")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            Button {
                attemptSave()
            } label: {
                Text(saving ? "Saving…" : "Save")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(canSave ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                    .foregroundStyle(canSave ? .white : .secondary)
            }
            .disabled(!canSave || saving)
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var banners: some View {
        if let error = session.errorMessage {
            banner(error, symbol: "exclamationmark.triangle.fill", color: .red)
        } else if session.frameState == .relocalizing {
            VStack(spacing: 8) {
                banner("Look around to find your saved placements…", symbol: "arrow.triangle.2.circlepath.camera", color: .orange)
                Button("Start a new map instead") { session.startFresh() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        } else {
            if session.frameState == .relocalized {
                banner("Found your saved placements — re-place any device, or add new ones.", symbol: "checkmark.circle.fill", color: .green)
            } else if session.frameState == .fresh, !staleIDs.isEmpty {
                banner("New map: \(staleIDs.count) device\(staleIDs.count == 1 ? "" : "s") placed earlier will need re-placing.",
                       symbol: "info.circle.fill", color: .orange)
            }
            if let msg = session.trackingMessage {
                banner(msg, symbol: "camera.metering.unknown", color: .yellow)
            }
        }
    }

    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Bottom

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            Text(distanceText)
                .font(.callout.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())

            if devices.isEmpty {
                Text("Add devices to this room first — you can still set your seat.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                devicePicker
            }

            HStack(spacing: 10) {
                Button {
                    session.setSeat()
                } label: {
                    Label(seatSet ? "Seat ✓" : "Set my seat", systemImage: "chair.lounge")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(seatSet ? .blue : .primary)
                .disabled(!session.canPlace)

                Button {
                    placeSelected()
                } label: {
                    Label(placeTitle, systemImage: "scope")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedID == nil || !session.canPlace)

                Button {
                    session.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(!session.canUndo)
                .accessibilityLabel("Undo")
            }
            .controlSize(.large)

            Text(seatSet
                 ? "Aim the square at a device and tap Place. Re-place to correct it."
                 : "Sit in your usual spot and hold the phone where your wrist is when you point, then tap Set my seat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var devicePicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(devices) { d in
                        let status = placementStatus(d)
                        Button {
                            selectedID = d.id
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: d.kind.symbolName)
                                Text(d.name).lineLimit(1)
                                if status != .none {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(status == .now ? Color.green : Color.secondary)
                                }
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selectedID == d.id ? AnyShapeStyle(Color.accentColor.opacity(0.3)) : AnyShapeStyle(.thinMaterial),
                                        in: Capsule())
                            .overlay(Capsule().stroke(selectedID == d.id ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .id(d.id)
                    }
                }
            }
            .onChange(of: selectedID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    // MARK: - Derived

    private enum PlacementStatus { case none, earlier, now }

    private func placementStatus(_ d: ControlledDevice) -> PlacementStatus {
        if session.placed[d.id] != nil { return .now }
        if session.sameFrame, d.coordinates != nil { return .earlier }
        return .none
    }

    private var seatSet: Bool {
        session.seat != nil || (session.sameFrame && room?.seat != nil)
    }

    private var canSave: Bool {
        session.errorMessage == nil && session.hasChanges && session.makePlacement().canSave(in: store.config)
    }

    private var staleIDs: [UUID] { session.makePlacement().staleDeviceIDs(in: store.config) }

    private var staleTitle: String {
        let n = staleIDs.count
        return "\(n) device\(n == 1 ? "" : "s") placed earlier will need re-placing"
    }

    private var staleNames: String {
        staleIDs.compactMap { store.config.device(id: $0)?.name }.joined(separator: ", ")
    }

    private var placeTitle: String {
        guard let id = selectedID, let d = store.config.device(id: id) else { return "Place" }
        return session.placed[id] == nil ? "Place \(d.name)" : "Re-place \(d.name)"
    }

    private var distanceText: String {
        if let hint = missHint { return hint }
        if !session.canPlace { return "–" }
        guard let d = session.hitDistance else { return "Move closer / aim at a surface" }
        return String(format: "%.1f m", d)
    }

    /// Next device (room order, after `id`, wrapping) not placed in this session
    /// and not already placed in this frame.
    private func nextUnplaced(after id: UUID?) -> UUID? {
        let list = devices
        guard !list.isEmpty else { return nil }
        let start = id.flatMap { cur in list.firstIndex { $0.id == cur } }.map { $0 + 1 } ?? 0
        for k in 0..<list.count {
            let d = list[(start + k) % list.count]
            if placementStatus(d) == .none { return d.id }
        }
        return id ?? list.first?.id
    }

    // MARK: - Actions

    private func placeSelected() {
        guard let id = selectedID else { return }
        if session.place(deviceID: id) {
            missHint = nil
            selectedID = nextUnplaced(after: id)
        } else {
            missHint = "Move closer / aim at a surface"
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            Task {
                try? await Task.sleep(for: .seconds(2))
                missHint = nil
            }
        }
    }

    private func attemptSave() {
        if staleIDs.isEmpty {
            Task { await save() }
        } else {
            confirmStale = true
        }
    }

    private func save() async {
        guard !saving else { return }
        let placement = session.makePlacement()
        guard placement.canSave(in: store.config) else { return }
        saving = true
        let warning = await session.saveWorldMap()
        store.update { placement.apply(to: &$0) } // one update → one sync push
        saving = false
        if let warning {
            mapWarning = warning
        } else {
            dismiss()
        }
    }
}

// MARK: - AR view + reticle

private struct ARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// Dims everything outside a centred square; the raycast goes through its centre.
private struct ReticleOverlay: View {
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.28
            let square = CGRect(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2, width: side, height: side)
            ZStack {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRoundedRect(in: square, cornerSize: CGSize(width: 12, height: 12))
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                RoundedRectangle(cornerRadius: 12)
                    .stroke(active ? Color.white : Color.white.opacity(0.5), lineWidth: 2)
                    .frame(width: side, height: side)
                    .position(x: square.midX, y: square.midY)

                Circle()
                    .fill(active ? Color.green : Color.white.opacity(0.6))
                    .frame(width: 8, height: 8)
                    .position(x: square.midX, y: square.midY)
            }
        }
    }
}
