import SwiftUI
import WatchMagicKit

struct HomeView: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var sync: PhoneSyncService

    @State private var showNewRoom = false
    @State private var newRoomName = ""
    @State private var renamingRoom: Room?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    currentRoomPicker
                } footer: {
                    Text("The watch only targets devices in this room.")
                }

                if !store.hasToken {
                    Section {
                        NavigationLink {
                            ConnectView()
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Connect to Home Assistant").font(.headline)
                                    Text("Enter your server URL and a long-lived access token to import devices and rooms.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "house.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(.tint)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Apple Watch") {
                    SyncStatusCard()
                }

                Section {
                    if store.config.rooms.isEmpty {
                        Text("No rooms yet. Tap + to create one, or import areas from Home Assistant.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.config.rooms) { room in
                        NavigationLink(value: room.id) {
                            roomRow(room)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.deleteRooms([room.id])
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renameText = room.name
                                renamingRoom = room
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                    }
                } header: {
                    Text("Rooms")
                } footer: {
                    if !store.config.rooms.isEmpty {
                        Text("Swipe a room to rename or delete it.")
                    }
                }

                Section {
                    NavigationLink {
                        ConnectView()
                    } label: {
                        LabeledContent {
                            Text(store.hasToken ? "Token saved" : "Not connected")
                                .foregroundStyle(store.hasToken ? Color.secondary : Color.orange)
                        } label: {
                            Label("Home Assistant", systemImage: "house")
                        }
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings & traces", systemImage: "slider.horizontal.3")
                    }
                }

                if let err = store.lastSaveError {
                    Section { Text(err).foregroundStyle(.red) }
                }
            }
            .navigationTitle("WatchMagic")
            .navigationDestination(for: UUID.self) { id in
                RoomDetailView(roomID: id)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newRoomName = ""
                        showNewRoom = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add room")
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .alert("New room", isPresented: $showNewRoom) {
                TextField("Name", text: $newRoomName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { store.addRoom(name: name) }
                }
            }
            .alert("Rename room", isPresented: Binding(
                get: { renamingRoom != nil },
                set: { if !$0 { renamingRoom = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingRoom = nil }
                Button("Save") {
                    if let r = renamingRoom { store.renameRoom(r.id, to: renameText) }
                    renamingRoom = nil
                }
            }
        }
    }

    // MARK: Current room

    private var currentRoomPicker: some View {
        Menu {
            Picker("Current room", selection: Binding(
                get: { store.config.currentRoomID },
                set: { store.setCurrentRoom($0) }
            )) {
                Text("None").tag(UUID?.none)
                ForEach(store.config.rooms) { room in
                    Text(room.name).tag(UUID?.some(room.id))
                }
            }
            .pickerStyle(.inline)
            if store.config.rooms.isEmpty {
                Button("Add a room first…") {
                    newRoomName = ""
                    showNewRoom = true
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("I'm in:")
                    .foregroundStyle(.secondary)
                Text(store.config.currentRoom?.name ?? "No room")
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
            }
            .font(.largeTitle.weight(.bold))
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .accessibilityLabel("Current room: \(store.config.currentRoom?.name ?? "none")")
    }

    private func roomRow(_ room: Room) -> some View {
        let devices = store.config.devices(in: room)
        let taught = devices.filter { $0.calibrationStatus == .taught }.count
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(room.name).font(.body.weight(.medium))
                    if room.id == store.config.currentRoomID {
                        Image(systemName: "location.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Current room")
                    }
                }
                Text("\(devices.count) device\(devices.count == 1 ? "" : "s") · \(taught) taught")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Sync status

struct SyncStatusCard: View {
    @EnvironmentObject private var sync: PhoneSyncService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.tint)
                    if let last = sync.lastSyncedAt {
                        Text("Last synced \(Self.relative(last, now: context.date))")
                    } else {
                        Text("Not synced yet")
                    }
                    Spacer()
                    Button("Sync now") { sync.pushNow() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            HStack(spacing: 14) {
                statusPill("Paired", ok: sync.isPaired)
                statusPill("App installed", ok: sync.isWatchAppInstalled)
                statusPill("Reachable", ok: sync.isReachable)
            }
            if let err = sync.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusPill(_ title: String, ok: Bool) -> some View {
        Label(title, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .font(.caption)
            .foregroundStyle(ok ? Color.green : Color.secondary)
            .labelStyle(.titleAndIcon)
    }

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 10 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}
