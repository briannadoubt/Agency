import Foundation

/// Steps in the new project wizard flow.
enum WizardStep: Int, CaseIterable, Sendable {
    case goalInput
    case generatingRoadmap
    case reviewRoadmap
    case generatingArchitecture
    case reviewArchitecture
    case scaffolding
    case complete

    var isLoading: Bool {
        switch self {
        case .generatingRoadmap, .generatingArchitecture, .scaffolding:
            return true
        default:
            return false
        }
    }

    var canGoBack: Bool {
        switch self {
        case .goalInput, .generatingRoadmap, .generatingArchitecture, .scaffolding, .complete:
            return false
        case .reviewRoadmap, .reviewArchitecture:
            return true
        }
    }
}

/// Observable state for the new project wizard.
@MainActor
@Observable
final class WizardState {
    // Current step
    var currentStep: WizardStep = .goalInput

    // Step 1: Goal input
    var projectName: String = ""
    var projectGoal: String = ""

    // Step 2-3: Roadmap
    var roadmapContent: String = ""
    var roadmapError: String?

    // Step 4-5: Architecture
    var architectureContent: String = ""
    var architectureError: String?
    var skipArchitecture: Bool = false

    // Step 6: Scaffolding
    var projectLocation: URL?
    var scaffoldingError: String?

    // Step 7: Complete
    var createdProjectURL: URL?

    // Computed properties
    var isProjectNameValid: Bool {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Check for invalid filename characters
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return trimmed.rangeOfCharacter(from: invalidChars) == nil
    }

    var canProceedFromGoal: Bool {
        isProjectNameValid && !projectGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var parsedPhaseCount: Int {
        // Count lines starting with "# Phase" (case insensitive)
        roadmapContent.components(separatedBy: .newlines)
            .filter { $0.lowercased().hasPrefix("# phase") }
            .count
    }

    var parsedTaskCount: Int {
        // Count lines starting with "- [ ]"
        roadmapContent.components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]") }
            .count
    }

    var parsedComponentCount: Int {
        // Count ## headers in architecture
        architectureContent.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("## ") }
            .count
    }

    // Navigation
    func goBack() {
        switch currentStep {
        case .reviewRoadmap:
            currentStep = .goalInput
        case .reviewArchitecture:
            currentStep = .reviewRoadmap
        default:
            break
        }
    }

    func reset() {
        currentStep = .goalInput
        projectName = ""
        projectGoal = ""
        roadmapContent = ""
        roadmapError = nil
        architectureContent = ""
        architectureError = nil
        skipArchitecture = false
        projectLocation = nil
        scaffoldingError = nil
        createdProjectURL = nil
    }
}
