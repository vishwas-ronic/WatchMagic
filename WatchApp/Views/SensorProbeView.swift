import SwiftUI
import WatchMagicKit

/// Diagnostics (spec 1.2.7): reference frames, heading source, attitude,
/// pointing, target resolution, gestures, latency, and trace recording.
struct SensorProbeView: View {
    @EnvironmentObject private var engine: ControlEngine
    @EnvironmentObject private var motion: MotionService
    @EnvironmentObject private var sync: WatchSyncService
    @EnvironmentObject private var runtime: RuntimeSession
    @EnvironmentObject private var services: AppServices

    var body: some View {
        let m = motion.status
        let aim = engine.aim

        List {
            Section("Record") {
                recordButton
                Button("Send last 60 s") { engine.sendLastMinute() }
                Button("Send diag log") { engine.sendDiagLog() }
                if let status = engine.dumpStatus {
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
                if let status = sync.traceStatus {
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("Heading") {
                row("Frames", m.availableFrames.joined(separator: "\n"))
                row("Source", m.source.displayName)
                row("Heading ready", m.headingReady ? "Yes" : "No")
                row("Heading available", m.headingAvailable ? "Yes" : "No")
                row("Compass", m.compassHeadingDeg.map { deg($0) } ?? "—")
                row("Accuracy", m.compassAccuracyDeg.map { "±" + deg($0) } ?? "—")
                if m.source == .magneticNorthFrame {
                    row("CM heading", m.motionHeadingDeg.map { deg($0) } ?? "—")
                    row("Mag field", m.magneticFieldAccuracy ?? "—")
                }
                row("Top heading (calc)", m.deviceTopHeadingDeg.map { deg($0) } ?? "—")
                row("Yaw offset", deg(m.yawOffsetDeg))
                if m.source == .compassAnchored { row("Anchor updates", "\(m.compassAnchorUpdates)") }
                row("Location auth", m.locationAuthorization)
                if m.source != .magneticNorthFrame {
                    Button("Re-zero heading") { motion.resetHeading() }
                }
            }

            Section("Attitude") {
                row("Yaw", deg(m.yawDeg))
                row("Pitch", deg(m.pitchDeg))
                row("Roll", deg(m.rollDeg))
                row("Convention", conventionText(m))
                row("Rate", String(format: "%.0f Hz (req %.0f)", m.measuredRateHz, m.requestedRateHz))
                Toggle("100 Hz", isOn: Binding(
                    get: { motion.status.requestedRateHz >= 100 },
                    set: { motion.setRate($0 ? 100 : 50) }
                ))
            }

            Section("Wearing") {
                row("Wrist", m.wristIsLeft ? "Left" : "Right")
                row("Crown", m.crownIsRight ? "Right" : "Left")
                row("Pointing sign", m.pointingSign > 0 ? "+x" : "−x")
            }

            Section("Pointing") {
                row("Heading", m.pointing.isZero ? "—" : deg(m.pointing.compassHeadingDeg))
                row("Yaw (CCW)", deg(m.pointing.yawDeg))
                row("Pitch", deg(m.pointing.pitchDeg))
                row("Ang. speed", String(format: "%.2f rad/s", aim.angularSpeed))
            }

            Section("Target") {
                row("Resolved", resolutionText(aim.resolution))
                row("Nearest", nearestText(aim))
                row("Lock", aim.isLocked ? (aim.windowOpen ? "Locked · window open" : "Locked") : "—")
            }

            Section("Gesture") {
                if let g = aim.lastGesture {
                    row("Last", g.gesture.displayName + (aim.lastGestureActed ? " (acted)" : " (ignored)"))
                    row("Peak rate", String(format: "%.1f rad/s", g.peakRate))
                } else {
                    row("Last", "—")
                }
            }

            Section("Latency") {
                row("Last call", engine.latenciesMs.last.map { String(format: "%.0f ms", $0) } ?? "—")
                row("Median (\(engine.latenciesMs.count))", engine.latencyMedianMs.map { String(format: "%.0f ms", $0) } ?? "—")
            }

            Section("Sync & session") {
                row("WCSession", sync.activated ? (sync.isReachable ? "Reachable" : "Activated") : "Inactive")
                row("Config", sync.lastConfigReceivedAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "None")
                row("Token", sync.hasToken ? "Stored" : "Missing")
                row("Unsynced teach", "\(sync.pendingTaughtIDs.count)")
                row("Runtime", runtime.state.displayName)
                if let error = sync.lastError {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Sensor Probe")
        .onAppear { services.keepAlive() }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var recordButton: some View {
        switch engine.recording {
        case .recording(let remaining):
            HStack {
                ProgressView()
                Text(String(format: "Recording… %.0f s", remaining.rounded(.up)))
            }
        case .idle:
            Button("Record 10 s trace") { engine.startRecording(duration: 10) }
        case .finished(let msg):
            Button("Record 10 s trace") { engine.startRecording(duration: 10) }
            Text(msg).font(.caption2).foregroundStyle(.green)
        case .failed(let msg):
            Button("Record 10 s trace") { engine.startRecording(duration: 10) }
            Text(msg).font(.caption2).foregroundStyle(.orange)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(.caption2.monospacedDigit()).multilineTextAlignment(.trailing)
        }
    }

    private func deg(_ d: Double) -> String { String(format: "%.1f°", d) }

    private func conventionText(_ m: MotionStatus) -> String {
        let current = m.convention.map { $0 == .referenceToDevice ? "ref→dev ✓" : "dev→ref ✗" } ?? "tilt watch"
        return "\(current) (\(m.conventionVotesRefToDev)/\(m.conventionVotesDevToRef))"
    }

    private func name(_ id: UUID) -> String { engine.device(id)?.name ?? "?" }

    private func resolutionText(_ r: Resolution) -> String {
        switch r {
        case .none: return "None"
        case .locked(let id, let angle): return "\(name(id)) \(deg(angle))"
        case .ambiguous(let ids): return "Ambiguous: " + ids.map(name).joined(separator: ", ")
        }
    }

    private func nearestText(_ aim: AimSnapshot) -> String {
        guard let id = aim.nearestID, let a = aim.nearestAngleDeg else { return "—" }
        return "\(name(id)) \(deg(a))"
    }
}
