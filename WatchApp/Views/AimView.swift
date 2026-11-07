import SwiftUI
import WatchMagicKit

/// Main screen: what you're aiming at, lock state, crown disambiguation,
/// last action / error, zero-gesture prompt, session-ended overlay.
struct AimView: View {
    @EnvironmentObject private var engine: ControlEngine
    @EnvironmentObject private var runtime: RuntimeSession
    @EnvironmentObject private var motion: MotionService

    @State private var crown = 0.0
    @State private var lastDetent = 0

    var body: some View {
        content
            .navigationTitle(engine.room?.name ?? "WatchMagic")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: Route.teach) {
                        Image(systemName: "scope").accessibilityLabel("Teach")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.probe) {
                        Image(systemName: "waveform.path.ecg").accessibilityLabel("Sensor Probe")
                    }
                }
            }
            .focusable(true)
            .digitalCrownRotation($crown, from: -100_000, through: 100_000, by: 1,
                                  sensitivity: .low, isContinuous: true,
                                  isHapticFeedbackEnabled: engine.aim.isAmbiguous)
            .onChange(of: crown) { _, value in
                let detent = Int(value.rounded())
                guard detent != lastDetent else { return }
                engine.crown(next: detent > lastDetent)
                lastDetent = detent
            }
            .overlay {
                if runtime.state.isEnded { resumeOverlay }
            }
            .onAppear {
                engine.setAimScreenVisible(true)
                runtime.start()
            }
            .onDisappear {
                engine.setAimScreenVisible(false)
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if engine.config == nil {
            message("Open WatchMagic on your iPhone to set up", symbol: "iphone")
        } else if engine.room == nil {
            message("Choose \"I'm in\" on your iPhone", symbol: "house")
        } else if engine.roomDevices.isEmpty {
            message("No devices in \(engine.room?.name ?? "this room")", symbol: "lightbulb.slash")
        } else {
            aimContent
        }
    }

    private var aimContent: some View {
        let aim = engine.aim
        let selected = engine.device(aim.selectedID)
        let state = engine.state(of: selected)

        return VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.gray.opacity(0.3), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: ringFraction(aim))
                    .stroke(ringColor(aim), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.15), value: ringFraction(aim))
                Image(systemName: selected.map { DeviceStyle.symbol(for: $0.kind, isOn: state?.isOn ?? false) } ?? "scope")
                    .font(.system(size: 28))
                    .foregroundStyle(selected == nil ? Color.secondary : DeviceStyle.color(state))
            }
            .frame(width: 64, height: 64)

            if aim.isAmbiguous {
                ambiguousList(aim)
            } else if let selected {
                Text(selected.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(DeviceStyle.stateText(state, kind: selected.kind))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(idleTitle(aim))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }

            footer(aim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ambiguousList(_ aim: AimSnapshot) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(aim.lockCandidates.enumerated()), id: \.element) { index, id in
                let d = engine.device(id)
                let isSelected = index == aim.selectedIndex
                HStack(spacing: 4) {
                    Image(systemName: isSelected ? "chevron.right" : "circle.dotted")
                        .font(.caption2)
                    Text(d?.name ?? "?")
                        .font(isSelected ? .headline : .footnote)
                        .lineLimit(1)
                    if isSelected, let d {
                        Text(DeviceStyle.stateText(engine.state(of: d), kind: d.kind))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            Text("Turn crown to choose")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func footer(_ aim: AimSnapshot) -> some View {
        if aim.zeroNeeded, let anchor = engine.anchorDevice {
            VStack(spacing: 2) {
                Text("Point at \(anchor.name) and hold")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                ProgressView(value: aim.zeroProgress)
                    .tint(.orange)
            }
        } else if let error = engine.errorLine {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if let line = engine.actionLine {
            Text(line)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else if !engine.hasClient {
            Text("No Home Assistant token yet")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func idleTitle(_ aim: AimSnapshot) -> String {
        if !aim.headingReady {
            if aim.zeroNeeded { return "Set heading" }
            if aim.source == .zeroGesture && engine.anchorDevice == nil {
                return "Teach a device first"
            }
            return "Waiting for compass…"
        }
        return "Aim at a device"
    }

    private func ringFraction(_ aim: AimSnapshot) -> Double {
        guard aim.isLocked else { return 0 }
        return aim.windowOpen ? 1 : 0.35
    }

    private func ringColor(_ aim: AimSnapshot) -> Color {
        if engine.busy { return .blue }
        return aim.windowOpen ? .green : .green.opacity(0.5)
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resumeOverlay: some View {
        Button {
            runtime.start(userInitiated: true)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "pause.circle")
                    .font(.title)
                Text("Session ended — tap to resume")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}
