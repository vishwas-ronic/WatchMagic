import Foundation

// MARK: - Frame conventions (read this before using any pointing API)
//
// WORLD FRAME (a.k.a. "reference frame"), matching CoreMotion's
// `CMAttitudeReferenceFrame.xMagneticNorthZVertical`:
//   +x = magnetic north (horizontal), +y = west (horizontal), +z = up.
//   Right-handed: x × y = z.
//
// YAW is measured in degrees counter-clockwise from +x about +z (looking down
// from above). So yaw 0° = north, +90° = west, ±180° = south, −90° = east.
// NOTE: this is the mathematical convention, i.e. compass heading = −yaw
// (normalised to 0…360). Use `Vector3.compassHeadingDeg` for display.
//
// PITCH is the elevation above the horizontal plane, degrees, +90° = straight up.
//
// ROOM FRAME (seat / device coordinates typed in on the phone): any frame the
// user chooses, but it MUST be right-handed with +z up (e.g. x = east,
// y = north, z = up; or x = along a wall, y = 90° to its left, z = up). The
// compass offset (see ReferenceDirections) rotates the room frame about z into
// the world frame.

/// A 3-component vector of Doubles. Used for directions, positions (metres),
/// rotation rates (rad/s) and gravity (g).
public struct Vector3: Codable, Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public init(x: Double, y: Double, z: Double) {
        self.init(x, y, z)
    }

    public static let zero = Vector3(0, 0, 0)
    public static let unitX = Vector3(1, 0, 0)
    public static let unitY = Vector3(0, 1, 0)
    public static let unitZ = Vector3(0, 0, 1)

    /// Unit vector from yaw (CCW from +x about +z) and pitch (elevation), degrees.
    public init(yawDeg: Double, pitchDeg: Double) {
        let yaw = yawDeg * .pi / 180
        let pitch = pitchDeg * .pi / 180
        self.init(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
    }

    public func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }

    public func cross(_ o: Vector3) -> Vector3 {
        Vector3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }

    public var norm: Double { (x * x + y * y + z * z).squareRoot() }

    /// Unit vector; returns `.zero` for a (near-)zero vector.
    public var normalized: Vector3 {
        let n = norm
        return n > 1e-12 ? Vector3(x / n, y / n, z / n) : .zero
    }

    public var isZero: Bool { norm <= 1e-12 }

    /// Angle between the two vectors in degrees (0…180). Returns 180 if either is zero.
    public func angle(to o: Vector3) -> Double {
        let n = norm * o.norm
        guard n > 1e-12 else { return 180 }
        let c = max(-1, min(1, dot(o) / n))
        return acos(c) * 180 / .pi
    }

    /// Yaw in degrees, (−180, 180], CCW from +x (north) about +z. 0 for a vertical vector.
    public var yawDeg: Double {
        (x == 0 && y == 0) ? 0 : atan2(y, x) * 180 / .pi
    }

    /// Elevation above the horizontal plane, degrees (−90…90).
    public var pitchDeg: Double {
        let n = norm
        guard n > 1e-12 else { return 0 }
        return asin(max(-1, min(1, z / n))) * 180 / .pi
    }

    /// Compass heading in degrees (0…360, clockwise from north) — `-yawDeg` normalised.
    public var compassHeadingDeg: Double {
        let h = (-yawDeg).truncatingRemainder(dividingBy: 360)
        return h < 0 ? h + 360 : h
    }

    /// Rotates the vector about +z by `deg` (positive = CCW looking down, i.e. yaw increases).
    public func rotatedAboutZ(deg: Double) -> Vector3 {
        let a = deg * .pi / 180
        let c = cos(a), s = sin(a)
        return Vector3(c * x - s * y, s * x + c * y, z)
    }

    public static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static prefix func - (a: Vector3) -> Vector3 { Vector3(-a.x, -a.y, -a.z) }
    public static func * (a: Vector3, s: Double) -> Vector3 { Vector3(a.x * s, a.y * s, a.z * s) }
    public static func * (s: Double, a: Vector3) -> Vector3 { a * s }
    public static func / (a: Vector3, s: Double) -> Vector3 { Vector3(a.x / s, a.y / s, a.z / s) }

    public var description: String {
        String(format: "(%.3f, %.3f, %.3f)", x, y, z)
    }
}

/// Angle helpers.
public enum Angle {
    /// Normalises degrees into (−180, 180].
    public static func normalizedDeg(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 }
        if d > 180 { d -= 360 }
        return d
    }

    /// Circular mean of angles in degrees; nil for an empty list or if the
    /// angles cancel out (resultant ~0).
    public static func circularMeanDeg(_ degs: [Double]) -> Double? {
        guard !degs.isEmpty else { return nil }
        var s = 0.0, c = 0.0
        for d in degs {
            s += sin(d * .pi / 180)
            c += cos(d * .pi / 180)
        }
        guard (s * s + c * c).squareRoot() > 1e-9 else { return nil }
        return atan2(s, c) * 180 / .pi
    }
}
