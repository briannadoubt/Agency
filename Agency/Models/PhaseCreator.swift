import Foundation
import CryptoKit

enum PhaseScaffoldingError: LocalizedError, Equatable {
    case missingProjectRoot
    case emptyLabel
    case phaseAlreadyExists(String)
    case failedToCreate(String)
    case planWriteFailed(String)

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
        case .planWriteFailed(let message):
            return "Unable to write plan artifact: \(message)"
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
    let materializedCards: [String]
    let skippedTasks: [String]
    let logs: [String]
    let exitCode: Int
}

struct PhaseScaffoldingOptions: Equatable {
    let projectRoot: URL
    let label: String
    let seedPlan: Bool
    let seedCardTitles: [String]
    let taskHints: String?
    let proposedTasks: [String]
    let autoCreateCards: Bool
}

struct PlanTask: Codable, Equatable {
    let title: String
    let acceptanceCriteria: [String]
    let rationale: String
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
                     taskHints: String? = nil,
                     proposedTasks: [String] = [],
                     autoCreateCards: Bool = false) async throws -> PhaseScaffoldingResult {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhaseScaffoldingError.emptyLabel
        }

        let projectURL = projectRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        guard fileManager.directoryExists(at: projectURL) else { throw PhaseScaffoldingError.missingProjectRoot }

        let slug = makeSlug(from: label)
        let nextNumber = try nextPhaseNumber(at: projectURL)
        let phaseName = "phase-\(nextNumber)-\(slug)"
        let phaseURL = projectURL.appendingPathComponent(phaseName, isDirectory: true)

        guard !fileManager.directoryExists(at: phaseURL) else {
            throw PhaseScaffoldingError.phaseAlreadyExists(phaseName)
        }

        var logs: [String] = []
        logs.append("Creating phase \(phaseName)")

        var createdPhaseURL: URL?

        do {
            try fileManager.createDirectory(at: phaseURL, withIntermediateDirectories: true)
            createdPhaseURL = phaseURL

            let statusURLs = try createStatusFolders(at: phaseURL)
            logs.append("Created status folders: \(statusURLs.map { $0.lastPathComponent }.joined(separator: ", "))")

            let phase = try Phase(path: phaseURL)
            var snapshot = PhaseSnapshot(phase: phase, cards: [])
            let planTasks = generatePlanTasks(taskHints: taskHints,
                                              proposedTasks: proposedTasks,
                                              phaseLabel: label)

            var planPath: String?
            if seedPlan {
                planPath = try writePlanArtifact(phaseNumber: nextNumber,
                                                 phaseLabel: label,
                                                 phaseURL: phaseURL,
                                                 taskHints: taskHints,
                                                 tasks: planTasks)
                logs.append("Wrote plan artifact at \(planPath ?? "")")
            }

            var seededCardPaths: [String] = []
            if !seedCardTitles.isEmpty {
                for title in seedCardTitles {
                    let card = try await cardCreator.createCard(in: snapshot,
                                                                title: title,
                                                                includeHistoryEntry: true)
                    snapshot = PhaseSnapshot(phase: phase, cards: snapshot.cards + [card])
                    seededCardPaths.append(card.filePath.path)
                }
                logs.append("Seeded \(seededCardPaths.count) card(s)")
            }

            var materializedCardPaths: [String] = []
            var skippedTasks: [String] = []

            if autoCreateCards, seedPlan {
                let (created, skipped) = try await materializeCards(from: planTasks,
                                                                    snapshot: snapshot)
                snapshot = PhaseSnapshot(phase: snapshot.phase, cards: snapshot.cards + created)
                materializedCardPaths = created.map { $0.filePath.path }
                skippedTasks = skipped
                if !materializedCardPaths.isEmpty {
                    logs.append("Auto-created \(materializedCardPaths.count) cards from plan tasks")
                }
                if !skippedTasks.isEmpty {
                    logs.append("Skipped \(skippedTasks.count) tasks due to duplicates")
                }
            } else if autoCreateCards, !seedPlan {
                logs.append("Auto-create cards requested but plan seed disabled; skipping.")
            }

            return PhaseScaffoldingResult(phaseNumber: nextNumber,
                                          phaseLabel: label,
                                          phaseSlug: slug,
                                          phasePath: phaseURL.path,
                                          createdDirectories: statusFolderPaths(at: phaseURL),
                                          planArtifact: planPath,
                                          seededCards: seededCardPaths,
                                          materializedCards: materializedCardPaths,
                                          skippedTasks: skippedTasks,
                                          logs: logs,
                                          exitCode: 0)
        } catch let error as PhaseScaffoldingError {
            if let createdPhaseURL {
                try? fileManager.removeItem(at: createdPhaseURL)
                let message = "cleanup: removed \(createdPhaseURL.lastPathComponent) after failure."
                logs.append(message)
                fputs(message + "\n", stderr)
            }
            throw error
        } catch {
            if let createdPhaseURL {
                try? fileManager.removeItem(at: createdPhaseURL)
                let message = "cleanup: removed \(createdPhaseURL.lastPathComponent) after failure."
                logs.append(message)
                fputs(message + "\n", stderr)
            }
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
                                   taskHints: String?,
                                   tasks: [PlanTask]) throws -> String {
        let backlogURL = phaseURL.appendingPathComponent(CardStatus.backlog.folderName, isDirectory: true)
        let filename = "\(phaseNumber).0-phase-plan.md"
        let fileURL = backlogURL.appendingPathComponent(filename, isDirectory: false)
        let contents = renderPlanTemplate(phaseNumber: phaseNumber,
                                          phaseLabel: phaseLabel,
                                          taskHints: taskHints,
                                          tasks: tasks)
        do {
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw PhaseScaffoldingError.planWriteFailed(error.localizedDescription)
        }
        return fileURL.path
    }

    private func renderPlanTemplate(phaseNumber: Int,
                                    phaseLabel: String,
                                    taskHints: String?,
                                    tasks: [PlanTask]) -> String {
        let code = "\(phaseNumber).0"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tasksJSON = (try? encoder.encode(tasks)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let checksum = checksumHex(for: tasksJSON)

        var lines: [String] = [
            "---",
            "owner: bri",
            "agent_flow: plan",
            "agent_status: idle",
            "branch: null",
            "risk: normal",
            "review: not-requested",
            "plan_version: 1",
            "plan_checksum: \(checksum)",
            "---",
            "",
            "# \(code) Phase \(phaseLabel) Plan",
            "",
            "Summary:",
            "Plan scaffold for phase \(phaseNumber) (\(phaseLabel)).",
            "",
            "Acceptance Criteria:",
            "- [ ] Plan tasks include rationale and acceptance criteria",
            "- [ ] Cards are created or ready to create from plan tasks",
            "- [ ] Plan checksum recorded for migration safety",
            "",
            "Notes:",
        ]

        if let taskHints, !taskHints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(taskHints)
            lines.append("")
        }

        lines.append("Plan Tasks:")
        if tasks.isEmpty {
            lines.append("- No tasks proposed yet.")
        } else {
            for task in tasks {
                lines.append("- **\(task.title)**")
                lines.append("  - Acceptance Criteria:")
                for criterion in task.acceptanceCriteria {
                    lines.append("    - [ ] \(criterion)")
                }
                lines.append("  - Rationale: \(task.rationale)")
            }
        }
        lines.append("")

        lines.append("Plan Tasks (machine readable):")
        lines.append("```json")
        lines.append(tasksJSON)
        lines.append("```")
        lines.append("")

        let today = DateFormatters.dateString(from: dateProvider())

        lines.append(contentsOf: [
            "History:",
            "- \(today): Phase plan scaffolded by CLI."
        ])

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func checksumHex(for json: String) -> String {
        let data = Data(json.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func generatePlanTasks(taskHints: String?,
                                   proposedTasks: [String],
                                   phaseLabel: String) -> [PlanTask] {
        let sanitizedProposed = proposedTasks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var titles: [String] = sanitizedProposed

        if titles.isEmpty, let taskHints, !taskHints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            titles = taskTitles(fromHints: taskHints)
        }

        if titles.isEmpty {
            titles = defaultTasks(for: phaseLabel)
        }

        var seenSlugs = Set<String>()
        var tasks: [PlanTask] = []
        let rationale = rationaleText(taskHints: taskHints)

        for title in titles {
            let slug = makeSlug(from: title)
            guard !slug.isEmpty, seenSlugs.insert(slug).inserted else { continue }
            tasks.append(PlanTask(title: title,
                                  acceptanceCriteria: acceptanceCriteria(for: title),
                                  rationale: rationale))
        }

        return tasks
    }

    private func taskTitles(fromHints hints: String) -> [String] {
        var titles: [String] = []
        for line in hints.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let cleaned = trimmed
                .replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^\\d+\\.\\s*", with: "", options: .regularExpression)
            if !cleaned.isEmpty {
                titles.append(cleaned)
            }
        }
        return titles
    }

    private func defaultTasks(for phaseLabel: String) -> [String] {
        [
            "Define scope and success criteria for \(phaseLabel)",
            "Draft backlog outline for \(phaseLabel)",
            "Materialize initial cards and owners for \(phaseLabel)"
        ]
    }

    private func acceptanceCriteria(for title: String) -> [String] {
        [
            "Document expected outcome for \(title)",
            "Identify owner, dependencies, and due date for \(title)",
            "Record risks/assumptions and validation steps for \(title)"
        ]
    }

    private func rationaleText(taskHints: String?) -> String {
        guard let taskHints, !taskHints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Seeded during phase creation run."
        }
        return "Derived from provided task hints: \(taskHints)"
    }

    private func materializeCards(from tasks: [PlanTask],
                                  snapshot: PhaseSnapshot) async throws -> ([Card], [String]) {
        var created: [Card] = []
        var skipped: [String] = []
        var workingSnapshot = snapshot

        for task in tasks {
            do {
                let card = try await cardCreator.createCard(in: workingSnapshot,
                                                            title: task.title,
                                                            acceptanceCriteria: task.acceptanceCriteria,
                                                            notes: task.rationale,
                                                            includeHistoryEntry: true)
                workingSnapshot = PhaseSnapshot(phase: workingSnapshot.phase,
                                                cards: workingSnapshot.cards + [card])
                created.append(card)
            } catch let error as CardCreationError {
                if case .duplicateFilename = error {
                    skipped.append(task.title)
                    continue
                }
                throw error
            }
        }

        return (created, skipped)
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
            write("Phase scaffolding starting…")
            write("Label: \(options.label)")
            write("Project: \(options.projectRoot.path)")

            let result = try await creator.createPhase(at: options.projectRoot,
                                                       label: options.label,
                                                       seedPlan: options.seedPlan,
                                                       seedCardTitles: options.seedCardTitles,
                                                       taskHints: options.taskHints,
                                                       proposedTasks: options.proposedTasks,
                                                       autoCreateCards: options.autoCreateCards)
            for log in result.logs {
                write("log: \(log)")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                write(json)
            }
            return Output(exitCode: 0, stdout: stdout, result: result)
        } catch let error as PhaseScaffoldingError {
            write("error: \(error.localizedDescription)")
            let exit: Int
            switch error {
            case .phaseAlreadyExists:
                exit = 2
            case .missingProjectRoot:
                exit = 3
            case .emptyLabel:
                exit = 4
            case .planWriteFailed:
                exit = 5
            case .failedToCreate:
                exit = 1
            }
            return Output(exitCode: exit, stdout: stdout, result: nil)
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
        var proposedTasks: [String] = []
        var autoCreateCards = false

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
            case "--proposed-task":
                index += 1
                guard index < arguments.count else { throw PhaseScaffoldingError.emptyLabel }
                proposedTasks.append(arguments[index])
            case "--auto-create-cards":
                autoCreateCards = true
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
                                       taskHints: taskHints,
                                       proposedTasks: proposedTasks,
                                       autoCreateCards: autoCreateCards)
    }
}
