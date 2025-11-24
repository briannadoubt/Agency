import Foundation

struct PhaseSnapshot: Equatable {
    let phase: Phase
    let cards: [Card]
}

enum ProjectScannerError: Error {
    case missingProjectRoot(URL)
    case missingStatusDirectory(phase: Phase, status: CardStatus)
}

/// Scans the markdown-driven kanban project and produces an in-memory representation.
@MainActor
struct ProjectScanner {
    private let fileManager: FileManager
    private let parser: CardFileParser

    init(fileManager: FileManager = .default, parser: CardFileParser = CardFileParser()) {
        self.fileManager = fileManager
        self.parser = parser
    }

    /// Performs a full scan of the project at `rootURL`.
    func scan(rootURL: URL) throws -> [PhaseSnapshot] {
        let projectURL = rootURL.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)

        guard directoryExists(at: projectURL) else {
            throw ProjectScannerError.missingProjectRoot(projectURL)
        }

        let phases = phaseDirectories(at: projectURL)
            .compactMap { try? Phase(path: $0) }
            .sorted { lhs, rhs in
                if lhs.number == rhs.number { return lhs.label < rhs.label }
                return lhs.number < rhs.number
            }

        var snapshots: [PhaseSnapshot] = []

        for phase in phases {
            let cards = try scanCards(in: phase)
            snapshots.append(PhaseSnapshot(phase: phase, cards: cards))
        }

        return snapshots
    }

    private func scanCards(in phase: Phase) throws -> [Card] {
        var cards: [Card] = []

        for status in CardStatus.allCases {
            let statusURL = phase.path.appendingPathComponent(status.folderName, isDirectory: true)

            guard directoryExists(at: statusURL) else {
                throw ProjectScannerError.missingStatusDirectory(phase: phase, status: status)
            }

            for fileURL in files(at: statusURL) {
                guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                if let card = try? parser.parse(fileURL: fileURL, contents: contents) {
                    cards.append(card)
                }
            }
        }

        return cards.sorted(by: cardOrdering)
    }

    private func cardOrdering(_ lhs: Card, _ rhs: Card) -> Bool {
        let lhsParts = lhs.code.split(separator: ".")
        let rhsParts = rhs.code.split(separator: ".")

        let lhsMajor = Int(lhsParts.first ?? "0") ?? 0
        let rhsMajor = Int(rhsParts.first ?? "0") ?? 0

        if lhsMajor == rhsMajor {
            let lhsMinor = Int(lhsParts.dropFirst().first ?? "0") ?? 0
            let rhsMinor = Int(rhsParts.dropFirst().first ?? "0") ?? 0
            if lhsMinor == rhsMinor {
                return lhs.slug < rhs.slug
            }
            return lhsMinor < rhsMinor
        }

        return lhsMajor < rhsMajor
    }

    private func phaseDirectories(at url: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(at: url,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles]) else { return [] }

        return contents.filter { isDirectory($0) && $0.lastPathComponent.wholeMatch(of: ProjectConventions.phaseDirectoryPattern) != nil }
    }

    private func files(at url: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(at: url,
                                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: [.skipsHiddenFiles]) else { return [] }

        return contents.filter(isRegularFile)
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    }
}

/// Watches the project folder and emits debounced scan results when changes occur.
@MainActor
final class ProjectScannerWatcher {
    private let scanner: ProjectScanner
    private var watchTask: Task<Void, Never>?

    init(scanner: ProjectScanner = ProjectScanner()) {
        self.scanner = scanner
    }

    func watch(rootURL: URL, debounce: Duration = .milliseconds(150)) -> AsyncStream<Result<[PhaseSnapshot], Error>> {
        AsyncStream { continuation in
            Task { @MainActor [weak self] in
                await self?.startWatchLoop(rootURL: rootURL, debounce: debounce, continuation: continuation)
            }

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.cancelWatching()
                }
            }
        }
    }

    private func startWatchLoop(rootURL: URL,
                                debounce: Duration,
                                continuation: AsyncStream<Result<[PhaseSnapshot], Error>>.Continuation) async {
        cancelWatching()

        watchTask = Task { @MainActor [scanner] in
            var lastSnapshot: [PhaseSnapshot]? = nil

            @MainActor
            func emitCurrent() async {
                do {
                    let snapshots = try await scanner.scan(rootURL: rootURL)
                    if let last = lastSnapshot, last == snapshots { return }
                    lastSnapshot = snapshots
                    continuation.yield(.success(snapshots))
                } catch {
                    continuation.yield(.failure(error))
                }
            }

            await emitCurrent()

            while !Task.isCancelled {
                try? await Task.sleep(for: debounce)
                if Task.isCancelled { break }
                await emitCurrent()
            }

            continuation.finish()
        }
    }

    private func cancelWatching() {
        watchTask?.cancel()
        watchTask = nil
    }
}

extension Card {
    /// Returns the `parallelizable` flag defaulting to `false` when omitted.
    var isParallelizable: Bool { frontmatter.parallelizable ?? false }
}
