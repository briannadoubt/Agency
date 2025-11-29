import AppIntents
import Foundation

/// AppEntity representing a kanban card for Shortcuts and Siri integration.
struct CardEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Card")
    }

    static let defaultQuery = CardEntityQuery()

    var id: String
    var code: String
    var title: String
    var status: CardStatusAppEnum
    var phaseNumber: Int
    var phaseLabel: String
    var summary: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(code) \(title)",
            subtitle: "\(status.localizedStringResource) - Phase \(phaseNumber)"
        )
    }

    init(id: String, code: String, title: String, status: CardStatusAppEnum, phaseNumber: Int, phaseLabel: String, summary: String?) {
        self.id = id
        self.code = code
        self.title = title
        self.status = status
        self.phaseNumber = phaseNumber
        self.phaseLabel = phaseLabel
        self.summary = summary
    }

    init(card: Card, phase: Phase) {
        self.id = card.filePath.path
        self.code = card.code
        self.title = card.title ?? card.slug
        self.status = CardStatusAppEnum(from: card.status)
        self.phaseNumber = phase.number
        self.phaseLabel = phase.label
        self.summary = card.summary
    }
}

/// AppEnum for card status to use in intent parameters.
enum CardStatusAppEnum: String, AppEnum {
    case backlog
    case inProgress
    case done

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Card Status")
    }

    static var caseDisplayRepresentations: [CardStatusAppEnum: DisplayRepresentation] {
        [
            .backlog: DisplayRepresentation(title: "Backlog"),
            .inProgress: DisplayRepresentation(title: "In Progress"),
            .done: DisplayRepresentation(title: "Done")
        ]
    }

    init(from status: CardStatus) {
        switch status {
        case .backlog:
            self = .backlog
        case .inProgress:
            self = .inProgress
        case .done:
            self = .done
        }
    }

    var toCardStatus: CardStatus {
        switch self {
        case .backlog:
            return .backlog
        case .inProgress:
            return .inProgress
        case .done:
            return .done
        }
    }
}

/// Query for finding cards by ID or searching by string.
struct CardEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [CardEntity] {
        guard let snapshot = AppIntentsProjectAccess.shared.snapshot else {
            return []
        }

        var results: [CardEntity] = []
        for phaseSnapshot in snapshot.phases {
            for card in phaseSnapshot.cards {
                if identifiers.contains(card.filePath.path) {
                    results.append(CardEntity(card: card, phase: phaseSnapshot.phase))
                }
            }
        }
        return results
    }

    /// Search cards by string matching against code, title, or summary.
    @MainActor
    func entities(matching string: String) async throws -> [CardEntity] {
        guard let snapshot = AppIntentsProjectAccess.shared.snapshot else {
            return []
        }

        let searchTerm = string.lowercased()
        var results: [CardEntity] = []

        for phaseSnapshot in snapshot.phases {
            for card in phaseSnapshot.cards {
                let matchesCode = card.code.lowercased().contains(searchTerm)
                let matchesTitle = (card.title ?? card.slug).lowercased().contains(searchTerm)
                let matchesSummary = card.summary?.lowercased().contains(searchTerm) ?? false

                if matchesCode || matchesTitle || matchesSummary {
                    results.append(CardEntity(card: card, phase: phaseSnapshot.phase))
                }
            }
        }
        return results
    }

    @MainActor
    func suggestedEntities() async throws -> [CardEntity] {
        guard let snapshot = AppIntentsProjectAccess.shared.snapshot else {
            return []
        }

        var results: [CardEntity] = []
        for phaseSnapshot in snapshot.phases {
            for card in phaseSnapshot.cards {
                results.append(CardEntity(card: card, phase: phaseSnapshot.phase))
            }
        }
        return results
    }
}
