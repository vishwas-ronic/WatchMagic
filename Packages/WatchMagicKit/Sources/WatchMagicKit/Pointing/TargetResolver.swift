import Foundation

/// A device that can be aimed at, with its unit reference direction (world frame).
public struct TargetCandidate: Equatable, Hashable, Sendable {
    public var id: UUID
    public var direction: Vector3

    public init(id: UUID, direction: Vector3) {
        self.id = id
        self.direction = direction
    }
}

/// Result of resolving a pointing vector against the room's devices.
public enum Resolution: Equatable, Hashable, Sendable {
    /// Nothing within tolerance.
    case none
    /// One clear winner.
    case locked(id: UUID, angleDeg: Double)
    /// Two or more devices within the ambiguity margin, sorted by angle (closest first).
    case ambiguous([UUID])

    /// IDs involved (empty for `.none`).
    public var ids: [UUID] {
        switch self {
        case .none: return []
        case .locked(let id, _): return [id]
        case .ambiguous(let ids): return ids
        }
    }

    public var isNone: Bool { self == .none }
}

/// Picks the device the user is pointing at (spec 1.2.2).
public enum TargetResolver {

    /// - Locked iff the best angle ≤ `toleranceDeg` and (no runner-up, or
    ///   runner-up − best ≥ `marginDeg`).
    /// - Ambiguous if the best is within tolerance but the runner-up is within
    ///   the margin: returns every candidate with angle ≤ best + margin and
    ///   ≤ tolerance + margin (always at least two), sorted by angle.
    /// - Otherwise `.none`.
    public static func resolve(
        pointing: Vector3,
        candidates: [TargetCandidate],
        toleranceDeg: Double,
        marginDeg: Double
    ) -> Resolution {
        guard !pointing.isZero else { return .none }
        let scored = candidates
            .filter { !$0.direction.isZero }
            .map { (id: $0.id, angle: pointing.angle(to: $0.direction)) }
            .sorted { $0.angle < $1.angle }
        guard let best = scored.first, best.angle <= toleranceDeg else { return .none }
        guard scored.count > 1, scored[1].angle - best.angle < marginDeg else {
            return .locked(id: best.id, angleDeg: best.angle)
        }
        let limit = min(best.angle + marginDeg, toleranceDeg + marginDeg)
        var ids = scored.filter { $0.angle <= limit }.map(\.id)
        if ids.count < 2 { ids = [scored[0].id, scored[1].id] }
        return .ambiguous(ids)
    }

    /// Convenience using `Settings` tolerances.
    public static func resolve(pointing: Vector3, candidates: [TargetCandidate], settings: Settings) -> Resolution {
        resolve(pointing: pointing, candidates: candidates,
                toleranceDeg: settings.aimToleranceDeg, marginDeg: settings.ambiguityMarginDeg)
    }

    /// Zero-gesture helper: degrees to ADD to the measured yaw so that the
    /// measured pointing matches the reference direction. Result in (−180, 180].
    /// Apply with `measured.rotatedAboutZ(deg: correction)`.
    public static func yawCorrection(measured: Vector3, reference: Vector3) -> Double {
        Angle.normalizedDeg(reference.yawDeg - measured.yawDeg)
    }
}
