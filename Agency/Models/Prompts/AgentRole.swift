import Foundation

/// Agent roles that define behavior and prompt selection.
enum AgentRole: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    /// Executes acceptance criteria, writes code, runs tests.
    case implementer

    /// Analyzes changes, provides feedback, identifies issues.
    case reviewer

    /// Gathers information, documents findings, explores codebase.
    case researcher

    /// Designs solutions, breaks down tasks, creates plans.
    case architect

    /// Coordinates flows, monitors progress, manages card lifecycle.
    case supervisor

    var id: String { rawValue }

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .implementer: return "Implementer"
        case .reviewer: return "Reviewer"
        case .researcher: return "Researcher"
        case .architect: return "Architect"
        case .supervisor: return "Supervisor"
        }
    }

    /// Short description of the role's responsibilities.
    var description: String {
        switch self {
        case .implementer:
            return "Executes acceptance criteria, writes code, and runs tests."
        case .reviewer:
            return "Analyzes changes, provides feedback, and identifies issues."
        case .researcher:
            return "Gathers information, documents findings, and explores the codebase."
        case .architect:
            return "Designs solutions, breaks down tasks, and creates implementation plans."
        case .supervisor:
            return "Coordinates agent flows, monitors progress, and manages card lifecycle."
        }
    }

    /// The default agent flow for this role, if applicable.
    var defaultFlow: AgentFlow? {
        switch self {
        case .implementer: return .implement
        case .reviewer: return .review
        case .researcher: return .research
        case .architect: return .plan
        case .supervisor: return nil
        }
    }

    /// The template filename for this role (without extension).
    var templateName: String {
        rawValue
    }

    /// Infers role from an agent flow.
    static func role(for flow: AgentFlow) -> AgentRole {
        switch flow {
        case .implement: return .implementer
        case .review: return .reviewer
        case .research: return .researcher
        case .plan: return .architect
        }
    }
}
