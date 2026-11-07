import SwiftUI

@main
struct WatchMagicApp: App {
    @StateObject private var store: ConfigStore
    @StateObject private var traces: TraceStore
    @StateObject private var sync: PhoneSyncService
    @StateObject private var house: HouseService

    init() {
        let store = ConfigStore()
        let traces = TraceStore()
        let sync = PhoneSyncService(store: store, traceStore: traces)
        _store = StateObject(wrappedValue: store)
        _traces = StateObject(wrappedValue: traces)
        _sync = StateObject(wrappedValue: sync)
        _house = StateObject(wrappedValue: HouseService(store: store))
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(traces)
                .environmentObject(sync)
                .environmentObject(house)
                .tint(Color("AccentColor"))
        }
    }
}
