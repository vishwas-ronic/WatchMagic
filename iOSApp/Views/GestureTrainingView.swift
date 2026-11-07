import SwiftUI
import WatchMagicKit

/// Settings → Train gestures. The iPhone guides; the watch records each set
/// and sends `train-<label>-….csv` files (→ Settings → Training data).
struct GestureTrainingView: View {
    @EnvironmentObject private var sync: PhoneSyncService
    @EnvironmentObject private var traces: TraceStore
    @StateObject private var trainer = GestureTrainingController()

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if trainer.phase == .summary {
                    summary
                } else {
                    stepHeader
                    GestureAnimationView(label: trainer.label, pulse: trainer.cuePulse,
                                         loops: trainer.phase != .running || trainer.label == .none)
                        .frame(height: 190)
                    progress
                    controls
                    watchLine
                }
            }
            .padding(20)
        }
        .navigationTitle("Train gestures")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            traces.refresh()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            trainer.cancelRunning(sync: sync)
        }
        .onChange(of: sync.lastTrainingStatus?.phase) { _, _ in traces.refresh() }
    }

    // MARK: Pieces

    private var stepHeader: some View {
        VStack(spacing: 8) {
            Text("Step \(trainer.stepIndex + 1) of \(GestureTrainingController.steps.count)"
                 + (trainer.round > 1 ? " · round \(trainer.round)" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(trainer.stepTitle)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
            Text(trainer.stepInstruction)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch trainer.phase {
        case .running:
            if trainer.cueTotal > 0 {
                VStack(spacing: 6) {
                    Text("Cue \(trainer.cue) of \(trainer.cueTotal)")
                        .font(.system(size: 44, weight: .heavy, design: .rounded).monospacedDigit())
                    ProgressView(value: Double(trainer.cue), total: Double(trainer.cueTotal))
                }
            } else {
                VStack(spacing: 6) {
                    Text(String(format: "%.0f s", trainer.remaining.rounded(.up)))
                        .font(.system(size: 56, weight: .heavy, design: .rounded).monospacedDigit())
                    ProgressView(value: 60 - min(60, trainer.remaining), total: 60)
                }
            }
        case .connecting(let msg):
            Label(msg, systemImage: "applewatch.radiowaves.left.and.right")
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case .saving:
            HStack(spacing: 8) {
                ProgressView()
                Text("Saving on the watch…")
            }
        case .stepDone(let msg, let ok):
            Label(msg, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .multilineTextAlignment(.center)
        case .ready, .summary:
            Text("Wear the watch, open WatchMagic on it, then tap Start. Turn the ringer on to hear the cues.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch trainer.phase {
        case .ready:
            Button {
                trainer.start(sync: sync)
            } label: {
                Text("Start").font(.title2.bold()).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Skip this step") { trainer.skip() }
        case .connecting, .running, .saving:
            Button("Stop", role: .destructive) { trainer.cancelRunning(sync: sync) }
                .buttonStyle(.bordered)
                .controlSize(.large)
        case .stepDone:
            HStack(spacing: 12) {
                Button("Redo") { trainer.redo(sync: sync) }
                    .buttonStyle(.bordered)
                Button(trainer.isLastStep ? "Finish" : "Next step") { trainer.advance() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        case .summary:
            EmptyView()
        }
    }

    @ViewBuilder
    private var watchLine: some View {
        if let st = sync.lastTrainingStatus, trainer.isBusy {
            Text("Watch: " + watchText(st))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func watchText(_ st: TrainingStatus) -> String {
        switch st.phase {
        case .accepted: return "ready"
        case .recording: return "recording"
        case .cue: return "cue \((st.cueIndex ?? 0) + 1) of \(st.cueTotal ?? 0)"
        case .finished: return "saving \(st.samples ?? 0) samples"
        case .fileSent: return "file sent"
        case .cancelled: return "stopped"
        case .failed: return st.message ?? "failed"
        }
    }

    private var summary: some View {
        let counts = trainer.receivedCounts(in: traces.training)
        return VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Training data received").font(.title2.bold())
            VStack(spacing: 8) {
                ForEach(GestureTrainingController.steps, id: \.self) { l in
                    HStack {
                        Text(l.title)
                        Spacer()
                        Text("\(counts[l] ?? 0) file\(counts[l] == 1 ? "" : "s")")
                            .foregroundStyle((counts[l] ?? 0) > 0 ? Color.primary : Color.orange)
                    }
                }
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            Text("Files are in Settings → Training data (share them from there).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Do another round") { trainer.anotherRound() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

// MARK: - Gesture animation

/// A stylised forearm + hand (watch on the wrist, pointing right/forward)
/// acting out the gesture: Flick UP/DOWN = the hand snaps ~25° about the wrist
/// and returns (fast out, slower back); Twist = the forearm rolls ~70° about
/// its axis and back; none = a relaxed sway. Plays once whenever `pulse`
/// changes (each cue) and loops every 2.5 s while `loops`. Reduce Motion: a
/// static diagram with an arrow.
struct GestureAnimationView: View {
    let label: TrainingLabel
    let pulse: Int
    let loops: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flick = 0.0
    @State private var roll = 0.0
    @State private var sway = 0.0

    private let skin = Color(red: 0.93, green: 0.76, blue: 0.62)
    private let skinShade = Color(red: 0.84, green: 0.65, blue: 0.51)

    var body: some View {
        ZStack {
            arm
                .rotationEffect(.degrees(sway + (reduceMotion ? staticSway : 0)), anchor: .leading)
                .rotation3DEffect(.degrees(reduceMotion ? staticRoll : roll), axis: (x: 1, y: 0, z: 0),
                                  perspective: 0.4)
            arrow
            if label == .none { idleIcons }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .task(id: "\(label.rawValue)-\(loops)-\(reduceMotion)") {
            resetPose()
            guard loops, !reduceMotion else { return }
            while !Task.isCancelled {
                await play()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
        .onChange(of: pulse) { _, _ in
            guard !reduceMotion else { return }
            Task { await play() }
        }
    }

    private var arm: some View {
        HStack(spacing: -6) {
            // Forearm with the watch near the wrist.
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [skin, skinShade], startPoint: .top, endPoint: .bottom))
                .frame(width: 170, height: 40)
                .overlay(alignment: .trailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.75)).frame(width: 22, height: 46)
                        RoundedRectangle(cornerRadius: 8).fill(Color.orange).frame(width: 30, height: 34)
                        RoundedRectangle(cornerRadius: 6).fill(Color.black).frame(width: 24, height: 28)
                    }
                    .padding(.trailing, 14)
                }
            // Hand pointing forward, rotating about the wrist.
            HStack(spacing: -4) {
                RoundedRectangle(cornerRadius: 14).fill(skin).frame(width: 46, height: 36)
                Capsule().fill(skin).frame(width: 40, height: 12).offset(y: -8)
            }
            .rotationEffect(.degrees(reduceMotion ? staticFlick : flick), anchor: .leading)
        }
    }

    @ViewBuilder
    private var arrow: some View {
        switch label {
        case .flickUp:
            Image(systemName: "arrow.up").font(.system(size: 34, weight: .bold)).foregroundStyle(.tint)
                .offset(x: 120, y: -60)
        case .flickDown:
            Image(systemName: "arrow.down").font(.system(size: 34, weight: .bold)).foregroundStyle(.tint)
                .offset(x: 120, y: 60)
        case .twist:
            Image(systemName: "arrow.clockwise").font(.system(size: 34, weight: .bold)).foregroundStyle(.tint)
                .offset(x: 0, y: -62)
        case .none:
            EmptyView()
        }
    }

    private var idleIcons: some View {
        HStack(spacing: 18) {
            ForEach(["keyboard", "cup.and.saucer", "iphone", "hand.wave", "figure.walk"], id: \.self) {
                Image(systemName: $0)
            }
        }
        .font(.title3)
        .foregroundStyle(.secondary)
        .offset(y: 78)
    }

    // Static (Reduce Motion) pose.
    private var staticFlick: Double {
        switch label {
        case .flickUp: return -25
        case .flickDown: return 25
        default: return 0
        }
    }
    private var staticRoll: Double { label == .twist ? 40 : 0 }
    private var staticSway: Double { 0 }

    private var accessibilityText: String {
        switch label {
        case .flickUp: return "Flick the hand up sharply at the wrist, then return"
        case .flickDown: return "Flick the hand down sharply at the wrist, then return"
        case .twist: return "Roll the forearm quickly and back"
        case .none: return "Move normally"
        }
    }

    private func resetPose() {
        flick = 0
        roll = 0
        sway = 0
    }

    /// One repetition of the gesture.
    private func play() async {
        switch label {
        case .flickUp, .flickDown:
            withAnimation(.easeOut(duration: 0.12)) { flick = label == .flickUp ? -25 : 25 }
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation(.easeInOut(duration: 0.5)) { flick = 0 }
            try? await Task.sleep(nanoseconds: 500_000_000)
        case .twist:
            withAnimation(.easeOut(duration: 0.15)) { roll = 70 }
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.easeInOut(duration: 0.5)) { roll = 0 }
            try? await Task.sleep(nanoseconds: 500_000_000)
        case .none:
            withAnimation(.easeInOut(duration: 1.2)) { sway = -6 }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeInOut(duration: 1.2)) { sway = 4 }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeInOut(duration: 0.8)) { sway = 0 }
        }
    }
}
