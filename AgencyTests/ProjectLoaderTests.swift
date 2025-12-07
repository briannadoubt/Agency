import Foundation
import Testing
@testable import Agency

@MainActor
struct ProjectLoaderTests {
    @Test func failsWhenProjectFolderLacksProjectRoot() async throws {
        let suiteName = "ProjectLoaderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let loader = ProjectLoader(bookmarkStore: ProjectBookmarkStore(defaults: defaults, bookmarkKey: "bookmark"),
                                   validator: ConventionsValidator(),
                                   watcher: StubWatcher(stream: AsyncStream { $0.finish() }),
                                   fileManager: .default)

        loader.loadProject(at: tempRoot)

        if case .failed(let message) = loader.state {
            #expect(message.contains("project/ root"))
        } else {
            Issue.record("Expected failure when project root is missing.")
        }

        #expect(defaults.data(forKey: "bookmark") == nil)
    }

    @Test func loadsAndStoresBookmarkOnSuccess() async throws {
        let (rootURL, phaseSnapshot) = try makeSampleProject()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stubStore = StubBookmarkStore()
        let watcher = StubWatcher.singleSuccess([phaseSnapshot])
        let loader = ProjectLoader(bookmarkStore: stubStore,
                                   validator: ConventionsValidator(),
                                   watcher: watcher,
                                   fileManager: .default)

        loader.loadProject(at: rootURL)

        // Wait for state to become loaded (up to 2 seconds)
        for _ in 0..<40 {
            if case .loaded = loader.state { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        if case .loaded(let snapshot) = loader.state {
            #expect(snapshot.phases == [phaseSnapshot])
        } else {
            Issue.record("Expected loaded state after successful scan, got \(loader.state)")
        }

        #expect(stubStore.savedURL != nil)
    }

    @Test func restoresBookmarkAndRescans() async throws {
        let suiteName = "ProjectLoaderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let (rootURL, phaseSnapshot) = try makeSampleProject()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let initialWatcher = StubWatcher.singleSuccess([phaseSnapshot])
        let initialLoader = ProjectLoader(bookmarkStore: ProjectBookmarkStore(defaults: defaults, bookmarkKey: "bookmark"),
                                          validator: ConventionsValidator(),
                                          watcher: initialWatcher,
                                          fileManager: .default)

        initialLoader.loadProject(at: rootURL)
        try await Task.sleep(for: .milliseconds(30))

        let restoreWatcher = StubWatcher.singleSuccess([phaseSnapshot])
        let restoredLoader = ProjectLoader(bookmarkStore: ProjectBookmarkStore(defaults: defaults, bookmarkKey: "bookmark"),
                                           validator: ConventionsValidator(),
                                           watcher: restoreWatcher,
                                           fileManager: .default)

        restoredLoader.restoreBookmarkIfAvailable()
        try await Task.sleep(for: .milliseconds(50))

        if case .loaded(let snapshot) = restoredLoader.state {
            #expect(snapshot.rootURL == rootURL)
        } else {
            Issue.record("Expected bookmark restoration to trigger a scan.")
        }
    }

    private func makeSampleProject() throws -> (URL, PhaseSnapshot) {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let projectURL = tempRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectURL.appendingPathComponent("phase-1-core", isDirectory: true)

        for status in CardStatus.allCases {
            try fileManager.createDirectory(at: phaseURL.appendingPathComponent(status.folderName, isDirectory: true),
                                            withIntermediateDirectories: true)
        }

        let cardURL = phaseURL.appendingPathComponent("backlog/1.1-sample.md")
        try sampleCardContents().write(to: cardURL, atomically: true, encoding: .utf8)

        let phase = try Phase(path: phaseURL)
        let card = try CardFileParser().parse(fileURL: cardURL, contents: sampleCardContents())
        let snapshot = PhaseSnapshot(phase: phase, cards: [card])

        return (tempRoot, snapshot)
    }

    private func sampleCardContents() -> String {
        """
        ---
        owner: test
        ---
        # 1.1 Sample

        Summary:
        Example card
        """
    }
}

private struct StubWatcher: ProjectScannerWatching {
    let stream: AsyncStream<Result<[PhaseSnapshot], Error>>

    func watch(rootURL: URL, debounce: Duration) -> AsyncStream<Result<[PhaseSnapshot], Error>> {
        stream
    }

    static func singleSuccess(_ snapshots: [PhaseSnapshot]) -> StubWatcher {
        StubWatcher(stream: AsyncStream { continuation in
            continuation.yield(.success(snapshots))
            continuation.finish()
        })
    }
}

private final class StubBookmarkStore: ProjectBookmarkStoring {
    var savedURL: URL?

    func saveBookmark(for url: URL) throws {
        savedURL = url
    }

    func restoreBookmark() -> SecurityScopedAccess? {
        guard let url = savedURL else { return nil }
        return SecurityScopedAccess(url: url)
    }

    func clearBookmark() {
        savedURL = nil
    }
}
