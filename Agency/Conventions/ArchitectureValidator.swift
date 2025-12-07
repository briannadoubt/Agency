import Foundation

/// Validates ARCHITECTURE.md presence, structure, and freshness relative to ROADMAP.md.
struct ArchitectureValidator {
    private let fileManager: FileManager
    private let parser: ArchitectureParser
    private let roadmapParser: RoadmapParser

    init(fileManager: FileManager = .default,
         parser: ArchitectureParser = ArchitectureParser(),
         roadmapParser: RoadmapParser = RoadmapParser()) {
        self.fileManager = fileManager
        self.parser = parser
        self.roadmapParser = roadmapParser
    }

    func validateArchitecture(at rootURL: URL) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let architectureURL = rootURL.appendingPathComponent("ARCHITECTURE.md")

        guard fileManager.fileExists(atPath: architectureURL.path) else {
            issues.append(ValidationIssue(path: relativePath(of: architectureURL, from: rootURL),
                                          message: "Missing ARCHITECTURE.md at repository root.",
                                          severity: .error,
                                          suggestedFix: "Run the architecture generator to create ARCHITECTURE.md."))
            return issues
        }

        guard let contents = try? String(contentsOf: architectureURL, encoding: .utf8) else {
            issues.append(ValidationIssue(path: relativePath(of: architectureURL, from: rootURL),
                                          message: "Unable to read ARCHITECTURE.md.",
                                          severity: .error,
                                          suggestedFix: "Check file permissions and UTF-8 encoding."))
            return issues
        }

        let parsed = parser.parse(contents: contents)
        guard let document = parsed.document else {
            issues.append(ValidationIssue(path: relativePath(of: architectureURL, from: rootURL),
                                          message: "Architecture machine-readable block is missing or invalid.",
                                          severity: .error,
                                          suggestedFix: "Ensure ARCHITECTURE.md includes an `Architecture (machine readable)` JSON block."))
            return issues
        }

        let requiredSections = [
            "Summary",
            "Goals & Constraints",
            "System Overview",
            "Components",
            "Data & Storage",
            "Integrations",
            "Testing & Observability",
            "Risks & Mitigations",
            "History"
        ]

        for section in requiredSections {
            let content = parsed.sections[section]?.trimmed() ?? ""
            if content.isEmpty {
                issues.append(ValidationIssue(path: relativePath(of: architectureURL, from: rootURL),
                                              message: "Missing required section: \(section).",
                                              severity: .warning,
                                              suggestedFix: "Add a '\(section):' section to ARCHITECTURE.md."))
            }
        }

        if parsed.frontmatter["architecture_version"] == nil {
            issues.append(ValidationIssue(path: relativePath(of: architectureURL, from: rootURL),
                                          message: "architecture_version missing from frontmatter.",
                                          severity: .warning,
                                          suggestedFix: "Add `architecture_version: 1` to the frontmatter."))
        }

        let roadmapURL = rootURL.appendingPathComponent("ROADMAP.md")
        if let roadmapContents = try? String(contentsOf: roadmapURL, encoding: .utf8),
           let roadmapDocument = roadmapParser.parse(contents: roadmapContents).document {
            let expected = ArchitectureGenerator.fingerprint(for: roadmapDocument)
            if expected != document.roadmapFingerprint {
                issues.append(ValidationIssue(path: relativePath(of: architectureURL, from: rootURL),
                                              message: "ARCHITECTURE.md is stale compared to ROADMAP.md.",
                                              severity: .warning,
                                              suggestedFix: "Regenerate ARCHITECTURE.md after updating the roadmap."))
            }
        } else {
            issues.append(ValidationIssue(path: relativePath(of: roadmapURL, from: rootURL),
                                          message: "ROADMAP.md missing or unreadable; cannot verify architecture currency.",
                                          severity: .warning,
                                          suggestedFix: "Add or fix ROADMAP.md, then rerun validation."))
        }

        return issues
    }

    // MARK: - Helpers

    private func relativePath(of url: URL, from root: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }
}
