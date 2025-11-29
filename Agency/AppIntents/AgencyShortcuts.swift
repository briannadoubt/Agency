import AppIntents

/// Provides App Shortcuts for Agency, making intents available via Siri and Shortcuts.
struct AgencyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListCardsIntent(),
            phrases: [
                "List cards in \(.applicationName)",
                "Show my \(.applicationName) cards",
                "What cards are in \(.applicationName)"
            ],
            shortTitle: "List Cards",
            systemImageName: "list.bullet.rectangle"
        )
    }
}
