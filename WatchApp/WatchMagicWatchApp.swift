import Combine
import SwiftUI
import WatchKit
import WatchMagicKit

/// Navigation destinations pushed on top of the Aim screen.
enum Route: Hashable {
    case teach
    case teachDevice(UUID)
    case probe
    /// Phone-guided gesture-training recording.
    case training
}

/// Owns the watch app's services (shared with the App Intent).
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    let motion: MotionService
    let sync: WatchSyncService
    let runtime: RuntimeSession
    let alwaysOn = AlwaysOnSession()
    let engine: ControlEngine

    @Published var path: [Route] = []

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        Diag.event("app_launch", ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                                  "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String])
        motion = MotionService()
        sync = WatchSyncService()
        runtime = RuntimeSession()
        engine = ControlEngine(motion: motion, sync: sync)
        sync.activate()
        motion.start()
        // Gesture training is guided from the iPhone; the watch just records.
        sync.onTrainingStart = { [weak self] start in
            guard let self else {
                return TrainingStatus(sessionID: start.sessionID, label: start.label, phase: .failed, message: "Not ready")
            }
            self.keepAlive(evenInBackground: true)
            if self.path.last != .training { self.path.append(.training) }
            return self.engine.startTraining(start)
        }
        sync.onTrainingCancel = { [weak self] id in self?.engine.cancelTraining(sessionID: id) }
        runtime.$state
            .removeDuplicates()
            .sink { [weak self] state in
                Diag.event("runtime_session", ["state": state.displayName,
                                               "expires": self?.runtime.expirationDate,
                                               "restarts": self?.runtime.restartCount])
            }
            .store(in: &cancellables)
        // Follow the iPhone's "Always listening" switch.
        engine.$config
            .compactMap { $0?.settings.alwaysListening }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.keepAlive() }
            .store(in: &cancellables)
        alwaysOn.$state
            .removeDuplicates()
            .sink { s in Diag.event("always_on_state", ["state": s.displayName]) }
            .store(in: &cancellables)
        // Launch straight into listening (no tap needed).
        keepAlive()
        motion.$status
            .map { MotionKey(running: $0.isRunning, source: $0.source.rawValue, ready: $0.headingReady) }
            .removeDuplicates()
            .sink { k in Diag.event("motion_state", ["running": k.running, "headingSource": k.source, "headingReady": k.ready]) }
            .store(in: &cancellables)
    }

    private struct MotionKey: Equatable {
        var running: Bool
        var source: String
        var ready: Bool
    }

    private var alwaysListening: Bool {
        engine.config?.settings.alwaysListening ?? Settings().alwaysListening
    }

    /// Listening on: Always listening → workout session (no time limit, works
    /// from the watch face). Off → only while WatchMagic is on screen (incl.
    /// dimmed with the wrist down); back on the watch face it stops.
    /// `evenInBackground`: phone-guided training records with the screen off.
    func keepAlive(evenInBackground: Bool = false) {
        if alwaysListening {
            if runtime.state == .running || runtime.state == .starting { runtime.stop() }
            motion.start()
            alwaysOn.start()
            return
        }
        if alwaysOn.isActive { alwaysOn.stop() }
        if !evenInBackground, WKApplication.shared().applicationState == .background {
            stopListening()
        } else {
            // The runtime session keeps frames coming with the wrist down while
            // WatchMagic is still the app on screen; it is ended on the watch face.
            motion.start()
            runtime.start(userInitiated: true)
        }
    }

    /// Always listening off and back on the watch face: no motion, no session.
    private func stopListening() {
        if runtime.state == .running || runtime.state == .starting { runtime.stop() }
        if motion.status.isRunning { motion.stop() }
        Diag.event("listening", ["state": "off", "why": "background, always listening off"])
    }

    func enteredBackground() {
        if !alwaysListening, engine.training == nil || engine.training?.done == true { stopListening() }
    }

    /// App Intent / Action button: back to the Aim screen and start aiming.
    func startAiming() {
        path = []
        motion.refreshWearing()
        keepAlive()
    }

    func becameActive() {
        motion.refreshWearing()
        keepAlive()
    }
}

@main
struct WatchMagicWatchApp: App {
    @StateObject private var services = AppServices.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                .environmentObject(services.engine)
                .environmentObject(services.motion)
                .environmentObject(services.sync)
                .environmentObject(services.runtime)
        }
        .onChange(of: scenePhase) { _, phase in
            Diag.event("scene_phase", ["phase": "\(phase)"])
            if phase == .active { services.becameActive() }
            if phase == .background {
                services.enteredBackground()
                Diag.shared.flush()
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        NavigationStack(path: $services.path) {
            AimView()
                // Watch-face complication / Smart Stack widget tap.
                .onOpenURL { url in
                    Diag.event("open_url", ["url": url.absoluteString])
                    if url.scheme == "watchmagic" { services.startAiming() }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .teach: TeachView()
                    case .teachDevice(let id): TeachDeviceView(deviceID: id)
                    case .probe: SensorProbeView()
                    case .training: TrainingRecordingView()
                    }
                }
        }
    }
}
