import Foundation
import Testing
@testable import Agency

@MainActor
struct CardSearchFilterTests {

    @Test func filtersByPartialCode() async throws {
        let cards = [
            makeCard(code: "4.4", slug: "search", owner: "bri", title: "Search cards"),
            makeCard(code: "2.1", slug: "other", owner: "sam", title: "Other work")
        ]

        let filtered = CardSearchFilter(query: "4.").filter(cards)

        #expect(filtered.count == 1)
        #expect(filtered.first?.code == "4.4")
    }

    @Test func filtersByOwnerFrontmatter() async throws {
        let cards = [
            makeCard(code: "1.1", slug: "alpha", owner: "alex"),
            makeCard(code: "1.2", slug: "bravo", owner: "sam"),
            makeCard(code: "1.3", slug: "charlie", owner: nil),
            makeCard(code: "1.4", slug: "whitespace", owner: " bri ")
        ]

        let ownerFiltered = CardSearchFilter(query: "", ownerFilter: .owner("alex")).filter(cards)
        #expect(ownerFiltered.map(\.code) == ["1.1"])

        let unassigned = CardSearchFilter(query: "", ownerFilter: .unassigned).filter(cards)
        #expect(unassigned.map(\.code) == ["1.3"])

        let trimmed = CardSearchFilter(query: "", ownerFilter: .owner("bri")).filter(cards)
        #expect(trimmed.map(\.code) == ["1.4"])
    }

    @Test func matchesTitleSummaryAndNotes() async throws {
        let cards = [
            makeCard(code: "3.1", slug: "notes", owner: "dee", title: "Title", summary: "Offline capability", notes: "Search should work offline."),
            makeCard(code: "3.2", slug: "other", owner: "dee", title: "Another", summary: "Unrelated")
        ]

        let filteredBySummary = CardSearchFilter(query: "offline").filter(cards)
        #expect(filteredBySummary.map(\.code) == ["3.1"])
    }

    private func makeCard(code: String,
                         slug: String,
                         status: CardStatus = .backlog,
                         owner: String?,
                         title: String? = nil,
                         summary: String? = nil,
                         notes: String? = nil) -> Card {
        let frontmatter = CardFrontmatter(owner: owner, orderedFields: [])
        return Card(code: code,
                    slug: slug,
                    status: status,
                    filePath: URL(fileURLWithPath: "/tmp/\(code)-\(slug).md"),
                    frontmatter: frontmatter,
                    sections: [],
                    title: title,
                    summary: summary,
                    acceptanceCriteria: [],
                    notes: notes,
                    history: [])
    }
}
