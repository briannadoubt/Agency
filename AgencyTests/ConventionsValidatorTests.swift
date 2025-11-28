import Foundation
import Testing
@testable import Agency

@MainActor
struct ConventionsValidatorTests {
    private let fileManager = FileManager.default

    @Test func validLayoutPasses() throws {
        let root = try makeValidProject()
        defer { cleanup(root) }

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)

        #expect(issues.isEmpty)
    }

    @Test func missingStatusDirectorySurfacesError() throws {
        let root = try makeValidProject()
        defer { cleanup(root) }

        let missing = root.appendingPathComponent("project/phase-0-setup/backlog")
        try fileManager.removeItem(at: missing)

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)

        #expect(issues.contains { $0.severity == .error && $0.path.contains("backlog") })
    }

    @Test func invalidCardFilenameIsReported() throws {
        let root = try makeValidProject()
        defer { cleanup(root) }

        let invalid = root.appendingPathComponent("project/phase-0-setup/in-progress/not-a-card.txt")
        fileManager.createFile(atPath: invalid.path, contents: Data())

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)

        #expect(issues.contains { $0.message.contains("<phase>.<task>-slug.md") })
    }

    @Test func missingSectionIsFlaggedWithWarning() throws {
        let root = try makeValidProject()
        defer { cleanup(root) }

        let card = root.appendingPathComponent("project/phase-0-setup/backlog/0.1-conventions.md")
        let broken = """
        ---
        owner: bri
        ---

        # 0.1 Conventions

        Summary:
        text

        Acceptance Criteria:
        - [ ] one

        History:
        - 2025-01-01: seeded
        """
        try broken.write(to: card, atomically: true, encoding: .utf8)

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)

        #expect(issues.contains { $0.severity == .warning && $0.message.contains("Notes") })
    }

    @Test func duplicateCodesAreReported() throws {
        let root = try makeValidProject()
        defer { cleanup(root) }

        let duplicate = root.appendingPathComponent("project/phase-0-setup/done/0.1-conventions.md")
        try fileManager.copyItem(at: root.appendingPathComponent("project/phase-0-setup/backlog/0.1-conventions.md"), to: duplicate)

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)

        #expect(issues.contains { $0.message.contains("Duplicate card code") })
    }

    @Test func orphanedFilesAreReported() throws {
        let root = try makeValidProject()
        defer { cleanup(root) }

        let orphan = root.appendingPathComponent("project/phase-0-setup/readme.txt")
        fileManager.createFile(atPath: orphan.path, contents: Data())

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)

        #expect(issues.contains { $0.severity == .warning && $0.message.contains("Orphaned") })
    }

    @Test func planArtifactsPassValidation() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { cleanup(root) }

        let project = root.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phase = project.appendingPathComponent("phase-3-demo", isDirectory: true)
        for status in CardStatus.allCases {
            let statusURL = phase.appendingPathComponent(status.folderName, isDirectory: true)
            try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)
            fileManager.createFile(atPath: statusURL.appendingPathComponent(".gitkeep").path, contents: Data())
        }

        let plan = """
        ---
        owner: bri
        agent_flow: plan
        agent_status: idle
        branch: null
        risk: normal
        review: not-requested
        plan_version: 1
        plan_checksum: deadbeef
        ---

        # 3.0 Phase Demo Plan

        Summary:
        Plan scaffold for demo.

        Acceptance Criteria:
        - [ ] Plan tasks include rationale and acceptance criteria

        Notes:
        Task hints captured.

        Plan Tasks:
        - **Task One**
          - Acceptance Criteria:
            - [ ] Do it
          - Rationale: seed

        Plan Tasks (machine readable):
        ```json
        [
          {
            "title": "Task One",
            "acceptanceCriteria": ["Do it"],
            "rationale": "seed"
          }
        ]
        ```

        History:
        - 2025-11-28: Phase plan scaffolded.
        """

        try plan.write(to: phase.appendingPathComponent("backlog/3.0-phase-plan.md"), atomically: true, encoding: .utf8)

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)
        #expect(issues.isEmpty)
    }
}

private extension ConventionsValidatorTests {
    func makeValidProject() throws -> URL {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let project = root.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phase = project.appendingPathComponent("phase-0-setup", isDirectory: true)
        for status in CardStatus.allCases {
            let statusURL = phase.appendingPathComponent(status.folderName, isDirectory: true)
            try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)
            let minor: String
            switch status {
            case .backlog: minor = "1"
            case .inProgress: minor = "2"
            case .done: minor = "3"
            }
            let cardName = "0.\(minor)-conventions.md"
            let markdown = """
            ---
            owner: bri
            ---

            # 0.\(minor) Conventions

            Summary:
            valid

            Acceptance Criteria:
            - [ ] first

            Notes:
            none

            History:
            - 2025-01-01: seeded
            """
            try markdown.write(to: statusURL.appendingPathComponent(cardName), atomically: true, encoding: .utf8)
        }

        return root
    }

    func cleanup(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }
}
