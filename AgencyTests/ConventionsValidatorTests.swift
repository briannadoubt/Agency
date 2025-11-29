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

    @Test func missingRoadmapIsError() throws {
        let root = try makeValidProject(includeRoadmap: false, includeArchitecture: false)
        defer { cleanup(root) }

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)

        #expect(issues.contains { $0.severity == .error && $0.path.hasSuffix("ROADMAP.md") })
    }

    @Test func invalidRoadmapMachineBlockIsError() throws {
        let root = try makeValidProject()
        defer { cleanup(root) }

        try "roadmap missing json".write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)

        #expect(issues.contains { $0.severity == .error && $0.message.contains("machine-readable") })
    }

    @Test func missingArchitectureIsError() throws {
        let root = try makeValidProject(includeArchitecture: false)
        defer { cleanup(root) }

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)

        #expect(issues.contains { $0.severity == .error && $0.path == "ARCHITECTURE.md" || $0.path.hasSuffix("ARCHITECTURE.md") })
    }

    @Test func staleArchitectureSurfacesWarning() throws {
        let root = try makeValidProject()
        defer { cleanup(root) }

        let architecture = root.appendingPathComponent("ARCHITECTURE.md")
        let contents = try String(contentsOf: architecture, encoding: .utf8)
        let parsed = ArchitectureParser().parse(contents: contents)
        var document = parsed.document!
        let staleFingerprint = "stale-\(document.roadmapFingerprint)"
        document = ArchitectureDocument(version: document.version,
                                        generatedAt: document.generatedAt,
                                        projectGoal: document.projectGoal,
                                        targetPlatforms: document.targetPlatforms,
                                        languages: document.languages,
                                        techStack: document.techStack,
                                        roadmapFingerprint: staleFingerprint,
                                        phases: document.phases,
                                        manualNotes: document.manualNotes)
        let rewritten = ArchitectureRenderer().render(document: document,
                                                     history: parsed.history,
                                                     manualNotes: document.manualNotes)
        try rewritten.write(to: architecture, atomically: true, encoding: .utf8)

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)

        #expect(issues.contains { $0.severity == .warning && $0.message.contains("fingerprint") })
    }

    @Test func missingCardForRoadmapTaskIsError() throws {
        let root = try makeValidProject()
        defer { cleanup(root) }

        let card = root.appendingPathComponent("project/phase-0-setup/backlog/0.1-conventions.md")
        try fileManager.removeItem(at: card)

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)

        #expect(issues.contains { $0.severity == .error && $0.message.contains("Missing card for roadmap task") })
    }

    @Test func roadmapStatusMismatchIsWarning() throws {
        let root = try makeValidProject()
        defer { cleanup(root) }

        let destination = root.appendingPathComponent("project/phase-0-setup/backlog/0.3-conventions.md")
        try fileManager.moveItem(at: root.appendingPathComponent("project/phase-0-setup/done/0.3-conventions.md"), to: destination)

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)

        #expect(issues.contains { $0.severity == .warning && $0.message.contains("expected in done") })
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

        let roadmapPhase = RoadmapPhaseEntry(number: 3,
                                             label: "demo",
                                             status: .planned,
                                             summary: "demo",
                                             tasks: [])
        let roadmap = RoadmapDocument(version: 1,
                                       projectGoal: "Plan demo",
                                       generatedAt: "2025-11-29",
                                       phases: [roadmapPhase],
                                       manualNotes: "")
        let roadmapMarkdown = RoadmapRenderer().render(document: roadmap,
                                                       history: ["- 2025-11-29: seeded roadmap."],
                                                       manualNotes: roadmap.manualNotes)
        try roadmapMarkdown.write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)
        try seedArchitecture(root: root, roadmap: roadmap)

        let issues = ConventionsValidator(fileManager: fileManager).validateProject(at: root)
        #expect(issues.isEmpty)
    }
}

private extension ConventionsValidatorTests {
    func makeValidProject(includeRoadmap: Bool = true, includeArchitecture: Bool = true) throws -> URL {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let project = root.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phase = project.appendingPathComponent("phase-0-setup", isDirectory: true)
        for status in CardStatus.allCases {
            let statusURL = phase.appendingPathComponent(status.folderName, isDirectory: true)
            try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)
            fileManager.createFile(atPath: statusURL.appendingPathComponent(".gitkeep").path, contents: Data())
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

        if includeRoadmap {
            let document = try seedRoadmap(root: root)
            if includeArchitecture {
                try seedArchitecture(root: root, roadmap: document)
            }
        }

        return root
    }

    func cleanup(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    @discardableResult
    func seedRoadmap(root: URL) throws -> RoadmapDocument {
        let tasks = [
            RoadmapTaskEntry(code: "0.1", title: "Conventions", summary: "Layout", owner: "bri", risk: "normal", status: CardStatus.backlog.folderName, acceptanceCriteria: ["first"], parallelizable: false),
            RoadmapTaskEntry(code: "0.2", title: "Conventions", summary: "Layout", owner: "bri", risk: "normal", status: CardStatus.inProgress.folderName, acceptanceCriteria: [], parallelizable: false),
            RoadmapTaskEntry(code: "0.3", title: "Conventions", summary: "Layout", owner: "bri", risk: "normal", status: CardStatus.done.folderName, acceptanceCriteria: [], parallelizable: false)
        ]
        let phase = RoadmapPhaseEntry(number: 0,
                                      label: "setup",
                                      status: .planned,
                                      summary: "setup phase",
                                      tasks: tasks)
        let document = RoadmapDocument(version: 1,
                                        projectGoal: "Validation project",
                                        generatedAt: "2025-11-29",
                                        phases: [phase],
                                        manualNotes: "")
        let markdown = RoadmapRenderer().render(document: document,
                                                history: ["- 2025-11-29: seeded roadmap."],
                                                manualNotes: document.manualNotes)
        try markdown.write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)
        return document
    }

    func seedArchitecture(root: URL, roadmap: RoadmapDocument) throws {
        let fingerprint = ArchitectureGenerator.fingerprint(for: roadmap)
        let phaseSummaries = roadmap.phases.map { phase in
            ArchitecturePhaseSummary(number: phase.number,
                                     label: phase.label,
                                     status: phase.status.rawValue,
                                     tasks: phase.tasks.map { task in
                                         ArchitectureTaskSummary(code: task.code,
                                                                 title: task.title,
                                                                 summary: task.summary,
                                                                 status: task.status)
                                     })
        }

        let document = ArchitectureDocument(version: 1,
                                             generatedAt: "2025-11-29",
                                             projectGoal: roadmap.projectGoal,
                                             targetPlatforms: [],
                                             languages: [],
                                             techStack: [],
                                             roadmapFingerprint: fingerprint,
                                             phases: phaseSummaries,
                                             manualNotes: roadmap.manualNotes)
        let markdown = ArchitectureRenderer().render(document: document,
                                                    history: ["- 2025-11-29: seeded architecture."],
                                                    manualNotes: document.manualNotes)
        try markdown.write(to: root.appendingPathComponent("ARCHITECTURE.md"), atomically: true, encoding: .utf8)
    }
}
