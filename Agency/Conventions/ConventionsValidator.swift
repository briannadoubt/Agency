import Foundation

/// Enumerates the canonical card statuses and their folder names.
enum CardStatus: String, CaseIterable {
    case backlog = "backlog"
    case inProgress = "in-progress"
    case done = "done"

    nonisolated var folderName: String { rawValue }

    /// Human-readable label used for UI and history entries.
    nonisolated var displayName: String {
        switch self {
        case .backlog:
            return "Backlog"
        case .inProgress:
            return "In Progress"
        case .done:
            return "Done"
        }
    }

    /// Linear workflow index used to validate transitions without skips.
    nonisolated private var workflowIndex: Int {
        switch self {
        case .backlog: return 0
        case .inProgress: return 1
        case .done: return 2
        }
    }

    /// Returns true when transitioning directly between adjacent workflow states.
    nonisolated func canTransition(to status: CardStatus) -> Bool {
        abs(workflowIndex - status.workflowIndex) <= 1
    }
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
    let suggestedFix: String?
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
    private let parser: CardFileParser
    private let roadmapParser: RoadmapParser
    private let architectureParser: ArchitectureParser

    init(fileManager: FileManager = .default,
         parser: CardFileParser = CardFileParser(),
         roadmapParser: RoadmapParser = RoadmapParser(),
         architectureParser: ArchitectureParser = ArchitectureParser()) {
        self.fileManager = fileManager
        self.parser = parser
        self.roadmapParser = roadmapParser
        self.architectureParser = architectureParser
    }

    /// Validates the repository at the given root URL.
    /// Returns accumulated issues instead of throwing to tolerate missing/extra sections.
    func validateProject(at rootURL: URL) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let projectURL = rootURL.appendingPathComponent(ProjectConventions.projectRootName)
        var cards: [(code: String, path: String)] = []
        var parsedCards: [Card] = []

        guard fileManager.directoryExists(at: projectURL) else {
            issues.append(ValidationIssue(path: relativePath(of: projectURL, from: rootURL),
                                          message: "Missing \(ProjectConventions.projectRootName) root folder.",
                                          severity: .error,
                                          suggestedFix: "Create a project/ folder containing phase-<n>-<name> directories."))
            return issues
        }

        let roadmapURL = rootURL.appendingPathComponent("ROADMAP.md")
        let roadmapDocument = validateRoadmap(at: roadmapURL,
                                              rootURL: rootURL,
                                              issues: &issues)

        let architectureURL = rootURL.appendingPathComponent("ARCHITECTURE.md")
        let architectureDocument = validateArchitecture(at: architectureURL,
                                                        rootURL: rootURL,
                                                        roadmap: roadmapDocument,
                                                        issues: &issues)

        let phaseDirectories = directories(at: projectURL)
            .filter { phaseDirectoryNameIsValid($0.lastPathComponent) }

        if phaseDirectories.isEmpty {
            issues.append(ValidationIssue(path: relativePath(of: projectURL, from: rootURL),
                                          message: "No phase directories found (expected folders like phase-0-setup).",
                                          severity: .error,
                                          suggestedFix: "Add a phase-* directory with backlog/in-progress/done children."))
            return issues
        }

        for phaseURL in phaseDirectories {
            let (phaseIssues, phaseCards, parsed) = validatePhase(at: phaseURL, rootURL: rootURL)
            issues.append(contentsOf: phaseIssues)
            cards.append(contentsOf: phaseCards)
            parsedCards.append(contentsOf: parsed)
        }

        issues.append(contentsOf: duplicateCodeIssues(from: cards))

        if let roadmapDocument {
            let codes = Set(cards.map { $0.code })
            issues.append(contentsOf: validateRoadmapTasks(roadmapDocument,
                                                           cards: parsedCards,
                                                           codesOnDisk: codes,
                                                           rootURL: rootURL))
        }

        if let roadmapDocument, let architectureDocument {
            issues.append(contentsOf: validateArchitectureFreshness(architectureDocument,
                                                                    roadmap: roadmapDocument,
                                                                    rootURL: rootURL))
        }

        return issues
    }

    private func validatePhase(at phaseURL: URL, rootURL: URL) -> ([ValidationIssue], [(code: String, path: String)], [Card]) {
        var issues: [ValidationIssue] = []
        var cards: [(code: String, path: String)] = []
        var parsedCards: [Card] = []

        let statusFolders = Set(CardStatus.allCases.map { $0.folderName })

        for entry in entries(at: phaseURL) {
            let name = entry.lastPathComponent
            if statusFolders.contains(name) { continue }

            issues.append(ValidationIssue(path: relativePath(of: entry, from: rootURL),
                                          message: "Orphaned item inside phase; not under a status folder.",
                                          severity: .warning,
                                          suggestedFix: "Move to one of: backlog/, in-progress/, done/."))
        }

        for status in CardStatus.allCases {
            let statusURL = phaseURL.appendingPathComponent(status.folderName)

            guard fileManager.directoryExists(at: statusURL) else {
                issues.append(ValidationIssue(path: relativePath(of: statusURL, from: rootURL),
                                              message: "Missing \(status.folderName) folder under \(phaseURL.lastPathComponent).",
                                              severity: .error,
                                              suggestedFix: "Create \(status.folderName) and move relevant cards into it."))
                continue
            }

            let (cardIssues, scannedCards, parsed) = validateCards(in: statusURL, rootURL: rootURL)
            issues.append(contentsOf: cardIssues)
            cards.append(contentsOf: scannedCards)
            parsedCards.append(contentsOf: parsed)
        }

        return (issues, cards, parsedCards)
    }

    private func validateCards(in statusURL: URL, rootURL: URL) -> ([ValidationIssue], [(code: String, path: String)], [Card]) {
        var issues: [ValidationIssue] = []
        var cards: [(code: String, path: String)] = []
        var parsedCards: [Card] = []

        for entry in files(at: statusURL) {
            let name = entry.lastPathComponent
            guard entry.isFileURL else { continue }

            if !cardFilenameIsValid(name) {
                issues.append(ValidationIssue(path: relativePath(of: entry, from: rootURL),
                                              message: "Card filename does not match <phase>.<task>-slug.md convention.",
                                              severity: .error,
                                              suggestedFix: "Rename to <phase>.<task>-slug.md (e.g. 4.3-validator.md)."))
                continue
            }

            let code = String(name.split(separator: "-").first ?? "")
            cards.append((code: code, path: relativePath(of: entry, from: rootURL)))

            guard let contents = try? String(contentsOf: entry, encoding: .utf8) else {
                issues.append(ValidationIssue(path: relativePath(of: entry, from: rootURL),
                                              message: "Unable to read file contents.",
                                              severity: .warning,
                                              suggestedFix: "Confirm file permissions and UTF-8 encoding."))
                continue
            }

            do {
                let card = try parser.parse(fileURL: entry, contents: contents)
                parsedCards.append(card)
                issues.append(contentsOf: structuralIssues(for: card, rootURL: rootURL))
            } catch {
                issues.append(ValidationIssue(path: relativePath(of: entry, from: rootURL),
                                              message: "Failed to parse card: \(error.localizedDescription)",
                                              severity: .error,
                                              suggestedFix: "Fix YAML frontmatter or section headings, then re-run validator."))
            }
        }

        return (issues, cards, parsedCards)
    }

    private func validateRoadmap(at roadmapURL: URL,
                                 rootURL: URL,
                                 issues: inout [ValidationIssue]) -> RoadmapDocument? {
        guard fileManager.fileExists(atPath: roadmapURL.path) else {
            issues.append(ValidationIssue(path: relativePath(of: roadmapURL, from: rootURL),
                                          message: "Missing ROADMAP.md.",
                                          severity: .error,
                                          suggestedFix: "Generate ROADMAP.md or run the initializer with a goal/roadmap."))
            return nil
        }

        do {
            let contents = try String(contentsOf: roadmapURL, encoding: .utf8)
            let parsed = roadmapParser.parse(contents: contents)
            guard let document = parsed.document else {
                issues.append(ValidationIssue(path: relativePath(of: roadmapURL, from: rootURL),
                                              message: "ROADMAP.md is missing a valid machine-readable block.",
                                              severity: .error,
                                              suggestedFix: "Ensure the 'Roadmap (machine readable)' JSON exists or regenerate the roadmap."))
                return nil
            }

            if document.phases.isEmpty {
                issues.append(ValidationIssue(path: relativePath(of: roadmapURL, from: rootURL),
                                              message: "ROADMAP.md has no phases.",
                                              severity: .error,
                                              suggestedFix: "Add at least one phase to the roadmap."))
            }

            if document.projectGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(ValidationIssue(path: relativePath(of: roadmapURL, from: rootURL),
                                              message: "ROADMAP.md is missing a project goal.",
                                              severity: .warning,
                                              suggestedFix: "Populate project_goal and regenerate the roadmap."))
            }

            return document
        } catch {
            issues.append(ValidationIssue(path: relativePath(of: roadmapURL, from: rootURL),
                                          message: "Unable to read ROADMAP.md: \(error.localizedDescription)",
                                          severity: .error,
                                          suggestedFix: "Check file permissions and encoding."))
            return nil
        }
    }

    private func validateArchitecture(at architectureURL: URL,
                                      rootURL: URL,
                                      roadmap: RoadmapDocument?,
                                      issues: inout [ValidationIssue]) -> ArchitectureDocument? {
        guard fileManager.fileExists(atPath: architectureURL.path) else {
            issues.append(ValidationIssue(path: relativePath(of: architectureURL, from: rootURL),
                                          message: "Missing ARCHITECTURE.md.",
                                          severity: .error,
                                          suggestedFix: "Run the initializer or architecture generator to create ARCHITECTURE.md."))
            return nil
        }

        do {
            let contents = try String(contentsOf: architectureURL, encoding: .utf8)
            let parsed = architectureParser.parse(contents: contents)
            guard let document = parsed.document else {
                issues.append(ValidationIssue(path: relativePath(of: architectureURL, from: rootURL),
                                              message: "ARCHITECTURE.md is missing a valid machine-readable block.",
                                              severity: .error,
                                              suggestedFix: "Ensure the 'Architecture (machine readable)' JSON exists or regenerate ARCHITECTURE.md."))
                return nil
            }

            if document.phases.isEmpty {
                issues.append(ValidationIssue(path: relativePath(of: architectureURL, from: rootURL),
                                              message: "ARCHITECTURE.md has no phases.",
                                              severity: .warning,
                                              suggestedFix: "Regenerate architecture from the roadmap."))
            }

            if document.projectGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(ValidationIssue(path: relativePath(of: architectureURL, from: rootURL),
                                              message: "ARCHITECTURE.md is missing the project goal.",
                                              severity: .warning,
                                              suggestedFix: "Regenerate architecture from roadmap to include project_goal."))
            }

            return document
        } catch {
            issues.append(ValidationIssue(path: relativePath(of: architectureURL, from: rootURL),
                                          message: "Unable to read ARCHITECTURE.md: \(error.localizedDescription)",
                                          severity: .error,
                                          suggestedFix: "Check file permissions and encoding."))
            return nil
        }
    }

    private func validateArchitectureFreshness(_ architecture: ArchitectureDocument,
                                               roadmap: RoadmapDocument,
                                               rootURL: URL) -> [ValidationIssue] {
        let expected = ArchitectureGenerator.fingerprint(for: roadmap)
        guard architecture.roadmapFingerprint != expected else { return [] }

        return [ValidationIssue(path: "ARCHITECTURE.md",
                                message: "ARCHITECTURE.md is out of date with ROADMAP.md (fingerprint mismatch).",
                                severity: .warning,
                                suggestedFix: "Regenerate ARCHITECTURE.md after updating ROADMAP.md." )]
    }

    private func validateRoadmapTasks(_ roadmap: RoadmapDocument,
                                      cards: [Card],
                                      codesOnDisk: Set<String>,
                                      rootURL: URL) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var cardsByCode: [String: Card] = [:]
        for card in cards where cardsByCode[card.code] == nil {
            cardsByCode[card.code] = card
        }

        for phase in roadmap.phases {
            for task in phase.tasks {
                let phasePath = "project/phase-\(phase.number)-\(phase.label)"
                if !codesOnDisk.contains(task.code) {
                    issues.append(ValidationIssue(path: phasePath,
                                                  message: "Missing card for roadmap task \(task.code) \(task.title).",
                                                  severity: .error,
                                                  suggestedFix: "Run task materializer/initializer to generate cards."))
                    continue
                }

                guard let card = cardsByCode[task.code] else { continue }

                if card.status.folderName != task.status {
                    issues.append(ValidationIssue(path: relativePath(of: card.filePath, from: rootURL),
                                                  message: "Task \(task.code) expected in \(task.status) but card is in \(card.status.folderName).",
                                                  severity: .warning,
                                                  suggestedFix: "Move the card or update the roadmap status to match."))
                }

                if card.title?.contains(task.title) == false {
                    issues.append(ValidationIssue(path: relativePath(of: card.filePath, from: rootURL),
                                                  message: "Card title for \(task.code) does not reflect roadmap task title \(task.title).",
                                                  severity: .warning,
                                                  suggestedFix: "Align the card heading with the roadmap task title."))
                }

                if !task.acceptanceCriteria.isEmpty {
                    let missingCriteria = task.acceptanceCriteria.filter { criterion in
                        !card.acceptanceCriteria.contains(where: { $0.title == criterion })
                    }

                    if !missingCriteria.isEmpty {
                        issues.append(ValidationIssue(path: relativePath(of: card.filePath, from: rootURL),
                                                      message: "Card for \(task.code) is missing roadmap acceptance criteria: \(missingCriteria.joined(separator: ", ")).",
                                                      severity: .warning,
                                                      suggestedFix: "Regenerate the card or add the missing acceptance criteria."))
                    }
                }
            }
        }

        return issues
    }

    private func structuralIssues(for card: Card, rootURL: URL) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let requiredSections = ["Summary", "Acceptance Criteria", "Notes", "History"]

        if card.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            issues.append(ValidationIssue(path: relativePath(of: card.filePath, from: rootURL),
                                          message: "Missing top-level heading (e.g. '# \(card.code) <title>').",
                                          severity: .warning,
                                          suggestedFix: "Add a '# \(card.code) <title>' heading at the top of the file."))
        }

        for section in requiredSections where card.section(named: section) == nil {
            issues.append(ValidationIssue(path: relativePath(of: card.filePath, from: rootURL),
                                          message: "Missing required section heading: \(section).",
                                          severity: .warning,
                                          suggestedFix: "Add a '\(section):' section to the card."))
        }

        return issues
    }

    private func duplicateCodeIssues(from cards: [(code: String, path: String)]) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let grouped = Dictionary(grouping: cards, by: { $0.code })

        for (code, entries) in grouped where entries.count > 1 {
            let paths = entries.map { $0.path }.joined(separator: ", ")
            issues.append(ValidationIssue(path: paths,
                                          message: "Duplicate card code detected: \(code).",
                                          severity: .error,
                                          suggestedFix: "Rename duplicate filenames so each <phase>.<task> code is unique within the project."))
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

    private func entries(at url: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: url,
                                              includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                              options: [.skipsHiddenFiles])) ?? []
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
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
