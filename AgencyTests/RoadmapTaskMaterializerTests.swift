import XCTest
@testable import Agency

@MainActor
final class RoadmapTaskMaterializerTests: XCTestCase {

    func testMaterializesSinglePhaseCreatesCards() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try roadmap(singlePhaseWithTwoTasks()).write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)
        try seedArchitecture(from: singlePhaseWithTwoTasks(), at: root)

        let materializer = RoadmapTaskMaterializer(fileManager: fm,
                                                   parser: RoadmapParser(),
                                                   cardParser: CardFileParser(),
                                                   writer: CardMarkdownWriter(),
                                                   validator: ConventionsValidator(fileManager: fm, parser: CardFileParser()))

        let result = try materializer.materialize(options: TaskMaterializationOptions(projectRoot: root, dryRun: false))

        XCTAssertTrue(result.created.contains("project/phase-1-setup/backlog/1.1-bootstrap.md"))
        XCTAssertTrue(result.created.contains("project/phase-1-setup/in-progress/1.2-wire-up.md"))

        let bootstrap = try String(contentsOf: root.appendingPathComponent("project/phase-1-setup/backlog/1.1-bootstrap.md"), encoding: .utf8)
        XCTAssertTrue(bootstrap.contains("Bootstrap skeleton"))
        XCTAssertTrue(bootstrap.contains("- [ ] prepare CI"))
    }

    func testIdempotentRegenerationKeepsHistoryAndCompletion() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Seed existing card with history and a completed criterion.
        let phase = root.appendingPathComponent("project/phase-2-delivery/backlog", isDirectory: true)
        try fm.createDirectory(at: phase, withIntermediateDirectories: true)
        let cardURL = phase.appendingPathComponent("2.1-ship.md")
        let cardContents = """
        ---
        owner: bri
        risk: high
        review: not-requested
        ---

        # 2.1 Ship Release

        Summary:
        Old summary

        Acceptance Criteria:
        - [x] finish docs

        Notes:
        existing notes

        History:
        - 2025-11-28: created manually
        """
        try cardContents.write(to: cardURL, atomically: true, encoding: .utf8)

        try roadmap(deliveryRoadmap()).write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)
        try seedArchitecture(from: deliveryRoadmap(), at: root)

        let materializer = RoadmapTaskMaterializer(fileManager: fm,
                                                   parser: RoadmapParser(),
                                                   cardParser: CardFileParser(),
                                                   writer: CardMarkdownWriter(),
                                                   validator: ConventionsValidator(fileManager: fm, parser: CardFileParser()))

        _ = try materializer.materialize(options: TaskMaterializationOptions(projectRoot: root, dryRun: false))
        _ = try materializer.materialize(options: TaskMaterializationOptions(projectRoot: root, dryRun: false))

        let updated = try String(contentsOf: cardURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("Ship the release"))
        XCTAssertTrue(updated.contains("- [x] finish docs"), "Keeps completion state on regeneration")
        XCTAssertTrue(updated.contains("2025-11-28: created manually"))
    }

    func testMultiPhaseDryRunPreviewsWithoutWriting() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try roadmap(multiPhaseRoadmap()).write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)
        try seedArchitecture(from: multiPhaseRoadmap(), at: root)

        let materializer = RoadmapTaskMaterializer(fileManager: fm,
                                                   parser: RoadmapParser(),
                                                   cardParser: CardFileParser(),
                                                   writer: CardMarkdownWriter(),
                                                   validator: ConventionsValidator(fileManager: fm, parser: CardFileParser()))

        let result = try materializer.materialize(options: TaskMaterializationOptions(projectRoot: root, dryRun: true))

        XCTAssertTrue(result.dryRun)
        XCTAssertTrue(result.created.contains("project/phase-3-integration/backlog/3.1-hook-cli.md"))
        XCTAssertTrue(result.created.contains("project/phase-4-launch/backlog/4.1-announce.md"))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("project").path))
    }
}

// MARK: - Fixtures

private func roadmap(_ body: String) -> String { body }

private func singlePhaseWithTwoTasks() -> String {
    """
    ---
    roadmap_version: 1
    project_goal: Sample
    generated_at: 2025-11-29
    ---

    # Roadmap

    Summary:
    sample

    Phase Overview:
    - Phase 1 — setup (planned)

    ## Phase 1 — setup (planned)

    Summary:
    Setup phase.

    Tasks:
    - [ ] 1.1 Bootstrap — Bootstrap skeleton
      - Status: backlog
      - Acceptance Criteria:
        - [ ] prepare CI
    - [ ] 1.2 Wire Up — Connect APIs
      - Status: in-progress

    Roadmap (machine readable):
    ```json
    {
      "version": 1,
      "projectGoal": "Sample",
      "generatedAt": "2025-11-29",
      "manualNotes": "",
      "phases": [
        {
          "number": 1,
          "label": "setup",
          "status": "planned",
          "summary": "",
          "tasks": [
            {"code": "1.1", "title": "Bootstrap", "summary": "Bootstrap skeleton", "status": "backlog", "acceptanceCriteria": ["prepare CI"], "parallelizable": false},
            {"code": "1.2", "title": "Wire Up", "summary": "Connect APIs", "status": "in-progress", "acceptanceCriteria": [], "parallelizable": false}
          ]
        }
      ]
    }
    ```

    History:
    - 2025-11-29: seeded
    """
}

private func deliveryRoadmap() -> String {
    """
    ---
    roadmap_version: 1
    project_goal: Deliver
    generated_at: 2025-11-29
    ---

    # Roadmap

    Summary:
    deliver

    Phase Overview:
    - Phase 2 — delivery (planned)

    ## Phase 2 — delivery (planned)

    Summary:
    ship

    Tasks:
    - [ ] 2.1 Ship Release — Ship the release
      - Status: backlog
      - Acceptance Criteria:
        - [ ] finish docs

    Roadmap (machine readable):
    ```json
    {
      "version": 1,
      "projectGoal": "Deliver",
      "generatedAt": "2025-11-29",
      "manualNotes": "",
      "phases": [
        {
          "number": 2,
          "label": "delivery",
          "status": "planned",
          "summary": "",
          "tasks": [
            {"code": "2.1", "title": "Ship Release", "summary": "Ship the release", "status": "backlog", "acceptanceCriteria": ["finish docs"], "parallelizable": false}
          ]
        }
      ]
    }
    ```

    History:
    - 2025-11-29: seeded
    """
}

private func multiPhaseRoadmap() -> String {
    """
    ---
    roadmap_version: 1
    project_goal: Multi
    generated_at: 2025-11-29
    ---

    # Roadmap

    Summary:
    multi

    Phase Overview:
    - Phase 3 — integration (planned)
    - Phase 4 — launch (planned)

    ## Phase 3 — integration (planned)

    Summary:
    integrate

    Tasks:
    - [ ] 3.1 Hook CLI — Wire the CLI
      - Status: backlog

    ## Phase 4 — launch (planned)

    Summary:
    launch

    Tasks:
    - [ ] 4.1 Announce — Announcement
      - Status: backlog

    Roadmap (machine readable):
    ```json
    {
      "version": 1,
      "projectGoal": "Multi",
      "generatedAt": "2025-11-29",
      "manualNotes": "",
      "phases": [
        {"number": 3, "label": "integration", "status": "planned", "summary": "", "tasks": [
          {"code": "3.1", "title": "Hook CLI", "summary": "Wire the CLI", "status": "backlog", "acceptanceCriteria": [], "parallelizable": false}
        ]},
        {"number": 4, "label": "launch", "status": "planned", "summary": "", "tasks": [
          {"code": "4.1", "title": "Announce", "summary": "Announcement", "status": "backlog", "acceptanceCriteria": [], "parallelizable": false}
        ]}
      ]
    }
    ```

    History:
    - 2025-11-29: seeded
    """
}

@MainActor
private func seedArchitecture(from roadmapMarkdown: String, at root: URL) throws {
    let parser = RoadmapParser()
    guard let document = parser.parse(contents: roadmapMarkdown).document else {
        throw XCTSkip("Unable to parse roadmap for architecture seed")
    }

    let fingerprint = ArchitectureGenerator.fingerprint(for: document)
    let phases = document.phases.map { phase in
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
    let architecture = ArchitectureDocument(version: 1,
                                            generatedAt: document.generatedAt,
                                            projectGoal: document.projectGoal,
                                            targetPlatforms: [],
                                            languages: [],
                                            techStack: [],
                                            roadmapFingerprint: fingerprint,
                                            phases: phases,
                                            manualNotes: document.manualNotes)
    let markdown = ArchitectureRenderer().render(document: architecture,
                                                history: ["- \(document.generatedAt): seeded architecture."],
                                                manualNotes: architecture.manualNotes)

    try markdown.write(to: root.appendingPathComponent("ARCHITECTURE.md"), atomically: true, encoding: .utf8)
}
