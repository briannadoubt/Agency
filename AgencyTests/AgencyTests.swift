//
//  AgencyTests.swift
//  AgencyTests
//
//  Created by Brianna Zamora on 11/21/25.
//

import Foundation
import Testing
@testable import Agency

struct AgencyTests {

    @MainActor
    @Test func watcherRefreshesWhenNewPhaseAppears() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let initialPhaseURL = projectURL.appendingPathComponent("phase-0-seed", isDirectory: true)

        try makePhaseDirectories(at: initialPhaseURL, fileManager: fileManager)

        let seedCardURL = initialPhaseURL.appendingPathComponent("backlog/0.1-seed.md")
        try cardContents(code: "0.1", slug: "seed").write(to: seedCardURL, atomically: true, encoding: .utf8)

        let watcher = ProjectScannerWatcher(scanner: ProjectScanner())
        var iterator = watcher.watch(rootURL: tempRoot, debounce: .milliseconds(50)).makeAsyncIterator()

        let firstResult = await iterator.next()
        #expect(firstResult != nil)

        if case .success(let initialSnapshots)? = firstResult {
            #expect(initialSnapshots.count == 1)
            #expect(initialSnapshots.first?.phase.number == 0)
        }

        let newPhaseURL = projectURL.appendingPathComponent("phase-1-fresh", isDirectory: true)
        try makePhaseDirectories(at: newPhaseURL, fileManager: fileManager)

        // Allow the watcher to attach to the new phase directories before writing a card.
        try await Task.sleep(for: .milliseconds(150))

        let newCardURL = newPhaseURL.appendingPathComponent("backlog/1.1-fresh.md")
        try cardContents(code: "1.1", slug: "fresh").write(to: newCardURL, atomically: true, encoding: .utf8)

        var sawNewPhase = false
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))

        while ContinuousClock().now < deadline, !sawNewPhase {
            guard let update = await iterator.next() else { break }

            if case .success(let snapshots) = update {
                sawNewPhase = snapshots.contains { $0.phase.number == 1 }
            }
        }

        #expect(sawNewPhase)
    }

    @MainActor
    @Test func scannerReturnsPhasesInNumericOrder() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURLs = [
            projectURL.appendingPathComponent("phase-2-beta", isDirectory: true),
            projectURL.appendingPathComponent("phase-0-alpha", isDirectory: true),
            projectURL.appendingPathComponent("phase-1-delta", isDirectory: true)
        ]

        for phaseURL in phaseURLs {
            try makePhaseDirectories(at: phaseURL, fileManager: fileManager)
        }

        let snapshots = try ProjectScanner(fileManager: fileManager).scan(rootURL: tempRoot)

        #expect(snapshots.map { $0.phase.number } == [0, 1, 2])
        #expect(snapshots.map { $0.phase.label } == ["alpha", "delta", "beta"])
    }

    @MainActor
    @Test func moverRelocatesCardAndKeepsContents() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectURL.appendingPathComponent("phase-0-alpha", isDirectory: true)
        try makePhaseDirectories(at: phaseURL, fileManager: fileManager)

        let sourceURL = phaseURL.appendingPathComponent("backlog/0.1-demo.md")
        let contents = cardContents(code: "0.1", slug: "demo")
        try contents.write(to: sourceURL, atomically: true, encoding: .utf8)

        let card = try CardFileParser().parse(fileURL: sourceURL, contents: contents)
        let mover = CardMover(fileManager: fileManager)

        try await mover.move(card: card, to: .inProgress, rootURL: tempRoot)

        let destinationURL = phaseURL.appendingPathComponent("in-progress/0.1-demo.md")

        #expect(!fileManager.fileExists(atPath: sourceURL.path))
        #expect(fileManager.fileExists(atPath: destinationURL.path))

        let movedContents = try String(contentsOf: destinationURL, encoding: .utf8)
        #expect(movedContents == contents)
    }

    @MainActor
    @Test func moverRejectsSkippingColumns() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectURL.appendingPathComponent("phase-0-alpha", isDirectory: true)
        try makePhaseDirectories(at: phaseURL, fileManager: fileManager)

        let sourceURL = phaseURL.appendingPathComponent("backlog/0.3-demo.md")
        let contents = richCardContents(code: "0.3", slug: "demo")
        try contents.write(to: sourceURL, atomically: true, encoding: .utf8)

        let card = try CardFileParser().parse(fileURL: sourceURL, contents: contents)
        let mover = CardMover(fileManager: fileManager)

        do {
            try await mover.move(card: card, to: .done, rootURL: tempRoot, logHistoryEntry: false)
            Issue.record("Move should have rejected skipping in-progress.")
        } catch let error as CardMoveError {
            #expect(error == .illegalTransition(from: .backlog, to: .done))
        }
    }

    @MainActor
    @Test func moverAppendsHistoryWhenLoggingEnabled() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let fixedDate = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 1, day: 2))!
        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectURL.appendingPathComponent("phase-0-alpha", isDirectory: true)
        try makePhaseDirectories(at: phaseURL, fileManager: fileManager)

        let sourceURL = phaseURL.appendingPathComponent("backlog/0.4-demo.md")
        let contents = richCardContents(code: "0.4", slug: "demo", historyEntry: "2025-01-01 - Seeded history.")
        try contents.write(to: sourceURL, atomically: true, encoding: .utf8)

        let card = try CardFileParser().parse(fileURL: sourceURL, contents: contents)
        let mover = CardMover(fileManager: fileManager,
                              dateProvider: { fixedDate })

        try await mover.move(card: card, to: .inProgress, rootURL: tempRoot, logHistoryEntry: true)

        let destinationURL = phaseURL.appendingPathComponent("in-progress/0.4-demo.md")
        let movedContents = try String(contentsOf: destinationURL, encoding: .utf8)
        let parsed = try CardFileParser().parse(fileURL: destinationURL, contents: movedContents)

        #expect(parsed.status == .inProgress)
        #expect(parsed.history.contains("2025-01-01 - Seeded history."))
        #expect(parsed.history.contains("2025-01-02 - Moved from Backlog to In Progress."))
    }

    @MainActor
    @Test func moverErrorsWhenDestinationMissing() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectURL.appendingPathComponent("phase-0-alpha", isDirectory: true)
        try makePhaseDirectories(at: phaseURL, fileManager: fileManager)

        let sourceURL = phaseURL.appendingPathComponent("backlog/0.2-demo.md")
        let contents = cardContents(code: "0.2", slug: "demo")
        try contents.write(to: sourceURL, atomically: true, encoding: .utf8)

        // Remove destination folder to force a failure.
        try fileManager.removeItem(at: phaseURL.appendingPathComponent("in-progress"))

        let card = try CardFileParser().parse(fileURL: sourceURL, contents: contents)
        let mover = CardMover(fileManager: fileManager)

        do {
            try await mover.move(card: card, to: .inProgress, rootURL: tempRoot)
            Issue.record("Move should have thrown when destination is missing.")
        } catch let error as CardMoveError {
            #expect(error == .destinationFolderMissing(.inProgress))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test func moverDoesNotAppendHistoryWhenMoveFails() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectURL.appendingPathComponent("phase-0-alpha", isDirectory: true)
        try makePhaseDirectories(at: phaseURL, fileManager: fileManager)

        let sourceURL = phaseURL.appendingPathComponent("backlog/0.5-demo.md")
        let contents = richCardContents(code: "0.5", slug: "demo", historyEntry: "2025-01-01 - Seeded history.")
        try contents.write(to: sourceURL, atomically: true, encoding: .utf8)

        // Remove destination to force failure.
        try fileManager.removeItem(at: phaseURL.appendingPathComponent("in-progress"))

        let card = try CardFileParser().parse(fileURL: sourceURL, contents: contents)
        let mover = CardMover(fileManager: fileManager)

        do {
            try await mover.move(card: card, to: .inProgress, rootURL: tempRoot, logHistoryEntry: true)
            Issue.record("Move should have thrown when destination is missing.")
        } catch let error as CardMoveError {
            #expect(error == .destinationFolderMissing(.inProgress))
            let persisted = try String(contentsOf: sourceURL, encoding: .utf8)
            let parsed = try CardFileParser().parse(fileURL: sourceURL, contents: persisted)
            #expect(parsed.history == ["2025-01-01 - Seeded history."])
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test func inspectorDraftMirrorsParsedCard() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectURL.appendingPathComponent("phase-1-core", isDirectory: true)
        try makePhaseDirectories(at: phaseURL, fileManager: fileManager)

        let cardURL = phaseURL.appendingPathComponent("backlog/1.4-card-inspector.md")
        let markdown = """
---
owner: test
---

# 1.4 Card Inspector

Summary:
Build a focused inspector pane.

Acceptance Criteria:
- [ ] show card details
- [x] launch editor

Notes:
- Read-only for now.
"""

        try markdown.write(to: cardURL, atomically: true, encoding: .utf8)

        let card = try CardFileParser().parse(fileURL: cardURL, contents: markdown)
        let draft = CardInspectorDraft(card: card)

        #expect(draft.title == "1.4 Card Inspector")
        #expect(draft.summary == "Build a focused inspector pane.")
        #expect(draft.acceptanceCriteria.map(\.title) == ["show card details", "launch editor"])
        #expect(draft.acceptanceCriteria.map(\.isComplete) == [false, true])
        #expect(draft.notes.contains("Read-only for now."))
    }

    @MainActor
    private func makePhaseDirectories(at url: URL, fileManager: FileManager) throws {
        for status in CardStatus.allCases {
            let statusURL = url.appendingPathComponent(status.folderName, isDirectory: true)
            try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)
        }
    }

    private func cardContents(code: String, slug: String) -> String {
        "---\nowner: test\n---\nSummary:\n- Task \(code)-\(slug)\n"
    }

    private func richCardContents(code: String, slug: String, historyEntry: String = "2025-01-01 - Created for testing.") -> String {
        """
---
owner: test
agent_status: idle
branch: null
parallelizable: false
---

# \(code) \(slug.capitalized)

Summary:
Basic summary for \(slug).

Acceptance Criteria:
- [ ] first

Notes:
- testing note

History:
- \(historyEntry)
"""
    }
}
