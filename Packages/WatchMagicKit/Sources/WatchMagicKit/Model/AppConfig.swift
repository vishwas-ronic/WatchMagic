import Foundation

/// The whole user configuration, persisted on the phone and synced to the
/// watch. The Home Assistant token is deliberately NOT part of this (it lives
/// in the phone's Keychain; `SyncPayload.ConfigContext` carries it separately).
///
/// Decoding tolerates missing keys (defaults are used) so the schema can grow,
/// e.g. for future automatic room detection. Bump `currentVersion` on
/// incompatible changes.
public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let defaultHAURL = URL(string: "http://homeassistant.local:8123")!

    public var version: Int
    public var haURL: URL
    public var rooms: [Room]
    public var devices: [ControlledDevice]
    public var currentRoomID: UUID?
    public var settings: Settings

    public init(
        version: Int = AppConfig.currentVersion,
        haURL: URL = AppConfig.defaultHAURL,
        rooms: [Room] = [],
        devices: [ControlledDevice] = [],
        currentRoomID: UUID? = nil,
        settings: Settings = Settings()
    ) {
        self.version = version
        self.haURL = haURL
        self.rooms = rooms
        self.devices = devices
        self.currentRoomID = currentRoomID
        self.settings = settings
    }

    // MARK: Lookups

    public var currentRoom: Room? {
        guard let id = currentRoomID else { return nil }
        return rooms.first { $0.id == id }
    }

    public func room(id: UUID) -> Room? { rooms.first { $0.id == id } }

    public func device(id: UUID) -> ControlledDevice? { devices.first { $0.id == id } }

    /// Devices of a room, in the room's order (unknown IDs skipped).
    public func devices(in room: Room) -> [ControlledDevice] {
        room.deviceIDs.compactMap { device(id: $0) }
    }

    /// Sets (or clears, with nil) a device's taught vector. Returns false if
    /// the device is unknown.
    @discardableResult
    public mutating func setTaughtVector(_ vector: Vector3?, forDevice deviceID: UUID) -> Bool {
        guard let i = devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        devices[i].taughtVector = vector?.normalized
        return true
    }

    // MARK: JSON

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }

    public static func fromJSON(_ data: Data) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: data)
    }

    // MARK: Codable (tolerant)

    private enum CodingKeys: String, CodingKey {
        case version, haURL, rooms, devices, currentRoomID, settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? AppConfig.currentVersion
        if let s = try? c.decodeIfPresent(String.self, forKey: .haURL), let u = URL(string: s) {
            haURL = u
        } else {
            haURL = AppConfig.defaultHAURL
        }
        rooms = try c.decodeIfPresent([Room].self, forKey: .rooms) ?? []
        devices = try c.decodeIfPresent([ControlledDevice].self, forKey: .devices) ?? []
        currentRoomID = try c.decodeIfPresent(UUID.self, forKey: .currentRoomID)
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(haURL.absoluteString, forKey: .haURL)
        try c.encode(rooms, forKey: .rooms)
        try c.encode(devices, forKey: .devices)
        try c.encodeIfPresent(currentRoomID, forKey: .currentRoomID)
        try c.encode(settings, forKey: .settings)
    }
}
