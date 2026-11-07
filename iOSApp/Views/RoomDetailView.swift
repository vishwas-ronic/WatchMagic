import SwiftUI
import WatchMagicKit

struct RoomDetailView: View {
    let roomID: UUID
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var house: HouseService

    @State private var name = ""
    @State private var didLoad = false
    @State private var showPicker = false
    @State private var showPlacement = false

    private var room: Room? { store.config.room(id: roomID) }

    var body: some View {
        Group {
            if let room {
                form(room)
            } else {
                ContentUnavailableView("Room deleted", systemImage: "square.dashed")
            }
        }
        .navigationTitle(room?.name ?? "Room")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didLoad, let room else { return }
            didLoad = true
            name = room.name
        }
        .onDisappear(perform: commitName)
        .sheet(isPresented: $showPicker) {
            DevicePickerView(roomID: roomID)
        }
        .fullScreenCover(isPresented: $showPlacement) {
            if let room {
                PlacementView(roomID: room.id, devices: store.config.devices(in: room), existingSeat: room.seat)
                    .environmentObject(store)
                    .environmentObject(house)
            }
        }
    }

    private func form(_ room: Room) -> some View {
        let devices = store.config.devices(in: room)
        let refs = ReferenceDirections(room: room, config: store.config)
        let isCurrent = store.config.currentRoomID == room.id

        return Form {
            Section("Name") {
                TextField("Room name", text: $name)
                    .onSubmit(commitName)
                    .submitLabel(.done)
            }

            Section {
                if isCurrent {
                    Label("This is your current room", systemImage: "location.fill")
                        .foregroundStyle(.tint)
                } else {
                    Button {
                        store.setCurrentRoom(room.id)
                    } label: {
                        Label("Set as current room", systemImage: "location")
                    }
                }
            }

            Section {
                Button {
                    showPlacement = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Place devices with camera").font(.headline)
                            Text("Aim your iPhone at each device and set your seat — no typing coordinates.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "camera.viewfinder").font(.title2)
                    }
                    .padding(.vertical, 4)
                }
                alignmentCard(room: room, devices: devices, refs: refs)
            }

            HouseRoomSection(room: room)

            Section {
                OptionalVectorField(value: room.seat) { v in
                    store.updateRoom(room.id) { $0.seat = v }
                }
            } header: {
                Text("Seat position (m)")
            } footer: {
                Text("Optional. Where you usually sit, in a room frame of your choosing (x, y on the floor, z up). Needed only for devices placed by coordinates. Placing with the camera sets it for you and replaces typed values.")
            }

            Section {
                if devices.isEmpty {
                    Text("No devices yet.").foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    NavigationLink {
                        DeviceEditorView(deviceID: device.id, roomID: room.id)
                    } label: {
                        DeviceRow(device: device)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { store.removeDevice(devices[i].id, fromRoom: room.id) }
                }
                .onMove { from, to in
                    store.moveDevices(inRoom: room.id, from: from, to: to)
                }
                Button {
                    showPicker = true
                } label: {
                    Label("Add devices", systemImage: "plus.circle")
                }
                if !devices.isEmpty {
                    Button {
                        Task {
                            // Older imports lack HA device names; fetch them first (best effort).
                            if store.importCache?.deviceNames == nil { _ = try? await store.refreshImport() }
                            store.tidyNames(inRoom: room.id)
                        }
                    } label: {
                        Label("Tidy names", systemImage: "textformat")
                    }
                }
            } header: {
                HStack {
                    Text("Devices")
                    Spacer()
                    if !devices.isEmpty { EditButton().font(.caption) }
                }
            } footer: {
                Text("Teach devices on the watch (Teach mode) from your seat for the best aim.")
            }

            Section {
                LabeledContent("Compass offset") {
                    if let off = refs.compassOffsetDeg {
                        Text(String(format: "%.1f°", off) + (refs.compassOffsetSource == .house ? " (from house)" : ""))
                    } else {
                        Text("Not derived").foregroundStyle(.secondary)
                    }
                }
                if let bias = refs.pitchBiasDeg {
                    LabeledContent("Pitch bias", value: String(format: "%+.1f°", bias))
                }
                Picker("Anchor device", selection: Binding(
                    get: { room.anchorDeviceID },
                    set: { id in store.updateRoom(room.id) { $0.anchorDeviceID = id } }
                )) {
                    Text("Automatic (first taught)").tag(UUID?.none)
                    ForEach(devices) { d in
                        Text(d.name).tag(UUID?.some(d.id))
                    }
                }
                if let anchor = ReferenceDirections.anchor(room: room, devices: store.config.devices,
                                                           house: HouseCalibration(config: store.config)),
                   let d = store.config.device(id: anchor.id) {
                    LabeledContent("Zero-gesture target", value: d.name)
                } else {
                    Text("No anchor yet: teach a device, or give the anchor coordinates and teach one device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Calibration")
            } footer: {
                Text("The compass offset and pitch bias come from devices that are both taught and have coordinates — in this room, or (for a room aligned to the house model) in any aligned room. The anchor is used when the watch has no compass heading: point at it and hold to zero.")
            }

            Section {
                Button(role: .destructive) {
                    store.deleteRooms([room.id])
                } label: {
                    Label("Delete room", systemImage: "trash")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
    }

    /// "Teach one placed device" hint, or "Aligned ✓" once a placed device is taught.
    @ViewBuilder
    private func alignmentCard(room: Room, devices: [ControlledDevice], refs: ReferenceDirections) -> some View {
        let placed = devices.filter { $0.coordinates != nil }
        if !placed.isEmpty {
            if room.seat == nil {
                Label("Set your seat (Place devices with camera → Set my seat) so placed devices can be aimed at.",
                      systemImage: "chair.lounge")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if let off = refs.compassOffsetDeg {
                Label(String(format: refs.compassOffsetSource == .house ? "Aligned via the house ✓ (offset %.0f°)" : "Aligned ✓ (offset %.0f°)", off),
                      systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else {
                Label("Teach any one placed device on the watch to align this room.", systemImage: "applewatch")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let room, !n.isEmpty, n != room.name else { return }
        store.renameRoom(room.id, to: n)
    }
}

struct DeviceRow: View {
    let device: ControlledDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.kind.symbolName)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(device.entityID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            CalibrationBadge(status: device.calibrationStatus)
        }
    }
}
