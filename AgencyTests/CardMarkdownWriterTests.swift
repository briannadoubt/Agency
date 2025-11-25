import Foundation
import Testing
@testable import Agency

@MainActor
struct CardMarkdownWriterTests {

    @Test
    func inlineEditsPreserveFrontmatterAndCheckboxes() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let statusURL = tempRoot.appendingPathComponent("project/phase-3-editing/in-progress", isDirectory: true)
        try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let fileURL = statusURL.appendingPathComponent("3.1-inline-editing.md")
        let markdown = """
---
owner: bri
agent_status: idle
custom: keep-me
---

# 3.1 Inline Editing

Summary:
Old summary.

Acceptance Criteria:
- [ ] first thing
- [x] second thing

Notes:
Old notes.

History:
- 2025-11-22: Created
"""

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        let parser = CardFileParser()
        let card = try parser.parse(fileURL: fileURL, contents: markdown)
        let writer = CardMarkdownWriter(parser: parser, fileManager: fileManager)
        let snapshot = try writer.loadSnapshot(for: card)

        var draft = CardDetailFormDraft.from(card: snapshot.card)
        draft.summary = "Updated summary"
        draft.notes = "Updated notes"
        draft.criteria[0].isComplete = true
        draft.criteria[1].isComplete = false

        let updated = try writer.saveFormDraft(draft, appendHistory: false, snapshot: snapshot)
        let saved = try String(contentsOf: fileURL, encoding: .utf8)

        let lines = saved.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count > 4)
        #expect(lines[0] == "---")
        #expect(lines[1] == "owner: bri")
        #expect(lines[2] == "agent_status: idle")
        #expect(lines[3] == "custom: keep-me")

        #expect(saved.contains("- [x] first thing"))
        #expect(saved.contains("- [ ] second thing"))

        #expect(updated.card.summary == "Updated summary")
        #expect(updated.card.notes == "Updated notes")
        #expect(updated.card.acceptanceCriteria.map(\.isComplete) == [true, false])
    }

    @Test
    func detectsConflictBeforeSaving() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let statusURL = tempRoot.appendingPathComponent("project/phase-3-editing/backlog", isDirectory: true)
        try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let fileURL = statusURL.appendingPathComponent("3.1-conflict.md")
        let markdown = """
---
owner: bri
---

Summary:
Original summary.
"""

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        let parser = CardFileParser()
        let card = try parser.parse(fileURL: fileURL, contents: markdown)
        let writer = CardMarkdownWriter(parser: parser, fileManager: fileManager)
        let snapshot = try writer.loadSnapshot(for: card)

        var draft = CardDetailFormDraft.from(card: snapshot.card)
        draft.summary = "Changed summary"

        try "External change".write(to: fileURL, atomically: true, encoding: .utf8)

        do {
            _ = try writer.saveFormDraft(draft, appendHistory: false, snapshot: snapshot)
            Issue.record("Expected conflict when the file changes on disk before saving")
        } catch let error as CardSaveError {
            #expect(error == .conflict)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let diskContents = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(diskContents == "External change")
    }

    @Test
    func addsFrontmatterWhenMissing() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let statusURL = tempRoot.appendingPathComponent("project/phase-3-editing/backlog", isDirectory: true)
        try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let fileURL = statusURL.appendingPathComponent("3.4-frontmatterless.md")
        let markdown = """
        # 3.4 Frontmatterless

        Summary:
        No frontmatter yet.
        """

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        let parser = CardFileParser()
        let card = try parser.parse(fileURL: fileURL, contents: markdown)
        let writer = CardMarkdownWriter(parser: parser, fileManager: fileManager)
        let snapshot = try writer.loadSnapshot(for: card)

        var draft = CardDetailFormDraft.from(card: snapshot.card)
        draft.owner = "bri"
        draft.risk = "medium"
        draft.parallelizable = true

        _ = try writer.saveFormDraft(draft, appendHistory: false, snapshot: snapshot)
        let saved = try String(contentsOf: fileURL, encoding: .utf8)

        #expect(saved.hasPrefix("---"))
        #expect(saved.contains("owner: bri"))
        #expect(saved.contains("risk: medium"))
        #expect(saved.contains("parallelizable: true"))
    }

    @Test
    func rejectsInvalidFrontmatterBeforeSaving() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let statusURL = tempRoot.appendingPathComponent("project/phase-3-editing/backlog", isDirectory: true)
        try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let fileURL = statusURL.appendingPathComponent("3.4-invalid-frontmatter.md")
        let markdown = """
        ---
        owner: bri
        ---

        Summary:
        Valid content.
        """

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        let parser = CardFileParser()
        let card = try parser.parse(fileURL: fileURL, contents: markdown)
        let writer = CardMarkdownWriter(parser: parser, fileManager: fileManager)
        let snapshot = try writer.loadSnapshot(for: card)

        let invalid = """
        ---
        owner bri
        ---

        Summary:
        Broken frontmatter.
        """

        do {
            _ = try writer.saveRaw(invalid, snapshot: snapshot)
            Issue.record("Expected parse failure before saving invalid YAML")
        } catch let error as CardSaveError {
            switch error {
            case .parseFailed(let message):
                #expect(message.contains("Invalid frontmatter entry"))
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }

        let disk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(disk == markdown)
    }
}
