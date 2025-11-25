import Foundation

enum CardOwnerFilter: Hashable {
    case any
    case owner(String)
    case unassigned
}

struct CardSearchFilter {
    var query: String = ""
    var ownerFilter: CardOwnerFilter = .any

    func filter(_ cards: [Card]) -> [Card] {
        guard !query.isEmpty || ownerFilter != .any else { return cards }
        return cards.filter(matches)
    }

    private func matches(_ card: Card) -> Bool {
        guard ownerMatches(card) else { return false }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }

        let loweredQuery = trimmedQuery.lowercased()

        if card.code.lowercased().contains(loweredQuery) { return true }
        if card.slug.lowercased().contains(loweredQuery) { return true }

        if let title = card.title?.localizedLowercasedContains(loweredQuery) { if title { return true } }
        if let summary = card.summary?.localizedLowercasedContains(loweredQuery) { if summary { return true } }
        if let notes = card.notes?.localizedLowercasedContains(loweredQuery) { if notes { return true } }

        return false
    }

    private func ownerMatches(_ card: Card) -> Bool {
        switch ownerFilter {
        case .any:
            return true
        case .unassigned:
            return (card.frontmatter.owner?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case .owner(let name):
            guard let ownerRaw = card.frontmatter.owner else { return false }
            let owner = ownerRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            return owner.caseInsensitiveCompare(name) == .orderedSame
        }
    }
}

private extension String {
    func localizedLowercasedContains(_ query: String) -> Bool {
        localizedCaseInsensitiveContains(query)
    }
}
