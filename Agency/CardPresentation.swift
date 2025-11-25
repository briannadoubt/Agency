import Foundation

enum RiskLevel: String, Equatable {
    case low
    case medium
    case high

    init(rawValue: String?) {
        let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalized {
        case "low"?, "lo"?:
            self = .low
        case "high"?, "hi"?:
            self = .high
        default:
            self = .medium
        }
    }

    var label: String {
        rawValue.capitalized
    }
}

struct CardPresentation: Equatable {
    let code: String
    let title: String?
    let summary: String?
    let owner: String?
    let branch: String?
    let agentStatus: String?
    let parallelizable: Bool
    let riskLevel: RiskLevel
    let completedCriteria: Int
    let totalCriteria: Int
    let criteria: [AcceptanceCriterion]

    init(card: Card) {
        code = card.code
        title = card.title
        summary = card.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        owner = card.frontmatter.owner
        branch = card.frontmatter.branch
        agentStatus = card.frontmatter.agentStatus
        parallelizable = card.frontmatter.parallelizable ?? false
        riskLevel = RiskLevel(rawValue: card.frontmatter.risk)
        completedCriteria = card.acceptanceCriteria.filter(\.isComplete).count
        totalCriteria = card.acceptanceCriteria.count
        criteria = card.acceptanceCriteria
    }
}
