import Foundation
import CryptoKit
import os.log

/// User-supplied inputs that tailor the generated architecture.
struct ArchitectureInput: Equatable {
    let targetPlatforms: [String]
    let languages: [String]
    let techStack: [String]
}

/// Options controlling how ARCHITECTURE.md is produced.
@MainActor
struct ArchitectureGenerationOptions: Equatable {
    let projectRoot: URL
    let roadmapPath: URL?
    let inputs: ArchitectureInput
    let dryRun: Bool

    init(projectRoot: URL,
         roadmapPath: URL? = nil,
         inputs: ArchitectureInput,
         dryRun: Bool = true) {
        self.projectRoot = projectRoot
        self.roadmapPath = roadmapPath
        self.inputs = inputs
        self.dryRun = dryRun
    }

    var resolvedRoadmapPath: URL {
        roadmapPath ?? projectRoot.appendingPathComponent("ROADMAP.md")
    }
}

struct ArchitectureTaskSummary: Codable, Equatable {
    let code: String
    let title: String
    let summary: String
    let status: String
}

struct ArchitecturePhaseSummary: Codable, Equatable {
    let number: Int
    let label: String
    let status: String
    let tasks: [ArchitectureTaskSummary]
}

struct ArchitectureDocument: Codable, Equatable {
    let version: Int
    let generatedAt: String
    let projectGoal: String
    let targetPlatforms: [String]
    let languages: [String]
    let techStack: [String]
    let roadmapFingerprint: String
    let phases: [ArchitecturePhaseSummary]
    let manualNotes: String?
}

struct ArchitectureGenerationResult: Equatable {
    let dryRun: Bool
    let architecturePath: String
    let history: [String]
    let markdown: String
}

enum ArchitectureGenerationError: LocalizedError, Equatable {
    case missingRoadmap(URL)
    case invalidRoadmap
    case filesystem(String)

    var errorDescription: String? {
        switch self {
        case .missingRoadmap(let url):
            return "Missing ROADMAP.md at \(url.path)."
        case .invalidRoadmap:
            return "ROADMAP.md is missing a valid machine-readable block."
        case .filesystem(let message):
            return message
        }
    }
}

/// Parses ARCHITECTURE.md into a machine-readable document plus preserved notes/history.
struct ArchitectureParseResult {
    let document: ArchitectureDocument?
    let manualNotes: String?
    let history: [String]
    let frontmatter: [String: String]
    let sections: [String: String]
}

struct ArchitectureParser {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "ArchitectureParser")

    func parse(contents: String) -> ArchitectureParseResult {
        let (frontmatter, body) = splitFrontmatter(from: contents)
        let sections = sections(from: body)
        let manualNotes = sections["Manual Notes"]?.trimmed()
        let history = parseHistory(from: sections["History"])
        let document = extractDocument(from: sections["Architecture (machine readable)"])

        return ArchitectureParseResult(document: document,
                                       manualNotes: manualNotes,
                                       history: history,
                                       frontmatter: frontmatter,
                                       sections: sections)
    }

    private func extractDocument(from section: String?) -> ArchitectureDocument? {
        guard let jsonBlock = extractJSON(from: section ?? "") else { return nil }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(ArchitectureDocument.self, from: Data(jsonBlock.utf8))
        } catch {
            Self.logger.warning("Failed to decode ArchitectureDocument from JSON: \(error.localizedDescription)")
            return nil
        }
    }

    private func extractJSON(from section: String) -> String? {
        guard let fenceStart = section.range(of: "```json") else { return nil }
        let remainder = section[fenceStart.upperBound...]
        guard let fenceEnd = remainder.range(of: "```") else { return nil }
        let json = remainder[..<fenceEnd.lowerBound]
        return String(json).trimmed()
    }

    private func parseHistory(from section: String?) -> [String] {
        guard let section else { return [] }
        return section
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
    }

    private func splitFrontmatter(from contents: String) -> ([String: String], String) {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(of: "---"),
              let end = lines[(start + 1)...].firstIndex(of: "---"),
              start == 0 else {
            return ([:], contents)
        }

        let frontmatterLines = Array(lines[(start + 1)..<end])
        var entries: [String: String] = [:]
        for line in frontmatterLines {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            entries[parts[0]] = parts[1]
        }

        let bodyLines = Array(lines[(end + 1)...])
        return (entries, bodyLines.joined(separator: "\n"))
    }

    private func sections(from body: String) -> [String: String] {
        var sections: [String: String] = [:]
        var currentTitle: String?
        var currentLines: [String] = []

        func flush() {
            guard let title = currentTitle else { return }
            sections[title] = currentLines.joined(separator: "\n").trimmed()
        }

        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") && trimmed.range(of: #"^[A-Za-z0-9 ().&/+-]+:"#, options: .regularExpression) != nil {
                flush()
                currentTitle = String(trimmed.dropLast())
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }

        flush()
        return sections
    }
}

/// Renders ARCHITECTURE.md in a deterministic, roadmap-aligned layout.
struct ArchitectureRenderer {
    func render(document: ArchitectureDocument, history: [String], manualNotes: String?) -> String {
        var lines: [String] = [
            "---",
            "architecture_version: \(document.version)",
            "roadmap_fingerprint: \(document.roadmapFingerprint)",
            "generated_at: \(document.generatedAt)",
            "project_goal: \(document.projectGoal)",
            "---",
            "",
            "# ARCHITECTURE.md",
            "",
            "Summary:",
            document.projectGoal,
            "",
            "Goals & Constraints:",
            "- Target platforms: \(list(document.targetPlatforms))",
            "- Languages: \(list(document.languages))",
            "- Tech stack: \(list(document.techStack))",
            "- Roadmap alignment: \(document.phases.count) phase(s); fingerprint \(document.roadmapFingerprint.prefix(12))",
            "",
            "System Overview:",
            "- Build for \(list(document.targetPlatforms)) using \(list(document.languages)) across \(list(document.techStack)).",
            "- Keep architecture current with roadmap tasks; regenerate when phases change.",
            "",
            "Components:"
        ]

        for phase in document.phases.sorted(by: { $0.number < $1.number }) {
            lines.append("- Phase \(phase.number) — \(phase.label) (\(phase.status))")
            if phase.tasks.isEmpty {
                lines.append("  - Tasks: none recorded in roadmap.")
            } else {
                lines.append("  - Tasks:")
                for task in phase.tasks {
                    lines.append("    - [\(checkbox(for: task.status))] \(task.code) \(task.title) — \(task.summary.isEmpty ? "No summary yet." : task.summary)")
                }
            }
        }

        lines.append(contentsOf: [
            "",
            "Data & Storage:",
            "- Align storage with platform constraints; prefer sandbox-friendly paths and backups.",
            "- Revisit data boundaries as roadmap phases complete and new components land.",
            "",
            "Integrations:",
            document.techStack.isEmpty ? "- None specified yet." : document.techStack.map { "- \($0)" }.joined(separator: "\n"),
            "",
            "Testing & Observability:",
            "- Mirror roadmap acceptance criteria with unit/UI tests per component.",
            "- Add logging/metrics for critical paths; update as phases progress.",
            "",
            "Risks & Mitigations:",
            "- Stale architecture vs roadmap: compare fingerprints and regenerate after roadmap changes.",
            "- Preserve manual annotations in Manual Notes; generator keeps them across runs.",
            "",
            "Architecture (machine readable):",
            "```json",
            json(from: document),
            "```",
            "",
            "Manual Notes:"
        ])

        if let manualNotes, !manualNotes.isEmpty {
            lines.append(manualNotes)
        } else {
            lines.append("None yet.")
        }

        lines.append(contentsOf: [
            "",
            "History:"
        ])

        if history.isEmpty {
            lines.append("- \(document.generatedAt): Architecture generated from roadmap.")
        } else {
            lines.append(contentsOf: history)
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func checkbox(for status: String) -> String {
        status == CardStatus.done.folderName ? "x" : " "
    }

    private func list(_ values: [String]) -> String {
        values.isEmpty ? "unspecified" : values.joined(separator: ", ")
    }

    private func json(from document: ArchitectureDocument) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(document),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

/// Generates ARCHITECTURE.md from ROADMAP.md and user-supplied stack inputs.
@MainActor
struct ArchitectureGenerator {
    private let fileManager: FileManager
    private let roadmapParser: RoadmapParser
    private let parser: ArchitectureParser
    private let renderer: ArchitectureRenderer
    private let dateProvider: () -> Date

    init(fileManager: FileManager = .default,
         roadmapParser: RoadmapParser = RoadmapParser(),
         parser: ArchitectureParser = ArchitectureParser(),
         renderer: ArchitectureRenderer = ArchitectureRenderer(),
         dateProvider: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.roadmapParser = roadmapParser
        self.parser = parser
        self.renderer = renderer
        self.dateProvider = dateProvider
    }

    func generate(options: ArchitectureGenerationOptions) throws -> ArchitectureGenerationResult {
        let roadmapURL = options.resolvedRoadmapPath
        guard fileManager.fileExists(atPath: roadmapURL.path) else {
            throw ArchitectureGenerationError.missingRoadmap(roadmapURL)
        }

        let contents = try String(contentsOf: roadmapURL, encoding: .utf8)
        guard let roadmap = roadmapParser.parse(contents: contents).document else {
            throw ArchitectureGenerationError.invalidRoadmap
        }

        let architectureURL = options.projectRoot.appendingPathComponent("ARCHITECTURE.md")
        let existing = (try? String(contentsOf: architectureURL, encoding: .utf8))
            .map { parser.parse(contents: $0) }

        let fingerprint = Self.fingerprint(for: roadmap)
        let today = DateFormatters.dateString(from: dateProvider())
        let document = ArchitectureDocument(version: existing?.document?.version ?? 1,
                                            generatedAt: today,
                                            projectGoal: roadmap.projectGoal,
                                            targetPlatforms: options.inputs.targetPlatforms,
                                            languages: options.inputs.languages,
                                            techStack: options.inputs.techStack,
                                            roadmapFingerprint: fingerprint,
                                            phases: makePhaseSummaries(from: roadmap),
                                            manualNotes: existing?.manualNotes ?? existing?.document?.manualNotes)
        let newHistoryEntry = "- \(today): Regenerated architecture from roadmap."
        let history = mergeHistory(existing?.history ?? [], newEntry: newHistoryEntry)
        let markdown = renderer.render(document: document, history: history, manualNotes: document.manualNotes)

        if !options.dryRun {
            do {
                try markdown.write(to: architectureURL, atomically: true, encoding: .utf8)
            } catch {
                throw ArchitectureGenerationError.filesystem(error.localizedDescription)
            }
        }

        return ArchitectureGenerationResult(dryRun: options.dryRun,
                                            architecturePath: relativePath(of: architectureURL, from: options.projectRoot),
                                            history: history,
                                            markdown: markdown)
    }

    // MARK: - Helpers

    static func fingerprint(for document: RoadmapDocument) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(document)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func makePhaseSummaries(from roadmap: RoadmapDocument) -> [ArchitecturePhaseSummary] {
        roadmap.phases
            .sorted(by: { $0.number < $1.number })
            .map { phase in
                let tasks = phase.tasks.map { task in
                    ArchitectureTaskSummary(code: task.code,
                                            title: task.title,
                                            summary: task.summary,
                                            status: task.status)
                }
                return ArchitecturePhaseSummary(number: phase.number,
                                                label: phase.label,
                                                status: phase.status.rawValue,
                                                tasks: tasks)
            }
    }

    private func mergeHistory(_ existing: [String], newEntry: String) -> [String] {
        if existing.contains(where: { $0 == newEntry }) {
            return existing
        }
        return existing + [newEntry]
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }
}
