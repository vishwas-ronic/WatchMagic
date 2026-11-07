import ARKit
import Combine
import Foundation
import RealityKit
import UIKit
import WatchMagicKit

/// Per-room `ARWorldMap` files (Application Support/WorldMaps/<roomID>.worldmap).
/// Local to this phone and never synced: they only let a later placement
/// session relocalize into the frame the room's coordinates were saved in.
enum WorldMapStore {
    static var directory: URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return support.appendingPathComponent("WorldMaps", isDirectory: true)
    }

    static func url(for roomID: UUID) -> URL {
        directory.appendingPathComponent("\(roomID.uuidString).worldmap")
    }

    static func load(roomID: UUID) -> ARWorldMap? {
        guard let data = try? Data(contentsOf: url(for: roomID)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    static func save(_ map: ARWorldMap, roomID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        try data.write(to: url(for: roomID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func delete(roomID: UUID) {
        try? FileManager.default.removeItem(at: url(for: roomID))
    }
}

/// Drives one "Place with camera" session for a room: runs ARKit world
/// tracking (LiDAR mesh when available), raycasts from the screen centre,
/// keeps the seat and device positions placed in this session (ARKit world
/// frame) and draws markers for them.
///
/// Frame handling: if the room has a saved world map, the session starts by
/// relocalizing into it; only then (`frame == .relocalized`) are positions in
/// the same frame as the room's stored coordinates. Otherwise (`.fresh`) the
/// session defines a new frame and `RoomPlacement` clears the coordinates of
/// devices that are not re-placed.
@MainActor
final class PlacementSession: NSObject, ObservableObject {
    enum FrameState: Equatable {
        /// Not started yet / AR unsupported.
        case starting
        /// Looking for the saved world map; placing is disabled.
        case relocalizing
        /// Matched the saved map: same frame as the stored coordinates.
        case relocalized
        /// New frame (no map, or the user chose to start fresh).
        case fresh
    }

    enum Mark: Hashable {
        case seat
        case device(UUID)
        /// House-alignment corner mark, slot 0 = A, 1 = B.
        case corner(Int)
    }

    /// A raycast hit (ARKit world frame).
    struct SurfaceHit {
        var position: SIMD3<Float>
        /// Unit surface normal, if known.
        var normal: SIMD3<Float>?
    }

    let roomID: UUID
    let arView: ARView
    let supportsMesh: Bool

    @Published private(set) var frameState: FrameState = .starting
    /// Short tracking hint ("Move the phone slowly…"), nil when tracking is normal.
    @Published private(set) var trackingMessage: String?
    /// Distance from the camera to the surface under the reticle (m), nil = no surface.
    @Published private(set) var hitDistance: Float?
    /// Device positions placed in this session (ARKit world frame).
    @Published private(set) var placed: [UUID: SIMD3<Float>] = [:]
    /// Seat set in this session (ARKit world frame).
    @Published private(set) var seat: SIMD3<Float>?
    /// House-alignment corners marked in this session (slot → ARKit world point).
    @Published private(set) var cornerMarks: [Int: SIMD3<Float>] = [:]
    /// Mount surface of devices placed in this session.
    @Published private(set) var mounts: [UUID: DeviceMount] = [:]
    /// Fatal problem (no camera access, AR unsupported, session failure).
    @Published private(set) var errorMessage: String?
    @Published private(set) var canUndo = false

    /// Room-frame positions stored before this session (shown once relocalized).
    private let existingCoords: [UUID: Vector3]
    private let existingSeat: Vector3?
    private let names: [UUID: String]
    private var history: [(mark: Mark, previous: SIMD3<Float>?, previousMount: DeviceMount?)] = []
    private var markers: [Mark: (anchor: AnchorEntity, label: Entity)] = [:]
    private var updateSubscription: Cancellable?
    private var lastUpdate: TimeInterval = 0

    var sameFrame: Bool { frameState == .relocalized }
    var canPlace: Bool { (frameState == .relocalized || frameState == .fresh) && errorMessage == nil }
    var hasChanges: Bool { !placed.isEmpty || seat != nil || !cornerMarks.isEmpty }

    init(roomID: UUID, devices: [ControlledDevice], existingSeat: Vector3?) {
        self.roomID = roomID
        self.names = Dictionary(devices.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        self.existingCoords = Dictionary(devices.compactMap { d in d.coordinates.map { (d.id, $0) } },
                                         uniquingKeysWith: { a, _ in a })
        self.existingSeat = existingSeat
        self.supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        self.arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        super.init()
        arView.renderOptions.insert(.disableMotionBlur)
        if supportsMesh {
            // Lets `scene.raycast` hit the LiDAR mesh (markers have no collision shapes).
            arView.environment.sceneUnderstanding.options.insert(.collision)
        }
        arView.session.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        guard frameState == .starting else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            errorMessage = "This iPhone doesn't support AR world tracking."
            return
        }
        let config = makeConfiguration()
        if let map = WorldMapStore.load(roomID: roomID) {
            config.initialWorldMap = map
            frameState = .relocalizing
        } else {
            frameState = .fresh
        }
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        updateSubscription?.cancel()
        updateSubscription = nil
        arView.session.pause()
    }

    /// Abandons relocalization (or this session's work) and starts a new frame.
    func startFresh() {
        for m in markers.values { arView.scene.removeAnchor(m.anchor) }
        markers = [:]
        placed = [:]
        seat = nil
        cornerMarks = [:]
        mounts = [:]
        history = []
        canUndo = false
        hitDistance = nil
        frameState = .fresh
        arView.session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal, .vertical]
        if supportsMesh { config.sceneReconstruction = .mesh }
        return config
    }

    // MARK: - Placing

    /// Places `deviceID` at the surface under the reticle. Returns false on a miss.
    @discardableResult
    func place(deviceID: UUID) -> Bool {
        guard canPlace, let hit = surfaceHit() else { return false }
        record(.device(deviceID), previous: placed[deviceID], previousMount: mounts[deviceID])
        placed[deviceID] = hit.position
        mounts[deviceID] = mount(for: hit)
        refreshMarker(.device(deviceID))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    /// Seat = the camera's current position (phone held where the wrist is when pointing).
    func setSeat() {
        guard canPlace else { return }
        let cam = arView.cameraTransform.translation
        record(.seat, previous: seat, previousMount: nil)
        seat = cam
        refreshMarker(.seat)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func undo() {
        guard let last = history.popLast() else { return }
        switch last.mark {
        case .seat: seat = last.previous
        case .device(let id):
            placed[id] = last.previous
            mounts[id] = last.previousMount
        case .corner(let slot): cornerMarks[slot] = last.previous
        }
        canUndo = !history.isEmpty
        refreshMarker(last.mark)
    }

    private func record(_ mark: Mark, previous: SIMD3<Float>?, previousMount: DeviceMount?) {
        history.append((mark, previous, previousMount))
        canUndo = true
    }

    // MARK: - House alignment

    /// Marks house-alignment corner `slot` (0 = A, 1 = B) at the surface under
    /// the reticle (aim where the two walls meet the floor). False on a miss.
    @discardableResult
    func markCorner(slot: Int) -> Bool {
        guard canPlace, let hit = surfaceHit() else { return false }
        record(.corner(slot), previous: cornerMarks[slot], previousMount: nil)
        cornerMarks[slot] = hit.position
        refreshMarker(.corner(slot))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    /// Forgets a corner mark (its polygon corner was changed).
    func clearCorner(slot: Int) {
        guard cornerMarks[slot] != nil else { return }
        record(.corner(slot), previous: cornerMarks[slot], previousMount: nil)
        cornerMarks[slot] = nil
        refreshMarker(.corner(slot))
    }

    /// Alignment from the two marks ↔ the two chosen polygon corners, or nil
    /// until both are marked (or if they're too close together).
    func houseAlignment(spaceID: String, corners: (PlanPoint, PlanPoint), floorLevel: Double) -> HouseAlignment? {
        guard let a = cornerMarks[0], let b = cornerMarks[1] else { return nil }
        return HouseAlignment.solve(spaceID: spaceID, roomCorners: (Self.roomPoint(a), Self.roomPoint(b)),
                                    houseCorners: corners, floorLevel: floorLevel)
    }

    // MARK: - Mount

    /// Mount from the hit surface's normal; "floor vs table" by height above
    /// the floor (marked corners, else the lowest ARKit floor plane).
    private func mount(for hit: SurfaceHit) -> DeviceMount? {
        guard let n = hit.normal else { return nil }
        let normal = ARFrameConversion.roomPoint(fromARKit: Vector3(Double(n.x), Double(n.y), Double(n.z)))
        let height = floorY().map { Double(hit.position.y - $0) }
        return DeviceMount.classify(normal: normal, heightAboveFloor: height)
    }

    /// Floor height (ARKit y), if known.
    private func floorY() -> Float? {
        let marks = cornerMarks.values
        if !marks.isEmpty { return marks.map(\.y).reduce(0, +) / Float(marks.count) }
        let floors = (arView.session.currentFrame?.anchors ?? [])
            .compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.alignment == .horizontal && $0.classification == .floor }
            .map { $0.transform.columns.3.y }
        return floors.min()
    }

    /// Surface point under the screen centre: LiDAR mesh first, then detected
    /// plane geometry, then estimated planes.
    private func surfaceHit() -> SurfaceHit? {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard arView.bounds.width > 0 else { return nil }
        if supportsMesh, let ray = arView.ray(through: center),
           let hit = arView.scene.raycast(origin: ray.origin, direction: ray.direction, length: 15,
                                          query: .nearest, mask: .all, relativeTo: nil).first {
            return SurfaceHit(position: hit.position, normal: simd_normalize(hit.normal))
        }
        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            if let r = arView.raycast(from: center, allowing: target, alignment: .any).first {
                let c = r.worldTransform.columns.3, y = r.worldTransform.columns.1
                // A plane hit's local +y is its normal.
                return SurfaceHit(position: SIMD3(c.x, c.y, c.z), normal: simd_normalize(SIMD3(y.x, y.y, y.z)))
            }
        }
        return nil
    }

    // MARK: - Saving

    /// This session's result, converted to the room frame.
    func makePlacement(houseAlignment: HouseAlignment? = nil) -> RoomPlacement {
        RoomPlacement(roomID: roomID,
                      seat: seat.map(Self.roomPoint),
                      devicePositions: placed.mapValues(Self.roomPoint),
                      sameFrame: sameFrame,
                      houseAlignment: houseAlignment,
                      deviceMounts: mounts.filter { placed[$0.key] != nil })
    }

    /// Saves the world map so the next session can relocalize into this frame.
    /// Returns a user-facing warning on failure.
    func saveWorldMap() async -> String? {
        do {
            let map: ARWorldMap = try await withCheckedThrowingContinuation { cont in
                arView.session.getCurrentWorldMap { map, error in
                    if let map {
                        cont.resume(returning: map)
                    } else {
                        cont.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                    }
                }
            }
            try WorldMapStore.save(map, roomID: roomID)
            return nil
        } catch {
            // A fresh frame makes the old map useless (it would relocalize into the wrong frame).
            if !sameFrame { WorldMapStore.delete(roomID: roomID) }
            return "The room map couldn't be saved (\(error.localizedDescription)). "
                + "Next time, placing starts a new map and earlier placements need re-placing."
        }
    }

    static func roomPoint(_ p: SIMD3<Float>) -> Vector3 {
        ARFrameConversion.roomPoint(fromARKit: Vector3(Double(p.x), Double(p.y), Double(p.z)))
    }

    static func arkitPoint(_ v: Vector3) -> SIMD3<Float> {
        let p = ARFrameConversion.arkitPoint(fromRoom: v)
        return SIMD3(Float(p.x), Float(p.y), Float(p.z))
    }

    // MARK: - Markers

    /// Shows stored placements once the session is in their frame.
    private func showExisting() {
        refreshMarker(.seat)
        for id in existingCoords.keys { refreshMarker(.device(id)) }
    }

    /// Re-creates the marker for `mark` from this session's value, else the
    /// stored one (only when relocalized), else removes it.
    private func refreshMarker(_ mark: Mark) {
        if let old = markers.removeValue(forKey: mark) { arView.scene.removeAnchor(old.anchor) }
        let current: SIMD3<Float>?
        let earlier: Vector3?
        let title: String
        switch mark {
        case .seat:
            current = seat; earlier = existingSeat; title = "Seat"
        case .device(let id):
            current = placed[id]; earlier = existingCoords[id]; title = names[id] ?? "Device"
        case .corner(let slot):
            current = cornerMarks[slot]; earlier = nil; title = slot == 0 ? "Corner A" : "Corner B"
        }
        let position: SIMD3<Float>
        let color: UIColor
        if let current {
            position = current
            switch mark {
            case .seat: color = .systemBlue
            case .corner: color = .systemOrange
            case .device: color = .systemGreen
            }
        } else if sameFrame, let earlier {
            position = Self.arkitPoint(earlier)
            color = .systemGray
        } else {
            return
        }
        markers[mark] = makeMarker(title: title, color: color, at: position, radius: mark == .seat ? 0.05 : 0.035)
    }

    private func makeMarker(title: String, color: UIColor, at position: SIMD3<Float>,
                            radius: Float) -> (anchor: AnchorEntity, label: Entity) {
        let anchor = AnchorEntity(world: position)
        let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [UnlitMaterial(color: color)])
        anchor.addChild(sphere)

        let label = Entity()
        label.position = [0, radius + 0.02, 0]
        let mesh = MeshResource.generateText(title, extrusionDepth: 0.001,
                                             font: .systemFont(ofSize: 0.05, weight: .semibold),
                                             containerFrame: .zero, alignment: .center,
                                             lineBreakMode: .byTruncatingTail)
        let text = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        text.position = [-mesh.bounds.center.x, 0, 0]
        label.addChild(text)
        anchor.addChild(label)
        arView.scene.addAnchor(anchor)
        face(label, toward: arView.cameraTransform.translation)
        return (anchor, label)
    }

    /// Yaw-only billboard: turns the label's +z (text front) toward the camera.
    private func face(_ label: Entity, toward camera: SIMD3<Float>) {
        let p = label.position(relativeTo: nil)
        let d = camera - p
        guard d.x * d.x + d.z * d.z > 1e-6 else { return }
        label.setOrientation(simd_quatf(angle: atan2(d.x, d.z), axis: [0, 1, 0]), relativeTo: nil)
    }

    // MARK: - Per-frame (throttled to ~10 Hz)

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUpdate >= 0.1 else { return }
        lastUpdate = now
        let cam = arView.cameraTransform.translation
        for m in markers.values { face(m.label, toward: cam) }

        let distance = canPlace ? surfaceHit().map { simd_distance($0.position, cam) } : nil
        switch (distance, hitDistance) {
        case (nil, nil): break
        case let (d?, old?) where abs(d - old) < 0.05: break
        default: hitDistance = distance
        }
    }

    // MARK: - Tracking state

    fileprivate func handleTracking(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal:
            trackingMessage = nil
            if frameState == .relocalizing {
                frameState = .relocalized
                showExisting()
            }
        case .notAvailable:
            trackingMessage = "Tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing: trackingMessage = "Move the phone slowly to start…"
            case .relocalizing: trackingMessage = nil // the view shows its own relocalization banner
            case .excessiveMotion: trackingMessage = "Slow down"
            case .insufficientFeatures: trackingMessage = "Aim at a more detailed, well-lit area"
            @unknown default: trackingMessage = "Tracking limited"
            }
        }
    }

    fileprivate func handleFailure(_ error: Error) {
        if let ar = error as? ARError, ar.code == .cameraUnauthorized {
            errorMessage = "Camera access is off. Allow it in Settings › WatchMagic › Camera."
        } else {
            errorMessage = "AR session failed: \(error.localizedDescription)"
        }
    }
}

extension PlacementSession: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = camera.trackingState
        MainActor.assumeIsolated { handleTracking(state) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        MainActor.assumeIsolated { handleFailure(error) }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
}
