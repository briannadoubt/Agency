import AppIntents
import Foundation

/// Intent to create a new card in a phase's backlog.
struct CreateCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Card"
    static let description = IntentDescription("Create a new kanban card in a phase's backlog")

    @Parameter(title: "Phase", description: "The phase number to create the card in")
    var phaseNumber: Int

    @Parameter(title: "Title", description: "The title of the new card")
    var title: String

    @MainActor
    func perform() async throws -> some ReturnsValue<CardEntity> & ProvidesDialog {
        guard let snapshot = AppIntentsProjectAccess.shared.snapshot else {
            throw IntentError.noProjectLoaded
        }

        // Find the phase
        guard let phaseSnapshot = snapshot.phases.first(where: { $0.phase.number == phaseNumber }) else {
            throw IntentError.operationFailed("Phase \(phaseNumber) not found")
        }

        // Create the card
        let result = await AppIntentsProjectAccess.shared.createCard(in: phaseSnapshot, title: title)

        switch result {
        case .success(let card):
            let entity = CardEntity(card: card, phase: phaseSnapshot.phase)
            return .result(value: entity, dialog: "Created card \(card.code) in phase \(phaseNumber)")
        case .failure(let error):
            throw IntentError.operationFailed(error.localizedDescription)
        }
    }
}
