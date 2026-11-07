import SwiftUI

@main
struct WatchMagicApp: App {
    @StateObject private var store: ConfigStore
    @StateObject private var traces: TraceStore
    @StateObject private var sync: PhoneSyncService

    init() {
        let store = ConfigStore()
        let traces = TraceStore()
        let sync = PhoneSyncService(store: store, traceStore: traces)
        _store = StateObject(wrappedValue: store)
        _traces = StateObject(wrappedValue: traces)
        _sync = StateObject(wrappedValue: sync)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(traces)
                .environmentObject(sync)
                .tint(Color("AccentColor"))
        }
    }
}
