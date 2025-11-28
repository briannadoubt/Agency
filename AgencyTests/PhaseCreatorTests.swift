import XCTest
@testable import Agency

final class PhaseCreatorTests: XCTestCase {

    @MainActor
    func testCreatesPhaseWithPlanAndSeedCards() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }

        let project = root.appendingPathComponent("project")
        let existing = project.appendingPathComponent("phase-1-existing")
        let existingBacklog = existing.appendingPathComponent(CardStatus.backlog.folderName, isDirectory: true)
        try fm.createDirectory(at: existingBacklog, withIntermediateDirectories: true)
        fm.createFile(atPath: existingBacklog.appendingPathComponent(".gitkeep").path, contents: Data())

        let creator = PhaseCreator(fileManager: fm, dateProvider: { Date(timeIntervalSince1970: 1732752000) }) // 2024-11-28 UTC
        let result = try await creator.createPhase(at: root,
                                                   label: "Agent Planning",
                                                   seedPlan: true,
                                                   seedCardTitles: ["Kickoff"],
                                                   taskHints: "Outline tasks for the phase",
                                                   proposedTasks: ["Kickoff", "Wire CLI", "Document exit codes"])

        XCTAssertFalse(result.phasePath.isEmpty)
        XCTAssertEqual(result.seededCards.count, 1, "seeded=\(result.seededCards)")
        if let planPath = result.planArtifact {
            XCTAssertTrue(FileManager.default.fileExists(atPath: planPath))
        }
    }

    @MainActor
    func testCommandOutputsJSON() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)

        let command = PhaseScaffoldingCommand()
        let output = await command.run(arguments: [
            "--project-root", root.path,
            "--label", "CLI Test",
            "--seed-plan",
            "--seed-card", "First",
            "--proposed-task", "Define CLI entrypoint",
            "--task-hints", "User wants agent-guided phase creation"
        ], fileManager: fm)

        XCTAssertEqual(output.exitCode, 0)
        XCTAssertNotNil(output.result)
        XCTAssertTrue(output.stdout.contains("phase-1-cli-test"))
        XCTAssertTrue(output.stdout.contains("Phase scaffolding starting"))

        let result = try XCTUnwrap(output.result)
        XCTAssertEqual(result.phaseNumber, 1)
        XCTAssertEqual(result.seededCards.count, 1)
        XCTAssertEqual(result.exitCode, 0)
    }

    @MainActor
    func testErrorsWhenProjectRootMissing() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let creator = PhaseCreator(fileManager: fm)

        do {
            _ = try await creator.createPhase(at: root, label: "No Project")
            XCTFail("Expected missing project error")
        } catch let error as PhaseScaffoldingError {
            XCTAssertEqual(error, .missingProjectRoot)
        } catch {
            XCTFail("Unexpected error: \\(error)")
        }
    }
}
