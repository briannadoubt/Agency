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

        AppShortcut(
            intent: ProjectStatusIntent(),
            phrases: [
                "Project status in \(.applicationName)",
                "How many cards in \(.applicationName)",
                "What's my \(.applicationName) status"
            ],
            shortTitle: "Project Status",
            systemImageName: "chart.bar"
        )

        AppShortcut(
            intent: MoveCardIntent(),
            phrases: [
                "Move card in \(.applicationName)",
                "Change card status in \(.applicationName)"
            ],
            shortTitle: "Move Card",
            systemImageName: "arrow.right.square"
        )

        AppShortcut(
            intent: CreateCardIntent(),
            phrases: [
                "Create card in \(.applicationName)",
                "Add card to \(.applicationName)",
                "New card in \(.applicationName)"
            ],
            shortTitle: "Create Card",
            systemImageName: "plus.rectangle"
        )

        AppShortcut(
            intent: OpenCardIntent(),
            phrases: [
                "Open card in \(.applicationName)",
                "Show card in \(.applicationName)",
                "View card in \(.applicationName)"
            ],
            shortTitle: "Open Card",
            systemImageName: "doc.text"
        )
    }
}
