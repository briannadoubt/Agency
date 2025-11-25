import Foundation
import Testing
@testable import Agency

struct CardCreatorTests {
    @MainActor
    @Test func createsPaddedCodeAndSlug() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectURL.appendingPathComponent("phase-3-editing", isDirectory: true)
        try makePhaseDirectories(at: phaseURL, fileManager: fileManager)

        let backlogURL = phaseURL.appendingPathComponent("backlog/3.01-existing.md")
        let doneURL = phaseURL.appendingPathComponent("done/3.02-finished.md")

        try sampleCard(code: "3.01", slug: "existing").write(to: backlogURL, atomically: true, encoding: .utf8)
        try sampleCard(code: "3.02", slug: "finished").write(to: doneURL, atomically: true, encoding: .utf8)

        let parser = CardFileParser()
        let cards = try [
            parser.parse(fileURL: backlogURL, contents: String(contentsOf: backlogURL)),
            parser.parse(fileURL: doneURL, contents: String(contentsOf: doneURL))
        ]
        let phase = try Phase(path: phaseURL)
        let snapshot = PhaseSnapshot(phase: phase, cards: cards)

        let fixedDate = ISO8601DateFormatter().date(from: "2025-11-25T12:00:00Z")!
        let creator = CardCreator(dateProvider: { fixedDate })

        let created = try await creator.createCard(in: snapshot,
                                                   title: "Launch API MVP!",
                                                   includeHistoryEntry: true)

        #expect(created.code == "3.03")
        #expect(created.slug == "launch-api-mvp")
        #expect(created.status == .backlog)

        let newFile = phaseURL.appendingPathComponent("backlog/3.03-launch-api-mvp.md")
        #expect(fileManager.fileExists(atPath: newFile.path))

        let contents = try String(contentsOf: newFile, encoding: .utf8)
        #expect(contents.contains("# 3.03 Launch API MVP!"))
        #expect(contents.contains("- 2025-11-25: Card created in Agency."))
    }

    @MainActor
    @Test func rejectsDuplicateFilenameAcrossStatuses() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectURL.appendingPathComponent("phase-3-editing", isDirectory: true)
        try makePhaseDirectories(at: phaseURL, fileManager: fileManager)

        let existing = phaseURL.appendingPathComponent("backlog/3.1-same-task.md")
        try sampleCard(code: "3.1", slug: "same-task").write(to: existing, atomically: true, encoding: .utf8)

        let phase = try Phase(path: phaseURL)
        let snapshot = PhaseSnapshot(phase: phase, cards: [])
        let creator = CardCreator()

        do {
            _ = try await creator.createCard(in: snapshot,
                                             title: "Same Task",
                                             includeHistoryEntry: false)
            Issue.record("Expected duplicate detection to throw.")
        } catch let error as CardCreationError {
            #expect(error == .duplicateFilename("3.1-same-task.md"))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @MainActor
    @Test func omitsHistoryWhenRequested() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectURL.appendingPathComponent("phase-2-import", isDirectory: true)
        try makePhaseDirectories(at: phaseURL, fileManager: fileManager)

        let phase = try Phase(path: phaseURL)
        let snapshot = PhaseSnapshot(phase: phase, cards: [])
        let creator = CardCreator()

        let card = try await creator.createCard(in: snapshot,
                                                title: "Plain Card",
                                                includeHistoryEntry: false)

        let fileURL = phaseURL.appendingPathComponent("backlog/\(card.code)-\(card.slug).md")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)

        #expect(!contents.contains("Card created in Agency."))
        #expect(card.history.isEmpty)
    }

    // MARK: - Helpers

    @MainActor
    private func makePhaseDirectories(at url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        for status in CardStatus.allCases {
            try fileManager.createDirectory(at: url.appendingPathComponent(status.folderName, isDirectory: true),
                                            withIntermediateDirectories: true)
        }
    }

    private func sampleCard(code: String, slug: String) -> String {
        """
        ---
        owner: tester
        ---

        # \(code) \(slug.replacingOccurrences(of: "-", with: " ").capitalized)

        Summary:
        Seed card for tests.

        Acceptance Criteria:
        - [ ] First

        Notes:

        Alignment:

        History:
        - 2025-11-20: Seeded for tests.
        """
    }
}
