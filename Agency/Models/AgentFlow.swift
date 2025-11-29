import Foundation

/// Supported agent flows used across the scheduler, coordinator, and runner layers.
enum AgentFlow: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case implement
    case review
    case research
    case plan

    /// Flows that the scheduler supports dispatching to workers today.
    static let schedulable: [AgentFlow] = [.implement, .review, .research]

    var id: String { rawValue }

    var label: String {
        rawValue.capitalized
    }
}
