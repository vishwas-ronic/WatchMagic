import Foundation
import CoreMotion
import CoreLocation
import WatchKit
import WatchMagicKit

/// Where absolute yaw comes from (spec 1.2.1), in order of preference.
enum HeadingSource: String, Sendable {
    /// CoreMotion `.xMagneticNorthZVertical`: yaw is already north-referenced.
    case magneticNorthFrame
    /// `.xArbitraryCorrectedZVertical` + a yaw offset anchored (and slowly
    /// re-anchored) from `CLLocationManager` heading.
    case compassAnchored
    /// `.xArbitraryCorrectedZVertical` + a yaw offset set by the zero gesture
    /// (point at the room's anchor device and hold 1.5 s).
    case zeroGesture

    var displayName: String {
        switch self {
        case .magneticNorthFrame: return "Magnetic north frame"
        case .compassAnchored: return "Arbitrary + compass"
        case .zeroGesture: return "Arbitrary + zero gesture"
        }
    }
}

/// One processed motion update, delivered on the motion queue.
struct MotionFrame: Sendable {
    var sample: MotionSample
    var kinematics: MotionKinematics
    /// Forearm pointing in the CoreMotion reference frame (no yaw correction).
    var rawPointing: Vector3
    /// Forearm pointing in the world frame (x = north, y = west, z = up), yaw-corrected.
    var pointing: Vector3
    /// False while yaw is still arbitrary (compass not anchored / not zeroed).
    var headingReady: Bool
    var source: HeadingSource
    var pointingSign: Double
}

/// Diagnostics / UI state, published on the main thread at ~12 Hz.
struct MotionStatus: Equatable {
    var isRunning = false
    var deviceMotionAvailable = true
    var source: HeadingSource = .zeroGesture
    var availableFrames: [String] = []
    var headingAvailable = false
    var locationAuthorization = "—"
    /// CLHeading.magneticHeading (heading of the device's reference direction).
    var compassHeadingDeg: Double?
    /// CLHeading.headingAccuracy (nil = invalid / none yet).
    var compassAccuracyDeg: Double?
    /// CMDeviceMotion.heading (north frame only).
    var motionHeadingDeg: Double?
    /// CMDeviceMotion.magneticField.accuracy (north frame only).
    var magneticFieldAccuracy: String?
    var yawOffsetDeg = 0.0
    var headingReady = false
    var compassAnchorUpdates = 0
    /// Compass heading of the device's top (+y) axis according to the
    /// yaw-corrected attitude — should match `compassHeadingDeg` when the
    /// compass anchoring is right (verify on device).
    var deviceTopHeadingDeg: Double?
    var yawDeg = 0.0, pitchDeg = 0.0, rollDeg = 0.0
    var pointing: Vector3 = .zero
    var convention: RotationConvention?
    var conventionVotesRefToDev = 0
    var conventionVotesDevToRef = 0
    var wristIsLeft = true
    var crownIsRight = true
    var pointingSign = 1.0
    var requestedRateHz = 50.0
    var measuredRateHz = 0.0
}

/// CoreMotion (+ CoreLocation heading) → `MotionFrame` stream with the
/// heading-source fallback of spec 1.2.1.
///
/// Threading: device-motion updates arrive on `queue` (a serial queue). The
/// per-sample consumer (`setSampleHandler`) runs on that queue. `status` is
/// published on the main thread at ~12 Hz. CLLocationManager lives on main.
/// State shared between the two is in `shared` (lock-protected).
final class MotionService: NSObject, ObservableObject, CLLocationManagerDelegate, @unchecked Sendable {

    /// Serial queue for motion updates and everything downstream of them.
    let queue = DispatchQueue(label: "ai.ronic.watchmagic.motion", qos: .userInteractive)

    @Published private(set) var status = MotionStatus()

    private let manager = CMMotionManager()
    private let operationQueue: OperationQueue
    private let locationManager = CLLocationManager()

    private struct Shared {
        var source: HeadingSource = .zeroGesture
        /// Yaw offset + readiness (compass anchoring / zero gesture), WatchMagicKit.
        var anchor = HeadingAnchor()
        var pointingSign = 1.0
        /// Device +y ("12 o'clock") axis in the raw reference frame, last sample.
        var lastDeviceTop: Vector3?
        var lastAngularSpeed = 0.0
        /// Latest valid CLHeading.magneticHeading.
        var lastCompassHeading: Double?
        var onSample: (@Sendable (MotionFrame) -> Void)?
    }
    private let shared = Locked(Shared())

    // Motion-queue-only bookkeeping.
    private var lastPublishT: TimeInterval = 0
    private var rateWindowStart: TimeInterval = 0
    private var rateWindowCount = 0
    private var measuredRate = 0.0
    private var votesRefToDev = 0
    private var votesDevToRef = 0
    private var lastConvention: RotationConvention?

    override init() {
        let oq = OperationQueue()
        oq.maxConcurrentOperationCount = 1
        operationQueue = oq
        super.init()
        oq.underlyingQueue = queue
        locationManager.delegate = self
        locationManager.headingFilter = 1
        status.deviceMotionAvailable = manager.isDeviceMotionAvailable
        status.headingAvailable = CLLocationManager.headingAvailable()
        status.locationAuthorization = Self.describe(locationManager.authorizationStatus)
        refreshWearing()
    }

    // MARK: - Control (main thread)

    /// Sets the per-sample consumer (called on `queue`).
    func setSampleHandler(_ handler: (@Sendable (MotionFrame) -> Void)?) {
        shared.withLock { $0.onSample = handler }
    }

    /// Starts device-motion updates (idempotent) and picks the heading source.
    func start() {
        guard !manager.isDeviceMotionActive, manager.isDeviceMotionAvailable else { return }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let headingAvailable = CLLocationManager.headingAvailable()
        let source: HeadingSource
        let frame: CMAttitudeReferenceFrame
        if frames.contains(.xMagneticNorthZVertical) {
            source = .magneticNorthFrame
            frame = .xMagneticNorthZVertical
        } else if headingAvailable && !Self.isDenied(locationManager.authorizationStatus) {
            source = .compassAnchored
            frame = .xArbitraryCorrectedZVertical
        } else {
            source = .zeroGesture
            frame = .xArbitraryCorrectedZVertical
        }
        // A new arbitrary frame has a new yaw origin: forget the old offset.
        shared.withLock {
            $0.source = source
            $0.anchor.reset()
            if source == .magneticNorthFrame { $0.anchor.markAnchored() }
            $0.lastDeviceTop = nil
        }
        var s = status
        s.availableFrames = Self.describe(frames)
        s.headingAvailable = headingAvailable
        s.source = source
        s.isRunning = true
        s.headingReady = (source == .magneticNorthFrame)
        s.yawOffsetDeg = 0
        status = s

        if source == .compassAnchored {
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }
            locationManager.startUpdatingHeading()
        }

        manager.deviceMotionUpdateInterval = 1 / status.requestedRateHz
        manager.startDeviceMotionUpdates(using: frame, to: operationQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(motion)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        locationManager.stopUpdatingHeading()
        status.isRunning = false
    }

    /// 50 or 100 Hz. Applied to the running stream without restarting it (so
    /// the arbitrary frame and its yaw offset survive).
    func setRate(_ hz: Double) {
        let hz = min(100, max(10, hz))
        status.requestedRateHz = hz
        manager.deviceMotionUpdateInterval = 1 / hz
    }

    /// Re-reads wrist side and crown orientation (call when the app becomes active).
    func refreshWearing() {
        let device = WKInterfaceDevice.current()
        let wristLeft = device.wristLocation == .left
        let crownRight = device.crownOrientation == .right
        let sign = ForearmGeometry.pointingSign(wristIsLeft: wristLeft, crownIsRight: crownRight)
        shared.withLock { $0.pointingSign = sign }
        status.wristIsLeft = wristLeft
        status.crownIsRight = crownRight
        status.pointingSign = sign
    }

    /// Zero gesture result: absolute yaw offset (degrees) to add to raw yaw.
    func applyZero(offsetDeg: Double) {
        let off = shared.withLock { s -> Double in
            s.anchor.set(offsetDeg: offsetDeg)
            return s.anchor.offsetDeg
        }
        status.yawOffsetDeg = off
        status.headingReady = true
    }

    /// Declares the current (arbitrary) yaw as the reference — used when the
    /// first device of a room is taught without any anchor to zero against.
    func markHeadingReady() {
        shared.withLock { $0.anchor.markAnchored() }
        status.headingReady = true
    }

    /// Forgets the yaw anchor (Sensor Probe → Re-zero). No effect on the north frame.
    func resetHeading() {
        let ready = shared.withLock { s -> Bool in
            guard s.source != .magneticNorthFrame else { return true }
            s.anchor.reset()
            return false
        }
        status.headingReady = ready
        if !ready { status.yawOffsetDeg = 0 }
    }

    // MARK: - Motion queue

    private func handle(_ dm: CMDeviceMotion) {
        let r = dm.attitude.rotationMatrix
        let m = [[r.m11, r.m12, r.m13], [r.m21, r.m22, r.m23], [r.m31, r.m32, r.m33]]
        let gravity = Vector3(dm.gravity.x, dm.gravity.y, dm.gravity.z)
        let q = dm.attitude.quaternion
        let snap = shared.snapshot

        var heading: Double?
        if snap.source == .magneticNorthFrame {
            heading = dm.heading >= 0 ? dm.heading : nil
        } else {
            heading = snap.lastCompassHeading
        }
        let sample = MotionSample(
            t: dm.timestamp,
            rotationRate: Vector3(dm.rotationRate.x, dm.rotationRate.y, dm.rotationRate.z),
            gravity: gravity,
            attitude: Quaternion(x: q.x, y: q.y, z: q.z, w: q.w),
            heading: heading
        )
        let raw = ForearmGeometry.worldPointing(rotationMatrix: m, sign: snap.pointingSign)
        let pointing = raw.rotatedAboutZ(deg: snap.anchor.offsetDeg)
        let kin = MotionKinematics(sample: sample, pointingSign: snap.pointingSign)
        // Device +y axis in the reference frame (same convention as worldPointing).
        let top = HeadingAnchor.deviceTopAxis(rotationMatrix: m)
        shared.withLock {
            $0.lastDeviceTop = top
            $0.lastAngularSpeed = kin.angularSpeed
        }

        snap.onSample?(MotionFrame(
            sample: sample, kinematics: kin, rawPointing: raw, pointing: pointing,
            headingReady: snap.anchor.isAnchored, source: snap.source, pointingSign: snap.pointingSign
        ))

        // Rate measurement.
        rateWindowCount += 1
        if sample.t - rateWindowStart >= 1 {
            if rateWindowStart > 0 { measuredRate = Double(rateWindowCount) / (sample.t - rateWindowStart) }
            rateWindowStart = sample.t
            rateWindowCount = 0
        }

        // Throttled diagnostics publish (~12 Hz).
        guard sample.t - lastPublishT >= 1.0 / 12 else { return }
        lastPublishT = sample.t
        if let c = RotationConvention.detect(rotationMatrix: m, gravity: gravity) {
            lastConvention = c
            if c == .referenceToDevice { votesRefToDev += 1 } else { votesDevToRef += 1 }
        }
        let deg = 180 / Double.pi
        let yaw = dm.attitude.yaw * deg, pitch = dm.attitude.pitch * deg, roll = dm.attitude.roll * deg
        let topHeading: Double? = snap.anchor.isAnchored && hypot(top.x, top.y) > 0.3
            ? top.rotatedAboutZ(deg: snap.anchor.offsetDeg).compassHeadingDeg : nil
        let motionHeading = snap.source == .magneticNorthFrame && dm.heading >= 0 ? dm.heading : nil
        let fieldAccuracy = snap.source == .magneticNorthFrame ? Self.describe(dm.magneticField.accuracy) : nil
        let rate = measuredRate, conv = lastConvention, v1 = votesRefToDev, v2 = votesDevToRef
        let offset = snap.anchor.offsetDeg, ready = snap.anchor.isAnchored, anchors = snap.anchor.compassUpdates
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var s = self.status
            s.yawDeg = yaw; s.pitchDeg = pitch; s.rollDeg = roll
            s.pointing = pointing
            s.convention = conv
            s.conventionVotesRefToDev = v1
            s.conventionVotesDevToRef = v2
            s.measuredRateHz = rate
            s.yawOffsetDeg = offset
            s.headingReady = ready
            s.compassAnchorUpdates = anchors
            s.deviceTopHeadingDeg = topHeading
            s.motionHeadingDeg = motionHeading
            s.magneticFieldAccuracy = fieldAccuracy
            self.status = s
        }
    }

    // MARK: - CLLocationManagerDelegate (main thread)

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let accuracy = newHeading.headingAccuracy
        let heading = newHeading.magneticHeading
        let valid = accuracy >= 0
        let result = shared.withLock { s -> (offset: Double, ready: Bool, anchors: Int) in
            s.lastCompassHeading = valid ? heading : nil
            // Accuracy / tilt / steadiness gating, first-set and 5% blending
            // live in WatchMagicKit's HeadingAnchor (CLHeading is assumed to be
            // the heading of the watch's top, +y, axis).
            if s.source == .compassAnchored {
                s.anchor.compassUpdate(headingDeg: heading, accuracyDeg: accuracy,
                                       deviceTop: s.lastDeviceTop, angularSpeed: s.lastAngularSpeed)
            }
            return (s.anchor.offsetDeg, s.anchor.isAnchored, s.anchor.compassUpdates)
        }
        var st = status
        st.compassHeadingDeg = valid ? heading : nil
        st.compassAccuracyDeg = valid ? accuracy : nil
        st.yawOffsetDeg = result.offset
        st.headingReady = result.ready
        st.compassAnchorUpdates = result.anchors
        status = st
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let auth = manager.authorizationStatus
        status.locationAuthorization = Self.describe(auth)
        if (auth == .authorizedWhenInUse || auth == .authorizedAlways),
           shared.snapshot.source == .compassAnchored {
            manager.startUpdatingHeading() // (re)start now that we're allowed
        }
        // Heading denied → fall back to the zero gesture (spec 1.2.1, step 3).
        if Self.isDenied(auth) {
            let switched = shared.withLock { s -> Bool in
                guard s.source == .compassAnchored else { return false }
                s.source = .zeroGesture
                return true
            }
            if switched {
                manager.stopUpdatingHeading()
                status.source = .zeroGesture
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Heading errors (e.g. interference) are transient; keep the last anchor.
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { false }

    // MARK: - Descriptions

    private static func isDenied(_ s: CLAuthorizationStatus) -> Bool {
        s == .denied || s == .restricted
    }

    private static func describe(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "Not determined"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "When in use"
        @unknown default: return "Unknown"
        }
    }

    private static func describe(_ frames: CMAttitudeReferenceFrame) -> [String] {
        var out: [String] = []
        if frames.contains(.xArbitraryZVertical) { out.append("xArbitraryZVertical") }
        if frames.contains(.xArbitraryCorrectedZVertical) { out.append("xArbitraryCorrectedZVertical") }
        if frames.contains(.xMagneticNorthZVertical) { out.append("xMagneticNorthZVertical") }
        if frames.contains(.xTrueNorthZVertical) { out.append("xTrueNorthZVertical") }
        return out.isEmpty ? ["(none)"] : out
    }

    private static func describe(_ a: CMMagneticFieldCalibrationAccuracy) -> String {
        switch a {
        case .uncalibrated: return "Uncalibrated"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        @unknown default: return "Unknown"
        }
    }
}
