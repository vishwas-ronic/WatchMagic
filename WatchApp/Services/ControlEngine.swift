import Foundation
import WatchKit
import WatchMagicKit

/// What the aiming pipeline looks like right now (published ~12 Hz + on events).
struct AimSnapshot: Equatable, Sendable {
    /// Aim screen visible (gestures may act).
    var enabled = false
    var headingReady = false
    var source: HeadingSource = .zeroGesture
    /// Lock candidates (one = clear lock; several = ambiguous, crown selects).
    var lockCandidates: [UUID] = []
    var selectedIndex = 0
    var windowOpen = false
    var resolution: Resolution = .none
    var nearestID: UUID?
    var nearestAngleDeg: Double?
    var pitchDeg = 0.0
    var angularSpeed = 0.0
    var zeroNeeded = false
    var zeroProgress = 0.0
    var lastGesture: DetectedGesture?
    /// Whether the last gesture was acted on (locked + window open).
    var lastGestureActed = false

    var isLocked: Bool { !lockCandidates.isEmpty }
    var isAmbiguous: Bool { lockCandidates.count > 1 }
    var selectedID: UUID? {
        lockCandidates.indices.contains(selectedIndex) ? lockCandidates[selectedIndex] : nil
    }
}

/// Events from the motion-queue pipeline to the main-actor engine.
enum PipelineEvent: Sendable {
    case snapshot(AimSnapshot)
    case locked(UUID)
    case selectionChanged(UUID)
    case gesture(DetectedGesture, target: UUID)
    case zeroed(correctionDeg: Double)
    case teach(TeachCapture.Event)
    case recordingProgress(remaining: TimeInterval)
    case recordingFinished(url: URL?, samples: Int, error: String?)
}

/// Per-sample pipeline, confined to the motion queue:
/// MotionFrame → TargetResolver → AimLockDetector → GestureDetector
/// (+ zero gesture, teach capture, trace recording). Only gestures that
/// `AimLockDetector.target(forGestureAt:)` accepts are emitted for action.
final class ControlPipeline: @unchecked Sendable {
    let queue: DispatchQueue

    // Queue-confined state.
    private var candidates: [TargetCandidate] = []
    private var anchor: TargetCandidate?
    private var settings = Settings()
    private var aimEnabled = false
    private let aimLock = AimLockDetector()
    private let gestures = GestureDetector(pointingSign: 1)
    private var zero = ZeroHoldDetector()
    private var teach: TeachCapture?
    private var recorder: TraceRecorder?
    private var snap = AimSnapshot()
    private var lastPublishT: TimeInterval = 0
    private var lastTickT: TimeInterval = 0
    private var lastTeachProgressT: TimeInterval = 0
    private let emitter = Locked<(@Sendable (PipelineEvent) -> Void)?>(nil)

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func setEmitter(_ e: @escaping @Sendable (PipelineEvent) -> Void) {
        emitter.withLock { $0 = e }
    }

    private func emit(_ e: PipelineEvent) {
        emitter.snapshot?(e)
    }

    // MARK: Commands (any thread → queue)

    func configure(candidates: [TargetCandidate], anchor: TargetCandidate?, settings: Settings, resetLock: Bool) {
        queue.async { [self] in
            self.candidates = candidates
            self.anchor = anchor
            self.settings = settings
            aimLock.configuration = AimLockDetector.Configuration(settings: settings)
            gestures.setSensitivity(settings.sensitivity)
            if resetLock {
                aimLock.reset()
                zero.reset()
                fillLock()
                emit(.snapshot(snap))
            }
        }
    }

    func setAimEnabled(_ on: Bool) {
        queue.async { [self] in
            aimEnabled = on
            if !on { zero.reset() }
        }
    }

    func select(next: Bool) {
        queue.async { [self] in
            let id = next ? aimLock.selectNext() : aimLock.selectPrevious()
            fillLock()
            emit(.snapshot(snap))
            if let id { emit(.selectionChanged(id)) }
        }
    }

    func startTeach() { queue.async { [self] in teach = TeachCapture() } }
    func cancelTeach() { queue.async { [self] in teach = nil } }

    func startRecording(duration: TimeInterval) {
        queue.async { [self] in recorder = TraceRecorder(duration: duration) }
    }

    // MARK: Per sample (motion queue)

    func process(_ f: MotionFrame) {
        let t = f.sample.t
        let k = f.kinematics
        gestures.pointingSign = f.pointingSign
        var urgent = false

        // Trace recording.
        if var r = recorder {
            if r.append(f.sample) {
                recorder = nil
                finishRecording(r.samples)
            } else {
                recorder = r
                if t - lastTickT >= 0.25 {
                    lastTickT = t
                    emit(.recordingProgress(remaining: r.remaining(at: t)))
                }
            }
        }

        // Teach capture.
        if var tc = teach {
            let ev = tc.process(t: t, pointing: f.pointing, angularSpeed: k.angularSpeed)
            switch ev {
            case .progress:
                teach = tc
                if t - lastTeachProgressT >= 0.1 {
                    lastTeachProgressT = t
                    emit(.teach(ev))
                }
            case .sampleCaptured:
                teach = tc
                emit(.teach(ev))
            case .finished, .inconsistent:
                teach = nil
                emit(.teach(ev))
            }
        }

        // Aim.
        let canAim = aimEnabled && f.headingReady && teach == nil
        var resolution: Resolution = .none
        var nearest: (id: UUID, angle: Double)?
        if f.headingReady {
            for c in candidates {
                let a = f.pointing.angle(to: c.direction)
                if nearest == nil || a < nearest!.angle { nearest = (c.id, a) }
            }
            if canAim {
                resolution = TargetResolver.resolve(pointing: f.pointing, candidates: candidates, settings: settings)
            }
        }
        switch aimLock.update(time: t, pitchDeg: k.pitchDeg, angularSpeed: k.angularSpeed, resolution: resolution) {
        case .locked(let id):
            emit(.locked(id))
            urgent = true
        case .unlocked:
            urgent = true
        default:
            break
        }

        // Gestures: act only when locked and the gesture window is open.
        if let g = gestures.process(f.sample) {
            snap.lastGesture = g
            if canAim, let target = aimLock.target(forGestureAt: g.t) {
                aimLock.noteGesture(at: g.t)
                snap.lastGestureActed = true
                emit(.gesture(g, target: target))
            } else {
                snap.lastGestureActed = false
            }
            urgent = true
        }

        // Zero gesture (yaw still arbitrary, anchor known, Aim screen open).
        var zeroNeeded = false
        var zeroProgress = 0.0
        if aimEnabled, !f.headingReady, f.source != .magneticNorthFrame, let a = anchor {
            zeroNeeded = true
            let r = zero.process(t: t, rawPointing: f.rawPointing, pitchDeg: k.pitchDeg,
                                 angularSpeed: k.angularSpeed, anchor: a.direction)
            zeroProgress = r.progress
            if let c = r.correctionDeg {
                emit(.zeroed(correctionDeg: c))
                urgent = true
            }
        }

        guard urgent || t - lastPublishT >= 1.0 / 12 else { return }
        lastPublishT = t
        snap.enabled = aimEnabled
        snap.headingReady = f.headingReady
        snap.source = f.source
        snap.resolution = resolution
        snap.nearestID = nearest?.id
        snap.nearestAngleDeg = nearest?.angle
        snap.pitchDeg = k.pitchDeg
        snap.angularSpeed = k.angularSpeed
        snap.zeroNeeded = zeroNeeded
        snap.zeroProgress = zeroProgress
        snap.windowOpen = aimLock.isGestureWindowOpen(at: t)
        fillLock()
        emit(.snapshot(snap))
    }

    private func fillLock() {
        snap.lockCandidates = aimLock.lock?.candidates ?? []
        snap.selectedIndex = aimLock.lock?.selectedIndex ?? 0
        if aimLock.lock == nil { snap.windowOpen = false }
    }

    private func finishRecording(_ samples: [MotionSample]) {
        let emitter = self.emitter
        DispatchQueue.global(qos: .utility).async {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            f.locale = Locale(identifier: "en_US_POSIX")
            let name = "trace-\(f.string(from: Date())).csv"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do {
                try MotionCSV.encode(samples).write(to: url, atomically: true, encoding: .utf8)
                emitter.snapshot?(.recordingFinished(url: url, samples: samples.count, error: nil))
            } catch {
                emitter.snapshot?(.recordingFinished(url: nil, samples: samples.count, error: error.localizedDescription))
            }
        }
    }
}

/// Wires motion → aiming → gestures → Home Assistant, and owns teach/record
/// flows. UI state is published on the main actor; the per-sample work runs
/// on the motion queue in `ControlPipeline`.
@MainActor
final class ControlEngine: ObservableObject {

    struct TeachStatus: Equatable {
        enum Phase: Equatable { case idle, capturing, saved, inconsistent, blocked }
        var deviceID: UUID?
        var phase: Phase = .idle
        var samples = 0
        var hold = 0.0
        var needsReaim = true
        var message: String?
    }

    enum RecordingStatus: Equatable {
        case idle
        case recording(remaining: TimeInterval)
        case finished(String)
        case failed(String)

        var isRecording: Bool { if case .recording = self { return true } else { return false } }
    }

    @Published private(set) var aim = AimSnapshot()
    @Published private(set) var config: AppConfig?
    @Published private(set) var room: Room?
    @Published private(set) var roomDevices: [ControlledDevice] = []
    @Published private(set) var anchorDevice: ControlledDevice?
    /// The room has devices placed by coordinates (and a seat) but no derived
    /// compass offset yet: teaching any one placed device aligns the room.
    @Published private(set) var needsAlignment = false
    @Published private(set) var hasClient = false
    @Published private(set) var states: [String: EntityState] = [:]
    @Published private(set) var actionLine: String?
    @Published private(set) var errorLine: String?
    @Published private(set) var busy = false
    /// Gesture (end of flick) → service call returned, last ≤ 10, milliseconds.
    @Published private(set) var latenciesMs: [Double] = []
    @Published private(set) var teach = TeachStatus()
    @Published private(set) var recording = RecordingStatus.idle

    let motion: MotionService
    let sync: WatchSyncService
    private let pipeline: ControlPipeline
    private var client: HAClient?
    private let urlSession: URLSession
    private var queued: (gesture: DetectedGesture, target: UUID)?
    private var fetching: Set<String> = []
    /// Uptime of the last state write per entity, so an older in-flight fetch
    /// can't overwrite a newer state (e.g. from a service-call response).
    private var stateStamp: [String: TimeInterval] = [:]

    init(motion: MotionService, sync: WatchSyncService) {
        self.motion = motion
        self.sync = sync
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 3
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        urlSession = URLSession(configuration: cfg)
        pipeline = ControlPipeline(queue: motion.queue)

        pipeline.setEmitter { [weak self] event in
            onMain { self?.handle(event) }
        }
        let p = pipeline
        motion.setSampleHandler { frame in p.process(frame) }
        sync.onConfigChange = { [weak self] config, token in self?.apply(config: config, token: token) }
        apply(config: sync.config, token: sync.token)
    }

    // MARK: - Derived

    var latencyMedianMs: Double? {
        guard !latenciesMs.isEmpty else { return nil }
        let s = latenciesMs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    func device(_ id: UUID?) -> ControlledDevice? {
        guard let id else { return nil }
        return config?.device(id: id)
    }

    func state(of device: ControlledDevice?) -> EntityState? {
        device.flatMap { states[$0.entityID] }
    }

    // MARK: - Commands (UI)

    func setAimScreenVisible(_ visible: Bool) {
        pipeline.setAimEnabled(visible)
    }

    func crown(next: Bool) {
        guard aim.isAmbiguous else { return }
        pipeline.select(next: next)
    }

    func startTeach(deviceID: UUID) {
        guard config?.device(id: deviceID) != nil, room != nil else { return }
        let ms = motion.status
        if !ms.headingReady {
            // Only the very first teach in a zero-gesture room may define the frame.
            let firstInArbitraryFrame = ms.source == .zeroGesture && anchorDevice == nil
            if !firstInArbitraryFrame {
                let msg = anchorDevice.map { "Set heading first: on Aim, point at \($0.name) and hold" }
                    ?? "Waiting for compass — hold the watch level and still"
                teach = TeachStatus(deviceID: deviceID, phase: .blocked, message: msg)
                return
            }
        }
        teach = TeachStatus(deviceID: deviceID, phase: .capturing)
        pipeline.startTeach()
    }

    func cancelTeach() {
        pipeline.cancelTeach()
        teach = TeachStatus()
    }

    func clearTaught(deviceID: UUID) {
        guard let room else { return }
        sync.setTaughtVector(nil, deviceID: deviceID, roomID: room.id)
    }

    func startRecording(duration: TimeInterval = 10) {
        guard !recording.isRecording else { return }
        recording = .recording(remaining: duration)
        pipeline.startRecording(duration: duration)
    }

    // MARK: - Config

    private func apply(config: AppConfig?, token: String?) {
        let newRoom = config?.currentRoom
        let roomChanged = newRoom?.id != room?.id
        self.config = config
        room = newRoom
        roomDevices = (config != nil && newRoom != nil) ? config!.devices(in: newRoom!) : []

        if let config, let token, !token.isEmpty {
            client = HAClient(baseURL: config.haURL, token: token, session: urlSession, timeout: 3)
        } else {
            client = nil
        }
        hasClient = client != nil

        // Recomputed on every config change, including a local teach (WatchSyncService
        // calls back here), so a newly taught placed device makes the others aimable at once.
        var candidates: [TargetCandidate] = []
        var anchor: TargetCandidate?
        var unaligned = false
        if let config, let newRoom {
            let refs = ReferenceDirections(room: newRoom, devices: config.devices)
            candidates = refs.candidates
            anchor = ReferenceDirections.anchor(room: newRoom, devices: config.devices)
            unaligned = newRoom.seat != nil && refs.compassOffsetDeg == nil
                && roomDevices.contains { $0.coordinates != nil }
        }
        needsAlignment = unaligned
        anchorDevice = anchor.flatMap { config?.device(id: $0.id) }
        pipeline.configure(candidates: candidates, anchor: anchor,
                           settings: config?.settings ?? Settings(), resetLock: roomChanged)
        if roomChanged { refreshRoomStates() }
    }

    // MARK: - Pipeline events

    private func handle(_ e: PipelineEvent) {
        switch e {
        case .snapshot(let s):
            aim = s
        case .locked(let id):
            WKInterfaceDevice.current().play(.click)
            if let d = device(id) { refreshState(d.entityID) }
        case .selectionChanged(let id):
            WKInterfaceDevice.current().play(.click)
            if let d = device(id) { refreshState(d.entityID) }
        case .gesture(let g, let target):
            handleGesture(g, target: target)
        case .zeroed(let correction):
            motion.applyZero(offsetDeg: correction)
            WKInterfaceDevice.current().play(.success)
            actionLine = "Heading set from \(anchorDevice?.name ?? "anchor")"
        case .teach(let ev):
            handleTeach(ev)
        case .recordingProgress(let remaining):
            if recording.isRecording { recording = .recording(remaining: remaining) }
        case .recordingFinished(let url, let n, let error):
            if let url {
                recording = sync.sendTrace(at: url)
                    ? .finished("\(n) samples → iPhone")
                    : .failed("Saved \(url.lastPathComponent), iPhone not connected")
            } else {
                recording = .failed(error ?? "Could not write trace")
            }
        }
    }

    private func handleTeach(_ ev: TeachCapture.Event) {
        guard teach.phase == .capturing, let deviceID = teach.deviceID else { return }
        switch ev {
        case .progress(let n, let hold, let reaim):
            teach.samples = n
            teach.hold = hold
            teach.needsReaim = reaim
        case .sampleCaptured(let n):
            teach.samples = n
            teach.hold = 0
            teach.needsReaim = true
            WKInterfaceDevice.current().play(.click)
        case .finished(let vector, let spread):
            guard let room else { return }
            sync.setTaughtVector(vector, deviceID: deviceID, roomID: room.id)
            if !motion.status.headingReady { motion.markHeadingReady() }
            teach.phase = .saved
            teach.samples = TeachCapture.samplesNeeded
            teach.message = String(format: "Saved ✓ (spread %.1f°)", spread)
            WKInterfaceDevice.current().play(.success)
        case .inconsistent(let spread):
            teach.phase = .inconsistent
            teach.message = String(format: "Not consistent (%.1f°) — retry", spread)
            WKInterfaceDevice.current().play(.failure)
        }
    }

    // MARK: - Actions

    private func handleGesture(_ g: DetectedGesture, target: UUID) {
        if busy {
            queued = (g, target) // latest wins; run when the current call returns
            return
        }
        run(g, target: target)
    }

    private func run(_ g: DetectedGesture, target: UUID) {
        guard let config, let device = config.device(id: target) else { return }
        guard let call = ActionMapper.map(gesture: g.gesture, device: device,
                                          state: states[device.entityID], settings: config.settings) else {
            actionLine = "\(g.gesture.displayName): nothing to do"
            return
        }
        guard let client else {
            fail("No HA token — set up on iPhone")
            return
        }
        busy = true
        errorLine = nil
        actionLine = "\(g.gesture.displayName) → \(call.serviceName)"
        Task { await execute(call, client: client, device: device, gesture: g) }
    }

    private enum Outcome {
        case success([EntityState], viaPhone: Bool)
        case failure(String)
    }

    private func execute(_ call: ServiceCall, client: HAClient, device: ControlledDevice, gesture: DetectedGesture) async {
        var outcome: Outcome
        do {
            outcome = .success(try await client.callService(call), viaPhone: false)
        } catch {
            let e = HAError.from(error)
            if e.isNetworkError {
                actionLine = "Retrying via iPhone…"
                do {
                    let r = try await sync.relay(call)
                    if let msg = r.errorMessage {
                        outcome = .failure(msg)
                    } else {
                        outcome = .success(r.states ?? [], viaPhone: true)
                    }
                } catch {
                    outcome = .failure(e.errorDescription ?? "HA unreachable")
                }
            } else {
                outcome = .failure(e.errorDescription ?? "HA error")
            }
        }
        let latency = ProcessInfo.processInfo.systemUptime - gesture.t

        switch outcome {
        case .success(let returned, let viaPhone):
            if latency >= 0 && latency < 60 {
                latenciesMs.append(latency * 1000)
                if latenciesMs.count > 10 { latenciesMs.removeFirst(latenciesMs.count - 10) }
            }
            WKInterfaceDevice.current().play(.success)
            errorLine = nil
            actionLine = String(format: "%@ ✓ %.0f ms%@", gesture.gesture.displayName, latency * 1000,
                                viaPhone ? " (via iPhone)" : "")
            if let s = returned.first(where: { $0.entityID == device.entityID }) {
                setState(s)
            } else {
                await fetchState(device.entityID, force: true)
            }
        case .failure(let message):
            fail(message)
        }

        busy = false
        if let q = queued {
            queued = nil
            if ProcessInfo.processInfo.systemUptime - q.gesture.t < 3 { run(q.gesture, target: q.target) }
        }
    }

    private func fail(_ message: String) {
        WKInterfaceDevice.current().play(.failure)
        errorLine = message
    }

    // MARK: - Entity states

    /// Lock / selection change: fetch the state, via the iPhone if HA is unreachable directly.
    private func refreshState(_ entityID: String) {
        Task { await fetchState(entityID, relayFallback: true) }
    }

    /// GET /api/states/<id>. `force` skips the de-duplication of concurrent fetches.
    /// `relayFallback`: on a network error, and if the phone is reachable,
    /// fetch the state through the phone instead (spec 1.2.5).
    private func fetchState(_ entityID: String, force: Bool = false, relayFallback: Bool = false) async {
        guard let client, force || !fetching.contains(entityID) else { return }
        let started = ProcessInfo.processInfo.systemUptime
        fetching.insert(entityID)
        defer { fetching.remove(entityID) }
        do {
            setState(try await client.entityState(entityID), requestedAt: started)
        } catch {
            guard relayFallback, HAError.from(error).isNetworkError, sync.isReachable,
                  let r = try? await sync.relayState(entityID),
                  let s = r.states?.first(where: { $0.entityID == entityID }) else { return }
            setState(s, requestedAt: started)
        }
    }

    private func setState(_ s: EntityState, requestedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let last = stateStamp[s.entityID], requestedAt < last { return }
        stateStamp[s.entityID] = requestedAt
        states[s.entityID] = s
    }

    private func refreshRoomStates() {
        let ids = roomDevices.map(\.entityID)
        Task {
            for id in ids { await fetchState(id) }
        }
    }
}
