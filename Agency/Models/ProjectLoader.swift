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

    private var watchTask: Task<Void, Never>?
    private var scopedAccess: SecurityScopedAccess?

    private(set) var state: State = .idle

    init(bookmarkStore: ProjectBookmarkStore = ProjectBookmarkStore(),
         validator: ConventionsValidator = ConventionsValidator(),
         watcher: ProjectScannerWatching = ProjectScannerWatcher(),
         fileManager: FileManager = .default) {
        self.bookmarkStore = bookmarkStore
        self.validator = validator
        self.watcher = watcher
        self.fileManager = fileManager
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
        let access = SecurityScopedAccess(url: url)
        beginLoading(access: access, persistBookmark: true)
    }

    private func beginLoading(access: SecurityScopedAccess, persistBookmark: Bool) {
        scopedAccess?.stopAccessing()
        scopedAccess = access
        state = .loading(access.url)

        guard projectRootExists(at: access.url) else {
            state = .failed("Selected folder must contain a project/ root.")
            scopedAccess?.stopAccessing()
            scopedAccess = nil
            return
        }

        if persistBookmark {
            do {
                try bookmarkStore.saveBookmark(for: access.url)
            } catch {
                state = .failed("Unable to save folder bookmark: \(error.localizedDescription)")
                scopedAccess?.stopAccessing()
                scopedAccess = nil
                return
            }
        }

        startWatchingProject(at: access.url)
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
        let data = try url.bookmarkData(options: [.withSecurityScope],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
        defaults.set(url.path, forKey: pathKey)
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
                return SecurityScopedAccess(url: url)
            }
        }

        if let path = defaults.string(forKey: pathKey) {
            let url = URL(fileURLWithPath: path)
            return SecurityScopedAccess(url: url)
        }

        return nil
    }

    func clearBookmark() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: pathKey)
    }
}
