import Foundation
import Testing
@testable import Agency

@MainActor
struct ModelsTests {

    @Test func phaseParsesFromDirectoryName() throws {
        let path = URL(fileURLWithPath: "/tmp/project/phase-2-execution", isDirectory: true)

        let phase = try Phase(path: path)

        #expect(phase.number == 2)
        #expect(phase.label == "execution")
        #expect(phase.path == path)
    }

    @Test func cardParsingCapturesMetadataAndSections() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/project/phase-0-setup/in-progress/0.2-models.md")
        let contents = """
        ---
        owner: bri
        agent_flow: solo
        agent_status: in-progress
        branch: implement/models
        risk: normal
        review: not-requested
        parallelizable: true
        ---

        # 0.2 Models

        Summary:
        Define conceptual models for phases and cards used by the kanban app.

        Acceptance Criteria:
        - [ ] Phase model includes number, label, and path
        - [ ] Card model includes code, slug, status (from folder), and file path

        Notes:
        - Treat filename prefix `<phase>.<task>` as the card code.

        History:
        - 2025-11-22: Card created by agent.
        """

        let card = try CardFileParser().parse(fileURL: fileURL, contents: contents)

        #expect(card.code == "0.2")
        #expect(card.slug == "models")
        #expect(card.status == .inProgress)
        #expect(card.filePath == fileURL)

        #expect(card.frontmatter.owner == "bri")
        #expect(card.frontmatter.agentFlow == "solo")
        #expect(card.frontmatter.agentStatus == "in-progress")
        #expect(card.frontmatter.branch == "implement/models")
        #expect(card.frontmatter.risk == "normal")
        #expect(card.frontmatter.review == "not-requested")
        #expect(card.frontmatter.parallelizable == true)
        #expect(card.frontmatter.orderedFields.map(\.key) == [
            "owner",
            "agent_flow",
            "agent_status",
            "branch",
            "risk",
            "review",
            "parallelizable"
        ])

        #expect(card.title == "0.2 Models")
        #expect(card.summary == "Define conceptual models for phases and cards used by the kanban app.")
        #expect(card.acceptanceCriteria.count == 2)
        #expect(card.acceptanceCriteria.first?.title.contains("Phase model") == true)
        #expect(card.acceptanceCriteria.allSatisfy { $0.isComplete == false })
        #expect(card.notes?.contains("card code") == true)
        #expect(card.history.first == "2025-11-22: Card created by agent.")
        #expect(card.section(named: "Summary")?.content.contains("conceptual models") == true)
        #expect(card.section(named: "Acceptance Criteria")?.content.contains("Phase model") == true)
        #expect(card.sections.last?.title == "History")
    }

    @Test func parallelizableDefaultsToNilWhenMissing() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/project/phase-1-planning/backlog/1.1-roadmap.md")
        let contents = """
        ---
        owner: bri
        agent_flow: paired
        agent_status: idle
        branch: null
        risk: elevated
        review: requested
        ---

        Summary:
        Capture roadmap milestones.
        """

        let card = try CardFileParser().parse(fileURL: fileURL, contents: contents)

        #expect(card.status == .backlog)
        #expect(card.frontmatter.parallelizable == nil)
        #expect(card.section(named: "Summary")?.content == "Capture roadmap milestones.")
        #expect(card.acceptanceCriteria.isEmpty)
    }

    @Test func acceptanceCriteriaCheckboxesAreCaptured() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/project/phase-2/product/backlog/2.1-launch.md")
        let contents = """
        ---
        owner: bri
        ---

        # 2.1 Launch

        Acceptance Criteria:
        - [ ] Unchecked item
        - [x] Completed item
        - [X] Uppercase completed item
        """

        let card = try CardFileParser().parse(fileURL: fileURL, contents: contents)

        #expect(card.acceptanceCriteria.count == 3)
        #expect(card.acceptanceCriteria[0].isComplete == false)
        #expect(card.acceptanceCriteria[1].isComplete == true)
        #expect(card.acceptanceCriteria[2].isComplete == true)
    }

    @Test func parsesCardsWithoutFrontmatter() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/project/phase-3-editing/backlog/3.4-frontmatterless.md")
        let contents = """
        # 3.4 Frontmatterless

        Summary:
        No frontmatter block yet.

        Acceptance Criteria:
        - [ ] Add frontmatter support
        """

        let card = try CardFileParser().parse(fileURL: fileURL, contents: contents)

        #expect(card.frontmatter.orderedFields.isEmpty)
        #expect(card.frontmatter.owner == nil)
        #expect(card.title == "3.4 Frontmatterless")
        #expect(card.section(named: "Summary")?.content == "No frontmatter block yet.")
        #expect(card.acceptanceCriteria.count == 1)
    }
}
