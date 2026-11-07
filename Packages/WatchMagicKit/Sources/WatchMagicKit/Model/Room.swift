import Foundation

/// A room: a seat position plus the devices in it (spec 1.1.2).
/// The compass offset is not stored; it is derived from taught devices that
/// also have coordinates (see `ReferenceDirections`).
public struct Room: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Home Assistant area ID this room was imported from, if any.
    public var haAreaID: String?
    /// Seat position in the room frame (metres; right-handed, +z up).
    public var seat: Vector3?
    /// Devices in this room (IDs into `AppConfig.devices`), in display order.
    public var deviceIDs: [UUID]
    /// Device used for the zero-gesture heading fallback. nil = first taught device.
    public var anchorDeviceID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        haAreaID: String? = nil,
        seat: Vector3? = nil,
        deviceIDs: [UUID] = [],
        anchorDeviceID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.haAreaID = haAreaID
        self.seat = seat
        self.deviceIDs = deviceIDs
        self.anchorDeviceID = anchorDeviceID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, haAreaID, seat, deviceIDs, anchorDeviceID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Room"
        haAreaID = try c.decodeIfPresent(String.self, forKey: .haAreaID)
        seat = try c.decodeIfPresent(Vector3.self, forKey: .seat)
        deviceIDs = try c.decodeIfPresent([UUID].self, forKey: .deviceIDs) ?? []
        anchorDeviceID = try c.decodeIfPresent(UUID.self, forKey: .anchorDeviceID)
    }
}
