import Foundation

/// How a 3×3 rotation matrix maps between frames.
///
/// CoreMotion: `CMAttitude.rotationMatrix` (m11…m33, rows m1x, m2x, m3x) is
/// ASSUMED to map reference-frame vectors to device-frame vectors
/// (`v_device = R · v_reference`). Evidence: `CMDeviceMotion.gravity` ≈
/// −(m13, m23, m33), the third column, which is `R · (0, 0, −1)`. Under that
/// assumption the device's x-axis expressed in the reference frame is the
/// FIRST ROW (m11, m12, m13).
///
/// VERIFY ON DEVICE via Sensor Probe: call `RotationConvention.detect(rotationMatrix:gravity:)`
/// with live data while the watch is tilted (not flat); it should return `.referenceToDevice`.
public enum RotationConvention: String, Codable, Sendable {
    /// `v_device = R · v_reference` (assumed CoreMotion convention). Device axes = rows.
    case referenceToDevice
    /// `v_reference = R · v_device`. Device axes = columns.
    case deviceToReference

    /// Determines the convention by comparing the gravity the matrix predicts
    /// with the measured device-frame gravity (unit g, pointing to Earth).
    /// Returns nil when the two conventions predict (nearly) the same gravity,
    /// e.g. when the watch lies flat — tilt it and try again.
    public static func detect(rotationMatrix m: [[Double]], gravity: Vector3) -> RotationConvention? {
        guard m.count == 3, m.allSatisfy({ $0.count == 3 }) else { return nil }
        let refToDev = Vector3(-m[0][2], -m[1][2], -m[2][2]) // R·(0,0,−1): third column
        let devToRef = Vector3(-m[2][0], -m[2][1], -m[2][2]) // Rᵀ·(0,0,−1): third row
        guard refToDev.angle(to: devToRef) > 10 else { return nil }
        return gravity.angle(to: refToDev) <= gravity.angle(to: devToRef) ? .referenceToDevice : .deviceToReference
    }
}

/// Unit quaternion (x, y, z, w), as in `CMQuaternion`.
public struct Quaternion: Codable, Hashable, Sendable {
    public var x: Double, y: Double, z: Double, w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }

    public static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)

    /// Standard (Hamilton) rotation matrix of this quaternion, rows. It rotates
    /// vectors by q: `v' = q v q*`. NOTE: how this relates to
    /// `CMAttitude.rotationMatrix` is unverified; for pointing prefer
    /// `ForearmGeometry.worldPointing(rotationMatrix:sign:)`. In the bundled
    /// synthetic fixtures, q rotates device-frame vectors into the world frame.
    public var rotationMatrix: [[Double]] {
        let n = (x * x + y * y + z * z + w * w).squareRoot()
        let (qx, qy, qz, qw) = n > 0 ? (x / n, y / n, z / n, w / n) : (0, 0, 0, 1)
        return [
            [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)],
            [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)],
            [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)],
        ]
    }

    /// Rotates `v` by this quaternion (`q v q*`).
    public func rotate(_ v: Vector3) -> Vector3 {
        let m = rotationMatrix
        return Vector3(
            m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
            m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
            m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z
        )
    }

    /// Quaternion from a rotation matrix (rows) that rotates vectors (`v' = M v`).
    public init(rotationMatrix m: [[Double]]) {
        let trace = m[0][0] + m[1][1] + m[2][2]
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            self.init(x: (m[2][1] - m[1][2]) / s, y: (m[0][2] - m[2][0]) / s, z: (m[1][0] - m[0][1]) / s, w: s / 4)
        } else if m[0][0] > m[1][1] && m[0][0] > m[2][2] {
            let s = (1 + m[0][0] - m[1][1] - m[2][2]).squareRoot() * 2
            self.init(x: s / 4, y: (m[0][1] + m[1][0]) / s, z: (m[0][2] + m[2][0]) / s, w: (m[2][1] - m[1][2]) / s)
        } else if m[1][1] > m[2][2] {
            let s = (1 + m[1][1] - m[0][0] - m[2][2]).squareRoot() * 2
            self.init(x: (m[0][1] + m[1][0]) / s, y: s / 4, z: (m[1][2] + m[2][1]) / s, w: (m[0][2] - m[2][0]) / s)
        } else {
            let s = (1 + m[2][2] - m[0][0] - m[1][1]).squareRoot() * 2
            self.init(x: (m[0][2] + m[2][0]) / s, y: (m[1][2] + m[2][1]) / s, z: s / 4, w: (m[1][0] - m[0][1]) / s)
        }
    }
}

/// Forearm pointing geometry. The forearm axis (elbow → hand) is the device
/// x-axis times a sign that depends on how the watch is worn.
public enum ForearmGeometry {

    /// +1 when the Digital Crown faces the hand (left wrist + crown right, or
    /// right wrist + crown left — the usual configurations), else −1.
    /// Pointing in the device frame = sign · (1, 0, 0).
    /// ASSUMPTION (verify on device via Sensor Probe): the hardware +x axis
    /// points toward the crown side of the case.
    public static func pointingSign(wristIsLeft: Bool, crownIsRight: Bool) -> Double {
        (wristIsLeft == crownIsRight) ? 1 : -1
    }

    /// Forearm pointing vector in the DEVICE frame.
    public static func devicePointing(sign: Double) -> Vector3 {
        Vector3(sign >= 0 ? 1 : -1, 0, 0)
    }

    /// Forearm pointing unit vector in the WORLD (reference) frame.
    /// - Parameters:
    ///   - rotationMatrix: 3×3 rows `[[m11, m12, m13], [m21, m22, m23], [m31, m32, m33]]`
    ///     copied straight from `CMAttitude.rotationMatrix`.
    ///   - convention: defaults to the assumed CoreMotion convention
    ///     (`.referenceToDevice`, so the device x-axis in world = first row).
    public static func worldPointing(
        rotationMatrix m: [[Double]],
        sign: Double,
        convention: RotationConvention = .referenceToDevice
    ) -> Vector3 {
        guard m.count == 3, m.allSatisfy({ $0.count == 3 }) else { return .zero }
        let xAxis: Vector3
        switch convention {
        case .referenceToDevice: xAxis = Vector3(m[0][0], m[0][1], m[0][2])
        case .deviceToReference: xAxis = Vector3(m[0][0], m[1][0], m[2][0])
        }
        return (xAxis * (sign >= 0 ? 1 : -1)).normalized
    }

    /// Forearm pointing from an attitude quaternion that rotates DEVICE vectors
    /// into the WORLD frame (as in the synthetic fixtures; for CMQuaternion this
    /// is unverified — prefer the rotation-matrix variant on the watch).
    public static func worldPointing(deviceToWorld q: Quaternion, sign: Double) -> Vector3 {
        q.rotate(devicePointing(sign: sign)).normalized
    }
}
