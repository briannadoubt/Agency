import Foundation

/// Validates the ROADMAP.md artifact structure and machine-readable payload.
struct RoadmapValidator {
    private let fileManager: FileManager
    private let parser: RoadmapParser

    init(fileManager: FileManager = .default, parser: RoadmapParser = RoadmapParser()) {
        self.fileManager = fileManager
        self.parser = parser
    }

    func validateRoadmap(at rootURL: URL) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let roadmapURL = rootURL.appendingPathComponent("ROADMAP.md")

        guard fileManager.fileExists(atPath: roadmapURL.path) else {
            issues.append(ValidationIssue(path: relativePath(of: roadmapURL, from: rootURL),
                                          message: "Missing ROADMAP.md at repository root.",
                                          severity: .error,
                                          suggestedFix: "Run the roadmap generator or add ROADMAP.md using the template."))
            return issues
        }

        guard let contents = try? String(contentsOf: roadmapURL, encoding: .utf8) else {
            issues.append(ValidationIssue(path: relativePath(of: roadmapURL, from: rootURL),
                                          message: "Unable to read ROADMAP.md.",
                                          severity: .error,
                                          suggestedFix: "Check file permissions and UTF-8 encoding."))
            return issues
        }

        let parsed = parser.parse(contents: contents)

        guard let document = parsed.document else {
            issues.append(ValidationIssue(path: relativePath(of: roadmapURL, from: rootURL),
                                          message: "Roadmap machine-readable block is missing or invalid.",
                                          severity: .error,
                                          suggestedFix: "Ensure ROADMAP.md includes a `Roadmap (machine readable)` JSON block that matches the schema."))
            return issues
        }

        if document.phases.isEmpty {
            issues.append(ValidationIssue(path: relativePath(of: roadmapURL, from: rootURL),
                                          message: "Roadmap contains no phases.",
                                          severity: .error,
                                          suggestedFix: "Populate phases/tasks or regenerate from the project."))
        }

        if parsed.frontmatter["roadmap_version"] == nil {
            issues.append(ValidationIssue(path: relativePath(of: roadmapURL, from: rootURL),
                                          message: "roadmap_version missing from frontmatter.",
                                          severity: .warning,
                                          suggestedFix: "Add `roadmap_version: 1` to the frontmatter."))
        }

        return issues
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }
}
