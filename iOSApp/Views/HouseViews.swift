import SwiftUI
import WatchMagicKit

// MARK: - Room detail: "House model" section

/// Matches a room to a space of HA's house model, shows its alignment, and
/// sends positions to the 3D view.
struct HouseRoomSection: View {
    let room: Room
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var house: HouseService

    var body: some View {
        Section {
            if let model = house.houseModel {
                NavigationLink {
                    HouseSpacePickerView(roomID: room.id, model: model)
                } label: {
                    LabeledContent("Space") {
                        if let id = room.houseSpaceID {
                            Text(model.space(id: id).map { "\($0.displayName) · \($0.id)" } ?? "\(id) (not in model)")
                        } else {
                            Text("Choose…").foregroundStyle(.secondary)
                        }
                    }
                }
                if let space = house.space(for: room) {
                    HouseOutlineView(polygon: space.poly, corners: [], selected: [], highlighted: room.houseAlignmentIfValid?.houseCorners ?? [])
                        .frame(height: 120)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    alignmentStatus
                }
            } else {
                Button {
                    Task { await house.refreshHouseModel() }
                } label: {
                    Label(house.loading ? "Loading house model…" : "Load house model from Home Assistant",
                          systemImage: "house.lodge")
                }
                .disabled(house.loading || !store.hasToken)
            }
            if let err = house.loadError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
            if room.houseAlignmentIfValid != nil {
                SendLayoutButton()
            }
        } header: {
            Text("House model")
        } footer: {
            Text("Match this room to its space in Home Assistant's 3D house, then use “Place devices with camera → Align to house” and mark two of its floor corners. Positions are then sent to the 3D view in house coordinates.")
        }
    }

    @ViewBuilder
    private var alignmentStatus: some View {
        if let a = room.houseAlignmentIfValid {
            if a.fitIsPoor {
                Label(String(format: "Aligned, but fit error %.2f m — re-mark the corners", a.fitErrorM),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            } else {
                Label(String(format: "Aligned to house ✓, fit error %.2f m", a.fitErrorM), systemImage: "checkmark.seal.fill")
                    .font(.footnote).foregroundStyle(.green)
            }
        } else {
            Label("Not aligned — Place devices with camera → Align to house", systemImage: "square.dashed")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// "Send to Home Assistant" + the last result.
struct SendLayoutButton: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var house: HouseService

    var body: some View {
        Button {
            Task { await house.push() }
        } label: {
            Label(house.pushing ? "Sending…" : "Send to Home Assistant", systemImage: "paperplane")
        }
        .disabled(house.pushing || !store.hasToken)
        if let r = house.lastPushResult {
            Text(r).font(.footnote).foregroundStyle(house.lastPushFailed ? .red : .secondary)
        }
    }
}

// MARK: - Space picker

struct HouseSpacePickerView: View {
    let roomID: UUID
    let model: HouseModel
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    private var room: Room? { store.config.room(id: roomID) }

    var body: some View {
        List {
            if let room, let s = model.suggestedSpace(forRoomName: room.name) {
                Section("Suggested") { row(s) }
            }
            Section {
                Button("None") { choose(nil) }
            }
            ForEach(model.spacesByFloor, id: \.floorID) { group in
                Section(group.floorID.isEmpty ? "Other" : group.floorID.capitalized) {
                    ForEach(group.spaces) { row($0) }
                }
            }
        }
        .navigationTitle("House space")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ s: HouseModel.Space) -> some View {
        Button {
            choose(s.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.displayName).foregroundStyle(.primary)
                    Text(s.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if room?.houseSpaceID == s.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }

    private func choose(_ id: String?) {
        store.updateRoom(roomID) { r in
            r.houseSpaceID = id
            // An alignment belongs to one space.
            if r.houseAlignment?.spaceID != id { r.houseAlignment = nil }
        }
        dismiss()
    }
}

// MARK: - Settings section

struct HouseSettingsSection: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var house: HouseService

    var body: some View {
        let aligned = store.config.rooms.filter { $0.houseAlignmentIfValid != nil }
        let bearing = HouseCalibration(config: store.config).northBearingDeg()
        Section {
            LabeledContent("House model") {
                if let m = house.houseModel {
                    Text("\(m.spaces.count) spaces")
                } else {
                    Text("Not loaded").foregroundStyle(.secondary)
                }
            }
            Button(house.loading ? "Loading…" : "Reload house model") {
                Task { await house.refreshHouseModel() }
            }
            .disabled(house.loading || !store.hasToken)
            if let err = house.loadError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
            LabeledContent("Rooms aligned", value: "\(aligned.count) of \(store.config.rooms.count)")
            if let bearing {
                LabeledContent("House north bearing", value: String(format: "%.1f°", bearing))
            }
            SendLayoutButton()
        } header: {
            Text("3D house view")
        } footer: {
            Text("Sends device and seat positions of aligned rooms to Home Assistant (sensor.watchmagic_layout). The north bearing needs one taught device in an aligned room; it assumes a magnetic declination of +1.0° E.")
        }
    }
}

// MARK: - Plan outline

/// The space polygon drawn like the plan (x right, y DOWN), fitted to the
/// view, with optional tappable corner dots.
struct HouseOutlineView: View {
    let polygon: [PlanPoint]
    /// Tappable corner candidates.
    let corners: [PlanPoint]
    /// Selected corner indices (into `corners`), labelled A, B.
    let selected: [Int]
    /// Extra points to highlight (e.g. the corners an alignment used).
    var highlighted: [PlanPoint] = []
    var marked: Set<Int> = []
    var onTapCorner: ((Int) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let t = Fit(points: polygon + corners, size: geo.size, inset: 14)
            ZStack {
                Path { p in
                    guard let first = polygon.first else { return }
                    p.move(to: t.map(first))
                    for q in polygon.dropFirst() { p.addLine(to: t.map(q)) }
                    p.closeSubpath()
                }
                .fill(Color.accentColor.opacity(0.12))
                Path { p in
                    guard let first = polygon.first else { return }
                    p.move(to: t.map(first))
                    for q in polygon.dropFirst() { p.addLine(to: t.map(q)) }
                    p.closeSubpath()
                }
                .stroke(Color.primary.opacity(0.7), lineWidth: 1.5)

                ForEach(Array(highlighted.enumerated()), id: \.offset) { _, q in
                    Circle().fill(Color.green).frame(width: 8, height: 8).position(t.map(q))
                }

                ForEach(Array(corners.enumerated()), id: \.offset) { i, q in
                    let slot = selected.firstIndex(of: i)
                    ZStack {
                        Circle()
                            .fill(slot == nil ? Color.secondary.opacity(0.6) : (marked.contains(i) ? Color.green : Color.accentColor))
                            .frame(width: slot == nil ? 12 : 22, height: slot == nil ? 12 : 22)
                        if let slot {
                            Text(slot == 0 ? "A" : "B").font(.caption2.bold()).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                    .position(t.map(q))
                    .onTapGesture { onTapCorner?(i) }
                }
            }
        }
    }

    /// Uniform scale + offset fitting plan points into the view (y down, like the plan).
    private struct Fit {
        let scale: CGFloat, ox: CGFloat, oy: CGFloat, minX: Double, minY: Double
        init(points: [PlanPoint], size: CGSize, inset: CGFloat) {
            let xs = points.map(\.x), ys = points.map(\.y)
            minX = xs.min() ?? 0; minY = ys.min() ?? 0
            let w = max((xs.max() ?? 1) - minX, 0.01), h = max((ys.max() ?? 1) - minY, 0.01)
            let aw = max(size.width - 2 * inset, 1), ah = max(size.height - 2 * inset, 1)
            scale = min(aw / w, ah / h)
            ox = inset + (aw - CGFloat(w) * scale) / 2
            oy = inset + (ah - CGFloat(h) * scale) / 2
        }
        func map(_ p: PlanPoint) -> CGPoint {
            CGPoint(x: ox + CGFloat(p.x - minX) * scale, y: oy + CGFloat(p.y - minY) * scale)
        }
    }
}
