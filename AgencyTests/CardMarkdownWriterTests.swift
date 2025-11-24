import Foundation
import Testing
@testable import Agency

@MainActor
struct CardMarkdownWriterTests {

    @Test
    func renderKeepsFrontmatterOrder() throws {
        let (fileURL, contents) = try makeTempCardFile()
        let parser = CardFileParser()
        let card = try parser.parse(fileURL: fileURL, contents: contents)
        let writer = CardMarkdownWriter()
        let snapshot = try writer.loadSnapshot(for: card)

        var draft = CardDetailFormDraft.from(card: snapshot.card)
        draft.branch = "feature/modal"
        draft.owner = "sam"

        let rendered = writer.renderMarkdown(from: draft,
                                             basedOn: snapshot.card,
                                             existingContents: snapshot.contents,
                                             appendHistory: false)

        let frontmatterLines = rendered.components(separatedBy: "---").dropFirst().first?
            .split(separator: "\n")
            .map(String.init) ?? []

        #expect(frontmatterLines == [
            "owner: sam",
            "agent_flow: solo",
            "agent_status: in-progress",
            "branch: feature/modal",
            "risk: normal",
            "review: not-requested",
            "parallelizable: true",
            "extra: keep"
        ])
    }

    @Test
    func saveRejectsWhenFileChangedOnDisk() throws {
        let (fileURL, contents) = try makeTempCardFile()
        let parser = CardFileParser()
        let card = try parser.parse(fileURL: fileURL, contents: contents)
        let writer = CardMarkdownWriter()
        let snapshot = try writer.loadSnapshot(for: card)

        // Mutate on disk to force conflict.
        try "mutated".write(to: fileURL, atomically: true, encoding: .utf8)

        var draft = CardDetailFormDraft.from(card: snapshot.card)
        draft.owner = "bri"

        #expect(throws: CardSaveError.conflict) {
            _ = try writer.saveFormDraft(draft,
                                         appendHistory: false,
                                         snapshot: snapshot)
        }
    }

    @Test
    func historyAppendsWhenRequested() throws {
        let (fileURL, contents) = try makeTempCardFile()
        let parser = CardFileParser()
        let card = try parser.parse(fileURL: fileURL, contents: contents)
        let writer = CardMarkdownWriter()
        var snapshot = try writer.loadSnapshot(for: card)

        var draft = CardDetailFormDraft.from(card: snapshot.card)
        draft.newHistoryEntry = "2025-11-24 - Added detail modal tests"

        snapshot = try writer.saveFormDraft(draft,
                                            appendHistory: true,
                                            snapshot: snapshot)

        #expect(snapshot.card.history.contains("2025-11-24 - Added detail modal tests"))
    }

    @Test
    func parseFailureDoesNotMutateDisk() throws {
        let (fileURL, contents) = try makeTempCardFile()
        let parser = CardFileParser()
        let card = try parser.parse(fileURL: fileURL, contents: contents)
        let writer = CardMarkdownWriter()
        let snapshot = try writer.loadSnapshot(for: card)

        do {
            _ = try writer.saveRaw("---\ninvalid", snapshot: snapshot)
            #expect(Bool(false), "Save should have thrown parseFailed")
        } catch let error as CardSaveError {
            #expect({ if case .parseFailed = error { return true } else { return false } }())
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }

        let disk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(disk == contents)
    }

    // MARK: Helpers

    private func makeTempCardFile() throws -> (URL, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let cardDir = root
            .appendingPathComponent("project")
            .appendingPathComponent("phase-2-ui-foundations")
            .appendingPathComponent("in-progress")

        try FileManager.default.createDirectory(at: cardDir, withIntermediateDirectories: true)

        let fileURL = cardDir.appendingPathComponent("2.5-detail-modal.md")
        let contents = """
        ---
        owner: bri
        agent_flow: solo
        agent_status: in-progress
        branch: implement/initial
        risk: normal
        review: not-requested
        parallelizable: true
        extra: keep
        ---

        # 2.5 Detail Modal

        Summary:
        Initial summary text.

        Acceptance Criteria:
        - [ ] First

        Notes:
        A note.

        History:
        - 2025-11-23 - Created
        """

        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return (fileURL, contents)
    }
}
