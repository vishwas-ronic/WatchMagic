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
    /// Space in HA's whole-house model this room is (e.g. "G-3"), if chosen.
    public var houseSpaceID: String?
    /// Room frame → house frame, solved from two marked corners (camera
    /// placement). Only meaningful in the frame of the room's current seat and
    /// coordinates; see `houseAlignmentIfValid`.
    public var houseAlignment: HouseAlignment?

    public init(
        id: UUID = UUID(),
        name: String,
        haAreaID: String? = nil,
        seat: Vector3? = nil,
        deviceIDs: [UUID] = [],
        anchorDeviceID: UUID? = nil,
        houseSpaceID: String? = nil,
        houseAlignment: HouseAlignment? = nil
    ) {
        self.id = id
        self.name = name
        self.haAreaID = haAreaID
        self.seat = seat
        self.deviceIDs = deviceIDs
        self.anchorDeviceID = anchorDeviceID
        self.houseSpaceID = houseSpaceID
        self.houseAlignment = houseAlignment
    }

    /// The alignment, if it belongs to the room's chosen house space.
    public var houseAlignmentIfValid: HouseAlignment? {
        guard let a = houseAlignment, let sid = houseSpaceID, a.spaceID == sid else { return nil }
        return a
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, haAreaID, seat, deviceIDs, anchorDeviceID, houseSpaceID, houseAlignment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Room"
        haAreaID = try c.decodeIfPresent(String.self, forKey: .haAreaID)
        seat = try c.decodeIfPresent(Vector3.self, forKey: .seat)
        deviceIDs = try c.decodeIfPresent([UUID].self, forKey: .deviceIDs) ?? []
        anchorDeviceID = try c.decodeIfPresent(UUID.self, forKey: .anchorDeviceID)
        houseSpaceID = try? c.decodeIfPresent(String.self, forKey: .houseSpaceID)
        houseAlignment = try? c.decodeIfPresent(HouseAlignment.self, forKey: .houseAlignment)
    }
}
