import Foundation

/// Generates normalized branch names and applies them to card frontmatter while preserving ordering.
@MainActor
final class BranchHelper {
    private let writer: CardMarkdownWriter
    private let dateProvider: () -> Date

    init(writer: CardMarkdownWriter = CardMarkdownWriter(),
         dateProvider: @escaping () -> Date = Date.init) {
        self.writer = writer
        self.dateProvider = dateProvider
    }

    /// Builds the recommended branch name for a card using the provided prefix.
    /// - Parameters:
    ///   - card: Target card (uses its code and slug).
    ///   - prefix: Optional prefix such as "implement" or "review". Falls back to "implement" when empty.
    func recommendedBranch(for card: Card, prefix: String?) -> String {
        let normalizedPrefix = BranchHelper.normalizeSegment(prefix, fallback: "implement")
        let normalizedSlug = BranchHelper.normalizeSlug(card.slug)
        return "\(normalizedPrefix)/\(card.code)-\(normalizedSlug)"
    }

    /// Renders a ready-to-run checkout command for the given branch.
    func checkoutCommand(for branch: String) -> String {
        "git checkout -b \(branch)"
    }

    /// Writes the recommended branch to frontmatter, appending a history entry when the value changes.
    /// Existing frontmatter ordering is preserved.
    func applyBranch(to card: Card, prefix: String?) throws -> CardDocumentSnapshot {
        let snapshot = try writer.loadSnapshot(for: card)
        let branch = recommendedBranch(for: snapshot.card, prefix: prefix)

        let existing = snapshot.card.frontmatter.branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing != branch else { return snapshot }

        var draft = CardDetailFormDraft.from(card: snapshot.card, today: dateProvider())
        draft.branch = branch
        draft.newHistoryEntry = BranchHelper.historyEntry(branch: branch, date: dateProvider())

        return try writer.saveFormDraft(draft, appendHistory: true, snapshot: snapshot)
    }

    static func historyEntry(branch: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: date)) - Branch set to \(branch)."
    }

    static func normalizeSlug(_ slug: String) -> String {
        sanitize(slug, fallback: "card")
    }

    static func normalizeSegment(_ raw: String?, fallback: String = "implement") -> String {
        sanitize(raw ?? "", fallback: fallback)
    }

    private static func sanitize(_ raw: String, fallback: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { character -> Character in
            if character.isLetter || character.isNumber || character == "." || character == "-" {
                return character
            }
            return "-"
        }

        var output = String(mapped)
        while output.contains("--") {
            output = output.replacingOccurrences(of: "--", with: "-")
        }

        output = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if output.isEmpty {
            return fallback
        }

        return output
    }
}
