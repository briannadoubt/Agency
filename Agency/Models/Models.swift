import Foundation

enum PhaseParsingError: Error {
    case invalidDirectoryName(String)
}

struct Phase: Equatable {
    let number: Int
    let label: String
    let path: URL

    init(path: URL) throws {
        let name = path.lastPathComponent
        let pattern = /^phase-(\d+)-([a-z0-9-]+)$/

        guard let match = name.wholeMatch(of: pattern),
              let number = Int(match.1) else {
            throw PhaseParsingError.invalidDirectoryName(name)
        }

        self.number = number
        self.label = String(match.2)
        self.path = path
    }
}

enum CardParsingError: Error {
    case invalidFilename(String)
    case statusNotFound(URL)
    case missingFrontmatterDelimiters(URL)
    case invalidFrontmatterLine(String, URL)
}

struct FrontmatterEntry: Equatable {
    let key: String
    let value: String
}

struct CardFrontmatter: Equatable {
    var owner: String?
    var agentFlow: String?
    var agentStatus: String?
    var branch: String?
    var risk: String?
    var review: String?
    var parallelizable: Bool?
    var orderedFields: [FrontmatterEntry]

    init(owner: String? = nil,
         agentFlow: String? = nil,
         agentStatus: String? = nil,
         branch: String? = nil,
         risk: String? = nil,
         review: String? = nil,
         parallelizable: Bool? = nil,
         orderedFields: [FrontmatterEntry] = []) {
        self.owner = owner
        self.agentFlow = agentFlow
        self.agentStatus = agentStatus
        self.branch = branch
        self.risk = risk
        self.review = review
        self.parallelizable = parallelizable
        self.orderedFields = orderedFields
    }

    init(entries: [FrontmatterEntry]) {
        self.init(orderedFields: entries)
        apply(entries)
    }

    private mutating func apply(_ entries: [FrontmatterEntry]) {
        for entry in entries {
            switch entry.key {
            case "owner":
                owner = entry.normalizedValue
            case "agent_flow":
                agentFlow = entry.normalizedValue
            case "agent_status":
                agentStatus = entry.normalizedValue
            case "branch":
                branch = entry.normalizedValue
            case "risk":
                risk = entry.normalizedValue
            case "review":
                review = entry.normalizedValue
            case "parallelizable":
                parallelizable = entry.normalizedBoolean
            default:
                continue
            }
        }
    }
}

struct CardSection: Equatable {
    let title: String
    let content: String
}

struct AcceptanceCriterion: Equatable {
    let title: String
    let isComplete: Bool
}

struct Card: Equatable {
    let code: String
    let slug: String
    let status: CardStatus
    let filePath: URL
    let frontmatter: CardFrontmatter
    let sections: [CardSection]
    let title: String?
    let summary: String?
    let acceptanceCriteria: [AcceptanceCriterion]
    let notes: String?
    let history: [String]

    func section(named title: String) -> CardSection? {
        sections.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }
}

@MainActor
struct CardFileParser {
    func parse(fileURL: URL, contents: String) throws -> Card {
        let status = try deriveStatus(from: fileURL)
        let identifiers = try deriveIdentifiers(from: fileURL)
        let (frontmatterEntries, body) = try splitFrontmatter(from: contents, fileURL: fileURL)
        let title = parseTitle(from: body)
        let sections = parseSections(from: body)
        let summary = sections.first { $0.title.caseInsensitiveCompare("Summary") == .orderedSame }?.content
        let acceptanceSection = sections.first { $0.title.caseInsensitiveCompare("Acceptance Criteria") == .orderedSame }
        let acceptanceCriteria = parseAcceptanceCriteria(from: acceptanceSection?.content ?? "")
        let notes = sections.first { $0.title.caseInsensitiveCompare("Notes") == .orderedSame }?.content
        let history = parseHistory(from: sections.first { $0.title.caseInsensitiveCompare("History") == .orderedSame }?.content ?? "")

        let frontmatter = CardFrontmatter(entries: frontmatterEntries)

        return Card(code: identifiers.code,
                    slug: identifiers.slug,
                    status: status,
                    filePath: fileURL,
                    frontmatter: frontmatter,
                    sections: sections,
                    title: title,
                    summary: summary,
                    acceptanceCriteria: acceptanceCriteria,
                    notes: notes,
                    history: history)
    }

    private func deriveStatus(from fileURL: URL) throws -> CardStatus {
        for status in CardStatus.allCases {
            if fileURL.pathComponents.contains(status.folderName) {
                return status
            }
        }

        throw CardParsingError.statusNotFound(fileURL)
    }

    private func deriveIdentifiers(from fileURL: URL) throws -> (code: String, slug: String) {
        let filename = fileURL.deletingPathExtension().lastPathComponent
        let parts = filename.split(separator: "-", maxSplits: 1).map(String.init)

        guard parts.count == 2 else {
            throw CardParsingError.invalidFilename(filename)
        }

        return (code: parts[0], slug: parts[1])
    }

    private func splitFrontmatter(from contents: String, fileURL: URL) throws -> ([FrontmatterEntry], String) {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let start = lines.firstIndex(of: "---") else {
            // No frontmatter; treat the full document as the body.
            return ([], contents)
        }

        guard let end = lines[(start + 1)...].firstIndex(of: "---"),
              start == 0 else {
            throw CardParsingError.missingFrontmatterDelimiters(fileURL)
        }

        let frontmatterLines = Array(lines[(start + 1)..<end])
        try validateFrontmatter(frontmatterLines, fileURL: fileURL)
        let bodyLines = Array(lines[(end + 1)...])
        let entries = frontmatterLines.compactMap(FrontmatterEntry.init(line:))
        let body = bodyLines.joined(separator: "\n")

        return (entries, body)
    }

    private func parseTitle(from body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2))
            }
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                // Stop once content begins without a leading title.
                return nil
            }
        }
        return nil
    }

    private func parseSections(from body: String) -> [CardSection] {
        var sections: [CardSection] = []
        var currentTitle: String?
        var currentLines: [String] = []

        func appendSectionIfNeeded() {
            guard let title = currentTitle else { return }
            let content = currentLines.trimmedJoined()
            sections.append(CardSection(title: title, content: content))
        }

        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isSectionTitle(trimmed) {
                appendSectionIfNeeded()
                currentTitle = String(trimmed.dropLast())
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }

        appendSectionIfNeeded()
        return sections
    }

    private func parseAcceptanceCriteria(from content: String) -> [AcceptanceCriterion] {
        var criteria: [AcceptanceCriterion] = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [") else { continue }

            let isComplete = trimmed.contains("- [x]") || trimmed.contains("- [X]")
            let titleStart = trimmed.dropFirst(4) // "- ["
                .drop(while: { $0 != "]" })
                .dropFirst() // drop closing ]
                .trimmingCharacters(in: .whitespaces)
            let title = String(titleStart)
            if !title.isEmpty {
                criteria.append(AcceptanceCriterion(title: title, isComplete: isComplete))
            }
        }

        return criteria
    }

    private func parseHistory(from content: String) -> [String] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { line in
                if line.hasPrefix("- ") {
                    return String(line.dropFirst(2))
                }
                return line.isEmpty ? nil : line
            }
    }

    private func validateFrontmatter(_ lines: [String], fileURL: URL) throws {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let separator = line.firstIndex(of: ":") else {
                throw CardParsingError.invalidFrontmatterLine(line, fileURL)
            }

            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                throw CardParsingError.invalidFrontmatterLine(line, fileURL)
            }
        }
    }

    private func isSectionTitle(_ line: String) -> Bool {
        guard line.hasSuffix(":") else { return false }
        guard !line.hasPrefix("-") else { return false }
        return line.range(of: #"^[A-Za-z][A-Za-z ]*:$"#, options: .regularExpression) != nil
    }
}

private extension FrontmatterEntry {
    init?(line: String) {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        self.init(key: key, value: value)
    }

    var normalizedValue: String? {
        guard !value.isEmpty, value.lowercased() != "null" else { return nil }
        return value
    }

    var normalizedBoolean: Bool? {
        switch value.lowercased() {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }
}

private extension Array where Element == String {
    func trimmedJoined() -> String {
        var lines = self
        while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}

extension CardParsingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidFilename(let name):
            return "Invalid card filename: \(name). Expected <phase>.<task>-slug.md."
        case .statusNotFound(let url):
            return "Cannot determine card status from path: \(url.path)."
        case .missingFrontmatterDelimiters(let url):
            return "Frontmatter is missing starting/ending '---' in \(url.lastPathComponent)."
        case .invalidFrontmatterLine(let line, let url):
            return "Invalid frontmatter entry \"\(line)\" in \(url.lastPathComponent)."
        }
    }
}
