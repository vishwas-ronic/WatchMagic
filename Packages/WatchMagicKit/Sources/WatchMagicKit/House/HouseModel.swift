import Foundation

// MARK: - House frame (read this before using any House API)
//
// HOUSE FRAME = the frame of Home Assistant's whole-house model
// (`/local/house3d/house.json`, maintained outside WatchMagic):
//   +x = plan right, +y = plan DOWN, +z = up; metres; origin = plot top-left.
//   z = metres above the ground-floor finished level.
// Because y points DOWN the plan while z points up, x × y = −z: the house
// frame is LEFT-handed. Converting from a (right-handed) room frame therefore
// needs a reflection, see `HouseAlignment`.

/// A 2-D point in the house plan (x right, y down; metres).
public struct PlanPoint: Codable, Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x; self.y = y
    }

    public func distance(to o: PlanPoint) -> Double { hypot(o.x - x, o.y - y) }

    public static func - (a: PlanPoint, b: PlanPoint) -> PlanPoint { PlanPoint(a.x - b.x, a.y - b.y) }
    public static func + (a: PlanPoint, b: PlanPoint) -> PlanPoint { PlanPoint(a.x + b.x, a.y + b.y) }

    public var description: String { String(format: "(%.3f, %.3f)", x, y) }

    /// Encoded as `[x, y]` like house.json.
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }
}

/// The subset of HA's `house.json` (schema 1.x) WatchMagic uses. Decoding is
/// tolerant: unknown fields are ignored, missing optional fields default, and
/// a malformed floor / space / wall is skipped instead of failing the file.
public struct HouseModel: Codable, Equatable, Sendable {
    public var schemaVersion: String?
    public var floors: [Floor]
    public var spaces: [Space]
    public var walls: [Wall]

    public struct Floor: Codable, Equatable, Hashable, Sendable, Identifiable {
        public var id: String
        /// Storey floor level (m above ground-floor finished level).
        public var z: Double
        public var clearHeight: Double?

        public init(id: String, z: Double, clearHeight: Double? = nil) {
            self.id = id; self.z = z; self.clearHeight = clearHeight
        }

        private enum CodingKeys: String, CodingKey {
            case id, z
            case clearHeight = "clear_height"
        }
    }

    public struct Space: Codable, Equatable, Hashable, Sendable, Identifiable {
        /// e.g. "G-3". Rooms map to spaces by this ID.
        public var id: String
        public var label: String?
        /// e.g. "Drawing Room".
        public var name: String?
        /// Floor ID ("ground", "first", …).
        public var floor: String?
        /// Storey floor level (m). nil = take it from the floor.
        public var z: Double?
        /// Floor polygon on inner wall faces (open ring; positive shoelace area
        /// as stored). `poly_render` is display-only and deliberately ignored.
        public var poly: [PlanPoint]

        public init(id: String, label: String? = nil, name: String? = nil, floor: String? = nil,
                    z: Double? = nil, poly: [PlanPoint]) {
            self.id = id; self.label = label; self.name = name; self.floor = floor; self.z = z; self.poly = poly
        }

        private enum CodingKeys: String, CodingKey {
            case id, label, name, floor, z, poly
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = try? c.decodeIfPresent(String.self, forKey: .label)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            floor = try? c.decodeIfPresent(String.self, forKey: .floor)
            z = try? c.decodeIfPresent(Double.self, forKey: .z)
            poly = try c.decode([PlanPoint].self, forKey: .poly)
        }

        /// "Drawing Room" (or the ID when unnamed).
        public var displayName: String { (name?.isEmpty == false ? name : nil) ?? id }
    }

    public struct Wall: Codable, Equatable, Hashable, Sendable, Identifiable {
        public var id: String
        public var floor: String?
        public var poly: [PlanPoint]
        public var z0: Double?
        public var z1: Double?

        public init(id: String, floor: String? = nil, poly: [PlanPoint], z0: Double? = nil, z1: Double? = nil) {
            self.id = id; self.floor = floor; self.poly = poly; self.z0 = z0; self.z1 = z1
        }
    }

    public init(schemaVersion: String? = nil, floors: [Floor] = [], spaces: [Space] = [], walls: [Wall] = []) {
        self.schemaVersion = schemaVersion
        self.floors = floors
        self.spaces = spaces
        self.walls = walls
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case floors, spaces, walls
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decodeIfPresent(String.self, forKey: .schemaVersion) {
            schemaVersion = s
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .schemaVersion) {
            schemaVersion = String(d)
        } else {
            schemaVersion = nil
        }
        floors = (try? c.decodeIfPresent(Lossy<Floor>.self, forKey: .floors))?.items ?? []
        spaces = ((try? c.decodeIfPresent(Lossy<Space>.self, forKey: .spaces))?.items ?? []).filter { $0.poly.count >= 3 }
        walls = (try? c.decodeIfPresent(Lossy<Wall>.self, forKey: .walls))?.items ?? []
    }

    public static func fromJSON(_ data: Data) throws -> HouseModel {
        try JSONDecoder().decode(HouseModel.self, from: data)
    }

    // MARK: Lookups

    public func space(id: String) -> Space? { spaces.first { $0.id == id } }

    public func floor(id: String) -> Floor? { floors.first { $0.id == id } }

    /// Floor level of a space: its own `z`, else its floor's, else 0.
    public func floorLevel(of space: Space) -> Double {
        space.z ?? space.floor.flatMap { floor(id: $0)?.z } ?? 0
    }

    /// Floors in ascending height, then any floor IDs used by spaces but not
    /// listed (in order of appearance), each with its spaces in file order.
    /// Spaces without a floor come last under the ID "".
    public var spacesByFloor: [(floorID: String, spaces: [Space])] {
        var order = floors.sorted { $0.z < $1.z }.map(\.id)
        for s in spaces where !order.contains(s.floor ?? "") { order.append(s.floor ?? "") }
        return order.compactMap { fid in
            let list = spaces.filter { ($0.floor ?? "") == fid }
            return list.isEmpty ? nil : (fid, list)
        }
    }

    public func spaces(onFloor floorID: String) -> [Space] {
        spaces.filter { $0.floor == floorID }
    }

    /// Best name match for a room name (case-, punctuation- and leading-zero-
    /// insensitive), or nil if nothing is reasonably similar.
    public func suggestedSpace(forRoomName roomName: String) -> Space? {
        var best: (Space, Double)?
        for s in spaces {
            let score = Self.nameSimilarity(roomName, s.displayName)
            if score > (best?.1 ?? 0) { best = (s, score) }
        }
        guard let best, best.1 >= 0.5 else { return nil }
        return best.0
    }

    /// 1 = same name after normalisation; 0.8 = one contains the other;
    /// otherwise the token Jaccard index.
    public static func nameSimilarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        if ta == tb { return 1 }
        let ja = ta.joined(separator: " "), jb = tb.joined(separator: " ")
        if ja.contains(jb) || jb.contains(ja) { return 0.8 }
        let sa = Set(ta), sb = Set(tb)
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { tok -> String in
                // "01" == "1"
                if tok.allSatisfy(\.isNumber) {
                    let t = tok.drop { $0 == "0" }
                    return t.isEmpty ? "0" : String(t)
                }
                return String(tok)
            }
    }
}

// MARK: - Polygon helpers

public enum PlanPolygon {
    /// Shoelace area (positive for the vertex order house.json stores).
    public static func signedArea(_ p: [PlanPoint]) -> Double {
        guard p.count >= 3 else { return 0 }
        var s = 0.0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    /// Even-odd point-in-polygon test.
    public static func contains(_ p: [PlanPoint], _ q: PlanPoint) -> Bool {
        guard p.count >= 3 else { return false }
        var inside = false
        var j = p.count - 1
        for i in p.indices {
            let a = p[i], b = p[j]
            if (a.y > q.y) != (b.y > q.y),
               q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Corners a person can actually stand in and mark: the polygon with
    /// edges shorter than `minEdge` (drawing chamfers, tiny jogs) collapsed —
    /// each short edge's two vertices are replaced by the intersection of the
    /// neighbouring edges' lines (the "virtual" sharp corner) when that point
    /// is near, else by the short edge's midpoint. Near-straight vertices
    /// (turn < `minTurnDeg`) are then dropped. Returns the input when it would
    /// collapse below 3 vertices.
    public static func corners(_ poly: [PlanPoint], minEdge: Double = 0.2, minTurnDeg: Double = 20) -> [PlanPoint] {
        var p = poly
        guard p.count > 3 else { return p }
        while p.count > 3 {
            var shortest: (i: Int, len: Double)?
            for i in p.indices {
                let len = p[i].distance(to: p[(i + 1) % p.count])
                if len < minEdge, len < (shortest?.len ?? .infinity) { shortest = (i, len) }
            }
            guard let (i, _) = shortest else { break }
            let n = p.count
            let a0 = p[(i - 1 + n) % n], a1 = p[i], b0 = p[(i + 1) % n], b1 = p[(i + 2) % n]
            let mid = PlanPoint((a1.x + b0.x) / 2, (a1.y + b0.y) / 2)
            var replacement = mid
            if let x = lineIntersection(a0, a1, b1, b0), x.distance(to: mid) <= 3 * minEdge {
                replacement = x
            }
            p[i] = replacement
            p.remove(at: (i + 1) % n)
        }
        // Drop near-straight vertices.
        var changed = true
        while changed, p.count > 3 {
            changed = false
            for i in p.indices {
                let n = p.count
                let prev = p[(i - 1 + n) % n], cur = p[i], next = p[(i + 1) % n]
                let d1 = cur - prev, d2 = next - cur
                let turn = abs(Angle.normalizedDeg((atan2(d2.y, d2.x) - atan2(d1.y, d1.x)) * 180 / .pi))
                if turn < minTurnDeg {
                    p.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return p.count >= 3 ? p : poly
    }

    /// Indices (i, j), i < j, of the two points farthest apart.
    public static func farthestPair(_ p: [PlanPoint]) -> (Int, Int)? {
        guard p.count >= 2 else { return nil }
        var best = (0, 1), bestD = -1.0
        for i in p.indices {
            for j in (i + 1)..<p.count {
                let d = p[i].distance(to: p[j])
                if d > bestD { bestD = d; best = (i, j) }
            }
        }
        return best
    }

    /// Intersection of the infinite lines (p1, p2) and (p3, p4); nil if parallel.
    static func lineIntersection(_ p1: PlanPoint, _ p2: PlanPoint, _ p3: PlanPoint, _ p4: PlanPoint) -> PlanPoint? {
        let d1 = p2 - p1, d2 = p4 - p3
        let den = d1.x * d2.y - d1.y * d2.x
        guard abs(den) > 1e-9 * max(1, d1.x * d1.x + d1.y * d1.y) else { return nil }
        let t = ((p3.x - p1.x) * d2.y - (p3.y - p1.y) * d2.x) / den
        return PlanPoint(p1.x + t * d1.x, p1.y + t * d1.y)
    }
}

/// Decodes an array, skipping elements that fail to decode.
struct Lossy<T: Decodable>: Decodable {
    var items: [T]

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) {
                out.append(v)
            } else if (try? c.decode(JSONValue.self)) == nil {
                break // couldn't even skip it
            }
        }
        items = out
    }
}
