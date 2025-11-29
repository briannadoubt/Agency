import XCTest
@testable import Agency

@MainActor
final class ProjectInitializerTests: XCTestCase {

    func testDryRunPreviewDoesNotWriteToExistingDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try sampleRoadmap().write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent("project/phase-1-setup/backlog"),
                               withIntermediateDirectories: true)
        let existingNote = root.appendingPathComponent("project/phase-1-setup/backlog/note.txt")
        try "keep".write(to: existingNote, atomically: true, encoding: .utf8)

        let initializer = ProjectInitializer(fileManager: fm,
                                             parser: RoadmapParser(),
                                             generator: RoadmapGenerator(fileManager: fm,
                                                                         scanner: ProjectScanner(fileManager: fm,
                                                                                                 parser: CardFileParser()),
                                                                         parser: RoadmapParser(),
                                                                         renderer: RoadmapRenderer()))
        let options = ProjectInitializationOptions(projectRoot: root,
                                                   dryRun: true,
                                                   applyChanges: false)
        let result = try initializer.initialize(options: options)

        XCTAssertTrue(result.dryRun)
        XCTAssertTrue(result.createdDirectories.contains("project/phase-1-setup/in-progress"))
        XCTAssertTrue(result.createdDirectories.contains("project/phase-1-setup/done"))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("project/phase-1-setup/in-progress").path))
        XCTAssertEqual(try String(contentsOf: existingNote, encoding: .utf8), "keep")
    }

    func testCreatesNewProjectFromExternalRoadmap() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        let root = temp.appendingPathComponent("proj-" + UUID().uuidString, isDirectory: true)
        let roadmapTemplate = temp.appendingPathComponent("roadmap-" + UUID().uuidString + ".md")
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: roadmapTemplate)
        }

        try sampleRoadmap().write(to: roadmapTemplate, atomically: true, encoding: .utf8)

        let initializer = ProjectInitializer(fileManager: fm,
                                             parser: RoadmapParser(),
                                             generator: RoadmapGenerator(fileManager: fm,
                                                                         scanner: ProjectScanner(fileManager: fm,
                                                                                                 parser: CardFileParser()),
                                                                         parser: RoadmapParser(),
                                                                         renderer: RoadmapRenderer()),
                                             architectureGenerator: ArchitectureGenerator(fileManager: fm,
                                                                                           roadmapParser: RoadmapParser(),
                                                                                           parser: ArchitectureParser(),
                                                                                           renderer: ArchitectureRenderer(),
                                                                                           dateProvider: { self.fixedDate() }))
        let options = ProjectInitializationOptions(projectRoot: root,
                                                   roadmapPath: roadmapTemplate,
                                                   dryRun: false,
                                                   applyChanges: true,
                                                   architectureInputs: ArchitectureInput(targetPlatforms: ["macOS"],
                                                                                         languages: ["Swift"],
                                                                                         techStack: ["SwiftUI"]))
        let result = try initializer.initialize(options: options)

        XCTAssertFalse(result.dryRun)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("project").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("project/phase-1-setup/backlog/.gitkeep").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("project/phase-2-delivery/done/.gitkeep").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("ROADMAP.md").path))
        let copied = try String(contentsOf: root.appendingPathComponent("ROADMAP.md"), encoding: .utf8)
        XCTAssertEqual(copied, sampleRoadmap())
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("ARCHITECTURE.md").path))
    }

    func testCommandDefaultsToDryRun() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try sampleRoadmap().write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)

        let command = ProjectInitializationCommand()
        let output = await command.run(arguments: ["--project-root", root.path], fileManager: fm)

        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.stdout.contains("dry-run"))
        XCTAssertTrue(output.result?.dryRun ?? false)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("project").path))
    }

    func testArchitectureGenerationCanBeDisabled() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try sampleRoadmap().write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)

        let initializer = ProjectInitializer(fileManager: fm,
                                             parser: RoadmapParser(),
                                             generator: RoadmapGenerator(fileManager: fm,
                                                                         scanner: ProjectScanner(fileManager: fm,
                                                                                                 parser: CardFileParser()),
                                                                         parser: RoadmapParser(),
                                                                         renderer: RoadmapRenderer()),
                                             architectureGenerator: ArchitectureGenerator(fileManager: fm,
                                                                                           roadmapParser: RoadmapParser(),
                                                                                           parser: ArchitectureParser(),
                                                                                           renderer: ArchitectureRenderer(),
                                                                                           dateProvider: { self.fixedDate() }))

        let options = ProjectInitializationOptions(projectRoot: root,
                                                   dryRun: false,
                                                   applyChanges: true,
                                                   generateArchitecture: false)
        _ = try initializer.initialize(options: options)

        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("ARCHITECTURE.md").path))
    }
}

// MARK: - Helpers

private func sampleRoadmap() -> String {
    """
    ---
    roadmap_version: 1
    project_goal: Sample project
    generated_at: 2025-11-29
    ---

    # Roadmap

    Summary:
    Sample bootstrap work.

    Phase Overview:
    - Phase 1 — setup (planned)
    - Phase 2 — delivery (planned)

    ## Phase 1 — setup (planned)

    Summary:
    Setup the repository.

    Tasks:
    - [ ] 1.1 Bootstrap — Create skeleton.
      - Status: backlog

    ## Phase 2 — delivery (planned)

    Summary:
    Deliver features.

    Tasks:
    - [ ] 2.1 Ship — Deliver the release.
      - Status: backlog

    Roadmap (machine readable):
    ```json
    {
      "version": 1,
      "projectGoal": "Sample project",
      "generatedAt": "2025-11-29",
      "manualNotes": "",
      "phases": [
        { "number": 1, "label": "setup", "status": "planned", "summary": "Setup the repository", "tasks": [] },
        { "number": 2, "label": "delivery", "status": "planned", "summary": "Deliver features", "tasks": [] }
      ]
    }
    ```

    History:
    - 2025-11-29: seeded
    """
}

private extension ProjectInitializerTests {
    func fixedDate() -> Date {
        ISO8601DateFormatter().date(from: "2025-11-29T12:00:00Z")!
    }
}
