import Foundation

/// Builds the `POST /api/states/sensor.watchmagic_layout` body that feeds HA's
/// 3D house view (contract "watchmagic-layout/1"):
///
///     {"state": "<ISO time>",
///      "attributes": {"schema": "watchmagic-layout/1",
///                     "devices": [{entity_id, pos: [x,y,z], space_id?, ha_area_id?, label?,
///                                  mount, source, updated?} | {entity_id, delete: true}],
///                     "seats":   [{id, pos, space_id?, label?} | {id, delete: true}],
///                     "north_bearing_deg"?: number}}
///
/// `pos` is in the house frame (see `HouseModel.swift`). HA merges devices by
/// entity_id and seats by id, and rejects the WHOLE post if one item is
/// invalid — so every item is validated here and invalid ones are skipped
/// with a reason. The token is never part of the body.
public enum HouseLayout {
    public static let schema = "watchmagic-layout/1"
    public static let sensorEntityID = "sensor.watchmagic_layout"
    public static let validX = -5.0...20.0
    public static let validY = -5.0...32.0
    public static let validZ = -5.0...12.0

    public struct DeviceItem: Equatable, Sendable {
        public var entityID: String
        public var pos: Vector3
        public var spaceID: String?
        public var haAreaID: String?
        public var label: String?
        public var mount: DeviceMount
        public var source: String
        public var updated: String?

        public init(entityID: String, pos: Vector3, spaceID: String? = nil, haAreaID: String? = nil,
                    label: String? = nil, mount: DeviceMount = .wall, source: String = "manual", updated: String? = nil) {
            self.entityID = entityID; self.pos = pos; self.spaceID = spaceID; self.haAreaID = haAreaID
            self.label = label; self.mount = mount; self.source = source; self.updated = updated
        }
    }

    public struct SeatItem: Equatable, Sendable {
        public var id: String
        public var pos: Vector3
        public var spaceID: String?
        public var label: String?

        public init(id: String, pos: Vector3, spaceID: String? = nil, label: String? = nil) {
            self.id = id; self.pos = pos; self.spaceID = spaceID; self.label = label
        }
    }

    public struct Skipped: Equatable, Sendable {
        /// entity_id or seat id (or room name).
        public var id: String
        public var reason: String
    }

    public struct Build: Equatable, Sendable {
        public var state: String
        public var devices: [DeviceItem]
        public var seats: [SeatItem]
        public var deletedEntityIDs: [String]
        public var deletedSeatIDs: [String]
        public var northBearingDeg: Double?
        public var skipped: [Skipped]

        public init(state: String, devices: [DeviceItem] = [], seats: [SeatItem] = [],
                    deletedEntityIDs: [String] = [], deletedSeatIDs: [String] = [],
                    northBearingDeg: Double? = nil, skipped: [Skipped] = []) {
            self.state = state; self.devices = devices; self.seats = seats
            self.deletedEntityIDs = deletedEntityIDs; self.deletedSeatIDs = deletedSeatIDs
            self.northBearingDeg = northBearingDeg; self.skipped = skipped
        }

        /// Nothing to add, update or delete.
        public var isEmpty: Bool {
            devices.isEmpty && seats.isEmpty && deletedEntityIDs.isEmpty && deletedSeatIDs.isEmpty
        }

        /// Entity IDs HA will hold after this post succeeds.
        public var sentEntityIDs: Set<String> { Set(devices.map(\.entityID)) }
        public var sentSeatIDs: Set<String> { Set(seats.map(\.id)) }

        public var body: JSONValue {
            var devs: [JSONValue] = devices.map { d in
                var o: [String: JSONValue] = [
                    "entity_id": .string(d.entityID),
                    "pos": HouseLayout.json(d.pos),
                    "mount": .string(d.mount.rawValue),
                    "source": .string(d.source),
                ]
                if let s = d.spaceID { o["space_id"] = .string(s) }
                if let a = d.haAreaID { o["ha_area_id"] = .string(a) }
                if let l = d.label { o["label"] = .string(l) }
                if let u = d.updated { o["updated"] = .string(u) }
                return .object(o)
            }
            devs += deletedEntityIDs.map { .object(["entity_id": .string($0), "delete": .bool(true)]) }
            var sts: [JSONValue] = seats.map { s in
                var o: [String: JSONValue] = ["id": .string(s.id), "pos": HouseLayout.json(s.pos)]
                if let sp = s.spaceID { o["space_id"] = .string(sp) }
                if let l = s.label { o["label"] = .string(l) }
                return .object(o)
            }
            sts += deletedSeatIDs.map { .object(["id": .string($0), "delete": .bool(true)]) }
            var attrs: [String: JSONValue] = [
                "schema": .string(HouseLayout.schema),
                "devices": .array(devs),
                "seats": .array(sts),
            ]
            if let b = northBearingDeg { attrs["north_bearing_deg"] = .double((b * 100).rounded() / 100) }
            return .object(["state": .string(state), "attributes": .object(attrs)])
        }

        /// JSON body (sorted keys).
        public func bodyData() throws -> Data {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try enc.encode(body)
        }

        /// e.g. "Sent 7 devices, 1 seat to the 3D view · removed 2 · skipped 1 (light.x: z out of range)".
        public var summary: String {
            func n(_ k: Int, _ word: String) -> String { "\(k) \(word)\(k == 1 ? "" : "s")" }
            var s = "Sent \(n(devices.count, "device")), \(n(seats.count, "seat")) to the 3D view"
            let removed = deletedEntityIDs.count + deletedSeatIDs.count
            if removed > 0 { s += " · removed \(removed)" }
            if !skipped.isEmpty {
                s += " · skipped \(skipped.count) ("
                    + skipped.prefix(3).map { "\($0.id): \($0.reason)" }.joined(separator: "; ")
                    + (skipped.count > 3 ? "; …" : "") + ")"
            }
            return s
        }
    }

    // MARK: Build from the config

    /// Builds the body from every room that has a house space and a valid
    /// alignment: its placed devices and its seat, converted to the house
    /// frame. Items pushed before (`previousEntityIDs` / `previousSeatIDs`)
    /// that are no longer sent get `"delete": true`.
    public static func build(config: AppConfig,
                             previousEntityIDs: Set<String> = [],
                             previousSeatIDs: Set<String> = [],
                             now: Date = Date(),
                             declinationDeg: Double = HouseCalibration.defaultDeclinationDeg) -> Build {
        let stamp = isoString(now)
        var devices: [DeviceItem] = []
        var seats: [SeatItem] = []
        var skipped: [Skipped] = []
        var seenEntities = Set<String>()

        for room in config.rooms {
            guard let space = room.houseSpaceID, let a = room.houseAlignmentIfValid else { continue }
            if let seat = room.seat {
                let item = SeatItem(id: seatID(for: room.id), pos: a.housePoint(fromRoom: seat),
                                    spaceID: space, label: room.name)
                if let why = invalidReason(pos: item.pos) {
                    skipped.append(Skipped(id: item.id, reason: why))
                } else {
                    seats.append(item)
                }
            }
            for d in config.devices(in: room) {
                guard let c = d.coordinates else { continue }
                guard isValidEntityID(d.entityID) else {
                    skipped.append(Skipped(id: d.entityID, reason: "invalid entity_id"))
                    continue
                }
                guard !seenEntities.contains(d.entityID) else {
                    skipped.append(Skipped(id: d.entityID, reason: "also placed in another room"))
                    continue
                }
                let item = DeviceItem(entityID: d.entityID, pos: a.housePoint(fromRoom: c), spaceID: space,
                                      haAreaID: room.haAreaID, label: d.name, mount: d.mount ?? .wall,
                                      source: d.coordinatesSource == .lidar ? "lidar" : "manual", updated: stamp)
                if let why = invalidReason(pos: item.pos) {
                    skipped.append(Skipped(id: d.entityID, reason: why))
                    continue
                }
                seenEntities.insert(d.entityID)
                devices.append(item)
            }
        }
        devices.sort { $0.entityID < $1.entityID }
        seats.sort { $0.id < $1.id }
        let sentE = Set(devices.map(\.entityID)), sentS = Set(seats.map(\.id))
        var bearing = HouseCalibration(config: config).northBearingDeg(declinationDeg: declinationDeg)
        if let b = bearing, !b.isFinite { bearing = nil }
        return Build(state: stamp, devices: devices, seats: seats,
                     deletedEntityIDs: previousEntityIDs.subtracting(sentE).filter(isValidEntityID).sorted(),
                     deletedSeatIDs: previousSeatIDs.subtracting(sentS).filter(isValidSeatID).sorted(),
                     northBearingDeg: bearing, skipped: skipped)
    }

    // MARK: Validation / formatting

    /// "seat-" + the first 8 characters of the room UUID, lowercased.
    public static func seatID(for roomID: UUID) -> String {
        "seat-" + roomID.uuidString.prefix(8).lowercased()
    }

    /// `domain.object_id`, lowercase letters, digits and underscores.
    public static func isValidEntityID(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9_]+\.[a-z0-9_]+$"#, options: .regularExpression) != nil
    }

    /// `[A-Za-z0-9_-]{1,40}`.
    public static func isValidSeatID(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) != nil
    }

    /// nil if `pos` is inside the accepted house-frame ranges, else why not.
    public static func invalidReason(pos p: Vector3) -> String? {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return "position not finite" }
        if !validX.contains(p.x) { return String(format: "x %.2f m out of range", p.x) }
        if !validY.contains(p.y) { return String(format: "y %.2f m out of range", p.y) }
        if !validZ.contains(p.z) { return String(format: "z %.2f m out of range", p.z) }
        return nil
    }

    /// ISO-8601 with milliseconds (so `state` changes on every post).
    public static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func json(_ p: Vector3) -> JSONValue {
        .array([p.x, p.y, p.z].map { .double(($0 * 1000).rounded() / 1000) })
    }
}
