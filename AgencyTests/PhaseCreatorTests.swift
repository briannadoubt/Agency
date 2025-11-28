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
            let contents = try String(contentsOfFile: planPath)
            XCTAssertTrue(contents.contains("plan_version: 1"))
            XCTAssertTrue(contents.contains("Plan Tasks (machine readable):"))
            XCTAssertTrue(contents.contains("Kickoff"))
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
            "--auto-create-cards",
            "--task-hints", "User wants agent-guided phase creation"
        ], fileManager: fm)

        XCTAssertEqual(output.exitCode, 0)
        XCTAssertNotNil(output.result)
        XCTAssertTrue(output.stdout.contains("phase-1-cli-test"))
        XCTAssertTrue(output.stdout.contains("Phase scaffolding starting"))

        let result = try XCTUnwrap(output.result)
        XCTAssertEqual(result.phaseNumber, 1)
        XCTAssertEqual(result.seededCards.count, 1)
        XCTAssertGreaterThanOrEqual(result.materializedCards.count, 1)
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

    @MainActor
    func testAutoMaterializationSkipsDuplicatesGracefully() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }

        let project = root.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)

        let creator = PhaseCreator(fileManager: fm)
        let result = try await creator.createPhase(at: root,
                                                   label: "Dup Test",
                                                   seedPlan: true,
                                                   seedCardTitles: ["Kickoff"],
                                                   taskHints: nil,
                                                   proposedTasks: ["Kickoff", "Wire CLI"],
                                                   autoCreateCards: true)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThanOrEqual(result.materializedCards.count + result.skippedTasks.count, 2)
    }

    @MainActor
    func testCreatesStatusDirectoriesAndGitkeep() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }

        let project = root.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)

        let creator = PhaseCreator(fileManager: fm)
        let result = try await creator.createPhase(at: root,
                                                   label: "Dirs Test",
                                                   seedPlan: false)

        let backlog = URL(fileURLWithPath: result.phasePath).appendingPathComponent("backlog/.gitkeep")
        let inProgress = URL(fileURLWithPath: result.phasePath).appendingPathComponent("in-progress/.gitkeep")
        let done = URL(fileURLWithPath: result.phasePath).appendingPathComponent("done/.gitkeep")

        XCTAssertTrue(fm.fileExists(atPath: backlog.path))
        XCTAssertTrue(fm.fileExists(atPath: inProgress.path))
        XCTAssertTrue(fm.fileExists(atPath: done.path))
    }

    @MainActor
    func testSecondRunCreatesNextPhaseNumber() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }

        let project = root.appendingPathComponent("project")
        let phase = project.appendingPathComponent("phase-1-existing")
        try fm.createDirectory(at: phase, withIntermediateDirectories: true)
        for status in CardStatus.allCases {
            try fm.createDirectory(at: phase.appendingPathComponent(status.folderName, isDirectory: true),
                                   withIntermediateDirectories: true)
        }

        let creator = PhaseCreator(fileManager: fm)
        let first = try await creator.createPhase(at: root, label: "Existing")
        XCTAssertEqual(first.phaseNumber, 2)
        XCTAssertTrue(first.phasePath.contains("phase-2-existing"))
    }

    @MainActor
    func testCLICommandCreatesNextPhaseWhenExistingPresent() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let phase = project.appendingPathComponent("phase-1-existing")
        try fm.createDirectory(at: phase.appendingPathComponent(CardStatus.backlog.folderName),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: phase.appendingPathComponent(CardStatus.inProgress.folderName),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: phase.appendingPathComponent(CardStatus.done.folderName),
                               withIntermediateDirectories: true)

        let command = PhaseScaffoldingCommand()
        let output = await command.run(arguments: [
            "--project-root", root.path,
            "--label", "Existing",
            "--seed-plan"
        ], fileManager: fm)

        XCTAssertEqual(output.exitCode, 0)
        let result = try XCTUnwrap(output.result)
        XCTAssertEqual(result.phaseNumber, 2)
        XCTAssertTrue(result.phasePath.contains("phase-2-existing"))
    }
}
