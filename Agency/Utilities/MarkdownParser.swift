import Foundation

/// Shared utilities for parsing markdown documents with YAML frontmatter and sections.
enum MarkdownParser {
    /// Parses YAML frontmatter from the beginning of a markdown document.
    /// Returns (frontmatter dictionary, body content).
    static func splitFrontmatter(from contents: String) -> ([String: String], String) {
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

    /// Parses sections from a markdown body where sections are marked by headers ending with `:`.
    /// Returns a dictionary mapping section titles to their content.
    static func sections(from body: String) -> [String: String] {
        var sections: [String: String] = [:]
        var currentTitle: String?
        var currentLines: [String] = []

        func flush() {
            guard let title = currentTitle else { return }
            sections[title] = currentLines.joined(separator: "\n").trimmed()
        }

        // Pattern matches section headers like "Summary:", "History:", "Manual Notes:"
        // Allows letters, numbers, spaces, parentheses, dots, ampersands, slashes, plus, minus
        let sectionPattern = #"^[A-Za-z0-9 ().&/+-]+:$"#

        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") && trimmed.range(of: sectionPattern, options: .regularExpression) != nil {
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

    /// Parses history entries from a section. Each entry is a line starting with "- ".
    static func parseHistory(from section: String?) -> [String] {
        guard let section else { return [] }
        return section
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
    }

    /// Extracts JSON content from a fenced code block (```json ... ```).
    static func extractJSON(from section: String) -> String? {
        guard let fenceStart = section.range(of: "```json") else { return nil }
        let remainder = section[fenceStart.upperBound...]
        guard let fenceEnd = remainder.range(of: "```") else { return nil }
        let json = remainder[..<fenceEnd.lowerBound]
        return String(json).trimmed()
    }
}
