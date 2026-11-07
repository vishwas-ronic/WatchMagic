import Foundation
import WatchMagicKit

/// Cached result of the last Home Assistant import (entities + areas).
/// Contains no secrets; persisted next to the config so the device picker
/// works offline.
struct HAImportCache: Codable, Equatable {
    var states: [EntityState]
    var areas: [HAArea]
    var fetchedAt: Date

    func state(for entityID: String) -> EntityState? {
        states.first { $0.entityID == entityID }
    }
}

/// Owns the app's `AppConfig` (persisted as JSON in Application Support) and
/// the Home Assistant token (Keychain). Every mutation saves to disk and calls
/// `onChange`, which the sync service uses to push the config to the watch.
@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var config: AppConfig
    /// The HA token ("" when none). Kept only in memory and the Keychain.
    @Published private(set) var token: String
    @Published private(set) var importCache: HAImportCache?
    /// Last persistence error, for display.
    @Published private(set) var lastSaveError: String?

    /// Called after every config or token change.
    var onChange: (() -> Void)?

    private let configURL: URL
    private let cacheURL: URL

    var hasToken: Bool { !token.isEmpty }

    init() {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = support.appendingPathComponent("WatchMagic", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("config.json")
        cacheURL = dir.appendingPathComponent("ha-import-cache.json")

        config = Self.loadConfig(from: configURL)
        token = Keychain.readToken() ?? ""
        if let data = try? Data(contentsOf: cacheURL) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            importCache = try? dec.decode(HAImportCache.self, from: data)
        }
    }

    private static func loadConfig(from url: URL) -> AppConfig {
        guard let data = try? Data(contentsOf: url) else { return AppConfig() }
        do {
            return try AppConfig.fromJSON(data)
        } catch {
            // Keep the unreadable file for inspection instead of silently overwriting it.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return AppConfig()
        }
    }

    // MARK: - Mutation

    /// Applies `mutate` to the config; if anything changed, saves and notifies.
    func update(_ mutate: (inout AppConfig) -> Void) {
        var c = config
        mutate(&c)
        guard c != config else { return }
        config = c
        save()
        onChange?()
    }

    private func save() {
        do {
            let data = try config.jsonData()
            try data.write(to: configURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastSaveError = nil
        } catch {
            lastSaveError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    /// Saves the token in the Keychain (empty string deletes it).
    func setToken(_ newToken: String) throws {
        let t = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != token else { return }
        if t.isEmpty {
            try Keychain.deleteToken()
        } else {
            try Keychain.saveToken(t)
        }
        token = t
        onChange?()
    }

    func setHAURL(_ url: URL) {
        update { $0.haURL = url }
    }

    /// A client for the stored URL + token, or nil without a token.
    func makeClient() -> HAClient? {
        guard hasToken else { return nil }
        return HAClient(baseURL: config.haURL, token: token)
    }

    // MARK: - Rooms

    @discardableResult
    func addRoom(name: String) -> Room {
        let room = Room(name: name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Room")
        update { c in
            c.rooms.append(room)
            if c.currentRoomID == nil { c.currentRoomID = room.id }
        }
        return room
    }

    func renameRoom(_ id: UUID, to name: String) {
        guard let n = name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return }
        update { c in
            if let i = c.rooms.firstIndex(where: { $0.id == id }) { c.rooms[i].name = n }
        }
    }

    func deleteRooms(_ ids: Set<UUID>) {
        update { c in
            c.rooms.removeAll { ids.contains($0.id) }
            Self.pruneOrphanDevices(&c)
            if let cur = c.currentRoomID, !c.rooms.contains(where: { $0.id == cur }) {
                c.currentRoomID = c.rooms.first?.id
            }
        }
    }

    func setCurrentRoom(_ id: UUID?) {
        update { $0.currentRoomID = id }
    }

    func updateRoom(_ id: UUID, _ mutate: (inout Room) -> Void) {
        update { c in
            if let i = c.rooms.firstIndex(where: { $0.id == id }) { mutate(&c.rooms[i]) }
        }
    }

    func moveDevices(inRoom roomID: UUID, from: IndexSet, to: Int) {
        updateRoom(roomID) { $0.deviceIDs.move(fromOffsets: from, toOffset: to) }
    }

    // MARK: - Devices

    /// Builds a device from an HA entity (kind inferred from the domain and
    /// `supported_color_modes`, name = friendly name).
    static func makeDevice(entityID: String, state: EntityState?) -> ControlledDevice {
        let kind = DeviceKind.infer(entityID: entityID, supportedColorModes: state?.supportedColorModes) ?? .switch
        return ControlledDevice(entityID: entityID, name: state?.displayName ?? entityID, kind: kind)
    }

    /// Adds entities to a room, skipping ones already in it.
    func addEntities(_ entityIDs: [String], toRoom roomID: UUID) {
        update { c in
            guard let i = c.rooms.firstIndex(where: { $0.id == roomID }) else { return }
            let existing = Set(c.devices(in: c.rooms[i]).map(\.entityID))
            for eid in entityIDs where !existing.contains(eid) {
                let d = Self.makeDevice(entityID: eid, state: importCache?.state(for: eid))
                c.devices.append(d)
                c.rooms[i].deviceIDs.append(d.id)
            }
        }
    }

    /// Removes a device from a room (and from the config if no room uses it).
    func removeDevice(_ deviceID: UUID, fromRoom roomID: UUID) {
        update { c in
            guard let i = c.rooms.firstIndex(where: { $0.id == roomID }) else { return }
            c.rooms[i].deviceIDs.removeAll { $0 == deviceID }
            if c.rooms[i].anchorDeviceID == deviceID { c.rooms[i].anchorDeviceID = nil }
            Self.pruneOrphanDevices(&c)
        }
    }

    func updateDevice(_ id: UUID, _ mutate: (inout ControlledDevice) -> Void) {
        update { c in
            if let i = c.devices.firstIndex(where: { $0.id == id }) { mutate(&c.devices[i]) }
        }
    }

    func setTaughtVector(_ vector: Vector3?, forDevice id: UUID) {
        update { $0.setTaughtVector(vector, forDevice: id) }
    }

    /// Drops devices no room references, and anchors pointing at missing devices.
    private static func pruneOrphanDevices(_ c: inout AppConfig) {
        let used = Set(c.rooms.flatMap(\.deviceIDs))
        c.devices.removeAll { !used.contains($0.id) }
        for i in c.rooms.indices {
            if let a = c.rooms[i].anchorDeviceID, !c.rooms[i].deviceIDs.contains(a) {
                c.rooms[i].anchorDeviceID = nil
            }
        }
    }

    // MARK: - Settings

    func updateSettings(_ mutate: (inout Settings) -> Void) {
        update { mutate(&$0.settings) }
    }

    func resetSettings() {
        update { $0.settings = Settings() }
    }

    // MARK: - Home Assistant import

    /// Room already created from this HA area, if any.
    func room(forArea areaID: String) -> Room? {
        config.rooms.first { $0.haAreaID == areaID }
    }

    /// Creates a room from an HA area with its light/fan/switch entities.
    /// Returns the existing room if the area was already imported.
    @discardableResult
    func importArea(_ area: HAArea) -> Room {
        if let existing = room(forArea: area.id) { return existing }
        var room = Room(name: area.name, haAreaID: area.id)
        update { c in
            var seen = Set<String>()
            for eid in area.entityIDs where seen.insert(eid).inserted {
                let d = Self.makeDevice(entityID: eid, state: importCache?.state(for: eid))
                c.devices.append(d)
                room.deviceIDs.append(d.id)
            }
            c.rooms.append(room)
            if c.currentRoomID == nil { c.currentRoomID = room.id }
        }
        return room
    }

    /// Fetches entities (required) and areas (best effort) and caches them.
    /// Returns a non-fatal area error message, if the area template failed.
    @discardableResult
    func refreshImport() async throws -> String? {
        guard let client = makeClient() else { throw HAError.unauthorized }
        async let statesTask = client.controllableStates()
        async let areasTask = client.areas()
        let states = try await statesTask
        var areas: [HAArea] = []
        var areaError: String?
        do {
            areas = try await areasTask
        } catch {
            areaError = "Areas: " + (HAError.from(error).errorDescription ?? "failed")
        }
        let cache = HAImportCache(states: states, areas: areas, fetchedAt: Date())
        importCache = cache
        saveCache(cache)
        return areaError
    }

    private func saveCache(_ cache: HAImportCache) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(cache) {
            try? data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
