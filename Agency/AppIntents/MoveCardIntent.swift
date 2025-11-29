import AppIntents
import Foundation

/// Intent to move a card to a different status.
struct MoveCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Move Card"
    static let description = IntentDescription("Move a kanban card to a different status")

    @Parameter(title: "Card", description: "The card to move")
    var card: CardEntity

    @Parameter(title: "Status", description: "The target status")
    var targetStatus: CardStatusAppEnum

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        guard let snapshot = AppIntentsProjectAccess.shared.snapshot else {
            throw IntentError.noProjectLoaded
        }

        // Find the actual Card object from the snapshot
        var foundCard: Card?
        var foundPhase: Phase?

        for phaseSnapshot in snapshot.phases {
            for c in phaseSnapshot.cards {
                if c.filePath.path == card.id {
                    foundCard = c
                    foundPhase = phaseSnapshot.phase
                    break
                }
            }
            if foundCard != nil { break }
        }

        guard let cardToMove = foundCard, let _ = foundPhase else {
            throw IntentError.cardNotFound(card.code)
        }

        // Validate transition
        let currentStatus = cardToMove.status
        let newStatus = targetStatus.toCardStatus

        guard currentStatus.canTransition(to: newStatus) else {
            throw IntentError.invalidTransition("Cannot move from \(currentStatus.displayName) to \(newStatus.displayName)")
        }

        // Perform the move
        let result = await AppIntentsProjectAccess.shared.moveCard(cardToMove, to: newStatus)

        switch result {
        case .success:
            return .result(dialog: "Moved \(card.code) to \(newStatus.displayName)")
        case .failure(let error):
            throw IntentError.operationFailed(error.localizedDescription)
        }
    }
}
