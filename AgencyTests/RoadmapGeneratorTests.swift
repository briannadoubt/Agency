import XCTest
@testable import Agency

@MainActor
final class RoadmapGeneratorTests: XCTestCase {

    @MainActor
    func testGeneratesRoadmapFromProjectCards() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try makePhase(number: 7,
                      label: "project-bootstrap",
                      cards: [
                        ("7.1-roadmap-spec-and-generator.md", "# 7.1 Roadmap Spec & Generator\n\nSummary:\nDefine roadmap spec.\n\nAcceptance Criteria:\n- [ ] first\n\nNotes:\nnote\n\nHistory:\n- 2025-11-29: seeded\n")
                      ],
                      root: root,
                      status: .backlog)

        let generator = RoadmapGenerator(fileManager: fm,
                                         scanner: ProjectScanner(fileManager: fm, parser: CardFileParser()),
                                         parser: RoadmapParser(),
                                         renderer: RoadmapRenderer(),
                                         dateProvider: { self.fixedDate() })
        let result = try generator.generate(goal: "Bootstrap projects from a roadmap.", at: root)

        let contents = try String(contentsOf: result.roadmapURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("roadmap_version: 1"))
        XCTAssertTrue(contents.contains("Roadmap (machine readable):"))
        XCTAssertTrue(contents.contains("7.1 Roadmap Spec & Generator"))

        let parsed = RoadmapParser().parse(contents: contents)
        XCTAssertEqual(parsed.document?.phases.count, 1)
        XCTAssertEqual(parsed.document?.phases.first?.tasks.count, 1)
        XCTAssertEqual(parsed.history.last, "- 2025-11-29: Regenerated roadmap from goal: Bootstrap projects from a roadmap.")
        XCTAssertEqual(result.document.projectGoal, "Bootstrap projects from a roadmap.")
    }

    @MainActor
    func testRegenerationPreservesManualNotesAndHistory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try makePhase(number: 6,
                      label: "agent-planning",
                      cards: [
                        ("6.1-phase-scaffolding-cli.md", "# 6.1 Phase Scaffolding CLI\n\nSummary:\nCLI work.\n\nAcceptance Criteria:\n- [ ] one\n\nNotes:\nnotes\n\nHistory:\n- 2025-11-28: seeded\n")
                      ],
                      root: root,
                      status: .done)

        let generator = RoadmapGenerator(fileManager: fm,
                                         scanner: ProjectScanner(fileManager: fm, parser: CardFileParser()),
                                         dateProvider: { self.fixedDate() })
        _ = try generator.generate(goal: "Initial goal", at: root)

        let roadmapURL = root.appendingPathComponent("ROADMAP.md")
        var contents = try String(contentsOf: roadmapURL, encoding: .utf8)
        contents.append("\nManual Notes:\nKeep this note\n\nHistory:\n- 2025-11-28: Manual edit\n")
        try contents.write(to: roadmapURL, atomically: true, encoding: .utf8)

        _ = try generator.generate(goal: "Refined goal", at: root)
        let regenerated = try String(contentsOf: roadmapURL, encoding: .utf8)

        XCTAssertTrue(regenerated.contains("Keep this note"))
        XCTAssertTrue(regenerated.contains("Manual edit"))
        XCTAssertTrue(regenerated.contains("Refined goal"))
    }

    func testValidatorCatchesMissingRoadmap() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let validator = RoadmapValidator(fileManager: fm, parser: RoadmapParser())
        let issues = validator.validateRoadmap(at: root)

        XCTAssertTrue(issues.contains { $0.message.contains("Missing ROADMAP.md") })
    }

    func testValidatorCatchesInvalidJSON() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let roadmap = """
        # Roadmap

        Roadmap (machine readable):
        ```json
        not-json
        ```
        """
        try roadmap.write(to: root.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)

        let validator = RoadmapValidator(fileManager: fm, parser: RoadmapParser())
        let issues = validator.validateRoadmap(at: root)

        XCTAssertTrue(issues.contains { $0.message.contains("machine-readable") })
    }
}

// MARK: - Helpers

private extension RoadmapGeneratorTests {
    func fixedDate() -> Date {
        ISO8601DateFormatter().date(from: "2025-11-29T12:00:00Z")!
    }

    func makePhase(number: Int,
                   label: String,
                   cards: [(name: String, contents: String)],
                   root: URL,
                   status: CardStatus) throws {
        let project = root.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phase = project.appendingPathComponent("phase-\(number)-\(label)", isDirectory: true)
        let fm = FileManager.default
        for folder in CardStatus.allCases {
            let dir = phase.appendingPathComponent(folder.folderName, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if folder == status {
                for card in cards {
                    let url = dir.appendingPathComponent(card.name)
                    try card.contents.write(to: url, atomically: true, encoding: .utf8)
                }
            } else {
                fm.createFile(atPath: dir.appendingPathComponent(".gitkeep").path, contents: Data())
            }
        }
    }
}
