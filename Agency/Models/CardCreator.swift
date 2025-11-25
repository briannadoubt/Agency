import Foundation

enum CardCreationError: LocalizedError, Equatable {
    case snapshotUnavailable
    case emptyTitle
    case missingPhaseDirectory
    case missingStatusDirectory(CardStatus)
    case duplicateFilename(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .snapshotUnavailable:
            return "No project is loaded."
        case .emptyTitle:
            return "Please enter a title for the new card."
        case .missingPhaseDirectory:
            return "Phase folder is missing on disk."
        case .missingStatusDirectory(let status):
            return "Missing \(status.folderName) folder."
        case .duplicateFilename(let name):
            return "A card named \(name) already exists in this phase."
        case .writeFailed(let message):
            return "Unable to create card: \(message)"
        }
    }
}

/// Generates card filenames, slugs, and markdown files using the repository conventions.
actor CardCreator {
    private let fileManager: FileManager
    private let parser: CardFileParser
    private let dateProvider: () -> Date

    init(fileManager: FileManager = .default,
         parser: CardFileParser = CardFileParser(),
         dateProvider: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.parser = parser
        self.dateProvider = dateProvider
    }

    /// Creates a new backlog card inside the provided phase snapshot.
    /// - Parameters:
    ///   - phaseSnapshot: Phase context (cards are used to compute the next task number).
    ///   - title: User-provided title that feeds the slug and heading.
    ///   - includeHistoryEntry: Whether to seed the History section with a creation entry.
    func createCard(in phaseSnapshot: PhaseSnapshot,
                    title: String,
                    includeHistoryEntry: Bool = true) async throws -> Card {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw CardCreationError.emptyTitle }

        let phaseURL = phaseSnapshot.phase.path.standardizedFileURL
        guard directoryExists(at: phaseURL) else { throw CardCreationError.missingPhaseDirectory }

        let backlogURL = phaseURL.appendingPathComponent(CardStatus.backlog.folderName, isDirectory: true)
        guard directoryExists(at: backlogURL) else { throw CardCreationError.missingStatusDirectory(.backlog) }

        let (nextMinor, width) = nextTaskNumber(from: phaseSnapshot)
        let formattedMinor = String(format: "%0*d", width, nextMinor)
        let code = "\(phaseSnapshot.phase.number).\(formattedMinor)"
        let slug = makeSlug(from: trimmedTitle)
        let filename = "\(code)-\(slug).md"

        guard !fileExists(filename, inPhaseDirectory: phaseURL) else {
            throw CardCreationError.duplicateFilename(filename)
        }

        let fileURL = backlogURL.appendingPathComponent(filename, isDirectory: false)
        let contents = renderTemplate(code: code,
                                      title: trimmedTitle,
                                      includeHistoryEntry: includeHistoryEntry)

        do {
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            return try await MainActor.run {
                try parser.parse(fileURL: fileURL, contents: contents)
            }
        } catch {
            throw CardCreationError.writeFailed(error.localizedDescription)
        }
    }

    private func nextTaskNumber(from snapshot: PhaseSnapshot) -> (next: Int, width: Int) {
        var maxMinor = 0
        var maxWidth = 1

        for card in snapshot.cards {
            let components = card.code.split(separator: ".", maxSplits: 1).map(String.init)
            guard components.count == 2 else { continue }
            guard let major = Int(components[0]), major == snapshot.phase.number else { continue }

            let minorString = components[1]
            let minorValue = Int(minorString) ?? 0
            maxMinor = max(maxMinor, minorValue)
            maxWidth = max(maxWidth, minorString.count)
        }

        let nextMinor = maxMinor + 1
        let nextWidth = max(maxWidth, String(nextMinor).count)
        return (nextMinor, nextWidth)
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
        return slug.isEmpty ? "card" : slug
    }

    private func renderTemplate(code: String,
                                title: String,
                                includeHistoryEntry: Bool) -> String {
        var lines: [String] = [
            "---",
            "owner: bri",
            "agent_flow: null",
            "agent_status: idle",
            "branch: null",
            "risk: normal",
            "review: not-requested",
            "---",
            "",
            "# \(code) \(title)",
            "",
            "Summary:",
            "",
            "Acceptance Criteria:",
            "- [ ] ",
            "",
            "Notes:",
            "",
            "Alignment:",
            "",
            "History:"
        ]

        if includeHistoryEntry {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .iso8601)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let today = formatter.string(from: dateProvider())
            lines.append("- \(today): Card created in Agency.")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func fileExists(_ filename: String, inPhaseDirectory phaseURL: URL) -> Bool {
        CardStatus.allCases.contains { status in
            let candidate = phaseURL
                .appendingPathComponent(status.folderName, isDirectory: true)
                .appendingPathComponent(filename, isDirectory: false)
            return fileManager.fileExists(atPath: candidate.path)
        }
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
