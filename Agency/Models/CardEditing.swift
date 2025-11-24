import Foundation

struct CardDetailFormDraft: Equatable {
    struct Criterion: Identifiable, Equatable {
        let id: UUID
        var title: String
        var isComplete: Bool

        init(id: UUID = UUID(), title: String, isComplete: Bool) {
            self.id = id
            self.title = title
            self.isComplete = isComplete
        }
    }

    var title: String
    var owner: String
    var agentFlow: String
    var agentStatus: String
    var branch: String
    var risk: String
    var review: String
    var parallelizable: Bool
    var summary: String
    var notes: String
    var criteria: [Criterion]
    var history: [String]
    var newHistoryEntry: String

    static func from(card: Card, today: Date = .init()) -> CardDetailFormDraft {
        CardDetailFormDraft(title: card.title ?? "",
                            owner: card.frontmatter.owner ?? "",
                            agentFlow: card.frontmatter.agentFlow ?? "",
                            agentStatus: card.frontmatter.agentStatus ?? "",
                            branch: card.frontmatter.branch ?? "",
                            risk: card.frontmatter.risk ?? "",
                            review: card.frontmatter.review ?? "",
                            parallelizable: card.frontmatter.parallelizable ?? false,
                            summary: card.summary ?? "",
                            notes: card.notes ?? "",
                            criteria: card.acceptanceCriteria.map { Criterion(title: $0.title, isComplete: $0.isComplete) },
                            history: card.history,
                            newHistoryEntry: CardDetailFormDraft.defaultHistoryPrefix(on: today))
    }

    mutating func appendHistoryIfNeeded() {
        guard let entry = CardDetailFormDraft.normalizedHistoryEntry(newHistoryEntry) else { return }
        history.append(entry)
        newHistoryEntry = CardDetailFormDraft.defaultHistoryPrefix(on: Date())
    }

    mutating func resetHistoryPrefill(on date: Date = .init()) {
        newHistoryEntry = CardDetailFormDraft.defaultHistoryPrefix(on: date)
    }

    static func defaultHistoryPrefix(on date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date) + " - "
    }

    static func normalizedHistoryEntry(_ entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = /^\d{4}-\d{2}-\d{2}\s*-\s*(.*)$/
        if let match = trimmed.wholeMatch(of: pattern) {
            let tail = match.1.trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty ? nil : trimmed
        }

        return trimmed
    }
}

struct CardDocumentSnapshot: Equatable {
    let card: Card
    let contents: String
    let modifiedAt: Date
}

enum CardSaveError: LocalizedError, Equatable {
    case conflict
    case parseFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .conflict:
            return "Card changed on disk. Please reload before saving."
        case .parseFailed(let message):
            return message
        case .writeFailed(let message):
            return message
        }
    }
}

/// Serializes edited card drafts back to markdown while preserving frontmatter order and unknown keys.
struct CardMarkdownWriter {
    private let parser: CardFileParser
    private let fileManager: FileManager

    init(parser: CardFileParser = CardFileParser(), fileManager: FileManager = .default) {
        self.parser = parser
        self.fileManager = fileManager
    }

    func loadSnapshot(for card: Card) throws -> CardDocumentSnapshot {
        let contents = try String(contentsOf: card.filePath, encoding: .utf8)
        let attributes = try fileManager.attributesOfItem(atPath: card.filePath.path)
        let modified = attributes[.modificationDate] as? Date ?? Date()
        let parsedCard = try parser.parse(fileURL: card.filePath, contents: contents)
        return CardDocumentSnapshot(card: parsedCard, contents: contents, modifiedAt: modified)
    }

    func saveFormDraft(_ draft: CardDetailFormDraft,
                       appendHistory: Bool,
                       snapshot: CardDocumentSnapshot) throws -> CardDocumentSnapshot {
        let rendered = renderMarkdown(from: draft,
                                      basedOn: snapshot.card,
                                      existingContents: snapshot.contents,
                                      appendHistory: appendHistory)

        return try write(rendered, snapshot: snapshot)
    }

    func saveRaw(_ raw: String, snapshot: CardDocumentSnapshot) throws -> CardDocumentSnapshot {
        return try write(raw, snapshot: snapshot)
    }

    func formDraft(fromRaw raw: String, fileURL: URL) throws -> CardDetailFormDraft {
        let parsed = try parser.parse(fileURL: fileURL, contents: raw)
        return CardDetailFormDraft.from(card: parsed)
    }

    func renderMarkdown(from draft: CardDetailFormDraft,
                        basedOn card: Card,
                        existingContents: String,
                        appendHistory: Bool) -> String {
        let updatedFrontmatter = updatedFrontmatterEntries(original: card.frontmatter.orderedFields,
                                                           draft: draft)
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let criteria = draft.criteria
        var historyEntries = draft.history
        if appendHistory, let entry = normalizedHistoryEntry(draft.newHistoryEntry) {
            historyEntries.append(entry)
        }

        let updatedSections = mergeSections(existing: card.sections,
                                            summary: summary,
                                            notes: notes,
                                            criteria: criteria,
                                            history: historyEntries)
        return compose(frontmatter: updatedFrontmatter,
                       title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                       sections: updatedSections,
                       fallbackOriginal: existingContents)
    }

    private func write(_ contents: String, snapshot: CardDocumentSnapshot) throws -> CardDocumentSnapshot {
        guard !hasConflict(with: snapshot) else {
            throw CardSaveError.conflict
        }

        do {
            // Validate the generated contents before touching disk to avoid corrupting the source file.
            let parsed = try parser.parse(fileURL: snapshot.card.filePath, contents: contents)

            try contents.write(to: snapshot.card.filePath, atomically: true, encoding: .utf8)
            let attributes = try fileManager.attributesOfItem(atPath: snapshot.card.filePath.path)
            let modified = attributes[.modificationDate] as? Date ?? Date()

            return CardDocumentSnapshot(card: parsed, contents: contents, modifiedAt: modified)
        } catch let error as CardParsingError {
            throw CardSaveError.parseFailed(error.localizedDescription)
        } catch {
            throw CardSaveError.writeFailed(error.localizedDescription)
        }
    }

    private func hasConflict(with snapshot: CardDocumentSnapshot) -> Bool {
        guard let disk = try? String(contentsOf: snapshot.card.filePath, encoding: .utf8) else { return false }
        return disk != snapshot.contents
    }

    private func updatedFrontmatterEntries(original: [FrontmatterEntry], draft: CardDetailFormDraft) -> [FrontmatterEntry] {
        var entries = original

        func upsert(key: String, value: String?) {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let value {
                    entries[index] = FrontmatterEntry(key: key, value: value)
                } else {
                    entries.remove(at: index)
                }
            } else if let value {
                entries.append(FrontmatterEntry(key: key, value: value))
            }
        }

        let boolValue = draft.parallelizable ? "true" : "false"

        upsert(key: "owner", value: draft.owner.emptyToNil())
        upsert(key: "agent_flow", value: draft.agentFlow.emptyToNil())
        upsert(key: "agent_status", value: draft.agentStatus.emptyToNil())
        upsert(key: "branch", value: draft.branch.emptyToNil())
        upsert(key: "risk", value: draft.risk.emptyToNil())
        upsert(key: "review", value: draft.review.emptyToNil())
        upsert(key: "parallelizable", value: boolValue)

        return entries
    }

    private func mergeSections(existing: [CardSection],
                               summary: String,
                               notes: String,
                               criteria: [CardDetailFormDraft.Criterion],
                               history: [String]) -> [CardSection] {
        var merged: [CardSection] = []
        var seen: Set<String> = []

        for section in existing {
            switch section.title.lowercased() {
            case "summary":
                merged.append(CardSection(title: "Summary", content: summary))
                seen.insert("summary")
            case "acceptance criteria":
                merged.append(CardSection(title: "Acceptance Criteria", content: renderCriteria(criteria)))
                seen.insert("acceptance criteria")
            case "notes":
                merged.append(CardSection(title: "Notes", content: notes))
                seen.insert("notes")
            case "history":
                merged.append(CardSection(title: "History", content: renderHistory(history)))
                seen.insert("history")
            default:
                merged.append(section)
            }
        }

        if !seen.contains("summary") {
            merged.append(CardSection(title: "Summary", content: summary))
        }
        if !seen.contains("acceptance criteria") {
            merged.append(CardSection(title: "Acceptance Criteria", content: renderCriteria(criteria)))
        }
        if !seen.contains("notes") {
            merged.append(CardSection(title: "Notes", content: notes))
        }
        if !seen.contains("history") {
            merged.append(CardSection(title: "History", content: renderHistory(history)))
        }

        return merged
    }

    private func renderCriteria(_ criteria: [CardDetailFormDraft.Criterion]) -> String {
        criteria.map { criterion in
            let box = criterion.isComplete ? "- [x]" : "- [ ]"
            return "\(box) \(criterion.title)"
        }.joined(separator: "\n")
    }

    private func renderHistory(_ entries: [String]) -> String {
        entries.map { "- \($0)" }.joined(separator: "\n")
    }

    private func normalizedHistoryEntry(_ entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = /^\d{4}-\d{2}-\d{2}\s*-\s*(.*)$/
        if let match = trimmed.wholeMatch(of: pattern) {
            let tail = match.1.trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty ? nil : trimmed
        }

        return trimmed
    }

    private func compose(frontmatter: [FrontmatterEntry],
                         title: String,
                         sections: [CardSection],
                         fallbackOriginal: String) -> String {
        guard !frontmatter.isEmpty else { return fallbackOriginal }

        var lines: [String] = ["---"]
        lines.append(contentsOf: frontmatter.map { "\($0.key): \($0.value)" })
        lines.append("---")
        lines.append("")

        if !title.isEmpty {
            lines.append("# \(title)")
            lines.append("")
        }

        for section in sections {
            lines.append("\(section.title):")
            if !section.content.isEmpty {
                lines.append(section.content)
            }
            lines.append("")
        }

        // Trim trailing blank lines while preserving a single newline at end of file.
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

private extension String {
    func emptyToNil() -> String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
