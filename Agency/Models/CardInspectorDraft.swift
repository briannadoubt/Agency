import Foundation

struct CardInspectorDraft: Equatable {
    struct CriterionDraft: Identifiable, Equatable {
        let id: UUID
        var title: String
        var isComplete: Bool

        init(id: UUID = UUID(), title: String, isComplete: Bool) {
            self.id = id
            self.title = title
            self.isComplete = isComplete
        }
    }

    var title: String
    var summary: String
    var notes: String
    var acceptanceCriteria: [CriterionDraft]

    static let empty = CardInspectorDraft(title: "",
                                          summary: "",
                                          notes: "",
                                          acceptanceCriteria: [])

    init(title: String, summary: String, notes: String, acceptanceCriteria: [CriterionDraft]) {
        self.title = title
        self.summary = summary
        self.notes = notes
        self.acceptanceCriteria = acceptanceCriteria
    }

    init(card: Card) {
        self.init(title: card.title ?? "",
                  summary: card.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                  notes: card.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                  acceptanceCriteria: card.acceptanceCriteria.map { CriterionDraft(title: $0.title, isComplete: $0.isComplete) })
    }
}
