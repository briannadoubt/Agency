import AppIntents
import Foundation

/// Intent to list cards, optionally filtered by status and/or phase.
struct ListCardsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Cards"
    static let description = IntentDescription("List kanban cards from your Agency project")

    @Parameter(title: "Status", description: "Filter cards by status")
    var status: CardStatusAppEnum?

    @Parameter(title: "Phase", description: "Filter cards by phase number")
    var phaseNumber: Int?

    @MainActor
    func perform() async throws -> some ReturnsValue<[CardEntity]> & ProvidesDialog {
        guard let snapshot = AppIntentsProjectAccess.shared.snapshot else {
            throw IntentError.noProjectLoaded
        }

        var cards: [CardEntity] = []

        for phaseSnapshot in snapshot.phases {
            // Filter by phase if specified
            if let filterPhase = phaseNumber, phaseSnapshot.phase.number != filterPhase {
                continue
            }

            for card in phaseSnapshot.cards {
                // Filter by status if specified
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
        var filterText = ""
        if let s = status {
            filterText += " in \(s.rawValue)"
        }
        if let p = phaseNumber {
            filterText += " from phase \(p)"
        }

        return .result(
            value: cards,
            dialog: "Found \(countText)\(filterText)"
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
