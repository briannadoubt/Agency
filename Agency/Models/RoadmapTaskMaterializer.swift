import Foundation

@MainActor
struct TaskMaterializationOptions: Equatable {
    let projectRoot: URL
    let roadmapPath: URL?
    let dryRun: Bool

    init(projectRoot: URL, roadmapPath: URL? = nil, dryRun: Bool = true) {
        self.projectRoot = projectRoot
        self.roadmapPath = roadmapPath
        self.dryRun = dryRun
    }
}

@MainActor
struct TaskMaterializationResult: Equatable {
    let dryRun: Bool
    let created: [String]
    let updated: [String]
    let moved: [String]
    let skipped: [String]
    let warnings: [String]

    var hasWarnings: Bool { !warnings.isEmpty }
}

@MainActor
enum TaskMaterializationError: LocalizedError, Equatable {
    case missingRoadmap(URL)
    case invalidRoadmap
    case conventionsFailed([ValidationIssue])
    case filesystem(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .missingRoadmap(let url):
            return "Missing ROADMAP.md at \(url.path)."
        case .invalidRoadmap:
            return "ROADMAP.md is missing a valid machine-readable block."
        case .conventionsFailed(let issues):
            let first = issues.first?.message ?? "Convention violations found."
            return first
        case .filesystem(let message):
            return message
        }
    }
}

/// Converts roadmap tasks into per-phase markdown cards, preserving existing edits when regenerating.
@MainActor
struct RoadmapTaskMaterializer {
    private let fileManager: FileManager
    private let parser: RoadmapParser
    private let cardParser: CardFileParser
    private let writer: CardMarkdownWriter
    private let validator: ConventionsValidator
    private let dateProvider: () -> Date

    init(fileManager: FileManager = .default,
         parser: RoadmapParser = RoadmapParser(),
         cardParser: CardFileParser = CardFileParser(),
         writer: CardMarkdownWriter = CardMarkdownWriter(),
         validator: ConventionsValidator = ConventionsValidator(),
         dateProvider: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.parser = parser
        self.cardParser = cardParser
        self.writer = writer
        self.validator = validator
        self.dateProvider = dateProvider
    }

    func materialize(options: TaskMaterializationOptions) throws -> TaskMaterializationResult {
        let roadmapURL = options.roadmapPath ?? options.projectRoot.appendingPathComponent("ROADMAP.md")
        guard fileManager.fileExists(atPath: roadmapURL.path) else {
            throw TaskMaterializationError.missingRoadmap(roadmapURL)
        }

        let contents = try String(contentsOf: roadmapURL, encoding: .utf8)
        guard let document = parser.parse(contents: contents).document else {
            throw TaskMaterializationError.invalidRoadmap
        }

        var created: [String] = []
        var updated: [String] = []
        var moved: [String] = []
        var skipped: [String] = []
        var warnings: [String] = []

        let projectURL = options.projectRoot.appendingPathComponent(ProjectConventions.projectRootName,
                                                                   isDirectory: true)
        try ensureProjectFolders(for: document, projectURL: projectURL, root: options.projectRoot, dryRun: options.dryRun)

        for phase in document.phases {
            let phaseURL = projectURL.appendingPathComponent("phase-\(phase.number)-\(phase.label)",
                                                            isDirectory: true)

            for task in phase.tasks {
                let targetStatus = CardStatus(rawValue: task.status) ?? .backlog
                let existingURL = findExistingCard(code: task.code, in: phaseURL)
                let filename: String
                if let existingURL {
                    filename = existingURL.lastPathComponent
                } else {
                    let slug = makeSlug(from: task.title)
                    filename = "\(task.code)-\(slug).md"
                }

                let targetURL = phaseURL
                    .appendingPathComponent(targetStatus.folderName, isDirectory: true)
                    .appendingPathComponent(filename, isDirectory: false)

                if let existingURL {
                    let destination = targetURL
                    if existingURL != destination {
                        if options.dryRun {
                            moved.append(relativePath(of: existingURL, from: options.projectRoot) + " -> " + relativePath(of: destination, from: options.projectRoot))
                        } else {
                            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try fileManager.moveItem(at: existingURL, to: destination)
                            moved.append(relativePath(of: existingURL, from: options.projectRoot) + " -> " + relativePath(of: destination, from: options.projectRoot))
                        }
                    }

                    let snapshotURL = options.dryRun ? existingURL : destination
                    if let snapshot = try? snapshot(at: snapshotURL) {
                        let merged = merge(task: task, into: snapshot)
                        if !options.dryRun {
                            _ = try writer.saveMergedContents(merged, snapshot: snapshot)
                        }
                        updated.append(relativePath(of: destination, from: options.projectRoot))
                    } else {
                        warnings.append("Unable to read existing card for \(task.code); skipping update.")
                        skipped.append(relativePath(of: existingURL, from: options.projectRoot))
                    }
                } else {
                    let rendered = renderNewCard(task: task)
                    if options.dryRun {
                        created.append(relativePath(of: targetURL, from: options.projectRoot))
                    } else {
                        try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try rendered.write(to: targetURL, atomically: true, encoding: .utf8)
                        created.append(relativePath(of: targetURL, from: options.projectRoot))
                    }
                }
            }
        }

        if !options.dryRun {
            let issues = validator.validateProject(at: options.projectRoot)
            let errors = issues.filter { $0.severity == .error }
            if !errors.isEmpty {
                throw TaskMaterializationError.conventionsFailed(errors)
            }
            warnings.append(contentsOf: issues.filter { $0.severity == .warning }.map { $0.message })
        }

        return TaskMaterializationResult(dryRun: options.dryRun,
                                         created: created.uniquePreservingOrder(),
                                         updated: updated.uniquePreservingOrder(),
                                         moved: moved.uniquePreservingOrder(),
                                         skipped: skipped.uniquePreservingOrder(),
                                         warnings: warnings.uniquePreservingOrder())
    }

    // MARK: - Helpers

    private func ensureProjectFolders(for document: RoadmapDocument,
                                      projectURL: URL,
                                      root: URL,
                                      dryRun: Bool) throws {
        if !fileManager.fileExists(atPath: projectURL.path) {
            if !dryRun {
                try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
            }
        }

        for phase in document.phases {
            let phaseURL = projectURL.appendingPathComponent("phase-\(phase.number)-\(phase.label)", isDirectory: true)
            if !fileManager.fileExists(atPath: phaseURL.path) {
                if !dryRun {
                    try fileManager.createDirectory(at: phaseURL, withIntermediateDirectories: true)
                }
            }

            for status in CardStatus.allCases {
                let statusURL = phaseURL.appendingPathComponent(status.folderName, isDirectory: true)
                if !fileManager.fileExists(atPath: statusURL.path) {
                    if !dryRun {
                        try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)
                        let gitkeep = statusURL.appendingPathComponent(".gitkeep")
                        fileManager.createFile(atPath: gitkeep.path, contents: Data())
                    }
                }
            }
        }
    }

    private func findExistingCard(code: String, in phaseURL: URL) -> URL? {
        for status in CardStatus.allCases {
            let statusURL = phaseURL.appendingPathComponent(status.folderName, isDirectory: true)
            guard let contents = try? fileManager.contentsOfDirectory(at: statusURL,
                                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                                      options: [.skipsHiddenFiles]) else { continue }

            if let match = contents.first(where: { $0.lastPathComponent.hasPrefix("\(code)-") }) {
                return match
            }
        }
        return nil
    }

    private func snapshot(at url: URL) throws -> CardDocumentSnapshot {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let modified = attributes[.modificationDate] as? Date ?? Date()
        let card = try cardParser.parse(fileURL: url, contents: contents)
        return CardDocumentSnapshot(card: card, contents: contents, modifiedAt: modified)
    }

    private func merge(task: RoadmapTaskEntry, into snapshot: CardDocumentSnapshot) -> String {
        var draft = CardDetailFormDraft.from(card: snapshot.card, today: dateProvider())
        draft.title = "\(task.code) \(task.title)"
        if let owner = task.owner { draft.owner = owner }
        if let risk = task.risk { draft.risk = risk }
        draft.parallelizable = task.parallelizable || draft.parallelizable
        draft.summary = task.summary

        let roadmapCriteria = task.acceptanceCriteria
        if !roadmapCriteria.isEmpty {
            let existing = Dictionary(uniqueKeysWithValues: draft.criteria.map { ($0.title, $0.isComplete) })
            draft.criteria = roadmapCriteria.map { title in
                CardDetailFormDraft.Criterion(title: title, isComplete: existing[title] ?? false)
            }
        }

        draft.notes = snapshot.card.notes ?? ""
        draft.history = snapshot.card.history

        return writer.renderMarkdown(from: draft,
                                     basedOn: snapshot.card,
                                     existingContents: snapshot.contents,
                                     appendHistory: false)
    }

    private func renderNewCard(task: RoadmapTaskEntry) -> String {
        var lines: [String] = [
            "---",
            "owner: \(task.owner ?? "bri")",
            "agent_flow: null",
            "agent_status: idle",
            "branch: null",
            "risk: \(task.risk ?? "normal")",
            "review: not-requested",
            "parallelizable: \(task.parallelizable ? "true" : "false")",
            "---",
            "",
            "# \(task.code) \(task.title)",
            "",
            "Summary:",
            task.summary,
            "",
            "Acceptance Criteria:",
        ]

        if task.acceptanceCriteria.isEmpty {
            lines.append(contentsOf: ["- [ ] ", ""])
        } else {
            for criterion in task.acceptanceCriteria {
                lines.append("- [ ] \(criterion)")
            }
            lines.append("")
        }

        lines.append("Notes:")
        lines.append("")
        lines.append("History:")
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: dateProvider())
        lines.append("- \(today): Card materialized from ROADMAP.md")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func makeSlug(from title: String) -> String {
        let lowered = title.lowercased()
        let replaced = lowered.map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }

        var slug = String(replaced)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }

        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "card" : slug
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }
}

private extension Array where Element: Hashable {
    func uniquePreservingOrder() -> [Element] {
        var seen: Set<Element> = []
        var result: [Element] = []
        for element in self where !seen.contains(element) {
            seen.insert(element)
            result.append(element)
        }
        return result
    }
}
