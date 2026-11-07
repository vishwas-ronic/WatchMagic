import SwiftUI

/// Navigation destinations pushed on top of the Aim screen.
enum Route: Hashable {
    case teach
    case teachDevice(UUID)
    case probe
}

/// Owns the watch app's services (shared with the App Intent).
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    let motion: MotionService
    let sync: WatchSyncService
    let runtime: RuntimeSession
    let engine: ControlEngine

    @Published var path: [Route] = []

    private init() {
        motion = MotionService()
        sync = WatchSyncService()
        runtime = RuntimeSession()
        engine = ControlEngine(motion: motion, sync: sync)
        sync.activate()
        motion.start()
    }

    /// App Intent / Action button: back to the Aim screen and start aiming.
    func startAiming() {
        path = []
        motion.refreshWearing()
        motion.start()
        runtime.start(userInitiated: true)
    }

    func becameActive() {
        motion.refreshWearing()
        motion.start()
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
            if phase == .active { services.becameActive() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        NavigationStack(path: $services.path) {
            AimView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .teach: TeachView()
                    case .teachDevice(let id): TeachDeviceView(deviceID: id)
                    case .probe: SensorProbeView()
                    }
                }
        }
    }
}
