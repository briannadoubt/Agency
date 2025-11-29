import Foundation

struct RoadmapTaskEntry: Codable, Equatable {
    let code: String
    let title: String
    let summary: String
    let owner: String?
    let risk: String?
    let status: String
    let acceptanceCriteria: [String]
    let parallelizable: Bool
}

struct RoadmapPhaseEntry: Codable, Equatable {
    enum Status: String, Codable {
        case current
        case planned
        case done
    }

    let number: Int
    let label: String
    let status: Status
    let summary: String
    let tasks: [RoadmapTaskEntry]
}

struct RoadmapDocument: Codable, Equatable {
    let version: Int
    let projectGoal: String
    let generatedAt: String
    let phases: [RoadmapPhaseEntry]
    let manualNotes: String?
}

struct RoadmapGenerationResult: Equatable {
    let roadmapURL: URL
    let document: RoadmapDocument
    let history: [String]
    let markdown: String
}

enum RoadmapGenerationError: LocalizedError, Equatable {
    case emptyGoal
    case noPhases

    var errorDescription: String? {
        switch self {
        case .emptyGoal:
            return "Project brief/goal is required to generate the roadmap."
        case .noPhases:
            return "No phases found under project/; cannot build roadmap."
        }
    }
}

struct RoadmapParseResult {
    let document: RoadmapDocument?
    let history: [String]
    let manualNotes: String?
    let frontmatter: [String: String]
}

struct RoadmapParser {
    func parse(contents: String) -> RoadmapParseResult {
        let (frontmatter, body) = splitFrontmatter(from: contents)
        let sections = sections(from: body)
        let manualNotes = sections["Manual Notes"]?.trimmed()
        let history = parseHistory(from: sections["History"])
        let document = extractDocument(from: sections["Roadmap (machine readable)"])
        return RoadmapParseResult(document: document,
                                  history: history,
                                  manualNotes: manualNotes,
                                  frontmatter: frontmatter)
    }

    private func extractDocument(from section: String?) -> RoadmapDocument? {
        guard let jsonBlock = extractJSON(from: section ?? "") else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(RoadmapDocument.self, from: Data(jsonBlock.utf8))
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
            if trimmed.hasSuffix(":") && trimmed.range(of: #"^[A-Za-z ].*:"#,
                                                       options: .regularExpression) != nil {
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

struct RoadmapRenderer {
    func render(document: RoadmapDocument, history: [String], manualNotes: String?) -> String {
        var lines: [String] = [
            "---",
            "roadmap_version: \(document.version)",
            "project_goal: \(document.projectGoal)",
            "generated_at: \(document.generatedAt)",
            "---",
            "",
            "# Roadmap",
            "",
            "Summary:",
            document.projectGoal,
            "",
            "Phase Overview:"
        ]

        for phase in document.phases {
            lines.append("- Phase \(phase.number) — \(phase.label) (\(phase.status.rawValue))")
        }

        lines.append("")

        for phase in document.phases.sorted(by: { $0.number < $1.number }) {
            lines.append("## Phase \(phase.number) — \(phase.label) (\(phase.status.rawValue))")
            lines.append("")
            lines.append("Summary:")
            lines.append(phase.summary.isEmpty ? "n/a" : phase.summary)
            lines.append("")
            lines.append("Tasks:")
            if phase.tasks.isEmpty {
                lines.append("- (none yet)")
            } else {
                for task in phase.tasks {
                    lines.append("- [\(checkbox(for: task.status))] \(task.code) \(task.title) — \(task.summary.isEmpty ? "No summary yet." : task.summary)")
                    if let owner = task.owner {
                        lines.append("  - Owner: \(owner)")
                    }
                    if let risk = task.risk {
                        lines.append("  - Risk: \(risk)")
                    }
                    if !task.acceptanceCriteria.isEmpty {
                        lines.append("  - Acceptance Criteria:")
                        for criterion in task.acceptanceCriteria {
                            lines.append("    - [ ] \(criterion)")
                        }
                    }
                    lines.append("  - Status: \(task.status)")
                    if task.parallelizable {
                        lines.append("  - Parallelizable: true")
                    }
                }
            }
            lines.append("")
        }

        lines.append("Roadmap (machine readable):")
        lines.append("```json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = (try? encoder.encode(document)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        lines.append(json)
        lines.append("```")
        lines.append("")

        if let manualNotes, !manualNotes.isEmpty {
            lines.append("Manual Notes:")
            lines.append(manualNotes)
            lines.append("")
        }

        lines.append("History:")
        if history.isEmpty {
            lines.append("- \(document.generatedAt): Roadmap generated.")
        } else {
            for entry in history {
                lines.append(entry)
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func checkbox(for status: String) -> String {
        status == CardStatus.done.folderName ? "x" : " "
    }
}

@MainActor
struct RoadmapGenerator {
    private let fileManager: FileManager
    private let scanner: ProjectScanner
    private let parser: RoadmapParser
    private let renderer: RoadmapRenderer
    private let dateProvider: () -> Date

    init(fileManager: FileManager = .default,
         scanner: ProjectScanner = ProjectScanner(),
         parser: RoadmapParser = RoadmapParser(),
         renderer: RoadmapRenderer = RoadmapRenderer(),
         dateProvider: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.scanner = scanner
        self.parser = parser
        self.renderer = renderer
        self.dateProvider = dateProvider
    }

    func generate(goal: String,
                 at rootURL: URL,
                 writeToDisk: Bool = true) throws -> RoadmapGenerationResult {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoadmapGenerationError.emptyGoal
        }

        let snapshots = try scanner.scan(rootURL: rootURL)
        guard !snapshots.isEmpty else { throw RoadmapGenerationError.noPhases }

        let roadmapURL = rootURL.appendingPathComponent("ROADMAP.md")
        let existing = (try? String(contentsOf: roadmapURL, encoding: .utf8))
            .map { parser.parse(contents: $0) }

        let phases = snapshots.map(makePhaseEntry)
        let today = Self.dateFormatter.string(from: dateProvider())
        let document = RoadmapDocument(version: existing?.document?.version ?? 1,
                                       projectGoal: goal,
                                       generatedAt: today,
                                       phases: phases,
                                       manualNotes: existing?.manualNotes ?? existing?.document?.manualNotes)
        let history = mergeHistory(existing?.history ?? [],
                                   newEntry: "- \(today): Regenerated roadmap from goal: \(goal)")
        let markdown = renderer.render(document: document, history: history, manualNotes: document.manualNotes)
        if writeToDisk {
            try markdown.write(to: roadmapURL, atomically: true, encoding: String.Encoding.utf8)
        }

        return RoadmapGenerationResult(roadmapURL: roadmapURL,
                                       document: document,
                                       history: history,
                                       markdown: markdown)
    }

    private func makePhaseEntry(from snapshot: PhaseSnapshot) -> RoadmapPhaseEntry {
        let status: RoadmapPhaseEntry.Status
        if snapshot.cards.contains(where: { $0.status == .inProgress }) {
            status = .current
        } else if snapshot.cards.allSatisfy({ $0.status == .done }) {
            status = .done
        } else {
            status = .planned
        }

        let tasks = snapshot.cards.map { card in
            RoadmapTaskEntry(code: card.code,
                             title: card.title ?? card.slug,
                             summary: card.summary ?? card.notes ?? "",
                             owner: card.frontmatter.owner,
                             risk: card.frontmatter.risk,
                             status: card.status.folderName,
                             acceptanceCriteria: card.acceptanceCriteria.map(\.title),
                             parallelizable: card.isParallelizable)
        }

        let summary: String
        if tasks.isEmpty {
            summary = "No tasks captured yet for this phase."
        } else {
            summary = "Derived from \(tasks.count) task(s) in phase-\(snapshot.phase.number)-\(snapshot.phase.label)."
        }

        return RoadmapPhaseEntry(number: snapshot.phase.number,
                                 label: snapshot.phase.label,
                                 status: status,
                                 summary: summary,
                                 tasks: tasks)
    }

    private func mergeHistory(_ existing: [String], newEntry: String) -> [String] {
        if existing.contains(where: { $0 == newEntry }) {
            return existing
        }
        return existing + [newEntry]
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
