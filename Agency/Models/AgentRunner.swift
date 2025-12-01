import Foundation
import Observation

/// Contract for any backend executor (simulator, Codex XPC, CLI wrapper) to plug into the UI.
protocol AgentExecutor {
    func run(request: CodexRunRequest,
             logURL: URL,
             outputDirectory: URL,
             emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async
}

/// Default in-process simulator used by the UI and tests.
struct SimulatedAgentExecutor: AgentExecutor {
    func run(request: CodexRunRequest,
             logURL: URL,
             outputDirectory: URL,
             emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
        let worker = SimulatedWorker(request: request,
                                     logURL: logURL,
                                     outputDirectory: outputDirectory,
                                     emit: emit)
        await worker.run()
    }
}

enum AgentRunPhase: String {
    case queued
    case running
    case succeeded
    case failed
    case canceled
}

/// Logical backend we use to execute an agent run. Keeps the UI flexible so different
/// agent types (Codex, CLI tools, hosted APIs) can plug in without changing UI code.
enum AgentBackendKind: String, CaseIterable, Identifiable {
    case simulated   // in-app stub used for previews/tests
    case codex       // XPC-based Codex workers
    case cli         // arbitrary CLI adapter (Cursor, Copilot, Claude wrappers, etc.)
    case claudeCode  // Claude Code CLI via XPC worker

    var id: String { rawValue }
}

struct AgentRunState: Identifiable, Equatable {
    let id: UUID
    let cardPath: String
    let flow: AgentFlow
    let backend: AgentBackendKind
    var phase: AgentRunPhase
    var progress: Double
    var logs: [String]
    var summary: String?
    var startedAt: Date
    var finishedAt: Date?
    var result: WorkerRunResult?
    var logDirectory: URL?
}

enum AgentRunError: LocalizedError, Equatable {
    case cardLocked(String)
    case snapshotUnavailable
    case updateFailed(String)
    case preparationFailed(String)
    case backendMissing(AgentBackendKind)

    var errorDescription: String? {
        switch self {
        case .cardLocked(let status):
            return "Card is locked by agent_status=\(status)."
        case .snapshotUnavailable:
            return "No card snapshot available."
        case .updateFailed(let message):
            return message
        case .preparationFailed(let message):
            return message
        case .backendMissing(let backend):
            return "No backend registered for \(backend.rawValue)."
        }
    }
}

/// Streams worker output (logs + progress) into the UI while keeping the real XPC pipeline swappable.
@MainActor
@Observable
final class AgentRunner {
    private let pipeline: CardEditingPipeline
    private let parser: CardFileParser
    private let fileManager: FileManager
    private var projectLoader: ProjectLoader?
    private var executors: [AgentBackendKind: any AgentExecutor]

    private var locks: Set<String> = []
    private var runs: [UUID: AgentRunState] = [:]
    private var runByCard: [String: UUID] = [:]
    private var pipelines: [UUID: RunPipeline] = [:]

    init(pipeline: CardEditingPipeline = .shared,
         parser: CardFileParser = CardFileParser(),
         fileManager: FileManager = .default,
         projectLoader: ProjectLoader? = nil,
         executors: [AgentBackendKind: any AgentExecutor] = [:]) {
        self.pipeline = pipeline
        self.parser = parser
        self.fileManager = fileManager
        self.projectLoader = projectLoader
        var registry = executors
        // Provide defaults so UI works without configuration.
        registry[.simulated] = registry[.simulated] ?? SimulatedAgentExecutor()
        registry[.codex] = registry[.codex] ?? CodexAgentExecutor()
        registry[.cli] = registry[.cli] ?? CLIPhaseExecutor()
        registry[.claudeCode] = registry[.claudeCode] ?? ClaudeCodeExecutor()
        self.executors = registry
    }

    func state(for card: Card) -> AgentRunState? {
        let path = card.filePath.standardizedFileURL.path
        guard let id = runByCard[path] else { return nil }
        return runs[id]
    }

    func startRun(card: Card,
                 flow: AgentFlow = .implement,
                 backend: AgentBackendKind = .simulated) async -> Result<AgentRunState, AgentRunError> {
        let selectedBackend: AgentBackendKind = (backend == .simulated && flow == .plan) ? .cli : backend

        let snapshot: CardDocumentSnapshot
        do {
            snapshot = try pipeline.loadSnapshot(for: card)
        } catch {
            return .failure(.snapshotUnavailable)
        }

        let latestCard = snapshot.card
        let path = latestCard.filePath.standardizedFileURL.path

        if let status = latestCard.frontmatter.agentStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
           !status.isEmpty, status.lowercased() != "idle" {
            return .failure(.cardLocked(status))
        }

        guard !locks.contains(path) else {
            return .failure(.cardLocked("running"))
        }

        let runID = UUID()
        locks.insert(path)

        guard let executor = executors[selectedBackend] else {
            locks.remove(path)
            return .failure(.backendMissing(selectedBackend))
        }

        let preparation: RunPreparation
        do {
            preparation = try prepareRequest(for: latestCard, runID: runID, flow: flow, backend: selectedBackend)
        } catch {
            locks.remove(path)
            return .failure(.preparationFailed(error.localizedDescription))
        }

        do {
            try updateFrontmatter(at: latestCard.filePath,
                                  mutate: { draft in
                                      draft.agentFlow = flow.rawValue
                                      draft.agentStatus = "queued"
                                  },
                                  history: historyEntry("Run \(runID) queued (\(flow.rawValue))"))
        } catch {
            locks.remove(path)
            return .failure(.updateFailed(error.localizedDescription))
        }

        let state = AgentRunState(id: runID,
                                  cardPath: path,
                                  flow: flow,
                                  backend: selectedBackend,
                                  phase: .queued,
                                  progress: 0.0,
                                  logs: ["Queued run for \(latestCard.slug)"],
                                  summary: nil,
                                  startedAt: .now,
                                  finishedAt: nil,
                                  result: nil,
                                  logDirectory: preparation.logDirectory)
        runs[runID] = state
        runByCard[path] = runID

        let workerTask = makeWorkerTask(using: executor,
                                        request: preparation.request,
                                        logURL: preparation.logURL,
                                        outputDirectory: preparation.outputDirectory)
        let streamTask: Task<Void, Never>? = nil // kept for future XPC stream reader
        pipelines[runID] = RunPipeline(runID: runID,
                                      request: preparation.request,
                                      logURL: preparation.logURL,
                                      outputDirectory: preparation.outputDirectory,
                                      workerTask: workerTask,
                                      streamTask: streamTask)

        return .success(state)
    }

    func cancel(runID: UUID) {
        guard var state = runs[runID] else { return }
        state.phase = .canceled
        state.finishedAt = .now
        state.logs.append("Canceled")
        runs[runID] = state

        if let pipeline = pipelines[runID] {
            pipeline.cancel()
            cleanupOutputs(at: pipeline.outputDirectory)
            pipelines.removeValue(forKey: runID)
        }
        releaseLock(for: state.cardPath)

        do {
            try updateFrontmatter(at: URL(fileURLWithPath: state.cardPath),
                                  mutate: { draft in
                                      draft.agentStatus = "canceled"
                                  },
                                  history: historyEntry("Run \(runID) canceled"))
        } catch {
            // UI already reflects cancellation; filesystem watcher can reconcile if needed.
        }
    }

    func resetAgentState(for card: Card) async -> Result<Void, AgentRunError> {
        let path = card.filePath.standardizedFileURL.path
        if let id = runByCard[path] {
            cancel(runID: id)
        }

        do {
            try updateFrontmatter(at: card.filePath,
                                  mutate: { draft in
                                      draft.agentFlow = ""
                                      draft.agentStatus = "idle"
                                  },
                                  history: historyEntry("Agent state reset to idle"))
            return .success(())
        } catch {
            return .failure(.updateFailed(error.localizedDescription))
        }
    }

    // MARK: - Internals

    private func makeWorkerTask(using executor: any AgentExecutor,
                                request: CodexRunRequest,
                                logURL: URL,
                                outputDirectory: URL) -> Task<Void, Never> {
        Task { [weak self, executor] in
            guard let self else { return }
            await executor.run(request: request,
                               logURL: logURL,
                               outputDirectory: outputDirectory) { event in
                await MainActor.run {
                    self.apply(event: event, for: request.runID)
                }
            }
        }
    }

    private func apply(event: WorkerLogEvent, for runID: UUID) {
        guard var state = runs[runID] else { return }

        switch event {
        case .log(let line):
            state.logs.append(line)
            if state.phase == .queued {
                transitionToRunning(runID: runID)
            }
        case .progress(let percent, let message):
            if state.phase == .queued {
                transitionToRunning(runID: runID)
            }
            state.progress = max(state.progress, percent)
            if let message {
                state.logs.append(message)
            }
        case .finished(let result):
            state.result = result
            let phase: AgentRunPhase
            if result.status == .canceled {
                phase = .canceled
            } else if result.status == .failed || result.exitCode != 0 {
                phase = .failed
            } else {
                phase = .succeeded
            }
            finish(runID: runID,
                   phase: phase,
                   summary: result.summary,
                   result: result)
            return
        }

        runs[runID] = state
    }

    private func transitionToRunning(runID: UUID) {
        guard var state = runs[runID], state.phase == .queued else { return }
        state.phase = .running
        state.logs.append("Worker started")
        runs[runID] = state

        let cardURL = URL(fileURLWithPath: state.cardPath)
        try? updateFrontmatter(at: cardURL,
                               mutate: { draft in
                                   draft.agentStatus = "running"
                                   draft.agentFlow = state.flow.rawValue
                               },
                               history: historyEntry("Run \(state.id) started"))
    }

    private func finishIfNeeded(runID: UUID) {
        guard let state = runs[runID] else { return }
        guard state.phase == .running || state.phase == .queued else { return }
        finish(runID: runID,
               phase: .succeeded,
               summary: state.summary ?? "Completed successfully",
               result: state.result)
    }

    private func finish(runID: UUID, phase: AgentRunPhase, summary: String?, result: WorkerRunResult?) {
        guard var state = runs[runID] else { return }
        state.phase = phase
        state.summary = summary
        state.progress = phase == .succeeded ? 1.0 : state.progress
        state.finishedAt = .now
        state.result = result ?? state.result
        if let summary {
            state.logs.append(summary)
        }
        runs[runID] = state

        if let pipeline = pipelines[runID] {
            pipeline.cancel()
            cleanupOutputs(at: pipeline.outputDirectory)
            pipelines.removeValue(forKey: runID)
        }
        releaseLock(for: state.cardPath)

        let statusValue: String
        switch phase {
        case .succeeded: statusValue = "succeeded"
        case .failed: statusValue = "failed"
        case .canceled: statusValue = "canceled"
        case .queued, .running: statusValue = "running"
        }

        let history = historyEntry(for: state, phase: phase)

        try? updateFrontmatter(at: URL(fileURLWithPath: state.cardPath),
                               mutate: { draft in
                                   draft.agentStatus = statusValue
                                   draft.agentFlow = state.flow.rawValue
                               },
                               history: history)

        if phase == .succeeded {
            Task { [projectLoader] in
                await projectLoader?.refreshProjectSnapshot()
            }
        }
    }

    private func releaseLock(for path: String) {
        locks.remove(path)
    }

    private func prepareRequest(for card: Card, runID: UUID, flow: AgentFlow, backend: AgentBackendKind) throws -> RunPreparation {
        let (projectRoot, relativeCardPath) = projectRootAndRelativePath(for: card.filePath)
        let bookmark = try bookmark(for: projectRoot)
        let cliArgs = cliArguments(for: flow,
                                   projectRoot: projectRoot,
                                   card: card,
                                   runID: runID)

        let base = fileManager.temporaryDirectory.appendingPathComponent("agency-runs", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
        let logDirectory = base.appendingPathComponent(runID.uuidString, isDirectory: true)

        let request = CodexRunRequest(runID: runID,
                                      flow: flow.rawValue,
                                      cardRelativePath: relativeCardPath,
                                      projectBookmark: bookmark,
                                      logDirectory: logDirectory,
                                      outputDirectory: logDirectory,
                                      allowNetwork: false,
                                      cliArgs: cliArgs)

        let directories = try RunDirectories.prepare(for: request, fileManager: fileManager)
        let scopedRequest = request.updatingDirectories(logDirectory: directories.logDirectory,
                                                        outputDirectory: directories.outputDirectory)

        let logURL = directories.logDirectory.appendingPathComponent("worker.log")
        return RunPreparation(request: scopedRequest,
                              logURL: logURL,
                              logDirectory: directories.logDirectory,
                              outputDirectory: directories.outputDirectory)
    }

    private func projectRootAndRelativePath(for cardURL: URL) -> (URL, String) {
        let standardized = cardURL.standardizedFileURL
        var current = standardized.deletingLastPathComponent()
        while current.pathComponents.count > 1 {
            if current.lastPathComponent == "project" {
                let root = current.deletingLastPathComponent()
                let relative = standardized.path.replacingOccurrences(of: root.path + "/", with: "")
                return (root, relative)
            }
            current = current.deletingLastPathComponent()
        }
        return (standardized.deletingLastPathComponent(), standardized.lastPathComponent)
    }

    private func bookmark(for url: URL) throws -> Data {
        try url.standardizedFileURL.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
    }

    private func updateFrontmatter(at url: URL,
                                   mutate: (inout CardDetailFormDraft) -> Void,
                                   history: String?) throws {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let card = try parser.parse(fileURL: url, contents: contents)
        let snapshot = try pipeline.loadSnapshot(for: card)
        var draft = CardDetailFormDraft.from(card: snapshot.card)
        mutate(&draft)

        if let history {
            draft.newHistoryEntry = history
        }

        _ = try pipeline.saveFormDraft(draft,
                                       appendHistory: history != nil,
                                       snapshot: snapshot)
    }

    private func historyEntry(_ message: String, date: Date = .now) -> String {
        CardDetailFormDraft.defaultHistoryPrefix(on: date) + message
    }

    private func historyEntry(for state: AgentRunState, phase: AgentRunPhase) -> String {
        let runID = state.id
        let flow = state.flow.rawValue

        switch phase {
        case .failed:
            let exitCode = state.result?.exitCode ?? 1
            let reason = (state.result?.summary ?? "failed").trimmingCharacters(in: .whitespacesAndNewlines)
            let logPath = state.logDirectory?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            if let logPath, !logPath.isEmpty {
                return historyEntry("Run \(runID) failed (\(flow)); exit \(exitCode); reason=\(reason); see logs at \(logPath)")
            }
            return historyEntry("Run \(runID) failed (\(flow)); exit \(exitCode); reason=\(reason)")

        case .succeeded:
            return historyEntry("Run \(runID) succeeded (\(flow))")

        case .canceled:
            return historyEntry("Run \(runID) canceled (\(flow))")

        case .queued, .running:
            return historyEntry("Run \(runID) finished (\(phase.rawValue))")
        }
    }

    private func cleanupOutputs(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    private func cliArguments(for flow: AgentFlow,
                              projectRoot: URL,
                              card: Card,
                              runID: UUID) -> [String] {
        guard flow == .plan else { return [] }

        var args: [String] = [
            "--project-root", projectRoot.path,
            "--label", planLabel(from: card),
            "--seed-plan"
        ]

        if let summary = card.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            args.append(contentsOf: ["--task-hints", summary])
        }

        args.append(contentsOf: ["--proposed-task", "Generated by run \(runID.uuidString)"])
        return args
    }

    private func planLabel(from card: Card) -> String {
        if let title = card.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            // Strip leading code prefix like "6.2 " if present.
            let components = title.split(separator: " ", maxSplits: 1)
            if components.count == 2, components[0].contains(".") {
                return String(components[1])
            }
            return title
        }

        let slugWords = card.slug.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return slugWords.isEmpty ? "Planned Phase" : slugWords
    }
}

private struct RunPreparation {
    let request: CodexRunRequest
    let logURL: URL
    let logDirectory: URL
    let outputDirectory: URL
}

private struct RunPipeline {
    let runID: UUID
    let request: CodexRunRequest
    let logURL: URL
    let outputDirectory: URL
    let workerTask: Task<Void, Never>
    let streamTask: Task<Void, Never>?

    func cancel() {
        workerTask.cancel()
        streamTask?.cancel()
    }
}

private struct SimulatedWorker {
    let request: CodexRunRequest
    let logURL: URL
    let outputDirectory: URL
    let emit: (@Sendable (WorkerLogEvent) async -> Void)?
    private let dateFormatter = ISO8601DateFormatter()

    func run() async {
        let start = Date()
        do {
            let readyExtra = ["runID": request.runID.uuidString,
                              "flow": request.flow,
                              "card": request.cardRelativePath]
            try record(event: "workerReady", extra: readyExtra)
            await emit?(.log("Worker ready for \(request.flow)"))

            let steps = 8
            for step in 1...steps {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(150))
                let progress = Double(step) / Double(steps)
                let message = "Step \(step) of \(steps) for \(request.flow)"
                try record(event: "progress",
                           extra: ["percent": String(progress),
                                   "message": message])
                await emit?(.progress(progress, message: message))
            }

            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            let result = WorkerRunResult(status: .succeeded,
                                         exitCode: 0,
                                         duration: Double(durationMs) / 1000,
                                         bytesRead: 0,
                                         bytesWritten: 0,
                                         summary: "Completed \(request.flow) flow")
            try recordFinished(result: result)
            await emit?(.finished(result))
        } catch is CancellationError {
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            let result = WorkerRunResult(status: .canceled,
                                         exitCode: 1,
                                         duration: Double(durationMs) / 1000,
                                         bytesRead: 0,
                                         bytesWritten: 0,
                                         summary: "Canceled")
            try? recordFinished(result: result)
            await emit?(.finished(result))
        } catch {
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            let result = WorkerRunResult(status: .failed,
                                         exitCode: 1,
                                         duration: Double(durationMs) / 1000,
                                         bytesRead: 0,
                                         bytesWritten: 0,
                                         summary: error.localizedDescription)
            try? recordFinished(result: result)
            await emit?(.finished(result))
        }
    }

    private func record(event: String, extra: [String: String]) throws {
        let logDirectory = logURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: logDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
        let entry = ["timestamp": dateFormatter.string(from: .now),
                     "event": event]
            .merging(extra) { $1 }
        let data = try JSONSerialization.data(withJSONObject: entry)
        try appendLine(data, to: logURL)
    }

    private func recordFinished(result: WorkerRunResult) throws {
        try record(event: "workerFinished",
                   extra: ["status": result.status.rawValue,
                           "summary": result.summary,
                           "durationMs": String(Int(result.duration * 1000)),
                           "exitCode": String(result.exitCode),
                           "bytesRead": String(result.bytesRead),
                           "bytesWritten": String(result.bytesWritten)])
    }

    private func appendLine(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(data)
        handle.write(Data([0x0a]))
    }
}

extension AgentRunner {
    var activeRunIDs: [UUID] { Array(pipelines.keys) }
}
