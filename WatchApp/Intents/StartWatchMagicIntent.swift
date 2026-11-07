import AppIntents

/// "Start WatchMagic" — opens the app on the Aim screen and starts the
/// extended runtime session. Assign it to the Ultra Action button via a
/// Shortcut (spec 1.2.6).
struct StartWatchMagicIntent: AppIntent {
    static let title: LocalizedStringResource = "Start WatchMagic"
    static let description = IntentDescription("Opens WatchMagic straight into aiming.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared.startAiming()
        return .result()
    }
}

/// Makes the intent discoverable in the Shortcuts app.
struct WatchMagicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWatchMagicIntent(),
            phrases: [
                "Start \(.applicationName)",
                "Aim with \(.applicationName)",
            ],
            shortTitle: "Start WatchMagic",
            systemImageName: "scope"
        )
    }
}
