import Foundation
import Testing
@testable import Agency

@MainActor
struct CardPresentationTests {

    @Test func mapsRiskAndCountsFromCard() {
        let card = makeCard(risk: "high", parallelizable: true, criteria: [true, false, true])
        let presentation = CardPresentation(card: card)

        #expect(presentation.riskLevel == .high)
        #expect(presentation.completedCriteria == 2)
        #expect(presentation.totalCriteria == 3)
        #expect(presentation.parallelizable)
        #expect(presentation.owner == "owner")
        #expect(presentation.branch == "feature/branch")
    }

    @Test func defaultsRiskToMedium() {
        let card = makeCard(risk: nil, criteria: [])
        let presentation = CardPresentation(card: card)

        #expect(presentation.riskLevel == .medium)
        #expect(presentation.totalCriteria == 0)
    }

    private func makeCard(risk: String?, parallelizable: Bool = false, criteria: [Bool]) -> Card {
        let frontmatter = CardFrontmatter(owner: "owner",
                                          agentFlow: nil,
                                          agentStatus: "idle",
                                          branch: "feature/branch",
                                          risk: risk,
                                          review: nil,
                                          parallelizable: parallelizable,
                                          orderedFields: [])

        let acceptance = criteria.enumerated().map { index, isDone in
            AcceptanceCriterion(title: "criterion-\(index)", isComplete: isDone)
        }

        return Card(code: "1.1",
                    slug: "test",
                    status: .backlog,
                    filePath: URL(fileURLWithPath: "/tmp/1.1-test.md"),
                    frontmatter: frontmatter,
                    sections: [],
                    title: "Sample",
                    summary: "Summary text",
                    acceptanceCriteria: acceptance,
                    notes: nil,
                    history: [])
    }
}
