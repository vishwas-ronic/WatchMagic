import SwiftUI
import WatchMagicKit

struct RoomDetailView: View {
    let roomID: UUID
    @EnvironmentObject private var store: ConfigStore

    @State private var name = ""
    @State private var didLoad = false
    @State private var showPicker = false

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
    }

    private func form(_ room: Room) -> some View {
        let devices = store.config.devices(in: room)
        let refs = ReferenceDirections(room: room, devices: devices)
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
                OptionalVectorField(value: room.seat) { v in
                    store.updateRoom(room.id) { $0.seat = v }
                }
            } header: {
                Text("Seat position (m)")
            } footer: {
                Text("Optional. Where you usually sit, in a room frame of your choosing (x, y on the floor, z up). Needed only for devices placed by coordinates.")
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
                        Text(String(format: "%.1f°", off))
                    } else {
                        Text("Not derived").foregroundStyle(.secondary)
                    }
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
                if let anchor = ReferenceDirections.anchor(room: room, devices: devices),
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
                Text("The compass offset comes from devices that are both taught and have coordinates. The anchor is used when the watch has no compass heading: point at it and hold to zero.")
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
