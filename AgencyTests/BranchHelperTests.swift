import Foundation
import Testing
@testable import Agency

@MainActor
struct BranchHelperTests {
    @Test
    func recommendedBranchNormalizesPrefixAndSlug() {
        let helper = BranchHelper()
        let card = Card(code: "4.2",
                        slug: "Branch_Helper",
                        status: .backlog,
                        filePath: URL(fileURLWithPath: "/tmp/4.2-branch_helper.md"),
                        frontmatter: CardFrontmatter(),
                        sections: [],
                        title: nil,
                        summary: nil,
                        acceptanceCriteria: [],
                        notes: nil,
                        history: [])

        let branch = helper.recommendedBranch(for: card, prefix: "Implement Work")

        #expect(branch == "implement-work/4.2-branch-helper")
    }

    @Test
    func applyBranchAddsHistoryWithoutReorderingFrontmatter() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let statusURL = tempRoot.appendingPathComponent("project/phase-4-developer-utilities/backlog", isDirectory: true)
        try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let fileURL = statusURL.appendingPathComponent("4.2-branch-helper.md")
        let markdown = """
        ---
        owner: bri
        agent_status: idle
        custom: keep-me
        ---

        # 4.2 Branch Helper

        Summary:
        existing summary

        Acceptance Criteria:
        - [ ] first

        Notes:
        none

        History:
        - 2025-11-22: Created
        """

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        let parser = CardFileParser()
        let card = try parser.parse(fileURL: fileURL, contents: markdown)
        let helper = BranchHelper(writer: CardMarkdownWriter(parser: parser, fileManager: fileManager),
                                  dateProvider: { Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 1, day: 3))! })

        _ = try helper.applyBranch(to: card, prefix: "implement")

        let saved = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = saved.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines[0] == "---")
        #expect(lines[1] == "owner: bri")
        #expect(lines[2] == "agent_status: idle")
        #expect(lines[3] == "custom: keep-me")
        #expect(lines[4] == "branch: implement/4.2-branch-helper")
        #expect(saved.contains("2025-01-03 - Branch set to implement/4.2-branch-helper."))
    }
}
