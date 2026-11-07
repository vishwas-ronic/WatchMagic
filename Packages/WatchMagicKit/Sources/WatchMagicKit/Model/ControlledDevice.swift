import Foundation

/// What kind of device an entity is treated as (spec 1.1.2). Auto-set from the
/// domain, user-overridable. `ActionMapper` never emits a service the entity's
/// domain lacks, whatever the kind says.
public enum DeviceKind: String, Codable, CaseIterable, Sendable {
    case dimmableLight, onOffLight, `switch`, fan

    public var displayName: String {
        switch self {
        case .dimmableLight: return "Dimmable light"
        case .onOffLight: return "On/off light"
        case .switch: return "Switch"
        case .fan: return "Fan"
        }
    }

    /// Infers the kind from the entity ID's domain. A light is dimmable if its
    /// `supported_color_modes` contain anything other than "onoff"
    /// (missing or empty modes → `.onOffLight`). Returns nil for other domains.
    public static func infer(entityID: String, supportedColorModes: [String]?) -> DeviceKind? {
        switch ControlledDevice.domain(of: entityID) {
        case "light":
            let modes = supportedColorModes ?? []
            return modes.contains(where: { $0 != "onoff" }) ? .dimmableLight : .onOffLight
        case "fan":
            return .fan
        case "switch":
            return .switch
        default:
            return nil
        }
    }
}

/// How a device is mounted (sent to HA's 3D view). Set by camera placement
/// from the surface hit; see `classify(normal:heightAboveFloor:)`.
public enum DeviceMount: String, Codable, CaseIterable, Sendable {
    case wall, ceiling, floor, table

    /// Height above the floor (m) below which an up-facing surface counts as the floor.
    public static let floorMaxHeight = 0.3

    /// Classifies a surface by its unit normal (room frame, +z up): facing
    /// down (z ≤ −0.6) → ceiling; facing up (z ≥ 0.6) → floor if less than
    /// `floorMaxHeight` above the floor, else table (unknown height → table);
    /// otherwise (roughly horizontal normal) → wall.
    public static func classify(normal: Vector3, heightAboveFloor: Double?) -> DeviceMount {
        let n = normal.normalized
        if n.isZero { return .wall }
        if n.z <= -0.6 { return .ceiling }
        if n.z >= 0.6 {
            guard let h = heightAboveFloor else { return .table }
            return h < floorMaxHeight ? .floor : .table
        }
        return .wall
    }
}

/// Where a device's coordinates came from.
public enum CoordinatesSource: String, Codable, Sendable {
    /// Camera (LiDAR) placement.
    case lidar
    /// Typed in.
    case manual
}

/// Calibration status shown on the phone.
public enum CalibrationStatus: String, Codable, Sendable {
    /// Has a vector taught on the watch ("Taught ✓").
    case taught
    /// Has room coordinates but no taught vector ("Coordinates only").
    case coordinatesOnly
    /// Neither ("Not placed").
    case notPlaced

    public var displayName: String {
        switch self {
        case .taught: return "Taught ✓"
        case .coordinatesOnly: return "Coordinates only"
        case .notPlaced: return "Not placed"
        }
    }
}

/// A Home Assistant entity the user controls.
public struct ControlledDevice: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// e.g. "light.bedroom_lamp".
    public var entityID: String
    public var name: String
    public var kind: DeviceKind
    /// True if the user overrode the inferred kind.
    public var kindOverridden: Bool
    /// Position in the room frame (metres), optional.
    public var coordinates: Vector3?
    /// Unit pointing vector (world frame) taught on the watch from the seat.
    public var taughtVector: Vector3?
    /// Mount surface (from camera placement); nil = unknown.
    public var mount: DeviceMount?
    /// Where `coordinates` came from; nil = unknown (treated as manual).
    public var coordinatesSource: CoordinatesSource?

    public init(
        id: UUID = UUID(),
        entityID: String,
        name: String,
        kind: DeviceKind,
        kindOverridden: Bool = false,
        coordinates: Vector3? = nil,
        taughtVector: Vector3? = nil,
        mount: DeviceMount? = nil,
        coordinatesSource: CoordinatesSource? = nil
    ) {
        self.id = id
        self.entityID = entityID
        self.name = name
        self.kind = kind
        self.kindOverridden = kindOverridden
        self.coordinates = coordinates
        self.taughtVector = taughtVector
        self.mount = mount
        self.coordinatesSource = coordinatesSource
    }

    /// The entity's domain ("light", "fan", "switch").
    public var domain: String { Self.domain(of: entityID) }

    public static func domain(of entityID: String) -> String {
        guard let dot = entityID.firstIndex(of: ".") else { return entityID }
        return String(entityID[..<dot])
    }

    public var calibrationStatus: CalibrationStatus {
        if taughtVector != nil { return .taught }
        if coordinates != nil { return .coordinatesOnly }
        return .notPlaced
    }

    private enum CodingKeys: String, CodingKey {
        case id, entityID, name, kind, kindOverridden, coordinates, taughtVector, mount, coordinatesSource
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        entityID = try c.decodeIfPresent(String.self, forKey: .entityID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? entityID
        if let raw = try? c.decodeIfPresent(String.self, forKey: .kind), let k = DeviceKind(rawValue: raw) {
            kind = k
        } else {
            kind = DeviceKind.infer(entityID: entityID, supportedColorModes: nil) ?? .switch
        }
        kindOverridden = try c.decodeIfPresent(Bool.self, forKey: .kindOverridden) ?? false
        coordinates = try c.decodeIfPresent(Vector3.self, forKey: .coordinates)
        taughtVector = try c.decodeIfPresent(Vector3.self, forKey: .taughtVector)
        mount = (try? c.decodeIfPresent(String.self, forKey: .mount)).flatMap(DeviceMount.init(rawValue:))
        coordinatesSource = (try? c.decodeIfPresent(String.self, forKey: .coordinatesSource))
            .flatMap(CoordinatesSource.init(rawValue:))
    }
}
