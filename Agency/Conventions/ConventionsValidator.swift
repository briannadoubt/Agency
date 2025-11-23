import Foundation

/// Enumerates the canonical card statuses and their folder names.
enum CardStatus: String, CaseIterable {
    case backlog = "backlog"
    case inProgress = "in-progress"
    case done = "done"

    var folderName: String { rawValue }
}

/// Describes a validation issue discovered while checking project conventions.
struct ValidationIssue: Equatable {
    enum Severity: Equatable {
        case error
        case warning
    }

    let path: String
    let message: String
    let severity: Severity
}

/// Shared constants and helpers for filesystem conventions.
enum ProjectConventions {
    static let projectRootName = "project"
    static let phaseDirectoryPattern = /^phase-\d+-[a-z0-9-]+$/
    static let cardFilenamePattern = /^\d+\.\d+-[a-z0-9-]+\.md$/
}

/// Validates the folder and naming conventions for the markdown-driven kanban project.
struct ConventionsValidator {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Validates the repository at the given root URL.
    /// Returns accumulated issues instead of throwing to tolerate missing/extra sections.
    func validateProject(at rootURL: URL) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let projectURL = rootURL.appendingPathComponent(ProjectConventions.projectRootName)

        guard directoryExists(at: projectURL) else {
            issues.append(ValidationIssue(path: relativePath(of: projectURL, from: rootURL),
                                          message: "Missing \(ProjectConventions.projectRootName) root folder.",
                                          severity: .error))
            return issues
        }

        let phaseDirectories = directories(at: projectURL)
            .filter { phaseDirectoryNameIsValid($0.lastPathComponent) }

        if phaseDirectories.isEmpty {
            issues.append(ValidationIssue(path: relativePath(of: projectURL, from: rootURL),
                                          message: "No phase directories found (expected folders like phase-0-setup).",
                                          severity: .error))
            return issues
        }

        for phaseURL in phaseDirectories {
            issues.append(contentsOf: validatePhase(at: phaseURL, rootURL: rootURL))
        }

        return issues
    }

    private func validatePhase(at phaseURL: URL, rootURL: URL) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        for status in CardStatus.allCases {
            let statusURL = phaseURL.appendingPathComponent(status.folderName)

            guard directoryExists(at: statusURL) else {
                issues.append(ValidationIssue(path: relativePath(of: statusURL, from: rootURL),
                                              message: "Missing \(status.folderName) folder under \(phaseURL.lastPathComponent).",
                                              severity: .error))
                continue
            }

            issues.append(contentsOf: validateCards(in: statusURL, rootURL: rootURL))
        }

        return issues
    }

    private func validateCards(in statusURL: URL, rootURL: URL) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        for entry in files(at: statusURL) {
            let name = entry.lastPathComponent
            guard entry.isFileURL else { continue }

            if !cardFilenameIsValid(name) {
                issues.append(ValidationIssue(path: relativePath(of: entry, from: rootURL),
                                              message: "Card filename does not match <phase>.<task>-slug.md convention.",
                                              severity: .error))
            }
        }

        return issues
    }

    private func directories(at url: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(at: url,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles]) else { return [] }

        return contents.filter { isDirectory($0) }
    }

    private func files(at url: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(at: url,
                                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: [.skipsHiddenFiles]) else { return [] }

        return contents.filter { isRegularFile($0) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private func phaseDirectoryNameIsValid(_ name: String) -> Bool {
        name.wholeMatch(of: ProjectConventions.phaseDirectoryPattern) != nil
    }

    private func cardFilenameIsValid(_ name: String) -> Bool {
        name.wholeMatch(of: ProjectConventions.cardFilenamePattern) != nil
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }
}
