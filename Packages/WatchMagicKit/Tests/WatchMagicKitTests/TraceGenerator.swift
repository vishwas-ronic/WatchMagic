import Foundation
@testable import WatchMagicKit

/// Deterministic RNG (SplitMix64) so generated traces are reproducible.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func gaussian(_ sigma: Double) -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &self)
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Half-sine rate pulse: `amplitude · sin(π (t − start) / duration)` on [start, start + duration].
struct Pulse {
    var start: Double
    var duration: Double
    var amplitude: Double

    func value(at t: Double) -> Double {
        guard t >= start, t <= start + duration else { return 0 }
        return amplitude * sin(.pi * (t - start) / duration)
    }
}

/// Synthesises CoreMotion-like samples from forearm Euler-angle rate profiles.
///
/// Forearm frame F (world-expressed): R_F = Rz(yaw) · Ry(−pitch) · Rx(roll), so
/// F's x-axis is the forearm (elbow → hand), pitch = its elevation, roll =
/// rotation about it. The watch's device frame is D = F · diag(s, s, 1) where s
/// is the pointing sign (s = −1 ≙ the watch rotated 180° on the wrist).
/// Outputs device-frame rotation rate (rad/s, from finite differences of R_D),
/// device-frame gravity (−z_world expressed in D) and the device→world
/// attitude quaternion, plus Gaussian noise.
struct TraceGenerator {
    var sign: Double = 1
    var sampleRate: Double = 100
    var duration: Double = 2.5
    var yaw0Deg: Double = 30
    var pitch0Deg: Double = 10
    var roll0Deg: Double = 20
    var pitchPulses: [Pulse] = []
    var rollPulses: [Pulse] = []
    var yawPulses: [Pulse] = []
    var gyroNoise: Double = 0.05
    var gravityNoise: Double = 0.01
    var seed: UInt64 = 42

    func generate() -> [MotionSample] {
        let h = 0.001 // integration step
        let steps = Int((duration / h).rounded())
        var yaw = [Double](repeating: 0, count: steps + 2)
        var pitch = yaw, roll = yaw
        yaw[0] = yaw0Deg * .pi / 180
        pitch[0] = pitch0Deg * .pi / 180
        roll[0] = roll0Deg * .pi / 180
        func rate(_ ps: [Pulse], _ t: Double) -> Double { ps.reduce(0) { $0 + $1.value(at: t) } }
        for k in 0...steps {
            let t = Double(k) * h + h / 2
            yaw[k + 1] = yaw[k] + rate(yawPulses, t) * h
            pitch[k + 1] = pitch[k] + rate(pitchPulses, t) * h
            roll[k + 1] = roll[k] + rate(rollPulses, t) * h
        }
        func rDevice(_ k: Int) -> [[Double]] {
            let f = mul(mul(rotZ(yaw[k]), rotY(-pitch[k])), rotX(roll[k]))
            return mul(f, [[sign, 0, 0], [0, sign, 0], [0, 0, 1]])
        }

        var rng = SeededRNG(seed: seed)
        var out: [MotionSample] = []
        let every = Int((1 / sampleRate / h).rounded())
        var k = 1
        while k < steps {
            let r = rDevice(k)
            let rt = transpose(r)
            let rdot = sub(rDevice(k + 1), rDevice(k - 1)).map { $0.map { $0 / (2 * h) } }
            let w = mul(rt, rdot) // skew-symmetric: body angular velocity
            let omega = Vector3((w[2][1] - w[1][2]) / 2, (w[0][2] - w[2][0]) / 2, (w[1][0] - w[0][1]) / 2)
            let gWorld = Vector3(0, 0, -1)
            let g = apply(rt, gWorld)
            out.append(MotionSample(
                t: Double(k) * h,
                rotationRate: omega + Vector3(rng.gaussian(gyroNoise), rng.gaussian(gyroNoise), rng.gaussian(gyroNoise)),
                gravity: (g + Vector3(rng.gaussian(gravityNoise), rng.gaussian(gravityNoise), rng.gaussian(gravityNoise))).normalized,
                attitude: Quaternion(rotationMatrix: r)
            ))
            k += every
        }
        return out
    }

    // MARK: Canned gestures (start at t0)

    static func flickUp(sign: Double = 1, t0: Double = 1.0, seed: UInt64 = 1) -> TraceGenerator {
        var g = TraceGenerator(sign: sign, seed: seed)
        g.pitchPulses = flickUpPulses(t0)
        g.rollPulses = [Pulse(start: t0, duration: 0.10, amplitude: 0.8)]
        g.yawPulses = [Pulse(start: t0, duration: 0.10, amplitude: 0.5)]
        return g
    }

    static func flickDown(sign: Double = 1, t0: Double = 1.0, seed: UInt64 = 2) -> TraceGenerator {
        var g = TraceGenerator(sign: sign, seed: seed)
        g.pitchPulses = flickUpPulses(t0).map { Pulse(start: $0.start, duration: $0.duration, amplitude: -$0.amplitude) }
        g.rollPulses = [Pulse(start: t0, duration: 0.10, amplitude: -0.8)]
        g.yawPulses = [Pulse(start: t0, duration: 0.10, amplitude: -0.5)]
        return g
    }

    /// Pronation then return.
    static func twist(sign: Double = 1, t0: Double = 1.0, seed: UInt64 = 3) -> TraceGenerator {
        var g = TraceGenerator(sign: sign, seed: seed)
        g.rollPulses = [Pulse(start: t0, duration: 0.12, amplitude: 8),
                        Pulse(start: t0 + 0.12, duration: 0.16, amplitude: -6)]
        g.pitchPulses = [Pulse(start: t0, duration: 0.12, amplitude: 0.8)]
        g.yawPulses = [Pulse(start: t0, duration: 0.2, amplitude: 0.4)]
        return g
    }

    /// Raising the arm from hanging (−75°) to horizontal over 1.5 s (peak ≈ 1.4 rad/s).
    static func slowRaise(sign: Double = 1, seed: UInt64 = 4) -> TraceGenerator {
        var g = TraceGenerator(sign: sign, duration: 3.0, pitch0Deg: -75, seed: seed)
        g.pitchPulses = [Pulse(start: 0.5, duration: 1.5, amplitude: 1.37)]
        g.rollPulses = [Pulse(start: 0.5, duration: 1.5, amplitude: 0.8)]
        g.yawPulses = [Pulse(start: 0.7, duration: 1.0, amplitude: 0.5)]
        return g
    }

    /// Slow wrist rotation out and back (peak 1.8 rad/s) with a slow sweep.
    static func slowRotate(sign: Double = 1, seed: UInt64 = 5) -> TraceGenerator {
        var g = TraceGenerator(sign: sign, duration: 3.5, seed: seed)
        g.rollPulses = [Pulse(start: 0.5, duration: 1.2, amplitude: 1.8),
                        Pulse(start: 2.0, duration: 1.2, amplitude: -1.8)]
        g.yawPulses = [Pulse(start: 0.8, duration: 1.0, amplitude: 0.6)]
        g.pitchPulses = [Pulse(start: 1.0, duration: 1.0, amplitude: 0.4)]
        return g
    }

    /// Sharp up (6 rad/s, 100 ms) then a slower return (3.5 rad/s, 160 ms).
    static func flickUpPulses(_ t0: Double) -> [Pulse] {
        [Pulse(start: t0, duration: 0.10, amplitude: 6),
         Pulse(start: t0 + 0.10, duration: 0.16, amplitude: -3.5)]
    }
}

// MARK: - 3×3 helpers (rows)

private func mul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
    (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
}
private func transpose(_ a: [[Double]]) -> [[Double]] {
    (0..<3).map { i in (0..<3).map { j in a[j][i] } }
}
private func sub(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
    (0..<3).map { i in (0..<3).map { j in a[i][j] - b[i][j] } }
}
private func apply(_ m: [[Double]], _ v: Vector3) -> Vector3 {
    Vector3(m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
            m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
            m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z)
}
private func rotX(_ a: Double) -> [[Double]] { [[1, 0, 0], [0, cos(a), -sin(a)], [0, sin(a), cos(a)]] }
private func rotY(_ a: Double) -> [[Double]] { [[cos(a), 0, sin(a)], [0, 1, 0], [-sin(a), 0, cos(a)]] }
private func rotZ(_ a: Double) -> [[Double]] { [[cos(a), -sin(a), 0], [sin(a), cos(a), 0], [0, 0, 1]] }
