import AudioToolbox
import Foundation
import UIKit
import WatchMagicKit

/// Runs the phone-guided gesture-training session: for each step it asks the
/// watch to record (`TrainingStart`), then plays the cues here (sound + haptic,
/// and the animation pulses) on the same schedule the watch uses, and waits
/// for the watch to send the file. Steps: flickUp, flickDown, twist (10 cues
/// each), then none (60 s).
@MainActor
final class GestureTrainingController: ObservableObject {
    enum Phase: Equatable {
        /// Waiting for Start on the current step.
        case ready
        /// Watch not reachable yet (message), retrying.
        case connecting(String)
        case running
        /// Recording done; waiting for the watch's file.
        case saving
        /// Step finished (result message).
        case stepDone(String, ok: Bool)
        /// All steps done.
        case summary
    }

    static let steps: [TrainingLabel] = [.flickUp, .flickDown, .twist, .none]
    /// Watch unreachable: retry this often, this many times.
    static let retryInterval: TimeInterval = 2
    static let maxRetries = 60

    @Published private(set) var stepIndex = 0
    @Published private(set) var phase: Phase = .ready
    /// Cues played so far in this step.
    @Published private(set) var cue = 0
    @Published private(set) var cueTotal = 0
    @Published private(set) var remaining: TimeInterval = 0
    /// Increments on every cue (drives the animation pulse).
    @Published private(set) var cuePulse = 0
    @Published private(set) var round = 1
    /// When this screen's session began (for the per-label summary).
    let sessionStart = Date()

    private var task: Task<Void, Never>?
    private var current: TrainingStart?

    var label: TrainingLabel { Self.steps[min(stepIndex, Self.steps.count - 1)] }
    var isLastStep: Bool { stepIndex >= Self.steps.count - 1 }
    var isBusy: Bool {
        switch phase {
        case .connecting, .running, .saving: return true
        default: return false
        }
    }

    /// "Flick UP — 10 times" / "Move normally — 60 s".
    var stepTitle: String {
        let plan = TrainingPlan.standard
        return label.isCued ? "\(label.title) — \(plan.cueCount) times" : "\(label.title) — \(Int(plan.noneDuration)) s"
    }

    var stepInstruction: String {
        switch label {
        case .flickUp, .flickDown, .twist:
            return "Point at a device like you're controlling it, \(label == .twist ? "twist" : "flick") when you feel/hear the cue, then point again."
        case .none:
            return "Move normally for 60 s: type on the phone, drink, scroll, talk with your hands, raise/lower your arm."
        }
    }

    // MARK: Commands

    func start(sync: PhoneSyncService) {
        guard !isBusy else { return }
        task?.cancel()
        task = Task { [weak self] in await self?.run(sync: sync) }
    }

    func redo(sync: PhoneSyncService) {
        phase = .ready
        start(sync: sync)
    }

    func skip() {
        cancelRunning(sync: nil)
        advance()
    }

    /// After a finished step: on to the next one (or the summary).
    func advance() {
        if isLastStep {
            phase = .summary
        } else {
            stepIndex += 1
            phase = .ready
        }
    }

    func anotherRound() {
        round += 1
        stepIndex = 0
        phase = .ready
    }

    /// Leaving the screen / Skip: stop locally and tell the watch.
    func cancelRunning(sync: PhoneSyncService?) {
        task?.cancel()
        task = nil
        if let current, isBusy { sync?.cancelTraining(sessionID: current.sessionID) }
        current = nil
        if isBusy { phase = .ready }
    }

    // MARK: Session

    private func run(sync: PhoneSyncService) async {
        let start = TrainingStart(label: label)
        var attempts = 0
        while true {
            if Task.isCancelled { return }
            do {
                _ = try await sync.startTraining(start)
                break
            } catch {
                attempts += 1
                guard attempts < Self.maxRetries else {
                    phase = .stepDone("The watch didn't respond. Open WatchMagic on the watch and press Redo.", ok: false)
                    return
                }
                phase = .connecting(error.localizedDescription + " — retrying…")
                try? await Task.sleep(nanoseconds: UInt64(Self.retryInterval * 1e9))
            }
        }
        current = start
        phase = .running
        let plan = start.plan
        let offsets = plan.cueOffsets(for: start.label)
        let duration = plan.duration(for: start.label)
        cueTotal = offsets.count
        cue = 0
        let t0 = ProcessInfo.processInfo.systemUptime
        var next = 0
        while !Task.isCancelled {
            let elapsed = ProcessInfo.processInfo.systemUptime - t0
            while next < offsets.count, elapsed >= offsets[next] {
                fireCue()
                next += 1
            }
            remaining = max(0, duration - elapsed)
            if elapsed >= duration { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if Task.isCancelled { return }

        phase = .saving
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var final: TrainingStatus?
        while ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
            if let st = sync.lastTrainingStatus, st.sessionID == start.sessionID,
               [.fileSent, .failed, .cancelled].contains(st.phase) {
                final = st
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if Task.isCancelled { return }
        current = nil
        switch final?.phase {
        case .fileSent?:
            let n = final?.samples.map { "\($0) samples" } ?? "recording"
            phase = .stepDone("Saved: \(n) → Training data", ok: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failed?, .cancelled?:
            phase = .stepDone(final?.message ?? "The watch stopped recording", ok: false)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        default:
            phase = .stepDone("No word from the watch — check Training data, or Redo", ok: false)
        }
    }

    private func fireCue() {
        cue += 1
        cuePulse += 1
        AudioServicesPlaySystemSound(1057) // short "tink"
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    /// Training files received since this screen opened, per label.
    func receivedCounts(in files: [TraceStore.TraceFile]) -> [TrainingLabel: Int] {
        var out: [TrainingLabel: Int] = [:]
        for f in files where f.date >= sessionStart {
            if let l = TrainingRecorder.label(ofFileName: f.name) { out[l, default: 0] += 1 }
        }
        return out
    }
}
