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
    case recordingFinished(url: URL?, samples: Int, error: String?, kind: TraceKind)
    case training(TrainingEvent)
}

/// Progress of a phone-guided training recording (motion queue → main).
enum TrainingEvent: Sendable {
    case recording(TrainingStart)
    case cue(TrainingStart, index: Int, total: Int, t: TimeInterval)
    /// `url` nil = not written (`error`). `complete` false = cut short (motion stopped).
    case finished(TrainingStart, url: URL?, samples: Int, complete: Bool, error: String?)
    case cancelled(TrainingStart)
}

/// Wearing info written into training CSV headers.
struct WearingInfo: Sendable {
    var wristIsLeft: Bool
    var crownIsRight: Bool
    var requestedRateHz: Double
}

/// Which motion dump a written CSV is.
enum TraceKind: String, Sendable {
    /// Sensor Probe → Record 10 s, completed.
    case record
    /// A recording cut short because samples stopped arriving (app suspended).
    case stalled
    /// Sensor Probe → Send last 60 s (rolling buffer).
    case ring
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
    /// Always-on rolling buffer of the last 60 s (Sensor Probe → Send last 60 s).
    private var ring = MotionRingBuffer(duration: 60, maxRateHz: 110)
    /// Strong-rotation bursts → diag log (sub-threshold flicks included).
    private var bursts = RotationBurstTracker(threshold: 1.5)
    private var names: [UUID: String] = [:]
    private var lockedID: UUID?
    private var lockedAtT: TimeInterval = 0
    /// Phone-guided gesture-training recording in progress.
    private var trainer: (start: TrainingStart, recorder: TrainingRecorder, wearing: WearingInfo)?
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

    func configure(candidates: [TargetCandidate], anchor: TargetCandidate?, settings: Settings, resetLock: Bool,
                   names: [UUID: String]) {
        queue.async { [self] in
            self.names = names
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

    /// Ends a recording that stopped receiving samples (watchdog on main):
    /// writes what was captured, if anything.
    func abortRecording(reason: String) {
        queue.async { [self] in
            guard let r = recorder else { return }
            recorder = nil
            Diag.event("recording_abort", ["reason": reason, "samples": r.samples.count])
            if r.samples.isEmpty {
                emit(.recordingFinished(url: nil, samples: 0, error: "Recording stopped: \(reason)", kind: .stalled))
            } else {
                finishRecording(r.samples, kind: .stalled)
            }
        }
    }

    /// Starts a training recording (from the next sample). Replaces any running one.
    func startTraining(_ start: TrainingStart, wearing: WearingInfo) {
        queue.async { [self] in
            if let old = trainer { emit(.training(.cancelled(old.start))) }
            trainer = (start, TrainingRecorder(label: start.label, plan: start.plan), wearing)
            aimLock.reset()
        }
    }

    func cancelTraining(sessionID: UUID?) {
        queue.async { [self] in
            guard let tr = trainer, sessionID == nil || tr.start.sessionID == sessionID else { return }
            trainer = nil
            Diag.event("training_cancel", ["label": tr.start.label.rawValue, "samples": tr.recorder.samples.count])
            emit(.training(.cancelled(tr.start)))
        }
    }

    private func processTraining(_ f: MotionFrame) {
        guard var tr = trainer else { return }
        let t = f.sample.t
        if tr.recorder.isStalled(at: t) {
            trainer = nil
            Diag.event("training_stalled", ["label": tr.start.label.rawValue, "samples": tr.recorder.samples.count,
                                            "gapS": t - (tr.recorder.lastSampleTime ?? t)])
            finishTraining(tr, sign: f.pointingSign)
            return
        }
        let first = tr.recorder.samples.isEmpty
        let events = tr.recorder.append(f.sample)
        trainer = tr
        if first { emit(.training(.recording(tr.start))) }
        for e in events {
            switch e {
            case .cue(let i, let n):
                emit(.training(.cue(tr.start, index: i, total: n, t: t)))
            case .finished:
                trainer = nil
                finishTraining(tr, sign: f.pointingSign)
            }
        }
    }

    private func finishTraining(_ tr: (start: TrainingStart, recorder: TrainingRecorder, wearing: WearingInfo), sign: Double) {
        let emitter = self.emitter
        DispatchQueue.global(qos: .utility).async {
            let rec = tr.recorder
            let name = TrainingRecorder.fileName(label: tr.start.label, date: Date())
            let url = Diag.outbox.appendingPathComponent(name)
            let csv = rec.csv(wristIsLeft: tr.wearing.wristIsLeft, crownIsRight: tr.wearing.crownIsRight,
                              pointingSign: sign, requestedRateHz: tr.wearing.requestedRateHz)
            do {
                try FileManager.default.createDirectory(at: Diag.outbox, withIntermediateDirectories: true)
                try csv.write(to: url, atomically: true, encoding: .utf8)
                Diag.event("training_written", ["file": name, "samples": rec.samples.count, "cues": rec.cueTimes.count,
                                                "complete": rec.isFinished, "rateHz": rec.measuredRateHz])
                emitter.snapshot?(.training(.finished(tr.start, url: url, samples: rec.samples.count,
                                                      complete: rec.isFinished, error: nil)))
            } catch {
                emitter.snapshot?(.training(.finished(tr.start, url: nil, samples: rec.samples.count,
                                                      complete: rec.isFinished, error: error.localizedDescription)))
            }
        }
    }

    /// Writes the last 60 s of samples as a trace (Sensor Probe → Send last 60 s).
    func dumpRing() {
        queue.async { [self] in
            let samples = ring.samples()
            Diag.event("ring_dump", ["samples": samples.count,
                                     "spanS": samples.last.map { $0.t - samples[0].t }])
            guard !samples.isEmpty else {
                emit(.recordingFinished(url: nil, samples: 0, error: "No motion samples yet", kind: .ring))
                return
            }
            finishRecording(samples, kind: .ring)
        }
    }

    // MARK: Per sample (motion queue)

    func process(_ f: MotionFrame) {
        let t = f.sample.t
        let k = f.kinematics
        gestures.pointingSign = f.pointingSign
        var urgent = false

        ring.append(f.sample)
        processTraining(f)

        // Trace recording. A gap > 1 s (app suspended) ends it with what it has.
        if let r = recorder, r.isStalled(at: t) {
            recorder = nil
            Diag.event("recording_stalled", ["gapS": t - (r.lastSampleTime ?? t), "samples": r.samples.count])
            finishRecording(r.samples, kind: .stalled)
        }
        if var r = recorder {
            if r.append(f.sample) {
                recorder = nil
                finishRecording(r.samples, kind: .record)
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
        let canAim = aimEnabled && f.headingReady && teach == nil && trainer == nil
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
            lockedID = id
            lockedAtT = t
            Diag.event("lock", ["device": names[id], "candidates": aimLock.lock?.candidates.count,
                                "angleDeg": angle(to: id, f.pointing), "pitchDeg": k.pitchDeg,
                                "speed": k.angularSpeed])
            emit(.locked(id))
            urgent = true
        case .unlocked:
            Diag.event("unlock", ["device": lockedID.flatMap { names[$0] }, "heldS": t - lockedAtT,
                                  "angleDeg": lockedID.flatMap { angle(to: $0, f.pointing) },
                                  "onTarget": lockedID.map { resolution.ids.contains($0) },
                                  "pitchDeg": k.pitchDeg, "speed": k.angularSpeed])
            lockedID = nil
            urgent = true
        default:
            break
        }

        // Gestures: act only when locked and the gesture window is open.
        if let g = gestures.process(f.sample) {
            bursts.noteGesture()
            snap.lastGesture = g
            let reason: String?
            if !aimEnabled { reason = "aim disabled" }
            else if teach != nil { reason = "teaching" }
            else if trainer != nil { reason = "training" }
            else if !f.headingReady { reason = "heading not ready" }
            else if aimLock.lock == nil { reason = "not locked" }
            else if !aimLock.isGestureWindowOpen(at: g.t) { reason = "window closed" }
            else { reason = nil }
            let lock = aimLock.lock
            var fields: [String: Any?] = [
                "type": g.gesture.rawValue, "peakRate": g.peakRate, "acted": reason == nil, "reason": reason,
                "pitchDeg": k.pitchDeg, "speed": k.angularSpeed,
            ]
            if let lock {
                fields["device"] = names[lock.selectedID]
                fields["lockAgeS"] = g.t - lock.lockedAt
                fields["windowAgeS"] = g.t - lock.windowStart
            }
            if reason == nil, let target = aimLock.target(forGestureAt: g.t) {
                aimLock.noteGesture(at: g.t)
                snap.lastGestureActed = true
                Diag.event("gesture", fields)
                emit(.gesture(g, target: target))
            } else {
                snap.lastGestureActed = false
                Diag.event("gesture", fields)
            }
            urgent = true
        }

        // Strong-rotation bursts (one line per burst, rate-limited).
        if let b = bursts.process(t: t, pitchRate: k.pitchRate, rollRate: k.rollRate, speed: k.angularSpeed) {
            Diag.event("burst", ["durS": b.duration, "maxPitchRate": b.maxPitchRate, "maxRollRate": b.maxRollRate,
                                 "maxSpeed": b.maxSpeed, "samples": b.samples, "gesture": b.gestureFired,
                                 "suppressedBefore": b.suppressedBefore, "locked": aimLock.lock != nil,
                                 "aimEnabled": aimEnabled])
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

    private func angle(to id: UUID, _ pointing: Vector3) -> Double? {
        candidates.first { $0.id == id }.map { pointing.angle(to: $0.direction) }
    }

    private func fillLock() {
        snap.lockCandidates = aimLock.lock?.candidates ?? []
        snap.selectedIndex = aimLock.lock?.selectedIndex ?? 0
        if aimLock.lock == nil { snap.windowOpen = false }
    }

    private func finishRecording(_ samples: [MotionSample], kind: TraceKind) {
        let emitter = self.emitter
        DispatchQueue.global(qos: .utility).async {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            f.locale = Locale(identifier: "en_US_POSIX")
            let prefix: String
            switch kind {
            case .record: prefix = "trace"
            case .stalled: prefix = "trace-partial"
            case .ring: prefix = "last60s"
            }
            let name = "\(prefix)-\(f.string(from: Date())).csv"
            // Persistent outbox (not tmp): the file must survive until the transfer finishes.
            let url = Diag.outbox.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: Diag.outbox, withIntermediateDirectories: true)
                try MotionCSV.encode(samples).write(to: url, atomically: true, encoding: .utf8)
                Diag.event("trace_written", ["file": name, "samples": samples.count, "kind": kind.rawValue])
                emitter.snapshot?(.recordingFinished(url: url, samples: samples.count, error: nil, kind: kind))
            } catch {
                Diag.event("trace_write_failed", ["file": name, "error": error.localizedDescription])
                emitter.snapshot?(.recordingFinished(url: nil, samples: samples.count, error: error.localizedDescription, kind: kind))
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
    /// Result of the last "Send last 60 s" / "Send diag log".
    @Published private(set) var dumpStatus: String?

    /// Phone-guided training recording, for the watch's Training screen.
    struct TrainingUI: Equatable {
        var label: TrainingLabel
        var phase: String
        var cue = 0
        var cueTotal: Int
        var done = false
    }
    @Published private(set) var training: TrainingUI?
    private var trainingStart: TrainingStart?

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
    /// Uptime of the last recording progress event (recording watchdog).
    private var lastRecordingProgress: TimeInterval = 0
    private var recordingWatchdog: Timer?
    private var aimVisible = false

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
        guard visible != aimVisible else { return }
        aimVisible = visible
        guard visible else {
            Diag.event("aim_stop")
            return
        }
        let ms = motion.status
        let url = config?.haURL
        Diag.event("aim_start", [
            "headingSource": ms.source.rawValue, "headingReady": ms.headingReady, "yawOffsetDeg": ms.yawOffsetDeg,
            "compassAccuracyDeg": ms.compassAccuracyDeg, "frames": ms.availableFrames,
            "room": room?.name, "candidates": aim.lockCandidates.isEmpty ? nil : aim.lockCandidates.count,
            "haURL": url?.absoluteString, "hasClient": hasClient, "phoneReachable": sync.isReachable,
            "rateHz": ms.measuredRateHz,
        ])
        if let host = url?.host {
            DispatchQueue.global(qos: .utility).async {
                let started = ProcessInfo.processInfo.systemUptime
                let r = Diag.resolve(host: host)
                Diag.event("ha_resolve", ["host": host, "addresses": r.addresses, "error": r.error,
                                          "ms": (ProcessInfo.processInfo.systemUptime - started) * 1000])
            }
        }
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
        lastRecordingProgress = ProcessInfo.processInfo.systemUptime
        Diag.event("recording_start", ["durationS": duration, "motionRunning": motion.status.isRunning])
        pipeline.startRecording(duration: duration)
        // Watchdog: if no samples arrive for > 1 s (motion stopped / app suspended),
        // end the recording with what it has instead of staying in "Recording…".
        recordingWatchdog?.invalidate()
        recordingWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkRecording() }
        }
    }

    private func checkRecording() {
        guard recording.isRecording else {
            recordingWatchdog?.invalidate()
            recordingWatchdog = nil
            return
        }
        // Progress events come every 0.25 s while samples flow.
        let silent = ProcessInfo.processInfo.systemUptime - lastRecordingProgress
        if silent > 1.5 {
            recordingWatchdog?.invalidate()
            recordingWatchdog = nil
            recording = .failed(String(format: "No motion samples for %.1f s — saving what was recorded", silent))
            pipeline.abortRecording(reason: String(format: "no samples for %.1f s", silent))
        }
    }

    // MARK: - Gesture training (guided from the phone)

    /// Phone asked to record `start`. Returns the reply status.
    func startTraining(_ start: TrainingStart) -> TrainingStatus {
        guard motion.status.deviceMotionAvailable else {
            return TrainingStatus(sessionID: start.sessionID, label: start.label, phase: .failed,
                                  message: "Device motion unavailable")
        }
        motion.start()
        trainingStart = start
        let ms = motion.status
        training = TrainingUI(label: start.label, phase: "Starting…",
                              cueTotal: start.plan.cueOffsets(for: start.label).count)
        Diag.event("training_start", ["label": start.label.rawValue, "cues": start.cueCount,
                                      "intervalS": start.cueIntervalS, "rateHz": ms.requestedRateHz])
        pipeline.startTraining(start, wearing: WearingInfo(wristIsLeft: ms.wristIsLeft, crownIsRight: ms.crownIsRight,
                                                           requestedRateHz: ms.requestedRateHz))
        return TrainingStatus(sessionID: start.sessionID, label: start.label, phase: .accepted)
    }

    /// Stops the current training recording (from the phone, or the watch's Stop button).
    func cancelTraining(sessionID: UUID? = nil) {
        pipeline.cancelTraining(sessionID: sessionID)
    }

    private func handleTraining(_ e: TrainingEvent) {
        func status(_ s: TrainingStart, _ phase: TrainingStatus.Phase, cue: Int? = nil, total: Int? = nil,
                    samples: Int? = nil, file: String? = nil, message: String? = nil) {
            sync.sendTrainingStatus(TrainingStatus(sessionID: s.sessionID, label: s.label, phase: phase, cueIndex: cue,
                                                   cueTotal: total, samples: samples, fileName: file, message: message))
        }
        func updateUI(_ s: TrainingStart, _ body: (inout TrainingUI) -> Void) {
            guard s.sessionID == trainingStart?.sessionID, var ui = training else { return }
            body(&ui)
            training = ui
        }
        switch e {
        case .recording(let s):
            updateUI(s) { $0.phase = "Recording" }
            status(s, .recording)
        case .cue(let s, let i, let n, let t):
            WKInterfaceDevice.current().play(.start)
            Diag.event("training_cue", ["label": s.label.rawValue, "index": i, "t": t])
            updateUI(s) { $0.cue = i + 1 }
            status(s, .cue, cue: i, total: n)
        case .finished(let s, let url, let n, let complete, let error):
            guard let url else {
                updateUI(s) { $0.phase = "Couldn't save"; $0.done = true }
                status(s, .failed, samples: n, message: error ?? "Could not write the recording")
                return
            }
            status(s, .finished, samples: n, file: url.lastPathComponent,
                   message: complete ? nil : "Motion stopped early — partial recording")
            if sync.sendTrace(at: url) {
                updateUI(s) { $0.phase = complete ? "Sent to iPhone ✓" : "Partial — sent to iPhone"; $0.done = true }
                status(s, .fileSent, samples: n, file: url.lastPathComponent)
            } else {
                updateUI(s) { $0.phase = "Saved; iPhone not connected"; $0.done = true }
                status(s, .failed, samples: n, file: url.lastPathComponent, message: "Watch not connected to the iPhone")
            }
            WKInterfaceDevice.current().play(complete ? .success : .failure)
        case .cancelled(let s):
            updateUI(s) { $0.phase = "Stopped"; $0.done = true }
            status(s, .cancelled)
        }
    }

    /// Sensor Probe → "Send last 60 s": the rolling buffer as a trace.
    func sendLastMinute() {
        dumpStatus = "Writing last 60 s…"
        pipeline.dumpRing()
    }

    /// Sensor Probe → "Send diag log": diag.log (+ its backup) to the phone's Traces list.
    func sendDiagLog() {
        dumpStatus = "Preparing diag log…"
        let sync = self.sync
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Diag.event("diag_send")
            Diag.shared.flushSync()
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            f.locale = Locale(identifier: "en_US_POSIX")
            let url = Diag.outbox.appendingPathComponent("diag-\(f.string(from: Date())).log")
            var data = Data()
            for src in [Diag.shared.backupURL, Diag.shared.url] {
                if let d = try? Data(contentsOf: src) { data.append(d) }
            }
            let ok = (try? FileManager.default.createDirectory(at: Diag.outbox, withIntermediateDirectories: true)) != nil
                && (try? data.write(to: url, options: .atomic)) != nil
            onMain {
                guard let self else { return }
                if !ok {
                    self.dumpStatus = "Could not write the log copy"
                } else {
                    self.dumpStatus = sync.sendTrace(at: url)
                        ? "Diag log (\(data.count / 1024) KB) → iPhone"
                        : "iPhone not connected"
                }
            }
        }
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
        var offsetDeg: Double?, offsetSource: String?, pitchBias: Double?
        if let config, let newRoom {
            // House-wide fallback: a room aligned to HA's house model is aimable once
            // any aligned room has a taught + placed device (HouseCalibration).
            let house = HouseCalibration(config: config)
            let refs = ReferenceDirections(room: newRoom, devices: config.devices, house: house)
            candidates = refs.candidates
            offsetDeg = refs.compassOffsetDeg
            offsetSource = refs.compassOffsetSource?.rawValue
            pitchBias = refs.pitchBiasDeg
            anchor = ReferenceDirections.anchor(room: newRoom, devices: config.devices, house: house)
            unaligned = newRoom.seat != nil && refs.compassOffsetDeg == nil
                && roomDevices.contains { $0.coordinates != nil }
        }
        needsAlignment = unaligned
        anchorDevice = anchor.flatMap { config?.device(id: $0.id) }
        let names = Dictionary(roomDevices.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        pipeline.configure(candidates: candidates, anchor: anchor,
                           settings: config?.settings ?? Settings(), resetLock: roomChanged, names: names)
        Diag.event("config_apply", [
            "room": newRoom?.name, "roomChanged": roomChanged, "devices": roomDevices.count,
            "candidates": candidates.count, "offsetDeg": offsetDeg, "offsetSource": offsetSource,
            "pitchBiasDeg": pitchBias, "anchor": anchorDevice?.name, "needsAlignment": unaligned,
            "hasClient": hasClient, "haURL": config?.haURL.absoluteString,
            "sensitivity": config?.settings.sensitivity.rawValue,
        ])
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
        case .training(let ev):
            handleTraining(ev)
        case .recordingProgress(let remaining):
            lastRecordingProgress = ProcessInfo.processInfo.systemUptime
            if recording.isRecording { recording = .recording(remaining: remaining) }
        case .recordingFinished(let url, let n, let error, let kind):
            var message: String
            var failed = false
            if let url {
                let sent = sync.sendTrace(at: url)
                Diag.event("trace_send", ["file": url.lastPathComponent, "kind": kind.rawValue, "queued": sent,
                                          "phoneReachable": sync.isReachable])
                switch kind {
                case .record: message = "\(n) samples"
                case .stalled: message = "Motion stopped early — \(n) samples"; failed = true
                case .ring: message = "Last 60 s (\(n) samples)"
                }
                message += sent ? " → iPhone" : ", saved; iPhone not connected"
                failed = failed || !sent
            } else {
                message = error ?? "Could not write trace"
                failed = true
            }
            if kind == .ring {
                dumpStatus = message
            } else {
                recordingWatchdog?.invalidate()
                recordingWatchdog = nil
                recording = failed ? .failed(message) : .finished(message)
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
            Diag.event("gesture_queued", ["type": g.gesture.rawValue, "device": device(target)?.name, "reason": "busy"])
            return
        }
        run(g, target: target)
    }

    private func run(_ g: DetectedGesture, target: UUID) {
        guard let config, let device = config.device(id: target) else {
            Diag.event("action", ["type": g.gesture.rawValue, "result": "unknown device", "deviceID": target])
            return
        }
        let state = states[device.entityID]
        var fields: [String: Any?] = [
            "type": g.gesture.rawValue, "device": device.name, "entity": device.entityID, "kind": device.kind.rawValue,
            "state": state?.state, "brightnessPct": state?.brightnessPct, "percentage": state?.percentage,
        ]
        guard let call = ActionMapper.map(gesture: g.gesture, device: device,
                                          state: state, settings: config.settings) else {
            fields["result"] = "nothing to do"
            Diag.event("action", fields)
            actionLine = "\(g.gesture.displayName): nothing to do"
            return
        }
        fields["result"] = call.serviceName
        fields["data"] = call.data.mapValues(\.foundationObject)
        guard let client else {
            fields["blocked"] = "no HA client (token missing)"
            Diag.event("action", fields)
            fail("No HA token — set up on iPhone")
            return
        }
        Diag.event("action", fields)
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
        let base: [String: Any?] = ["service": call.serviceName, "entity": call.entityID, "url": client.baseURL.absoluteString]
        var t0 = ProcessInfo.processInfo.systemUptime
        func ms() -> Double { (ProcessInfo.processInfo.systemUptime - t0) * 1000 }
        do {
            let states = try await client.callService(call)
            Diag.event("ha_call", base.merging(["ms": ms(), "ok": true, "viaPhone": false, "states": states.count]) { a, _ in a })
            outcome = .success(states, viaPhone: false)
        } catch {
            Diag.event("ha_call", base.merging(["ms": ms(), "ok": false, "viaPhone": false]) { a, _ in a }
                .merging(Diag.errorFields(error)) { a, _ in a })
            let e = HAError.from(error)
            if e.isNetworkError {
                actionLine = "Retrying via iPhone…"
                t0 = ProcessInfo.processInfo.systemUptime
                do {
                    let r = try await sync.relay(call)
                    if let msg = r.errorMessage {
                        Diag.event("ha_call", base.merging(["ms": ms(), "ok": false, "viaPhone": true, "error": msg]) { a, _ in a })
                        outcome = .failure(msg)
                    } else {
                        Diag.event("ha_call", base.merging(["ms": ms(), "ok": true, "viaPhone": true]) { a, _ in a })
                        outcome = .success(r.states ?? [], viaPhone: true)
                    }
                } catch {
                    Diag.event("ha_call", base.merging(["ms": ms(), "ok": false, "viaPhone": true,
                                                        "error": "relay: \(error.localizedDescription)"]) { a, _ in a })
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
            let s = try await client.entityState(entityID)
            Diag.event("ha_state", ["entity": entityID, "ok": true, "state": s.state,
                                    "ms": (ProcessInfo.processInfo.systemUptime - started) * 1000])
            setState(s, requestedAt: started)
        } catch {
            Diag.event("ha_state", ["entity": entityID, "ok": false,
                                    "ms": (ProcessInfo.processInfo.systemUptime - started) * 1000]
                .merging(Diag.errorFields(error)) { a, _ in a })
            guard relayFallback, HAError.from(error).isNetworkError, sync.isReachable else { return }
            let r = try? await sync.relayState(entityID)
            Diag.event("ha_state", ["entity": entityID, "viaPhone": true, "ok": r?.states?.isEmpty == false,
                                    "error": r?.errorMessage])
            guard let s = r?.states?.first(where: { $0.entityID == entityID }) else { return }
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
