import Foundation
import Observation

@MainActor
@Observable
final class ProjectLoader {
    enum State: Equatable {
        case idle
        case loading(URL)
        case loaded(ProjectSnapshot)
        case failed(String)
    }

    struct ProjectSnapshot: Equatable {
        let rootURL: URL
        let phases: [PhaseSnapshot]
        let validationIssues: [ValidationIssue]
    }

    private let bookmarkStore: ProjectBookmarkStore
    private let validator: ConventionsValidator
    private let watcher: ProjectScannerWatching
    private let fileManager: FileManager
    private let scanner: ProjectScanner
    private let cardMover: CardMover
    private let cardCreator: CardCreator
    private let editor = CardEditingPipeline.shared

    private var watchTask: Task<Void, Never>?
    private var scopedAccess: SecurityScopedAccess?

    private(set) var state: State = .idle

    init(bookmarkStore: ProjectBookmarkStore = ProjectBookmarkStore(),
         validator: ConventionsValidator = ConventionsValidator(),
         watcher: ProjectScannerWatching = ProjectScannerWatcher(),
         fileManager: FileManager = .default,
         scanner: ProjectScanner = ProjectScanner(),
         cardMover: CardMover = CardMover(),
         cardCreator: CardCreator = CardCreator()) {
        self.bookmarkStore = bookmarkStore
        self.validator = validator
        self.watcher = watcher
        self.fileManager = fileManager
        self.scanner = scanner
        self.cardMover = cardMover
        self.cardCreator = cardCreator
    }

    @MainActor deinit {
        watchTask?.cancel()
        scopedAccess?.stopAccessing()
    }

    var loadedSnapshot: ProjectSnapshot? {
        if case .loaded(let snapshot) = state {
            return snapshot
        }
        return nil
    }

    func restoreBookmarkIfAvailable() {
        guard state == .idle else { return }
        guard let access = bookmarkStore.restoreBookmark() else { return }
        beginLoading(access: access, persistBookmark: false)
    }

    func loadProject(at url: URL) {
        let access = SecurityScopedAccess(url: url.standardizedFileURL)
        beginLoading(access: access, persistBookmark: true)
    }

    func moveCard(_ card: Card,
                  to status: CardStatus,
                  logHistoryEntry: Bool) async -> Result<Void, CardMoveError> {
        guard let snapshot = loadedSnapshot else {
            return .failure(.snapshotUnavailable)
        }

        do {
            try await cardMover.move(card: card,
                                     to: status,
                                     rootURL: snapshot.rootURL,
                                     logHistoryEntry: logHistoryEntry)
            await refreshSnapshot(afterFilesystemChangeAt: snapshot.rootURL)
            return .success(())
        } catch let moveError as CardMoveError {
            return .failure(moveError)
        } catch {
            return .failure(.moveFailed(error.localizedDescription))
        }
    }

    func toggleAcceptanceCriterion(_ card: Card, index: Int) async -> Result<Void, Error> {
        guard let snapshot = loadedSnapshot else { return .failure(CardSaveError.parseFailed("Snapshot unavailable")) }

        do {
            _ = try editor.toggleAcceptanceCriterion(for: card, index: index)
            await refreshSnapshot(afterFilesystemChangeAt: snapshot.rootURL)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func createCard(in phase: PhaseSnapshot,
                    title: String,
                    includeHistoryEntry: Bool = true) async -> Result<Card, CardCreationError> {
        guard let snapshot = loadedSnapshot else { return .failure(.snapshotUnavailable) }

        do {
            let created = try await cardCreator.createCard(in: phase,
                                                           title: title,
                                                           includeHistoryEntry: includeHistoryEntry)
            await refreshSnapshot(afterFilesystemChangeAt: snapshot.rootURL)
            return .success(created)
        } catch let creationError as CardCreationError {
            return .failure(creationError)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    private func beginLoading(access: SecurityScopedAccess, persistBookmark: Bool) {
        scopedAccess?.stopAccessing()
        let resolvedURL = access.url.standardizedFileURL
        scopedAccess = access
        state = .loading(resolvedURL)

        guard projectRootExists(at: resolvedURL) else {
            state = .failed("Selected folder must contain a project/ root.")
            scopedAccess?.stopAccessing()
            scopedAccess = nil
            return
        }

        if persistBookmark {
            do {
                try bookmarkStore.saveBookmark(for: resolvedURL)
            } catch {
                state = .failed("Unable to save folder bookmark: \(error.localizedDescription)")
                scopedAccess?.stopAccessing()
                scopedAccess = nil
                return
            }
        }

        loadSnapshot(at: resolvedURL)
        startWatchingProject(at: resolvedURL)
    }

    private func loadSnapshot(at url: URL) {
        do {
            let phases = try scanner.scan(rootURL: url)
            let issues = validator.validateProject(at: url)
            state = .loaded(ProjectSnapshot(rootURL: url,
                                            phases: phases,
                                            validationIssues: issues))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startWatchingProject(at url: URL) {
        watchTask?.cancel()

        watchTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for await result in watcher.watch(rootURL: url, debounce: .milliseconds(150)) {
                switch result {
                case .success(let phases):
                    let issues = validator.validateProject(at: url)
                    state = .loaded(ProjectSnapshot(rootURL: url,
                                                    phases: phases,
                                                    validationIssues: issues))
                case .failure(let error):
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func refreshSnapshot(afterFilesystemChangeAt rootURL: URL) async {
        do {
            let phases = try scanner.scan(rootURL: rootURL)
            let issues = validator.validateProject(at: rootURL)
            state = .loaded(ProjectSnapshot(rootURL: rootURL,
                                            phases: phases,
                                            validationIssues: issues))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func projectRootExists(at url: URL) -> Bool {
        let projectURL = url.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

struct SecurityScopedAccess: Equatable {
    let url: URL
    private let didStart: Bool

    init(url: URL) {
        self.url = url
        self.didStart = url.startAccessingSecurityScopedResource()
    }

    func stopAccessing() {
        guard didStart else { return }
        url.stopAccessingSecurityScopedResource()
    }
}

struct ProjectBookmarkStore {
    private let defaults: UserDefaults
    private let bookmarkKey: String
    private var pathKey: String { "\(bookmarkKey).path" }

    init(defaults: UserDefaults = .standard, bookmarkKey: String = "projectBookmark") {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
    }

    func saveBookmark(for url: URL) throws {
        let resolved = url.standardizedFileURL
        let data = try resolved.bookmarkData(options: [.withSecurityScope],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
        defaults.set(resolved.path, forKey: pathKey)
    }

    func restoreBookmark() -> SecurityScopedAccess? {
        if let data = defaults.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) {
                if isStale {
                    try? saveBookmark(for: url)
                }
                return SecurityScopedAccess(url: url.standardizedFileURL)
            }
        }

        if let path = defaults.string(forKey: pathKey) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return SecurityScopedAccess(url: url)
        }

        return nil
    }

    func clearBookmark() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: pathKey)
    }
}
