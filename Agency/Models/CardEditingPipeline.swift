import Foundation

@MainActor
final class CardEditingPipeline {
    static let shared = CardEditingPipeline()

    private let writer: CardMarkdownWriter

    init(writer: CardMarkdownWriter = CardMarkdownWriter()) {
        self.writer = writer
    }

    func loadSnapshot(for card: Card) throws -> CardDocumentSnapshot {
        try writer.loadSnapshot(for: card)
    }

    func saveFormDraft(_ draft: CardDetailFormDraft,
                       appendHistory: Bool,
                       snapshot: CardDocumentSnapshot) throws -> CardDocumentSnapshot {
        try writer.saveFormDraft(draft, appendHistory: appendHistory, snapshot: snapshot)
    }

    func saveRaw(_ raw: String, snapshot: CardDocumentSnapshot) throws -> CardDocumentSnapshot {
        try writer.saveRaw(raw, snapshot: snapshot)
    }

    func toggleAcceptanceCriterion(for card: Card, index: Int) throws -> CardDocumentSnapshot {
        let snapshot = try loadSnapshot(for: card)
        var draft = CardDetailFormDraft.from(card: snapshot.card)

        guard draft.criteria.indices.contains(index) else {
            throw CardSaveError.parseFailed("Acceptance criterion index out of range")
        }

        draft.criteria[index].isComplete.toggle()
        return try saveFormDraft(draft, appendHistory: true, snapshot: snapshot)
    }
}
