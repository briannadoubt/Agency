import AppIntents
import Foundation

/// Intent to open a specific card in the Agency app.
struct OpenCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Card"
    static let description = IntentDescription("Open a specific card in Agency")
    static let openAppWhenRun = true

    @Parameter(title: "Card", description: "The card to open")
    var card: CardEntity

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        guard AppIntentsProjectAccess.shared.isProjectLoaded else {
            throw IntentError.noProjectLoaded
        }

        // Request navigation to the card
        AppIntentsProjectAccess.shared.requestNavigation(toCardPath: card.id)

        return .result(dialog: "Opening \(card.code) \(card.title)")
    }
}
