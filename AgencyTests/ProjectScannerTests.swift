import Foundation
import Testing
@testable import Agency

@MainActor
struct ProjectScannerTests {
    private let fileManager = FileManager.default

    @Test func scansPhasesAndCards() throws {
        let root = try makeProject(phases: ["phase-0-setup", "phase-1-growth"])
        defer { cleanup(root) }

        let cardContent = """
        ---
        owner: bri
        parallelizable: true
        ---

        Summary:
        Test card
        """

        try writeCard(code: "0.3", slug: "scanner", status: .backlog, in: root, phase: "phase-0-setup", contents: cardContent)
        try writeCard(code: "1.1", slug: "launch", status: .done, in: root, phase: "phase-1-growth", contents: cardContent)

        let snapshots = try ProjectScanner().scan(rootURL: root)

        #expect(snapshots.count == 2)
        #expect(snapshots.first?.cards.first?.status == .backlog)
        #expect(snapshots.first?.cards.first?.isParallelizable == true)
        #expect(snapshots.last?.cards.first?.status == .done)
    }

    @Test func missingStatusDirectoryThrows() throws {
        let root = try makeProject(phases: ["phase-0-setup"])
        defer { cleanup(root) }

        let missing = root.appendingPathComponent("project/phase-0-setup/backlog")
        try fileManager.removeItem(at: missing)

        do {
            _ = try ProjectScanner().scan(rootURL: root)
            Issue.record("Expected scan to throw for missing status directory")
        } catch {
            guard let scannerError = error as? ProjectScannerError,
                  case .missingStatusDirectory(let phase, let status) = scannerError else {
                Issue.record("Unexpected error: \(error)")
                return
            }

            #expect(phase.path == missing.deletingLastPathComponent())
            #expect(status == .backlog)
        }
    }

    @Test func defaultsParallelizableFlag() throws {
        let root = try makeProject(phases: ["phase-0-setup"])
        defer { cleanup(root) }

        let cardContent = """
        ---
        owner: bri
        ---

        Summary:
        Missing parallelizable flag
        """

        try writeCard(code: "0.2", slug: "missing-flag", status: .inProgress, in: root, phase: "phase-0-setup", contents: cardContent)

        let snapshots = try ProjectScanner().scan(rootURL: root)
        let card = try #require(snapshots.first?.cards.first)

        #expect(card.isParallelizable == false)
    }

    @Test func scansOneThousandCardsQuickly() throws {
        let root = try makeProject(phases: ["phase-0-setup"])
        defer { cleanup(root) }

        let body = """
        ---
        owner: bri
        ---

        Summary:
        Load test card
        """

        for index in 0..<1000 {
            let code = "0.\(index)"
            let slug = "card-\(index)"
            try writeCard(code: code, slug: slug, status: .backlog, in: root, phase: "phase-0-setup", contents: body)
        }

        let clock = ContinuousClock()
        let duration = clock.measure {
            _ = try? ProjectScanner().scan(rootURL: root)
        }

        #expect(duration < .milliseconds(500))
    }
}

private extension ProjectScannerTests {
    func makeProject(phases: [String]) throws -> URL {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let project = root.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        for phaseName in phases {
            let phaseURL = project.appendingPathComponent(phaseName, isDirectory: true)
            for status in CardStatus.allCases {
                try fileManager.createDirectory(at: phaseURL.appendingPathComponent(status.folderName, isDirectory: true),
                                                withIntermediateDirectories: true)
            }
        }

        return root
    }

    func writeCard(code: String, slug: String, status: CardStatus, in root: URL, phase: String, contents: String) throws {
        let fileURL = root
            .appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
            .appendingPathComponent(phase, isDirectory: true)
            .appendingPathComponent(status.folderName, isDirectory: true)
            .appendingPathComponent("\(code)-\(slug).md")

        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func cleanup(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }
}
