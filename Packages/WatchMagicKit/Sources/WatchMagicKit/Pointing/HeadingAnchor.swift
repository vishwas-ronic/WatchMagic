import Foundation

/// Absolute-yaw anchor for an arbitrary-yaw attitude frame (spec 1.2.1).
///
/// Holds the yaw offset (degrees, added to raw yaw: `world = raw.rotatedAboutZ(offsetDeg)`)
/// and whether it is known. The offset is set either from the compass
/// (`compassUpdate`, heading source "compass anchored") or directly
/// (`set(offsetDeg:)`, e.g. from the zero gesture).
///
/// Compass anchoring: the compass heading is ASSUMED to be the heading of the
/// device's top (+y, 12 o'clock) axis, NOT the forearm (±x). So
///   world yaw(+y) = −heading  (compass is clockwise, yaw CCW)
///   offset        = world yaw(+y) − raw yaw(+y)
/// A reading is used only when its accuracy is valid and ≤ 20°, the +y axis is
/// within ~30° of horizontal (its yaw is well defined and the compass tilt
/// compensation is at its best) and the wrist is steady (heading lags motion
/// slightly). The first good reading sets the offset; later ones blend it 5%
/// of the way (the short way round the circle) towards the new target.
///
/// Platform-free: no CoreMotion / CoreLocation types.
public struct HeadingAnchor: Equatable, Sendable {
    /// Only readings with heading accuracy ≤ this, degrees.
    public static let maxAccuracyDeg = 20.0
    /// Low-pass factor per accepted reading once anchored.
    public static let blendAlpha = 0.05
    /// |top.z| ≤ this (sin 30°): the top axis is within ~30° of horizontal.
    public static let maxTopAxisZ = 0.5
    /// Steady = angular speed below this, rad/s.
    public static let steadySpeed = 0.5

    public enum CompassResult: Equatable, Sendable {
        /// First good reading: the offset was set.
        case anchored
        /// Already anchored: the offset was blended towards the reading.
        case blended
        case rejected(Rejection)

        public var accepted: Bool { if case .rejected = self { return false } else { return true } }
    }

    public enum Rejection: Equatable, Sendable {
        /// Negative accuracy = invalid heading.
        case invalidHeading
        case poorAccuracy
        /// No attitude sample yet.
        case noAttitude
        case topAxisTooTilted
        case notSteady
    }

    /// Degrees in (−180, 180], to add to raw yaw.
    public private(set) var offsetDeg: Double
    /// False while yaw is still arbitrary.
    public private(set) var isAnchored: Bool
    /// Number of accepted compass readings.
    public private(set) var compassUpdates = 0

    public init(offsetDeg: Double = 0, isAnchored: Bool = false) {
        self.offsetDeg = Angle.normalizedDeg(offsetDeg)
        self.isAnchored = isAnchored
    }

    /// Sets the offset directly (zero gesture) and marks it anchored.
    public mutating func set(offsetDeg: Double) {
        self.offsetDeg = Angle.normalizedDeg(offsetDeg)
        isAnchored = true
    }

    /// Declares the current offset as the reference (first teach in an arbitrary frame).
    public mutating func markAnchored() {
        isAnchored = true
    }

    /// Forgets the anchor (offset back to 0). Keeps `compassUpdates`.
    public mutating func reset() {
        offsetDeg = 0
        isAnchored = false
    }

    /// Feeds one compass reading.
    /// - Parameters:
    ///   - headingDeg: compass heading of the device's top axis, degrees clockwise from north.
    ///   - accuracyDeg: heading accuracy, degrees (negative = invalid).
    ///   - deviceTop: the device's +y axis in the RAW reference frame (latest attitude), unit vector.
    ///   - angularSpeed: latest angular speed, rad/s.
    @discardableResult
    public mutating func compassUpdate(headingDeg: Double, accuracyDeg: Double, deviceTop: Vector3?,
                                       angularSpeed: Double) -> CompassResult {
        guard accuracyDeg >= 0 else { return .rejected(.invalidHeading) }
        guard accuracyDeg <= Self.maxAccuracyDeg else { return .rejected(.poorAccuracy) }
        guard let top = deviceTop, !top.isZero else { return .rejected(.noAttitude) }
        guard abs(top.normalized.z) <= Self.maxTopAxisZ else { return .rejected(.topAxisTooTilted) }
        guard angularSpeed < Self.steadySpeed else { return .rejected(.notSteady) }

        let target = Self.compassOffset(headingDeg: headingDeg, deviceTop: top)
        compassUpdates += 1
        if isAnchored {
            offsetDeg = Self.blend(from: offsetDeg, to: target, alpha: Self.blendAlpha)
            return .blended
        }
        offsetDeg = target
        isAnchored = true
        return .anchored
    }

    /// Offset that makes the raw top axis point at `headingDeg`: `−heading − yaw(top)`, in (−180, 180].
    public static func compassOffset(headingDeg: Double, deviceTop: Vector3) -> Double {
        Angle.normalizedDeg(-headingDeg - deviceTop.yawDeg)
    }

    /// Moves `from` a fraction `alpha` of the way to `to`, the short way round; result in (−180, 180].
    public static func blend(from: Double, to: Double, alpha: Double) -> Double {
        let diff = Angle.normalizedDeg(to - from)
        return Angle.normalizedDeg(from + alpha * diff)
    }

    /// The device's +y ("12 o'clock") axis in the reference frame from a
    /// `CMAttitude.rotationMatrix`-style matrix (rows m1x, m2x, m3x), under the
    /// same convention as `ForearmGeometry.worldPointing`.
    public static func deviceTopAxis(rotationMatrix m: [[Double]],
                                     convention: RotationConvention = .referenceToDevice) -> Vector3 {
        guard m.count == 3, m.allSatisfy({ $0.count == 3 }) else { return .zero }
        switch convention {
        case .referenceToDevice: return Vector3(m[1][0], m[1][1], m[1][2])
        case .deviceToReference: return Vector3(m[0][1], m[1][1], m[2][1])
        }
    }
}
