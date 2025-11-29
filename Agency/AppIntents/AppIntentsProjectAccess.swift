import Foundation

/// Singleton providing access to the current project snapshot for AppIntents.
/// This bridges the MainActor-isolated ProjectLoader with the AppIntents framework.
@MainActor
final class AppIntentsProjectAccess {
    static let shared = AppIntentsProjectAccess()

    private weak var projectLoader: ProjectLoader?

    private init() {}

    /// Register the project loader instance for AppIntents to access.
    func register(_ loader: ProjectLoader) {
        self.projectLoader = loader
    }

    /// Current project snapshot, if available.
    var snapshot: ProjectLoader.ProjectSnapshot? {
        projectLoader?.loadedSnapshot
    }

    /// Check if a project is currently loaded.
    var isProjectLoaded: Bool {
        snapshot != nil
    }

    /// Move a card to a new status.
    func moveCard(_ card: Card, to status: CardStatus) async -> Result<Void, CardMoveError> {
        guard let loader = projectLoader else {
            return .failure(.snapshotUnavailable)
        }
        return await loader.moveCard(card, to: status, logHistoryEntry: true)
    }

    /// Create a new card in a phase.
    func createCard(in phase: PhaseSnapshot, title: String) async -> Result<Card, CardCreationError> {
        guard let loader = projectLoader else {
            return .failure(.snapshotUnavailable)
        }
        return await loader.createCard(in: phase, title: title, includeHistoryEntry: true)
    }
}
