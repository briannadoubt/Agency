import Foundation

enum PhaseScaffoldingError: LocalizedError, Equatable {
    case missingProjectRoot
    case emptyLabel
    case phaseAlreadyExists(String)
    case failedToCreate(String)

    var errorDescription: String? {
        switch self {
        case .missingProjectRoot:
            return "Missing project/ root; run inside a valid Agency repository."
        case .emptyLabel:
            return "Please provide a phase label."
        case .phaseAlreadyExists(let name):
            return "Phase \(name) already exists."
        case .failedToCreate(let message):
            return "Unable to create phase: \(message)"
        }
    }
}

struct PhaseScaffoldingResult: Codable, Equatable {
    let phaseNumber: Int
    let phaseLabel: String
    let phaseSlug: String
    let phasePath: String
    let createdDirectories: [String]
    let planArtifact: String?
    let seededCards: [String]
    let logs: [String]
}

struct PhaseScaffoldingOptions: Equatable {
    let projectRoot: URL
    let label: String
    let seedPlan: Bool
    let seedCardTitles: [String]
    let taskHints: String?
}

/// Creates a new phase directory with status folders, optional plan artifact, and optional seed cards.
struct PhaseCreator {
    private let fileManager: FileManager
    private let cardCreator: CardCreator
    private let dateProvider: () -> Date

    init(fileManager: FileManager = .default,
         cardCreator: CardCreator = CardCreator(),
         dateProvider: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.cardCreator = cardCreator
        self.dateProvider = dateProvider
    }

    func createPhase(at projectRoot: URL,
                     label: String,
                     seedPlan: Bool = false,
                     seedCardTitles: [String] = [],
                     taskHints: String? = nil) async throws -> PhaseScaffoldingResult {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhaseScaffoldingError.emptyLabel
        }

        let projectURL = projectRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        guard directoryExists(at: projectURL) else { throw PhaseScaffoldingError.missingProjectRoot }

        let slug = makeSlug(from: label)
        let nextNumber = try nextPhaseNumber(at: projectURL)
        let phaseName = "phase-\(nextNumber)-\(slug)"
        let phaseURL = projectURL.appendingPathComponent(phaseName, isDirectory: true)

        guard !directoryExists(at: phaseURL) else {
            throw PhaseScaffoldingError.phaseAlreadyExists(phaseName)
        }

        var logs: [String] = []
        logs.append("Creating phase \(phaseName)")

        do {
            try fileManager.createDirectory(at: phaseURL, withIntermediateDirectories: true)
            let statusURLs = try createStatusFolders(at: phaseURL)
            logs.append("Created status folders: \(statusURLs.map { $0.lastPathComponent }.joined(separator: ", "))")

            var planPath: String?
            if seedPlan {
                planPath = try writePlanArtifact(phaseNumber: nextNumber,
                                                 phaseLabel: label,
                                                 phaseURL: phaseURL,
                                                 taskHints: taskHints)
                logs.append("Wrote plan artifact at \(planPath ?? "")")
            }

            var seededCardPaths: [String] = []
            if !seedCardTitles.isEmpty {
                let phase = try Phase(path: phaseURL)
                var snapshot = PhaseSnapshot(phase: phase, cards: [])
                for title in seedCardTitles {
                    let card = try await cardCreator.createCard(in: snapshot,
                                                                title: title,
                                                                includeHistoryEntry: true)
                    snapshot = PhaseSnapshot(phase: phase, cards: snapshot.cards + [card])
                    seededCardPaths.append(card.filePath.path)
                }
                logs.append("Seeded \(seededCardPaths.count) card(s)")
            }

            return PhaseScaffoldingResult(phaseNumber: nextNumber,
                                          phaseLabel: label,
                                          phaseSlug: slug,
                                          phasePath: phaseURL.path,
                                          createdDirectories: statusFolderPaths(at: phaseURL),
                                          planArtifact: planPath,
                                          seededCards: seededCardPaths,
                                          logs: logs)
        } catch {
            throw PhaseScaffoldingError.failedToCreate(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func nextPhaseNumber(at projectURL: URL) throws -> Int {
        guard let contents = try? fileManager.contentsOfDirectory(at: projectURL,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles]) else {
            return 0
        }

        let numbers = contents.compactMap { url -> Int? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false else { return nil }
            guard let phase = try? Phase(path: url) else { return nil }
            return phase.number
        }

        return (numbers.max() ?? 0) + 1
    }

    private func createStatusFolders(at phaseURL: URL) throws -> [URL] {
        var urls: [URL] = []
        for status in CardStatus.allCases {
            let url = phaseURL.appendingPathComponent(status.folderName, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            let keep = url.appendingPathComponent(".gitkeep")
            if !fileManager.fileExists(atPath: keep.path) {
                fileManager.createFile(atPath: keep.path, contents: Data())
            }
            urls.append(url)
        }
        return urls
    }

    private func statusFolderPaths(at phaseURL: URL) -> [String] {
        CardStatus.allCases.map { status in
            phaseURL.appendingPathComponent(status.folderName, isDirectory: true).path
        }
    }

    private func writePlanArtifact(phaseNumber: Int,
                                   phaseLabel: String,
                                   phaseURL: URL,
                                   taskHints: String?) throws -> String {
        let backlogURL = phaseURL.appendingPathComponent(CardStatus.backlog.folderName, isDirectory: true)
        let filename = "\(phaseNumber).0-phase-plan.md"
        let fileURL = backlogURL.appendingPathComponent(filename, isDirectory: false)
        let contents = renderPlanTemplate(phaseNumber: phaseNumber,
                                          phaseLabel: phaseLabel,
                                          taskHints: taskHints)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL.path
    }

    private func renderPlanTemplate(phaseNumber: Int,
                                    phaseLabel: String,
                                    taskHints: String?) -> String {
        let code = "\(phaseNumber).0"
        var lines: [String] = [
            "---",
            "owner: bri",
            "agent_flow: plan",
            "agent_status: idle",
            "branch: null",
            "risk: normal",
            "review: not-requested",
            "---",
            "",
            "# \(code) Phase \(phaseLabel) Plan",
            "",
            "Summary:",
            "Plan scaffold for phase \(phaseNumber) (\(phaseLabel)).",
            "",
            "Acceptance Criteria:",
            "- [ ] Flesh out tasks for phase \(phaseNumber)",
            "- [ ] Generate cards for agreed tasks",
            "",
            "Notes:",
        ]

        if let taskHints, !taskHints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(taskHints)
            lines.append("")
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: dateProvider())

        lines.append(contentsOf: [
            "History:",
            "- \(today): Phase plan scaffolded by CLI."
        ])

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private func makeSlug(from title: String) -> String {
        let lowered = title.lowercased()
        let replaced = lowered.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }

        var slug = String(replaced)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }

        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "phase" : slug
    }
}

/// Minimal CLI-style wrapper for phase scaffolding. Keeps human logs and JSON result on stdout.
struct PhaseScaffoldingCommand {
    struct Output {
        let exitCode: Int
        let stdout: String
        let result: PhaseScaffoldingResult?
    }

    func run(arguments: [String], fileManager: FileManager = .default) async -> Output {
        var stdout = ""
        func write(_ line: String) {
            stdout.append(line)
            stdout.append("\n")
        }

        do {
            let options = try parse(arguments: arguments)
            let creator = PhaseCreator(fileManager: fileManager)
            let result = try await creator.createPhase(at: options.projectRoot,
                                                       label: options.label,
                                                       seedPlan: options.seedPlan,
                                                       seedCardTitles: options.seedCardTitles,
                                                       taskHints: options.taskHints)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                write(json)
            }
            return Output(exitCode: 0, stdout: stdout, result: result)
        } catch {
            write("error: \(error.localizedDescription)")
            return Output(exitCode: 1, stdout: stdout, result: nil)
        }
    }

    // MARK: - Argument Parsing

    private func parse(arguments: [String]) throws -> PhaseScaffoldingOptions {
        var label: String?
        var projectRoot: URL?
        var seedPlan = false
        var seedCardTitles: [String] = []
        var taskHints: String?

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--label":
                index += 1
                guard index < arguments.count else { throw PhaseScaffoldingError.emptyLabel }
                label = arguments[index]
            case "--project-root":
                index += 1
                guard index < arguments.count else { throw PhaseScaffoldingError.missingProjectRoot }
                projectRoot = URL(fileURLWithPath: arguments[index])
            case "--seed-plan":
                seedPlan = true
            case "--seed-card":
                index += 1
                guard index < arguments.count else { throw PhaseScaffoldingError.emptyLabel }
                seedCardTitles.append(arguments[index])
            case "--task-hints":
                index += 1
                guard index < arguments.count else { throw PhaseScaffoldingError.emptyLabel }
                taskHints = arguments[index]
            default:
                break
            }
            index += 1
        }

        guard let label, let projectRoot else {
            if projectRoot == nil { throw PhaseScaffoldingError.missingProjectRoot }
            throw PhaseScaffoldingError.emptyLabel
        }

        return PhaseScaffoldingOptions(projectRoot: projectRoot,
                                       label: label,
                                       seedPlan: seedPlan,
                                       seedCardTitles: seedCardTitles,
                                       taskHints: taskHints)
    }
}
