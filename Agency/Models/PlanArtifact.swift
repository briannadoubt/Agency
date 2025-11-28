import Foundation

enum PlanArtifactError: LocalizedError {
    case tasksMissing

    var errorDescription: String? {
        switch self {
        case .tasksMissing:
            return "Plan artifact is missing machine-readable tasks."
        }
    }
}

struct PlanArtifact: Equatable {
    let tasks: [PlanTask]

    static func load(from url: URL) throws -> PlanArtifact {
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard let json = extractJSON(contents) else {
            throw PlanArtifactError.tasksMissing
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        let tasks = try decoder.decode([PlanTask].self, from: Data(json.utf8))
        return PlanArtifact(tasks: tasks)
    }

    private static func extractJSON(_ contents: String) -> String? {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let fenceStart = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "```json" }) else {
            return nil
        }

        let remaining = lines[(fenceStart + 1)...]
        guard let fenceEnd = remaining.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "```" }) else {
            return nil
        }

        let jsonLines = Array(remaining.prefix(upTo: fenceEnd))
        let json = jsonLines.joined(separator: "\n")
        return json.isEmpty ? nil : json
    }
}
