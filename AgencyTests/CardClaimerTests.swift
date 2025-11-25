import Foundation
import Testing
@testable import Agency

@MainActor
struct CardClaimerTests {
    @Test func previewReturnsLowestBacklogCard() async throws {
        let (rootURL, phaseSnapshots) = try makeSampleProject()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let snapshot = ProjectLoader.ProjectSnapshot(rootURL: rootURL,
                                                     phases: phaseSnapshots,
                                                     validationIssues: [])

        let claimer = CardClaimer()
        let candidate = try claimer.previewClaim(in: snapshot)

        #expect(candidate.code == "3.1")
        #expect(candidate.status == .backlog)
    }

    @Test func claimMovesCardAndUpdatesOwnerAndHistory() async throws {
        let fixedDate = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 1, day: 2))!
        let (rootURL, phaseSnapshots) = try makeProject(withLocked: false)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let snapshot = ProjectLoader.ProjectSnapshot(rootURL: rootURL,
                                                     phases: phaseSnapshots,
                                                     validationIssues: [])

        let claimer = CardClaimer(mover: CardMover(fileManager: .default, dateProvider: { fixedDate }),
                                  writer: CardMarkdownWriter(fileManager: .default),
                                  parser: CardFileParser(),
                                  dateProvider: { fixedDate },
                                  ownerProvider: { "default" })

        let claimed = try await claimer.claimLowestBacklog(in: snapshot,
                                                            preferredOwner: "sam",
                                                            dryRun: false)

        let backlogPath = rootURL
            .appendingPathComponent(ProjectConventions.projectRootName)
            .appendingPathComponent("phase-4-developer-utilities")
            .appendingPathComponent(CardStatus.backlog.folderName)
            .appendingPathComponent("4.1-claim.md")
            .path

        let inProgressURL = URL(fileURLWithPath: backlogPath.replacingOccurrences(of: "/backlog/", with: "/in-progress/"))

        #expect(!FileManager.default.fileExists(atPath: backlogPath))
        #expect(FileManager.default.fileExists(atPath: inProgressURL.path))
        #expect(claimed.status == .inProgress)
        #expect(claimed.frontmatter.owner == "sam")
        #expect(claimed.history.contains("2025-01-02 - Claimed by sam; moved to In Progress."))
    }

    @Test func dryRunDoesNotMoveCard() async throws {
        let (rootURL, phaseSnapshots) = try makeProject(withLocked: false)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let snapshot = ProjectLoader.ProjectSnapshot(rootURL: rootURL,
                                                     phases: phaseSnapshots,
                                                     validationIssues: [])

        let claimer = CardClaimer()
        let candidate = try await claimer.claimLowestBacklog(in: snapshot,
                                                              preferredOwner: nil,
                                                              dryRun: true)

        let backlogURL = candidate.filePath
        let inProgressURL = backlogURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(CardStatus.inProgress.folderName)
            .appendingPathComponent(backlogURL.lastPathComponent)

        #expect(FileManager.default.fileExists(atPath: backlogURL.path))
        #expect(!FileManager.default.fileExists(atPath: inProgressURL.path))
        #expect(candidate.status == .backlog)
    }

    @Test func refusesLockedCard() async throws {
        let (rootURL, phaseSnapshots) = try makeProject(withLocked: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let snapshot = ProjectLoader.ProjectSnapshot(rootURL: rootURL,
                                                     phases: phaseSnapshots,
                                                     validationIssues: [])

        let claimer = CardClaimer()

        do {
            _ = try await claimer.claimLowestBacklog(in: snapshot, preferredOwner: nil, dryRun: false)
            Issue.record("Expected claim to fail when card is locked.")
        } catch let error as CardClaimError {
            #expect(error == .cardLocked(status: "running"))
        }
    }

    @Test func previewHandlesThousandCardsUnderTargetTime() async throws {
        let phase = try Phase(path: URL(fileURLWithPath: "/tmp/phase-9-bulk"))
        var cards: [Card] = []

        for index in 1...1_000 {
            let minor = String(format: "%02d", index)
            let code = "9.\(minor)"
            let slug = "task-\(index)"
            let fileURL = URL(fileURLWithPath: "/tmp/phase-9-bulk/backlog/\(code)-\(slug).md")
            let frontmatter = CardFrontmatter(owner: nil,
                                               agentFlow: nil,
                                               agentStatus: "idle",
                                               branch: nil,
                                               risk: nil,
                                               review: nil,
                                               parallelizable: false,
                                               orderedFields: [])
            let card = Card(code: code,
                            slug: slug,
                            status: .backlog,
                            filePath: fileURL,
                            frontmatter: frontmatter,
                            sections: [],
                            title: nil,
                            summary: nil,
                            acceptanceCriteria: [],
                            notes: nil,
                            history: [])
            cards.append(card)
        }

        let snapshot = ProjectLoader.ProjectSnapshot(rootURL: URL(fileURLWithPath: "/tmp"),
                                                     phases: [PhaseSnapshot(phase: phase, cards: cards)],
                                                     validationIssues: [])

        let claimer = CardClaimer()
        let start = ContinuousClock().now
        let candidate = try claimer.previewClaim(in: snapshot)
        let duration = start.duration(to: ContinuousClock().now)

        #expect(candidate.code == "9.01")
        #expect(duration < .milliseconds(200))
    }

    private func makeSampleProject() throws -> (URL, [PhaseSnapshot]) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = root.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectRoot.appendingPathComponent("phase-3-sample", isDirectory: true)

        for status in CardStatus.allCases {
            try fileManager.createDirectory(at: phaseURL.appendingPathComponent(status.folderName, isDirectory: true),
                                            withIntermediateDirectories: true)
        }

        let backlogCardURL = phaseURL.appendingPathComponent("backlog/3.1-first.md")
        try cardMarkdown(code: "3.1", slug: "first", agentStatus: "idle", history: "2025-01-01 - Seeded").write(to: backlogCardURL, atomically: true, encoding: .utf8)

        let inProgressCardURL = phaseURL.appendingPathComponent("in-progress/3.2-active.md")
        try cardMarkdown(code: "3.2", slug: "active", agentStatus: "idle", history: "2025-01-01 - Seeded").write(to: inProgressCardURL, atomically: true, encoding: .utf8)

        let parser = CardFileParser()
        let backlogCard = try parser.parse(fileURL: backlogCardURL, contents: try String(contentsOf: backlogCardURL))
        let inProgressCard = try parser.parse(fileURL: inProgressCardURL, contents: try String(contentsOf: inProgressCardURL))
        let phase = try Phase(path: phaseURL)

        return (root, [PhaseSnapshot(phase: phase, cards: [backlogCard, inProgressCard])])
    }

    private func makeProject(withLocked locked: Bool) throws -> (URL, [PhaseSnapshot]) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = root.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectRoot.appendingPathComponent("phase-4-developer-utilities", isDirectory: true)

        for status in CardStatus.allCases {
            try fileManager.createDirectory(at: phaseURL.appendingPathComponent(status.folderName, isDirectory: true),
                                            withIntermediateDirectories: true)
        }

        let backlogURL = phaseURL.appendingPathComponent("backlog/4.1-claim.md")
        let agentStatus = locked ? "running" : "idle"
        try cardMarkdown(code: "4.1", slug: "claim", agentStatus: agentStatus, history: "2025-01-01 - Seeded").write(to: backlogURL, atomically: true, encoding: .utf8)

        let parser = CardFileParser()
        let backlogCard = try parser.parse(fileURL: backlogURL, contents: try String(contentsOf: backlogURL))
        let phase = try Phase(path: phaseURL)

        return (root, [PhaseSnapshot(phase: phase, cards: [backlogCard])])
    }

    private func cardMarkdown(code: String, slug: String, agentStatus: String, history: String) -> String {
        """
        ---
        owner: bri
        agent_status: \(agentStatus)
        branch: null
        risk: normal
        review: not-requested
        ---

        # \(code) \(slug)

        Summary:
        Short summary for \(slug).

        Acceptance Criteria:
        - [ ] first

        Notes:
        none

        History:
        - \(history)
        """
    }
}
