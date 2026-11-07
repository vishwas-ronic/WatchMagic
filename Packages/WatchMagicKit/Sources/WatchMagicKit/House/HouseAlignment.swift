import Foundation

/// Rigid transform from a room frame (right-handed, +z up — see `Vector3.swift`)
/// to the HA house frame (x = plan right, y = plan down, z = up: LEFT-handed —
/// see `HouseModel.swift`).
///
/// Because the two frames have opposite handedness, the plan part is a
/// reflection followed by a rotation, never a rotation alone:
///
///     F(x, y)        = (x, −y)                      // reflect: right- → left-handed
///     house.xy       = R(θ) · F(room.xy) + t        // R(θ) = [[cos θ, −sin θ], [sin θ, cos θ]]
///     house.z        = room.z + zOffset
///
/// i.e. `house.x = cos θ·x + sin θ·y + tx`, `house.y = sin θ·x − cos θ·y + ty`.
/// For horizontal directions: `yaw_house = θ − yaw_room` (yaw = atan2(y, x) in
/// each frame's own coordinates).
///
/// It is solved from two correspondences: two floor-level corners marked in AR
/// (room frame) ↔ two corners of the space's polygon (house plan). The
/// rotation comes from the direction between the marks, the translation from
/// their midpoints, and `zOffset = floorLevel − mean(mark.z)`.
public struct HouseAlignment: Codable, Equatable, Hashable, Sendable {
    /// Distance mismatch (m) above which the UI warns (wrong corner / bad mark).
    public static let fitWarningM = 0.25
    /// Marks closer than this can't fix the rotation reliably.
    public static let minCornerSeparationM = 0.5

    /// House space this alignment belongs to (e.g. "G-3").
    public var spaceID: String
    /// θ, degrees.
    public var rotationDeg: Double
    /// t (house plan, m).
    public var translation: PlanPoint
    /// house.z − room.z (m).
    public var zOffset: Double
    /// | |markA − markB| − |cornerA − cornerB| | in the plan (m).
    public var fitErrorM: Double
    /// The two polygon corners used (house plan), for display.
    public var houseCorners: [PlanPoint]

    public init(spaceID: String, rotationDeg: Double, translation: PlanPoint, zOffset: Double,
                fitErrorM: Double = 0, houseCorners: [PlanPoint] = []) {
        self.spaceID = spaceID
        self.rotationDeg = rotationDeg
        self.translation = translation
        self.zOffset = zOffset
        self.fitErrorM = fitErrorM
        self.houseCorners = houseCorners
    }

    public var fitIsPoor: Bool { fitErrorM > Self.fitWarningM }

    // MARK: Solve

    /// Solves the alignment from two marked corners (room frame, at floor
    /// level) and the matching polygon corners (house plan) of a space whose
    /// floor is at `floorLevel` (house z). nil if either pair is closer than
    /// `minCornerSeparationM`.
    public static func solve(spaceID: String,
                             roomCorners: (Vector3, Vector3),
                             houseCorners: (PlanPoint, PlanPoint),
                             floorLevel: Double) -> HouseAlignment? {
        let (r1, r2) = roomCorners
        let (h1, h2) = houseCorners
        let f1 = PlanPoint(r1.x, -r1.y), f2 = PlanPoint(r2.x, -r2.y)
        let dr = f2 - f1, dh = h2 - h1
        let lr = hypot(dr.x, dr.y), lh = hypot(dh.x, dh.y)
        guard lr >= minCornerSeparationM, lh >= minCornerSeparationM else { return nil }
        let theta = atan2(dh.y, dh.x) - atan2(dr.y, dr.x)
        let c = cos(theta), s = sin(theta)
        let fm = PlanPoint((f1.x + f2.x) / 2, (f1.y + f2.y) / 2)
        let hm = PlanPoint((h1.x + h2.x) / 2, (h1.y + h2.y) / 2)
        let t = PlanPoint(hm.x - (c * fm.x - s * fm.y), hm.y - (s * fm.x + c * fm.y))
        return HouseAlignment(spaceID: spaceID,
                              rotationDeg: Angle.normalizedDeg(theta * 180 / .pi),
                              translation: t,
                              zOffset: floorLevel - (r1.z + r2.z) / 2,
                              fitErrorM: abs(lr - lh),
                              houseCorners: [h1, h2])
    }

    // MARK: Transform

    private var cs: (c: Double, s: Double) {
        let a = rotationDeg * .pi / 180
        return (cos(a), sin(a))
    }

    /// Room-frame point → house-frame point.
    public func housePoint(fromRoom p: Vector3) -> Vector3 {
        let d = houseDirection(fromRoom: p)
        return Vector3(d.x + translation.x, d.y + translation.y, p.z + zOffset)
    }

    /// House-frame point → room-frame point (inverse of `housePoint(fromRoom:)`).
    public func roomPoint(fromHouse h: Vector3) -> Vector3 {
        let r = roomDirection(fromHouse: Vector3(h.x - translation.x, h.y - translation.y, 0))
        return Vector3(r.x, r.y, h.z - zOffset)
    }

    /// Room-frame direction → house-frame direction (no translation / z offset).
    public func houseDirection(fromRoom v: Vector3) -> Vector3 {
        let (c, s) = cs
        let fx = v.x, fy = -v.y
        return Vector3(c * fx - s * fy, s * fx + c * fy, v.z)
    }

    /// House-frame direction → room-frame direction.
    public func roomDirection(fromHouse v: Vector3) -> Vector3 {
        let (c, s) = cs
        let fx = c * v.x + s * v.y, fy = -s * v.x + c * v.y
        return Vector3(fx, -fy, v.z)
    }

    // MARK: Codable (tolerant)

    private enum CodingKeys: String, CodingKey {
        case spaceID, rotationDeg, translation, zOffset, fitErrorM, houseCorners
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaceID = try c.decode(String.self, forKey: .spaceID)
        rotationDeg = try c.decode(Double.self, forKey: .rotationDeg)
        translation = try c.decode(PlanPoint.self, forKey: .translation)
        zOffset = try c.decodeIfPresent(Double.self, forKey: .zOffset) ?? 0
        fitErrorM = try c.decodeIfPresent(Double.self, forKey: .fitErrorM) ?? 0
        houseCorners = (try? c.decodeIfPresent([PlanPoint].self, forKey: .houseCorners)) ?? []
    }
}
