import Foundation
import os.log

/// Result of project scaffolding.
struct ProjectScaffoldResult: Equatable, Sendable {
    let projectURL: URL
    let phasesCreated: Int
    let tasksCreated: Int
    let filesWritten: [String]
}

/// Error during project scaffolding.
enum ProjectScaffoldError: LocalizedError, Equatable {
    case invalidProjectName
    case locationNotSelected
    case folderAlreadyExists(String)
    case noPhasesParsed
    case fileSystemError(String)

    var errorDescription: String? {
        switch self {
        case .invalidProjectName:
            return "Project name is invalid."
        case .locationNotSelected:
            return "No folder location was selected."
        case .folderAlreadyExists(let name):
            return "A folder named '\(name)' already exists at this location."
        case .noPhasesParsed:
            return "Could not parse any phases from the roadmap."
        case .fileSystemError(let message):
            return message
        }
    }
}

/// Parsed phase from roadmap markdown.
struct ParsedPhase: Equatable {
    let number: Int
    let label: String
    let tasks: [ParsedTask]
}

/// Parsed task from roadmap markdown.
struct ParsedTask: Equatable {
    let title: String
    let isComplete: Bool
}

/// Creates new project folder structure from wizard inputs.
@MainActor
struct ProjectScaffolder {
    private let fileManager: FileManager
    private let dateProvider: () -> Date
    private let logger = Logger(subsystem: "dev.agency.app", category: "ProjectScaffolder")

    init(fileManager: FileManager = .default,
         dateProvider: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.dateProvider = dateProvider
    }

    /// Scaffolds a new project at the given location.
    func scaffold(
        projectName: String,
        location: URL,
        roadmapContent: String,
        architectureContent: String?
    ) throws -> ProjectScaffoldResult {
        // Validate project name
        let trimmedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ProjectScaffoldError.invalidProjectName
        }

        // Create project folder
        let projectURL = location.appendingPathComponent(trimmedName, isDirectory: true)
        guard !fileManager.fileExists(atPath: projectURL.path) else {
            throw ProjectScaffoldError.folderAlreadyExists(trimmedName)
        }

        do {
            try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        } catch {
            throw ProjectScaffoldError.fileSystemError("Failed to create project folder: \(error.localizedDescription)")
        }

        var filesWritten: [String] = []

        // Write ROADMAP.md
        let roadmapURL = projectURL.appendingPathComponent("ROADMAP.md")
        do {
            try roadmapContent.write(to: roadmapURL, atomically: true, encoding: .utf8)
            filesWritten.append("ROADMAP.md")
            logger.info("Wrote ROADMAP.md")
        } catch {
            throw ProjectScaffoldError.fileSystemError("Failed to write ROADMAP.md: \(error.localizedDescription)")
        }

        // Write ARCHITECTURE.md if provided
        if let architecture = architectureContent, !architecture.isEmpty {
            let architectureURL = projectURL.appendingPathComponent("ARCHITECTURE.md")
            do {
                try architecture.write(to: architectureURL, atomically: true, encoding: .utf8)
                filesWritten.append("ARCHITECTURE.md")
                logger.info("Wrote ARCHITECTURE.md")
            } catch {
                logger.warning("Failed to write ARCHITECTURE.md: \(error.localizedDescription)")
            }
        }

        // Parse phases from roadmap
        let phases = parsePhases(from: roadmapContent)
        guard !phases.isEmpty else {
            throw ProjectScaffoldError.noPhasesParsed
        }

        // Create project/ folder structure
        let projectFolderURL = projectURL.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: projectFolderURL, withIntermediateDirectories: true)

        var tasksCreated = 0

        for phase in phases {
            let phaseLabel = makeSlug(from: phase.label)
            let phaseFolderName = "phase-\(phase.number)-\(phaseLabel)"
            let phaseFolderURL = projectFolderURL.appendingPathComponent(phaseFolderName, isDirectory: true)

            // Create status subfolders
            for status in ["backlog", "in-progress", "done"] {
                let statusURL = phaseFolderURL.appendingPathComponent(status, isDirectory: true)
                try fileManager.createDirectory(at: statusURL, withIntermediateDirectories: true)

                // Add .gitkeep
                let gitkeepURL = statusURL.appendingPathComponent(".gitkeep")
                fileManager.createFile(atPath: gitkeepURL.path, contents: Data())
            }

            filesWritten.append("project/\(phaseFolderName)/")

            // Create task cards in backlog
            let backlogURL = phaseFolderURL.appendingPathComponent("backlog", isDirectory: true)
            for (index, task) in phase.tasks.enumerated() {
                let taskNumber = index + 1
                let taskCode = "\(phase.number).\(taskNumber)"
                let taskSlug = makeSlug(from: task.title)
                let taskFilename = "\(taskCode)-\(taskSlug).md"
                let taskURL = backlogURL.appendingPathComponent(taskFilename)

                let taskContent = renderTaskCard(
                    code: taskCode,
                    title: task.title,
                    phaseLabel: phase.label
                )

                do {
                    try taskContent.write(to: taskURL, atomically: true, encoding: .utf8)
                    filesWritten.append("project/\(phaseFolderName)/backlog/\(taskFilename)")
                    tasksCreated += 1
                } catch {
                    logger.warning("Failed to create task card \(taskFilename): \(error.localizedDescription)")
                }
            }
        }

        logger.info("Scaffolded project at \(projectURL.path) with \(phases.count) phases and \(tasksCreated) tasks")

        return ProjectScaffoldResult(
            projectURL: projectURL,
            phasesCreated: phases.count,
            tasksCreated: tasksCreated,
            filesWritten: filesWritten
        )
    }

    // MARK: - Parsing

    /// Parses phases and tasks from roadmap markdown.
    private func parsePhases(from content: String) -> [ParsedPhase] {
        var phases: [ParsedPhase] = []
        var currentPhase: (number: Int, label: String, tasks: [ParsedTask])?

        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Check for phase header: # Phase N: Label or # Phase N — Label
            if let match = parsePhaseHeader(trimmed) {
                // Save previous phase
                if let phase = currentPhase {
                    phases.append(ParsedPhase(number: phase.number, label: phase.label, tasks: phase.tasks))
                }
                currentPhase = (match.number, match.label, [])
            }
            // Check for task: - [ ] or - [x]
            else if trimmed.hasPrefix("- [") {
                if let task = parseTask(trimmed) {
                    currentPhase?.tasks.append(task)
                }
            }
        }

        // Save last phase
        if let phase = currentPhase {
            phases.append(ParsedPhase(number: phase.number, label: phase.label, tasks: phase.tasks))
        }

        return phases
    }

    private func parsePhaseHeader(_ line: String) -> (number: Int, label: String)? {
        // Match: # Phase N: Label or # Phase N — Label or # Phase N - Label
        let patterns = [
            #"^#\s*Phase\s+(\d+)\s*[:\-—]\s*(.+)$"#,
            #"^##\s*Phase\s+(\d+)\s*[:\-—]\s*(.+)$"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               match.numberOfRanges >= 3,
               let numberRange = Range(match.range(at: 1), in: line),
               let labelRange = Range(match.range(at: 2), in: line),
               let number = Int(line[numberRange]) {
                let label = String(line[labelRange]).trimmingCharacters(in: .whitespaces)
                // Remove trailing status like "(current)" or "(planned)"
                let cleanLabel = label.replacingOccurrences(of: #"\s*\([^)]+\)\s*$"#, with: "", options: .regularExpression)
                return (number, cleanLabel)
            }
        }
        return nil
    }

    private func parseTask(_ line: String) -> ParsedTask? {
        // Match: - [ ] Task title or - [x] Task title
        if line.hasPrefix("- [ ]") {
            let title = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return ParsedTask(title: title, isComplete: false)
        } else if line.hasPrefix("- [x]") || line.hasPrefix("- [X]") {
            let title = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return ParsedTask(title: title, isComplete: true)
        }
        return nil
    }

    // MARK: - Rendering

    private func renderTaskCard(code: String, title: String, phaseLabel: String) -> String {
        let today = DateFormatters.dateString(from: dateProvider())

        return """
        ---
        owner: agent
        agent_flow: implement
        agent_status: idle
        risk: medium
        parallelizable: false
        ---

        # \(code) \(title)

        Summary:
        Task from \(phaseLabel) phase.

        Acceptance Criteria:
        - [ ] Define acceptance criteria

        Notes:
        Generated by New Project wizard.

        History:
        - \(today) - Card created

        """
    }

    private func makeSlug(from text: String) -> String {
        let lowered = text.lowercased()
        let slug = lowered.map { char -> Character in
            if char.isLetter || char.isNumber { return char }
            return "-"
        }

        // Remove consecutive dashes
        var result = String(slug)
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
