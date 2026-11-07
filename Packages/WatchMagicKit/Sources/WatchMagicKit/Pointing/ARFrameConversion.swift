import Foundation

/// Converts between ARKit's world frame and the WatchMagic room frame.
///
/// ARKit (`worldAlignment = .gravity`): right-handed, +y up (against gravity),
/// +x to the right and −z forward as the camera faced at session start.
/// Room frame (see `Vector3.swift`): right-handed, +z up.
///
/// The mapping `(x, y, z)_ARKit → (x, −z, y)_room` is a proper rotation
/// (+90° about x; determinant +1), so handedness and cross products are
/// preserved: ARKit forward (0, 0, −1) becomes room +y, ARKit up becomes room +z.
/// Yaw of the resulting room frame is arbitrary (it depends on how the phone
/// faced at session start); `ReferenceDirections` absorbs it via the compass offset.
public enum ARFrameConversion {
    /// ARKit world point/direction → room frame.
    public static func roomPoint(fromARKit p: Vector3) -> Vector3 {
        Vector3(p.x, -p.z, p.y)
    }

    /// Room frame point/direction → ARKit world (inverse of `roomPoint(fromARKit:)`).
    public static func arkitPoint(fromRoom p: Vector3) -> Vector3 {
        Vector3(p.x, p.z, -p.y)
    }
}
