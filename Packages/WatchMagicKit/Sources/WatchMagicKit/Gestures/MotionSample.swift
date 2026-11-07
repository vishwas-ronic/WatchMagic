import Foundation

/// One motion sample, as produced by `CMDeviceMotion` on the watch.
public struct MotionSample: Codable, Equatable, Sendable {
    /// Timestamp, seconds (any monotonic origin).
    public var t: TimeInterval
    /// `CMDeviceMotion.rotationRate`, device frame, rad/s.
    public var rotationRate: Vector3
    /// `CMDeviceMotion.gravity`, device frame, unit g, pointing toward Earth.
    public var gravity: Vector3
    /// `CMAttitude.quaternion` (x, y, z, w).
    public var attitude: Quaternion
    /// Compass heading in degrees, if available (`CMDeviceMotion.heading`).
    public var heading: Double?
    /// `CMDeviceMotion.userAcceleration`, device frame, g (gravity removed).
    /// nil in traces recorded before it was added.
    public var userAcceleration: Vector3?

    public init(t: TimeInterval, rotationRate: Vector3, gravity: Vector3,
                attitude: Quaternion = .identity, heading: Double? = nil,
                userAcceleration: Vector3? = nil) {
        self.t = t
        self.rotationRate = rotationRate
        self.gravity = gravity
        self.attitude = attitude
        self.heading = heading
        self.userAcceleration = userAcceleration
    }
}

// MARK: - CSV

/// CSV format for motion traces (Sensor Probe → Record, and test fixtures):
///
///     t,rx,ry,rz,gx,gy,gz,qx,qy,qz,qw[,ax,ay,az][,heading]
///
/// One header line, then one sample per line. Columns are matched by header
/// name (order-independent); unknown extra columns are ignored; lines that are
/// empty or start with `#` are skipped (comment lines may precede the header).
/// `ax,ay,az` (user acceleration, g) and `heading` are optional (empty = nil),
/// so older traces still load.
public enum MotionCSV {
    public static let columns = ["t", "rx", "ry", "rz", "gx", "gy", "gz", "qx", "qy", "qz", "qw"]
    public static let header = columns.joined(separator: ",")

    public enum CSVError: Error, Equatable, LocalizedError {
        case missingColumn(String)
        case badValue(line: Int, column: String)

        public var errorDescription: String? {
            switch self {
            case .missingColumn(let c): return "Motion CSV is missing column \"\(c)\""
            case .badValue(let l, let c): return "Motion CSV line \(l): bad value in \"\(c)\""
            }
        }
    }

    /// Encodes samples, preceded by `comments` as `# <comment>` lines. The
    /// `ax,ay,az` / `heading` columns are written only if any sample has them.
    public static func encode(_ samples: [MotionSample], comments: [String] = []) -> String {
        let withAccel = samples.contains { $0.userAcceleration != nil }
        let withHeading = samples.contains { $0.heading != nil }
        var out = comments.map { "# " + $0.replacingOccurrences(of: "\n", with: " ") + "\n" }.joined()
        out += header + (withAccel ? ",ax,ay,az" : "") + (withHeading ? ",heading" : "") + "\n"
        out.reserveCapacity(samples.count * 130)
        for s in samples {
            var fields = [s.t, s.rotationRate.x, s.rotationRate.y, s.rotationRate.z,
                          s.gravity.x, s.gravity.y, s.gravity.z,
                          s.attitude.x, s.attitude.y, s.attitude.z, s.attitude.w].map(format)
            if withAccel {
                if let a = s.userAcceleration {
                    fields += [a.x, a.y, a.z].map(format)
                } else {
                    fields += ["", "", ""]
                }
            }
            if withHeading { fields.append(s.heading.map(format) ?? "") }
            out += fields.joined(separator: ",") + "\n"
        }
        return out
    }

    /// One CSV data line for a sample (no newline), matching `header` (no heading column).
    public static func line(for s: MotionSample) -> String {
        [s.t, s.rotationRate.x, s.rotationRate.y, s.rotationRate.z,
         s.gravity.x, s.gravity.y, s.gravity.z,
         s.attitude.x, s.attitude.y, s.attitude.z, s.attitude.w].map(format).joined(separator: ",")
    }

    public static func decode(_ text: String) throws -> [MotionSample] {
        var lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return [] }
        let head = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var index: [String: Int] = [:]
        for (i, name) in head.enumerated() where index[name] == nil { index[name] = i }
        for c in columns where index[c] == nil { throw CSVError.missingColumn(c) }
        let headingIdx = index["heading"]
        let accelIdx: (Int, Int, Int)? = {
            guard let x = index["ax"], let y = index["ay"], let z = index["az"] else { return nil }
            return (x, y, z)
        }()

        var samples: [MotionSample] = []
        samples.reserveCapacity(lines.count)
        for (n, line) in lines.enumerated() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            func v(_ c: String) throws -> Double {
                let i = index[c]!
                guard i < f.count, let d = Double(f[i]) else { throw CSVError.badValue(line: n + 2, column: c) }
                return d
            }
            var heading: Double?
            if let hi = headingIdx, hi < f.count { heading = Double(f[hi]) }
            var accel: Vector3?
            if let (xi, yi, zi) = accelIdx, max(xi, yi, zi) < f.count,
               let ax = Double(f[xi]), let ay = Double(f[yi]), let az = Double(f[zi]) {
                accel = Vector3(ax, ay, az)
            }
            samples.append(MotionSample(
                t: try v("t"),
                rotationRate: Vector3(try v("rx"), try v("ry"), try v("rz")),
                gravity: Vector3(try v("gx"), try v("gy"), try v("gz")),
                attitude: Quaternion(x: try v("qx"), y: try v("qy"), z: try v("qz"), w: try v("qw")),
                heading: heading,
                userAcceleration: accel
            ))
        }
        return samples
    }

    private static func format(_ d: Double) -> String {
        String(format: "%.6f", d)
    }
}

// MARK: - Kinematics

/// Forearm kinematics derived from one sample. Independent of how the watch is
/// worn: everything is computed in the device frame from the forearm pointing
/// vector `p = sign · x̂` and `up = −gravity`.
public struct MotionKinematics: Equatable, Sendable {
    /// Elevation of the forearm axis, degrees: asin(p · up).
    public var pitchDeg: Double
    /// Rate of change of that elevation, rad/s (positive = hand/tip rising):
    /// ((ω × p) · up) / cos(pitch). cos(pitch) is clamped at 0.25 to avoid
    /// blow-ups when pointing (nearly) straight up or down.
    public var pitchRate: Double
    /// Rotation rate about the forearm axis, rad/s: ω · p (sign depends on wrist; magnitude doesn't).
    public var rollRate: Double
    /// |ω|, rad/s.
    public var angularSpeed: Double

    public init(sample: MotionSample, pointingSign: Double) {
        let p = ForearmGeometry.devicePointing(sign: pointingSign)
        let up = (-sample.gravity).normalized
        let w = sample.rotationRate
        let s = max(-1, min(1, p.dot(up)))
        let pitch = asin(s)
        pitchDeg = pitch * 180 / .pi
        pitchRate = w.cross(p).dot(up) / max(0.25, cos(pitch))
        rollRate = w.dot(p)
        angularSpeed = w.norm
    }
}
