import Foundation

// Note: AgentRunStatus is now a typealias for AgentStatus in AgentStatus.swift

struct AgentRunLock: Codable, Equatable {
    let runID: UUID
    let flow: AgentFlow
    let startedAt: Date
    let cardRelativePath: String
}

struct AgentWorkerRequest: Equatable, Codable {
    let runID: UUID
    let flow: AgentFlow
    let cardRelativePath: String
    let projectBookmark: Data
    let logDirectory: URL
    let allowNetwork: Bool
    let allowFilesScope: URL

    var cliArguments: [String] {
        [
            "--flow", flow.rawValue,
            "--card", cardRelativePath,
            "--allow-files", allowFilesScope.path,
            "--run-id", runID.uuidString
        ]
    }
}

struct AgentWorkerEndpoint: Equatable {
    let runID: UUID
    let logDirectory: URL
}

protocol AgentWorkerClient {
    func launchWorker(request: AgentWorkerRequest) async throws -> AgentWorkerEndpoint
    func cancelWorker(runID: UUID) async
}

extension AgentWorkerClient {
    func cancelWorker(runID: UUID) async { }
}

struct AgentRunLogPaths: Equatable {
    let directory: URL
    let workerLog: URL
    let events: URL
    let result: URL
    let stdoutTail: URL
}

struct AgentRunLogLocator {
    private let baseDirectory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL,
         fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    func makePaths(for runID: UUID, on date: Date) throws -> AgentRunLogPaths {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"

        let directory = baseDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Agents", isDirectory: true)
            .appendingPathComponent(formatter.string(from: date), isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        return AgentRunLogPaths(directory: directory,
                                workerLog: directory.appendingPathComponent("worker.log"),
                                events: directory.appendingPathComponent("events.jsonl"),
                                result: directory.appendingPathComponent("result.json"),
                                stdoutTail: directory.appendingPathComponent("stdout-tail.txt"))
    }
}

// Note: AgentBackoffPolicy is now a typealias for BackoffPolicy in BackoffPolicy.swift
// Note: AgentRunOutcome is now a typealias for RunOutcome in RunOutcome.swift

enum AgentFlowError: LocalizedError, Equatable {
    case cardOutsideProject
    case alreadyLocked(runID: UUID, status: String?)
    case missingLock
    case mismatchedRunID
    case writeFailed(String)
    case workerLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .cardOutsideProject:
            return "Card path is not under the selected project root."
        case .alreadyLocked(let runID, let status):
            if let status, !status.isEmpty {
                return "Card is locked by agent_status=\(status) (runID=\(runID))."
            }
            return "Card is already locked for an agent run."
        case .missingLock:
            return "No lock exists for this card."
        case .mismatchedRunID:
            return "Run completion does not match the active lock."
        case .writeFailed(let message):
            return message
        case .workerLaunchFailed(let message):
            return message
        }
    }
}

struct AgentEnqueuedRun: Equatable {
    let runID: UUID
    let card: Card
    let request: AgentWorkerRequest
    let endpoint: AgentWorkerEndpoint
    let logPaths: AgentRunLogPaths
}

/// Coordinates agent frontmatter updates, lock management, XPC payload construction, and backoff metadata.
@MainActor
final class AgentFlowCoordinator {
    private var locks: [URL: AgentRunLock] = [:]
    private var failureCounts: [URL: Int] = [:]
    private var runContexts: [UUID: RunContext] = [:]

    private let worker: any AgentWorkerClient
    private let writer: CardMarkdownWriter
    private let logLocator: AgentRunLogLocator
    private let lockStore: AgentLockStore?
    private let dateProvider: @Sendable () -> Date
    private let backoffPolicy: AgentBackoffPolicy

    private struct RunContext {
        let cardURL: URL
        let flow: AgentFlow
        let logPaths: AgentRunLogPaths
        let branch: String?
        let reviewTarget: String?
        let researchPrompt: String?
    }

    init(worker: any AgentWorkerClient,
         writer: CardMarkdownWriter,
         logLocator: AgentRunLogLocator,
         lockStore: AgentLockStore? = nil,
         dateProvider: @escaping @Sendable () -> Date = Date.init,
         backoffPolicy: AgentBackoffPolicy) {
        self.worker = worker
        self.writer = writer
        self.logLocator = logLocator
        self.lockStore = lockStore
        self.dateProvider = dateProvider
        self.backoffPolicy = backoffPolicy
    }

    func enqueueRun(for card: Card,
                    flow: AgentFlow,
                    projectRoot: URL,
                    bookmark: Data,
                    allowNetwork: Bool = false,
                    branch: String? = nil,
                    reviewTarget: String? = nil,
                    researchPrompt: String? = nil) async throws -> AgentEnqueuedRun {
        let cardURL = card.filePath.standardizedFileURL
        let rootURL = projectRoot.standardizedFileURL

        guard cardURL.path.hasPrefix(rootURL.path) else {
            throw AgentFlowError.cardOutsideProject
        }

        if let existing = locks[cardURL] {
            throw AgentFlowError.alreadyLocked(runID: existing.runID,
                                               status: card.frontmatter.agentStatus)
        }

        if let status = card.frontmatter.agentStatus,
           !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           status.lowercased() != AgentRunStatus.idle.rawValue {
            throw AgentFlowError.alreadyLocked(runID: locks[cardURL]?.runID ?? UUID(),
                                               status: status)
        }

        let relativePath = cardRelativePath(of: cardURL, from: rootURL)
        let runID = UUID()
        let runDate = dateProvider()
        let logPaths = try logLocator.makePaths(for: runID, on: runDate)
        let lock = AgentRunLock(runID: runID,
                                flow: flow,
                                startedAt: dateProvider(),
                                cardRelativePath: relativePath)
        locks[cardURL] = lock
        do {
            try lockStore?.persist(lock, for: relativePath)
        } catch {
            locks.removeValue(forKey: cardURL)
            throw error
        }

        let queuedSnapshot: CardDocumentSnapshot
        let runningSnapshot: CardDocumentSnapshot

        do {
            queuedSnapshot = try update(card: card,
                                        snapshot: nil,
                                        flow: flow,
                                        status: .queued,
                                        runID: runID,
                                        branch: branch,
                                        reviewTarget: reviewTarget,
                                        researchPrompt: researchPrompt,
                                        logPaths: logPaths)
            runningSnapshot = try update(card: card,
                                         snapshot: queuedSnapshot,
                                         flow: flow,
                                         status: .running,
                                         runID: runID,
                                         branch: branch,
                                         reviewTarget: reviewTarget,
                                         researchPrompt: researchPrompt,
                                         logPaths: logPaths)
        } catch {
            locks.removeValue(forKey: cardURL)
            lockStore?.remove(relativePath: lock.cardRelativePath)
            throw error
        }

        let request = AgentWorkerRequest(runID: runID,
                                         flow: flow,
                                         cardRelativePath: relativePath,
                                         projectBookmark: bookmark,
                                         logDirectory: logPaths.directory,
                                         allowNetwork: allowNetwork,
                                         allowFilesScope: rootURL)

        do {
            let endpoint = try await worker.launchWorker(request: request)
            runContexts[runID] = RunContext(cardURL: cardURL,
                                            flow: flow,
                                            logPaths: logPaths,
                                            branch: branch,
                                            reviewTarget: reviewTarget,
                                            researchPrompt: researchPrompt)
            return AgentEnqueuedRun(runID: runID,
                                    card: runningSnapshot.card,
                                    request: request,
                                    endpoint: endpoint,
                                    logPaths: logPaths)
        } catch {
            locks.removeValue(forKey: cardURL)
            lockStore?.remove(relativePath: relativePath)
            runContexts.removeValue(forKey: runID)
            throw AgentFlowError.workerLaunchFailed(error.localizedDescription)
        }
    }

    func completeRun(for card: Card,
                     runID: UUID,
                     outcome: AgentRunOutcome) async throws -> Card {
        let cardURL = card.filePath.standardizedFileURL
        guard let lock = locks[cardURL] else {
            throw AgentFlowError.missingLock
        }
        guard lock.runID == runID else {
            throw AgentFlowError.mismatchedRunID
        }

        let context = runContexts[runID]
        let parsedResult = context.flatMap { parseFlowResult(for: $0.flow, at: $0.logPaths.result) }

        let snapshot = try update(card: card,
                                  snapshot: nil,
                                  flow: lock.flow,
                                  status: outcome.status,
                                  runID: runID,
                                  branch: context?.branch,
                                  reviewTarget: context?.reviewTarget,
                                  researchPrompt: context?.researchPrompt,
                                  logPaths: context?.logPaths,
                                  result: parsedResult)

        locks.removeValue(forKey: cardURL)
        lockStore?.remove(relativePath: lock.cardRelativePath)
        runContexts.removeValue(forKey: runID)

        if outcome == .failed {
            failureCounts[cardURL, default: 0] += 1
        } else {
            failureCounts[cardURL] = 0
        }

        return snapshot.card
    }

    func backoffDelay(for card: Card) -> TimeInterval? {
        let cardURL = card.filePath.standardizedFileURL
        let failures = failureCounts[cardURL] ?? 0
        return backoffPolicy.delayInterval(forFailureCount: failures)
    }

    func isLocked(_ card: Card) -> Bool {
        locks[card.filePath.standardizedFileURL] != nil
    }

    private func update(card: Card,
                        snapshot: CardDocumentSnapshot?,
                        flow: AgentFlow,
                        status: AgentRunStatus,
                        runID: UUID,
                        branch: String?,
                        reviewTarget: String?,
                        researchPrompt: String?,
                        logPaths: AgentRunLogPaths?,
                        result: SupportedFlowResult? = nil) throws -> CardDocumentSnapshot {
        do {
            let baseline = try snapshot ?? writer.loadSnapshot(for: card)
            var draft = CardDetailFormDraft.from(card: baseline.card, today: dateProvider())
            draft.agentFlow = flow.rawValue
            draft.agentStatus = status.rawValue

            if let branch, flow == .implement {
                draft.branch = branch
            }

            if status == .succeeded, flow == .implement, let checked = result?.checkedCriteria {
                draft.criteria = applyCheckedCriteria(checked, to: draft.criteria)
            }

            let history = historyLine(flow: flow,
                                       status: status,
                                       runID: runID,
                                       branch: branch,
                                       reviewTarget: reviewTarget,
                                       researchPrompt: researchPrompt,
                                       logPaths: logPaths,
                                       result: result)
            if let history {
                draft.newHistoryEntry = history
            } else {
                draft.newHistoryEntry = ""
            }

            return try writer.saveFormDraft(draft,
                                            appendHistory: history != nil,
                                            snapshot: baseline)
        } catch let error as CardSaveError {
            throw AgentFlowError.writeFailed(error.localizedDescription)
        } catch {
            throw AgentFlowError.writeFailed(error.localizedDescription)
        }
    }

    private func applyCheckedCriteria(_ indices: [Int], to criteria: [CardDetailFormDraft.Criterion]) -> [CardDetailFormDraft.Criterion] {
        var updated = criteria
        for index in indices {
            guard updated.indices.contains(index) else { continue }
            updated[index].isComplete = true
        }
        return updated
    }

    private func historyLine(flow: AgentFlow,
                             status: AgentRunStatus,
                             runID: UUID,
                             branch: String?,
                             reviewTarget: String?,
                             researchPrompt: String?,
                             logPaths: AgentRunLogPaths?,
                             result: SupportedFlowResult?) -> String? {
        let date = formattedDate(dateProvider())
        let logPath = logPaths.map { $0.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

        switch (flow, status) {
        case (.implement, .queued):
            if let branch {
                return "\(date): Run \(runID.uuidString) queued (implement) on branch \(branch)."
            }
            return "\(date): Run \(runID.uuidString) queued (implement)."
        case (.implement, .running):
            return "\(date): Run \(runID.uuidString) started (implement)."
        case (.implement, .succeeded):
            let checkedCount = result?.checkedCriteria?.count ?? 0
            let testsPassed: String
            if let passed = result?.tests?.passed {
                testsPassed = passed ? "pass" : "fail"
            } else {
                testsPassed = "unknown"
            }
            return "\(date): Run \(runID.uuidString) succeeded (implement); checked \(checkedCount) items; tests: \(testsPassed)."
        case (.implement, .failed):
            if let path = logPath {
                return "\(date): Run \(runID.uuidString) failed (implement); see logs at \(path)."
            }
            return "\(date): Run \(runID.uuidString) failed (implement)."
        case (.implement, .canceled):
            return "\(date): Run \(runID.uuidString) canceled (implement)."

        case (.review, .queued):
            let target = reviewTarget ?? branch
            if let target {
                return "\(date): Run \(runID.uuidString) queued (review) for \(target)."
            }
            return "\(date): Run \(runID.uuidString) queued (review)."
        case (.review, .running):
            return nil
        case (.review, .succeeded):
            let counts = severityCounts(from: result?.findings)
            let overall = result?.overall ?? "unknown"
            return "\(date): Run \(runID.uuidString) succeeded (review); findings blocking/warn/info: \(counts.error)/\(counts.warn)/\(counts.info); overall=\(overall)."
        case (.review, .failed):
            if let path = logPath {
                return "\(date): Run \(runID.uuidString) failed (review); see logs at \(path)."
            }
            return "\(date): Run \(runID.uuidString) failed (review)."
        case (.review, .canceled):
            return "\(date): Run \(runID.uuidString) canceled (review)."

        case (.research, .queued):
            if let prompt = researchPrompt, !prompt.isEmpty {
                return "\(date): Run \(runID.uuidString) queued (research) topic \"\(prompt)\"."
            }
            return "\(date): Run \(runID.uuidString) queued (research)."
        case (.research, .running):
            return nil
        case (.research, .succeeded):
            let sources = result?.sources?.count ?? 0
            return "\(date): Run \(runID.uuidString) succeeded (research); \(sources) sources captured."
        case (.research, .failed):
            if let path = logPath {
                return "\(date): Run \(runID.uuidString) failed (research); see logs at \(path)."
            }
            return "\(date): Run \(runID.uuidString) failed (research)."
        case (.research, .canceled):
            return "\(date): Run \(runID.uuidString) canceled (research)."
        default:
            return nil
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func cardRelativePath(of cardURL: URL, from rootURL: URL) -> String {
        let standardized = cardURL.standardizedFileURL
        let root = rootURL.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return standardized.path.replacingOccurrences(of: rootPath, with: "")
    }

    private func parseFlowResult(for flow: AgentFlow, at url: URL) -> SupportedFlowResult? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(SupportedFlowResult.self, from: data)
    }

    private func severityCounts(from findings: [SupportedFlowResult.Finding]?) -> (error: Int, warn: Int, info: Int) {
        guard let findings else { return (0, 0, 0) }
        var error = 0, warn = 0, info = 0
        for finding in findings {
            switch finding.severity?.lowercased() {
            case "error": error += 1
            case "warn", "warning": warn += 1
            case "info": info += 1
            default: break
            }
        }
        return (error, warn, info)
    }
}

private struct SupportedFlowResult: Decodable {
    struct Tests: Decodable { let ran: [String]?; let passed: Bool? }
    struct Finding: Decodable { let severity: String? }
    struct Source: Decodable { let title: String?; let url: String? }

    let status: String?
    let summary: String?
    let changedFiles: [String]?
    let tests: Tests?
    let checkedCriteria: [Int]?
    let findings: [Finding]?
    let overall: String?
    let bulletPoints: [String]?
    let sources: [Source]?
}

struct AgentLockSnapshot: Codable, Equatable {
    let card: String
    let runID: UUID
    let flow: AgentFlow
    let startedAt: Date
}

struct AgentLockStore {
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func persist(_ lock: AgentRunLock, for relativePath: String) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = AgentLockSnapshot(card: relativePath,
                                         runID: lock.runID,
                                         flow: lock.flow,
                                         startedAt: lock.startedAt)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL(for: relativePath), options: .atomic)
    }

    func remove(relativePath: String) {
        try? fileManager.removeItem(at: fileURL(for: relativePath))
    }

    private func fileURL(for relativePath: String) -> URL {
        let safeName = relativePath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "-")
        return directory.appendingPathComponent("\(safeName).json")
    }
}
