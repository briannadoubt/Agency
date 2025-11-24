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
            let cardName = "0.1-conventions.md"
            fileManager.createFile(atPath: statusURL.appendingPathComponent(cardName).path, contents: Data())
        }

        return root
    }

    func cleanup(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }
}
