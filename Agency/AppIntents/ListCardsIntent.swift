import AppIntents
import Foundation

/// Intent to list cards, optionally filtered by status.
struct ListCardsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Cards"
    static let description = IntentDescription("List kanban cards from your Agency project")

    @Parameter(title: "Status", description: "Filter cards by status")
    var status: CardStatusAppEnum?

    @MainActor
    func perform() async throws -> some ReturnsValue<[CardEntity]> & ProvidesDialog {
        guard let snapshot = AppIntentsProjectAccess.shared.snapshot else {
            throw IntentError.noProjectLoaded
        }

        var cards: [CardEntity] = []

        for phaseSnapshot in snapshot.phases {
            for card in phaseSnapshot.cards {
                if let filterStatus = status {
                    if CardStatusAppEnum(from: card.status) == filterStatus {
                        cards.append(CardEntity(card: card, phase: phaseSnapshot.phase))
                    }
                } else {
                    cards.append(CardEntity(card: card, phase: phaseSnapshot.phase))
                }
            }
        }

        let countText = cards.count == 1 ? "1 card" : "\(cards.count) cards"
        let statusText = status.map { " in \($0.rawValue)" } ?? ""

        return .result(
            value: cards,
            dialog: "Found \(countText)\(statusText)"
        )
    }
}

/// Errors that can occur during intent execution.
enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noProjectLoaded
    case cardNotFound(String)
    case invalidTransition(String)
    case operationFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noProjectLoaded:
            return "No project is currently loaded in Agency"
        case .cardNotFound(let code):
            return "Card '\(code)' not found"
        case .invalidTransition(let message):
            return "Invalid status transition: \(message)"
        case .operationFailed(let message):
            return "Operation failed: \(message)"
        }
    }
}
