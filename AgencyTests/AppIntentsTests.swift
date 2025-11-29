import Foundation
import Testing
@testable import Agency

struct AppIntentsTests {

    // MARK: - CardEntity Tests

    @MainActor
    @Test func cardEntityInitializesFromCard() async throws {
        let phase = try Phase(path: URL(fileURLWithPath: "/project/phase-1-test"))
        let card = Card(
            code: "1.1",
            slug: "test-card",
            status: .inProgress,
            filePath: URL(fileURLWithPath: "/project/phase-1-test/in-progress/1.1-test-card.md"),
            frontmatter: CardFrontmatter(),
            sections: [],
            title: "Test Card",
            summary: "A test card summary",
            acceptanceCriteria: [],
            notes: nil,
            history: []
        )

        let entity = CardEntity(card: card, phase: phase)

        #expect(entity.code == "1.1")
        #expect(entity.title == "Test Card")
        #expect(entity.status == .inProgress)
        #expect(entity.phaseNumber == 1)
        #expect(entity.phaseLabel == "test")
        #expect(entity.summary == "A test card summary")
    }

    @MainActor
    @Test func cardEntityUsesSlugWhenTitleMissing() async throws {
        let phase = try Phase(path: URL(fileURLWithPath: "/project/phase-2-demo"))
        let card = Card(
            code: "2.1",
            slug: "no-title",
            status: .backlog,
            filePath: URL(fileURLWithPath: "/project/phase-2-demo/backlog/2.1-no-title.md"),
            frontmatter: CardFrontmatter(),
            sections: [],
            title: nil,
            summary: nil,
            acceptanceCriteria: [],
            notes: nil,
            history: []
        )

        let entity = CardEntity(card: card, phase: phase)

        #expect(entity.title == "no-title")
    }

    // MARK: - CardStatusAppEnum Tests

    @Test func cardStatusAppEnumConvertsFromCardStatus() {
        #expect(CardStatusAppEnum(from: .backlog) == .backlog)
        #expect(CardStatusAppEnum(from: .inProgress) == .inProgress)
        #expect(CardStatusAppEnum(from: .done) == .done)
    }

    @Test func cardStatusAppEnumConvertsToCardStatus() {
        #expect(CardStatusAppEnum.backlog.toCardStatus == .backlog)
        #expect(CardStatusAppEnum.inProgress.toCardStatus == .inProgress)
        #expect(CardStatusAppEnum.done.toCardStatus == .done)
    }

    // MARK: - CardEntityQuery Tests

    @MainActor
    @Test func cardEntityQueryReturnsEmptyWhenNoProject() async throws {
        // Ensure no project is registered
        AppIntentsProjectAccess.shared.register(ProjectLoader())

        let query = CardEntityQuery()
        let results = try await query.entities(for: ["/some/path"])

        #expect(results.isEmpty)
    }

    @MainActor
    @Test func cardEntityQuerySearchMatchesTitle() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        // Set up a minimal project structure
        let projectURL = tempRoot.appendingPathComponent("project", isDirectory: true)
        let phaseURL = projectURL.appendingPathComponent("phase-1-test", isDirectory: true)

        for status in CardStatus.allCases {
            let statusURL = phaseURL.appendingPathComponent(status.folderName, isDirectory: true)
            try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)
        }

        // Create a card with a searchable title
        let cardURL = phaseURL.appendingPathComponent("backlog/1.1-authentication.md")
        let cardContent = """
        ---
        owner: test
        ---

        # 1.1 User Authentication

        Summary:
        Implement user authentication flow.

        Acceptance Criteria:
        - [ ] Login works

        History:
        - 2025-01-01: Created.
        """
        try cardContent.write(to: cardURL, atomically: true, encoding: .utf8)

        // Create ROADMAP.md to pass validation
        let roadmapContent = """
        ---
        roadmap_version: 1
        project_goal: Test
        ---

        # Roadmap

        Summary:
        Test roadmap.

        Phase Overview:
        - Phase 1 — test (planned)

        ## Phase 1 — test (planned)

        Summary:
        Test phase.

        Tasks:
        - [ ] 1.1 User Authentication — Implement user authentication flow.
          - Status: backlog

        Roadmap (machine readable):
        ```json
        {"version":1,"projectGoal":"Test","phases":[{"number":1,"label":"test","status":"planned","tasks":[{"code":"1.1","title":"User Authentication","summary":"Implement user authentication flow.","status":"backlog"}]}]}
        ```
        """
        try roadmapContent.write(to: tempRoot.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)

        // Create ARCHITECTURE.md
        let archContent = """
        ---
        architecture_version: 1
        roadmap_fingerprint: abc123
        ---

        # ARCHITECTURE.md

        Summary:
        Test architecture.
        """
        try archContent.write(to: tempRoot.appendingPathComponent("ARCHITECTURE.md"), atomically: true, encoding: .utf8)

        // Load the project
        let loader = ProjectLoader()
        loader.loadProject(at: tempRoot)

        // Wait for loading
        try await Task.sleep(for: .milliseconds(100))

        // Register with AppIntents
        AppIntentsProjectAccess.shared.register(loader)

        let query = CardEntityQuery()

        // Search for "auth" should find the card
        let authResults = try await query.entities(matching: "auth")
        #expect(authResults.count == 1)
        #expect(authResults.first?.code == "1.1")

        // Search for "xyz" should find nothing
        let noResults = try await query.entities(matching: "xyz")
        #expect(noResults.isEmpty)
    }
}
