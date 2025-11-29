import AppIntents
import Foundation

/// Intent to get aggregate card counts by status.
struct ProjectStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Project Status"
    static let description = IntentDescription("Get a summary of card counts by status in your Agency project")

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        guard let snapshot = AppIntentsProjectAccess.shared.snapshot else {
            throw IntentError.noProjectLoaded
        }

        var backlogCount = 0
        var inProgressCount = 0
        var doneCount = 0

        for phaseSnapshot in snapshot.phases {
            for card in phaseSnapshot.cards {
                switch card.status {
                case .backlog:
                    backlogCount += 1
                case .inProgress:
                    inProgressCount += 1
                case .done:
                    doneCount += 1
                }
            }
        }

        let total = backlogCount + inProgressCount + doneCount
        let summary = "\(total) cards: \(backlogCount) backlog, \(inProgressCount) in progress, \(doneCount) done"

        return .result(dialog: "\(summary)")
    }
}
