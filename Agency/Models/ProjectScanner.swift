import CoreServices
import Foundation

struct PhaseSnapshot: Equatable {
    let phase: Phase
    let cards: [Card]
}

enum ProjectScannerError: LocalizedError {
    case missingProjectRoot(URL)
    case missingStatusDirectory(phase: Phase, status: CardStatus)

    var errorDescription: String? {
        switch self {
        case .missingProjectRoot(let url):
            return "Project folder not found at '\(url.lastPathComponent)'"
        case .missingStatusDirectory(let phase, let status):
            return "Missing '\(status.folderName)' folder in phase '\(phase.label)'"
        }
    }
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

        guard fileManager.directoryExists(at: projectURL) else {
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

            guard fileManager.directoryExists(at: statusURL) else {
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

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    }
}

protocol ProjectScannerWatching {
    func watch(rootURL: URL, debounce: Duration) -> AsyncStream<Result<[PhaseSnapshot], Error>>
}

/// Watches the project folder and emits debounced scan results when changes occur.
@MainActor
final class ProjectScannerWatcher: ProjectScannerWatching {
    private let scanner: ProjectScanner

    init(scanner: ProjectScanner = ProjectScanner()) {
        self.scanner = scanner
    }

    func watch(rootURL: URL, debounce: Duration = .milliseconds(150)) -> AsyncStream<Result<[PhaseSnapshot], Error>> {
        AsyncStream { continuation in
            let scheduler = ProjectScanScheduler(scanner: scanner,
                                                 rootURL: rootURL,
                                                 debounce: debounce,
                                                 continuation: continuation)
            scheduler.start()

            continuation.onTermination = { _ in
                Task { @MainActor in
                    scheduler.stop()
                }
            }
        }
    }
}

extension Card {
    /// Returns the `parallelizable` flag defaulting to `false` when omitted.
    var isParallelizable: Bool { frontmatter.parallelizable ?? false }
}

@MainActor
private final class ProjectScanScheduler {
    private let scanner: ProjectScanner
    private let rootURL: URL
    private let debounce: Duration
    private let continuation: AsyncStream<Result<[PhaseSnapshot], Error>>.Continuation

    private var debouncedTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var changeStream: FileSystemChangeStream?
    private var lastSnapshot: [PhaseSnapshot]?

    init(scanner: ProjectScanner,
         rootURL: URL,
         debounce: Duration,
         continuation: AsyncStream<Result<[PhaseSnapshot], Error>>.Continuation) {
        self.scanner = scanner
        self.rootURL = rootURL
        self.debounce = debounce
        self.continuation = continuation
    }

    @MainActor deinit {
        debouncedTask?.cancel()
        pollTask?.cancel()
        changeStream?.stop()
    }

    func start() {
        scheduleImmediateScan()
        attachChangeStream()
    }

    func stop() {
        debouncedTask?.cancel()
        debouncedTask = nil
        pollTask?.cancel()
        pollTask = nil
        changeStream?.stop()
        changeStream = nil
    }

    private func attachChangeStream() {
        let stream = FileSystemChangeStream(rootURL: rootURL, debounce: debounce) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleScan()
            }
        }

        if let stream, stream.start() {
            changeStream = stream
        } else {
            pollTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: debounce)
                    await performScan()
                }
            }
        }
    }

    private func scheduleImmediateScan() {
        debouncedTask?.cancel()
        debouncedTask = Task { @MainActor [weak self] in
            await self?.performScan()
        }
    }

    private func scheduleScan() {
        debouncedTask?.cancel()
        let delay = debounce
        debouncedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await self?.performScan()
        }
    }

    private func performScan() async {
        do {
            let snapshots = try scanner.scan(rootURL: rootURL)
            if let lastSnapshot, lastSnapshot == snapshots {
                return
            }
            lastSnapshot = snapshots
            continuation.yield(.success(snapshots))
        } catch {
            continuation.yield(.failure(error))
        }
    }
}

@MainActor
private final class FileSystemChangeStream {
    private let rootURL: URL
    private let latency: Duration
    private let onEvent: () -> Void
    private var stream: FSEventStreamRef?

    init?(rootURL: URL, debounce: Duration, onEvent: @escaping () -> Void) {
        guard rootURL.isFileURL else { return nil }
        self.rootURL = rootURL
        self.latency = debounce
        self.onEvent = onEvent
    }

    @MainActor deinit {
        stop()
    }

    func start() -> Bool {
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil,
                                           release: nil,
                                           copyDescription: nil)

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                                             kFSEventStreamCreateFlagUseCFTypes |
                                             kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(nil,
                                               { _, info, _, _, _, _ in
                                                   guard let info else { return }
                                                   let watcher = Unmanaged<FileSystemChangeStream>
                                                       .fromOpaque(info)
                                                       .takeUnretainedValue()
                                                   watcher.handleEvent()
                                               },
                                               &context,
                                               [rootURL.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latencySeconds(from: latency),
                                               flags) else { return false }

        self.stream = stream

        // macOS 13+: dispatch-queue based scheduling replaces run loop scheduling.
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)

        FSEventStreamStart(stream)
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handleEvent() {
        onEvent()
    }
}

private func latencySeconds(from duration: Duration) -> CFTimeInterval {
    let components = duration.components
    let seconds = Double(components.seconds)
    let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    return seconds + attoseconds
}
