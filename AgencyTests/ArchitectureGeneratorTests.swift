import XCTest
@testable import Agency

@MainActor
final class ArchitectureGeneratorTests: XCTestCase {

    func testGeneratesArchitectureFromRoadmapAndInputs() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try sampleRoadmap().write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)

        let generator = ArchitectureGenerator(fileManager: fm,
                                              roadmapParser: RoadmapParser(),
                                              parser: ArchitectureParser(),
                                              renderer: ArchitectureRenderer(),
                                              dateProvider: { self.fixedDate() })

        let options = ArchitectureGenerationOptions(projectRoot: root,
                                                    inputs: ArchitectureInput(targetPlatforms: ["macOS", "iOS"],
                                                                             languages: ["Swift"],
                                                                             techStack: ["SwiftUI", "XPC"]),
                                                    dryRun: false)
        let result = try generator.generate(options: options)

        XCTAssertFalse(result.dryRun)
        let architectureURL = root.appendingPathComponent("ARCHITECTURE.md")
        XCTAssertTrue(fm.fileExists(atPath: architectureURL.path))
        let contents = try String(contentsOf: architectureURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("Target platforms: macOS, iOS"))
        XCTAssertTrue(contents.contains("Languages: Swift"))
        XCTAssertTrue(contents.contains("Tech stack: SwiftUI, XPC"))
        XCTAssertTrue(contents.contains("1.1 Bootstrap"))

        let parsed = ArchitectureParser().parse(contents: contents)
        XCTAssertEqual(parsed.document?.roadmapFingerprint,
                       ArchitectureGenerator.fingerprint(for: RoadmapParser().parse(contents: sampleRoadmap()).document!))
    }

    func testRegenerationPreservesManualNotesAndHistory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try sampleRoadmap().write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)

        let generator = ArchitectureGenerator(fileManager: fm,
                                              roadmapParser: RoadmapParser(),
                                              parser: ArchitectureParser(),
                                              renderer: ArchitectureRenderer(),
                                              dateProvider: { self.fixedDate() })

        let options = ArchitectureGenerationOptions(projectRoot: root,
                                                    inputs: ArchitectureInput(targetPlatforms: ["macOS"],
                                                                             languages: ["Swift"],
                                                                             techStack: ["SwiftUI"]),
                                                    dryRun: false)
        _ = try generator.generate(options: options)

        let architectureURL = root.appendingPathComponent("ARCHITECTURE.md")
        var contents = try String(contentsOf: architectureURL, encoding: .utf8)
        contents = contents.replacingOccurrences(of: "None yet.", with: "Hand-tuned cache settings.")
        contents = contents.replacingOccurrences(of: "History:\n- 2025-11-29: Regenerated architecture from roadmap.\n",
                                                 with: "History:\n- 2025-11-29: Regenerated architecture from roadmap.\n- 2025-11-28: manual note\n")
        try contents.write(to: architectureURL, atomically: true, encoding: .utf8)

        _ = try generator.generate(options: options)
        let regenerated = try String(contentsOf: architectureURL, encoding: .utf8)

        XCTAssertTrue(regenerated.contains("Hand-tuned cache settings."))
        XCTAssertTrue(regenerated.contains("manual note"))
        let historyCount = regenerated.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- 2025") }.count
        XCTAssertGreaterThanOrEqual(historyCount, 2)
    }

    func testValidatorFlagsStaleArchitectureWhenRoadmapChanges() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try sampleRoadmap().write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)

        let generator = ArchitectureGenerator(fileManager: fm,
                                              roadmapParser: RoadmapParser(),
                                              parser: ArchitectureParser(),
                                              renderer: ArchitectureRenderer(),
                                              dateProvider: { self.fixedDate() })
        let options = ArchitectureGenerationOptions(projectRoot: root,
                                                    inputs: ArchitectureInput(targetPlatforms: ["macOS"],
                                                                             languages: ["Swift"],
                                                                             techStack: ["SwiftUI"]),
                                                    dryRun: false)
        _ = try generator.generate(options: options)

        // Change roadmap to invalidate fingerprint.
        try updatedRoadmap().write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)

        let validator = ArchitectureValidator(fileManager: fm,
                                              parser: ArchitectureParser(),
                                              roadmapParser: RoadmapParser())
        let issues = validator.validateArchitecture(at: root)

        XCTAssertTrue(issues.contains { $0.message.contains("stale") })
    }
}

// MARK: - Fixtures

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

    ## Phase 1 — setup (planned)

    Summary:
    Setup the repository.

    Tasks:
    - [ ] 1.1 Bootstrap — Create skeleton.
      - Status: backlog
      - Summary: Build initial scaffolding.

    Roadmap (machine readable):
    ```json
    {
      "version": 1,
      "projectGoal": "Sample project",
      "generatedAt": "2025-11-29",
      "manualNotes": "",
      "phases": [
        {
          "number": 1,
          "label": "setup",
          "status": "planned",
          "summary": "Setup the repository.",
          "tasks": [
            {"code": "1.1", "title": "Bootstrap", "summary": "Create skeleton.", "owner": "bri", "risk": "normal", "status": "backlog", "acceptanceCriteria": [], "parallelizable": false}
          ]
        }
      ]
    }
    ```

    History:
    - 2025-11-29: seeded
    """
}

private func updatedRoadmap() -> String {
    """
    ---
    roadmap_version: 1
    project_goal: Sample project v2
    generated_at: 2025-11-30
    ---

    # Roadmap

    Summary:
    Updated bootstrap work.

    Phase Overview:
    - Phase 1 — setup (planned)
    - Phase 2 — delivery (planned)

    ## Phase 1 — setup (planned)

    Summary:
    Setup the repository.

    Tasks:
    - [x] 1.1 Bootstrap — Create skeleton.
      - Status: done

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
      "projectGoal": "Sample project v2",
      "generatedAt": "2025-11-30",
      "manualNotes": "",
      "phases": [
        {
          "number": 1,
          "label": "setup",
          "status": "planned",
          "summary": "Setup the repository.",
          "tasks": [
            {"code": "1.1", "title": "Bootstrap", "summary": "Create skeleton.", "owner": "bri", "risk": "normal", "status": "done", "acceptanceCriteria": [], "parallelizable": false}
          ]
        },
        {
          "number": 2,
          "label": "delivery",
          "status": "planned",
          "summary": "Deliver features.",
          "tasks": [
            {"code": "2.1", "title": "Ship", "summary": "Deliver the release.", "owner": "bri", "risk": "normal", "status": "backlog", "acceptanceCriteria": [], "parallelizable": false}
          ]
        }
      ]
    }
    ```

    History:
    - 2025-11-30: updated
    """
}

private extension ArchitectureGeneratorTests {
    func fixedDate() -> Date {
        ISO8601DateFormatter().date(from: "2025-11-29T12:00:00Z")!
    }
}
