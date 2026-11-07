import Foundation

/// Result of a camera (LiDAR) placement session for one room, and the rule
/// for merging it into the config while keeping every coordinate in the room
/// in ONE frame.
///
/// Frame-consistency rule:
/// - `sameFrame == true` (the session relocalized into the room's saved world
///   map, so its frame is the frame the stored coordinates were saved in):
///   placed devices / the seat are updated; everything else is kept.
/// - `sameFrame == false` (fresh session, new arbitrary frame): the seat must
///   be set in this session, placed devices get their new coordinates, and
///   every other device in the room has its coordinates CLEARED, because they
///   belong to an old frame and would point the wrong way.
/// Taught vectors are world-frame and never touched.
///
/// The house alignment (room frame → HA house frame) follows the same rule:
/// it is only valid in the frame it was marked in. Same frame: a newly marked
/// alignment replaces the stored one, otherwise it is kept. Fresh frame: the
/// room gets this session's alignment, or none (the old one is cleared).
/// Placed devices get `coordinatesSource = .lidar` and their surface mount.
public struct RoomPlacement: Equatable, Sendable {
    public var roomID: UUID
    /// Seat set in this session (room frame), if any.
    public var seat: Vector3?
    /// Device ID → position placed in this session (room frame).
    public var devicePositions: [UUID: Vector3]
    /// True if the session's frame is the frame of the room's stored coordinates.
    public var sameFrame: Bool
    /// Alignment to the house model marked in this session, if any.
    public var houseAlignment: HouseAlignment?
    /// Device ID → mount surface, for devices placed in this session.
    public var deviceMounts: [UUID: DeviceMount]

    public init(roomID: UUID, seat: Vector3?, devicePositions: [UUID: Vector3], sameFrame: Bool,
                houseAlignment: HouseAlignment? = nil, deviceMounts: [UUID: DeviceMount] = [:]) {
        self.roomID = roomID
        self.seat = seat
        self.devicePositions = devicePositions
        self.sameFrame = sameFrame
        self.houseAlignment = houseAlignment
        self.deviceMounts = deviceMounts
    }

    /// True if saving clears a stored house alignment (fresh frame, none marked now).
    public func clearsHouseAlignment(in config: AppConfig) -> Bool {
        guard !sameFrame, houseAlignment == nil, let room = config.room(id: roomID) else { return false }
        return room.houseAlignment != nil
    }

    /// The house alignment the room will have after saving.
    public func resultingHouseAlignment(in config: AppConfig) -> HouseAlignment? {
        if let houseAlignment { return houseAlignment }
        return sameFrame ? config.room(id: roomID)?.houseAlignment : nil
    }

    /// Devices in the room whose existing coordinates will be cleared on save
    /// (only in a fresh frame: placed earlier, not re-placed now).
    public func staleDeviceIDs(in config: AppConfig) -> [UUID] {
        guard !sameFrame, let room = config.room(id: roomID) else { return [] }
        return config.devices(in: room)
            .filter { $0.coordinates != nil && devicePositions[$0.id] == nil }
            .map(\.id)
    }

    /// The seat the room will have after saving (nil = cannot save).
    public func resultingSeat(in config: AppConfig) -> Vector3? {
        if let seat { return seat }
        return sameFrame ? config.room(id: roomID)?.seat : nil
    }

    /// True if saving would produce a usable room (a seat in the session's frame).
    public func canSave(in config: AppConfig) -> Bool {
        resultingSeat(in: config) != nil
    }

    /// Applies the placement to `config` following the frame-consistency rule.
    /// Returns false (and leaves `config` unchanged) if it can't be saved.
    @discardableResult
    public func apply(to config: inout AppConfig) -> Bool {
        guard let ri = config.rooms.firstIndex(where: { $0.id == roomID }),
              let newSeat = resultingSeat(in: config) else { return false }
        let roomDeviceIDs = Set(config.rooms[ri].deviceIDs)
        let stale = Set(staleDeviceIDs(in: config))
        let alignment = resultingHouseAlignment(in: config)
        config.rooms[ri].seat = newSeat
        config.rooms[ri].houseAlignment = alignment
        for i in config.devices.indices where roomDeviceIDs.contains(config.devices[i].id) {
            let id = config.devices[i].id
            if let p = devicePositions[id] {
                config.devices[i].coordinates = p
                config.devices[i].coordinatesSource = .lidar
                if let m = deviceMounts[id] { config.devices[i].mount = m }
            } else if stale.contains(id) {
                config.devices[i].coordinates = nil
                config.devices[i].coordinatesSource = nil
            }
        }
        return true
    }
}
