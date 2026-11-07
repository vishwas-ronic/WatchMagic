import SwiftUI
import WatchMagicKit

/// Choose Home Assistant entities to add to a room (multi-select).
struct DevicePickerView: View {
    let roomID: UUID
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var domain: EntityDomain = .all
    @State private var selection = Set<String>()
    @State private var loading = false
    @State private var error: String?

    private var inRoom: Set<String> {
        guard let room = store.config.room(id: roomID) else { return [] }
        return Set(store.config.devices(in: room).map(\.entityID))
    }

    private var filtered: [EntityState] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return (store.importCache?.states ?? []).filter { s in
            domain.matches(s.entityID)
                && (q.isEmpty || s.displayName.lowercased().contains(q) || s.entityID.lowercased().contains(q))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Domain", selection: $domain) {
                        ForEach(EntityDomain.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if store.importCache == nil && !loading && error == nil {
                    Section { Text("Connect to Home Assistant to list devices.").foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(filtered) { state in
                        let added = inRoom.contains(state.entityID)
                        Button {
                            toggle(state.entityID)
                        } label: {
                            HStack {
                                Image(systemName: added || selection.contains(state.entityID) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(added ? Color.secondary : Color.accentColor)
                                EntityRow(state: state, title: ConfigStore.cleanName(
                                    entityID: state.entityID, fallback: state.displayName, cache: store.importCache,
                                    roomName: store.config.room(id: roomID)?.name ?? ""))
                            }
                        }
                        .foregroundStyle(.primary)
                        .disabled(added)
                    }
                } header: {
                    if let cache = store.importCache {
                        Text("Updated \(cache.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
            .overlay {
                if loading && store.importCache == nil { ProgressView("Loading entities…") }
            }
            .searchable(text: $search, prompt: "Search entities")
            .refreshable { await load() }
            .navigationTitle("Add devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.isEmpty ? "Add" : "Add (\(selection.count))") {
                        let cacheOrder = (store.importCache?.states ?? []).map(\.entityID)
                        store.addEntities(cacheOrder.filter(selection.contains), toRoom: roomID)
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .task {
                if store.importCache?.states.isEmpty ?? true { await load() }
            }
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func load() async {
        guard store.hasToken else {
            error = "No Home Assistant token. Connect first."
            return
        }
        loading = true
        defer { loading = false }
        do {
            try await store.refreshImport()
            error = nil
        } catch {
            self.error = ConnectView.message(for: error)
        }
    }
}
