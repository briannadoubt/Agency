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
}
