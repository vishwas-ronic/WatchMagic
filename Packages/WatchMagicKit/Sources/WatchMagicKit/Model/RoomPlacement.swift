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
public struct RoomPlacement: Equatable, Sendable {
    public var roomID: UUID
    /// Seat set in this session (room frame), if any.
    public var seat: Vector3?
    /// Device ID → position placed in this session (room frame).
    public var devicePositions: [UUID: Vector3]
    /// True if the session's frame is the frame of the room's stored coordinates.
    public var sameFrame: Bool

    public init(roomID: UUID, seat: Vector3?, devicePositions: [UUID: Vector3], sameFrame: Bool) {
        self.roomID = roomID
        self.seat = seat
        self.devicePositions = devicePositions
        self.sameFrame = sameFrame
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
        config.rooms[ri].seat = newSeat
        for i in config.devices.indices where roomDeviceIDs.contains(config.devices[i].id) {
            let id = config.devices[i].id
            if let p = devicePositions[id] {
                config.devices[i].coordinates = p
            } else if stale.contains(id) {
                config.devices[i].coordinates = nil
            }
        }
        return true
    }
}
