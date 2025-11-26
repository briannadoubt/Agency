import Foundation
import os.log

/// Lightweight runtime used by the worker helper executable. This file deliberately avoids a `@main`
/// entry so the code can live in the primary target until the helper target is wired up in Xcode.
struct CodexWorkerRuntime {
    let payload: CodexRunRequest
    let endpointName: String
    let logDirectory: URL
    let outputDirectory: URL
    let allowNetwork: Bool

    private let logger = Logger(subsystem: "dev.agency.worker", category: "runtime")

    func run() async {
        do {
            let sandbox = WorkerSandbox(projectBookmark: payload.projectBookmark,
                                        outputDirectory: outputDirectory)
            let project = try sandbox.openProjectScope()
            defer { project.access.stopAccessing() }

            try sandbox.ensureOutputDirectoryExists()

            try record(event: "workerReady",
                       extra: ["runID": payload.runID.uuidString,
                               "project": project.url.path,
                               "output": outputDirectory.path,
                               "bookmarkStale": "\(project.bookmarkWasStale)"])

            // In the real helper this is where Codex CLI would run. Here we simulate fast completion.
            try await Task.sleep(for: .milliseconds(10))

            try record(event: "workerFinished",
                       extra: ["status": WorkerRunResult.Status.succeeded.rawValue,
                               "card": payload.cardRelativePath])
        } catch {
            logger.error("Worker runtime failed: \(error.localizedDescription)")
            do {
                try record(event: "workerFinished",
                           extra: ["status": WorkerRunResult.Status.failed.rawValue,
                                   "card": payload.cardRelativePath,
                                   "error": error.localizedDescription])
            } catch {
                logger.error("Unable to record failure event: \(error.localizedDescription)")
            }
        }
    }

    private func record(event: String, extra: [String: String]) throws {
        let logURL = logDirectory.appendingPathComponent("worker.log")
        let entry = ["timestamp": ISO8601DateFormatter().string(from: .now),
                     "event": event]
            .merging(extra) { $1 }
        let line = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        try appendLine(line, to: logURL)
    }

    private func appendLine(_ data: Data, to url: URL) throws {
        let handle: FileHandle
        if FileManager.default.fileExists(atPath: url.path) {
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        }
        handle.write(data)
        handle.write(Data([0x0a]))
        try handle.close()
    }
}

// MARK: - Bootstrap Helpers

enum CodexWorkerBootstrap {
    static func runtimeFromEnvironment(arguments: [String]) -> CodexWorkerRuntime? {
        let env = ProcessInfo.processInfo.environment
        guard
            let runIDString = env["CODEX_RUN_ID"],
            let runID = UUID(uuidString: runIDString),
            let endpointName = env["CODEX_ENDPOINT_NAME"],
            let logPath = env["CODEX_LOG_DIRECTORY"]
        else { return nil }

        let payload: CodexRunRequest
        if let payloadPathIndex = arguments.firstIndex(of: "--payload"),
           arguments.indices.contains(payloadPathIndex + 1) {
            let url = URL(fileURLWithPath: arguments[payloadPathIndex + 1])
            payload = (try? decodePayload(at: url)) ?? placeholderPayload(runID: runID)
        } else {
            payload = placeholderPayload(runID: runID)
        }

        let bookmarkOverride = env["CODEX_PROJECT_BOOKMARK_BASE64"].flatMap { Data(base64Encoded: $0) }
        let outputDirectory = env["CODEX_OUTPUT_DIRECTORY"].map { URL(fileURLWithPath: $0) } ?? payload.outputDirectory
        let resolvedPayload = CodexRunRequest(runID: payload.runID,
                                              flow: payload.flow,
                                              cardRelativePath: payload.cardRelativePath,
                                              projectBookmark: bookmarkOverride ?? payload.projectBookmark,
                                              logDirectory: payload.logDirectory,
                                              outputDirectory: outputDirectory,
                                              allowNetwork: payload.allowNetwork,
                                              cliArgs: payload.cliArgs)

        let allowNetwork = env["CODEX_ALLOW_NETWORK"] == "1"
        return CodexWorkerRuntime(payload: resolvedPayload,
                                  endpointName: endpointName,
                                  logDirectory: URL(fileURLWithPath: logPath),
                                  outputDirectory: outputDirectory,
                                  allowNetwork: allowNetwork)
    }

    private static func decodePayload(at url: URL) throws -> CodexRunRequest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CodexRunRequest.self, from: data)
    }

    private static func placeholderPayload(runID: UUID) -> CodexRunRequest {
        CodexRunRequest(runID: runID,
                        flow: "unknown",
                        cardRelativePath: "",
                        projectBookmark: Data(),
                        logDirectory: FileManager.default.temporaryDirectory,
                        outputDirectory: FileManager.default.temporaryDirectory,
                        allowNetwork: false,
                        cliArgs: [])
    }
}

// MARK: - Sandbox Helpers

struct BookmarkResolution {
    let url: URL
    let isStale: Bool
}

struct BookmarkResolver {
    typealias Resolver = (_ bookmark: Data, _ options: URL.BookmarkResolutionOptions) throws -> BookmarkResolution
    let resolve: Resolver

    static let live = BookmarkResolver { bookmark, options in
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark,
                          options: options,
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        return BookmarkResolution(url: url, isStale: isStale)
    }
}

enum WorkerSandboxError: LocalizedError {
    case missingBookmark
    case bookmarkResolutionFailed(String)
    case securityScopeUnavailable

    var errorDescription: String? {
        switch self {
        case .missingBookmark:
            return "Project bookmark missing; worker cannot access files."
        case .bookmarkResolutionFailed(let reason):
            return "Unable to resolve project bookmark: \(reason)"
        case .securityScopeUnavailable:
            return "Security scope could not be activated for the project bookmark."
        }
    }
}

struct WorkerSandbox {
    let projectBookmark: Data
    let outputDirectory: URL
    private let fileManager: FileManager
    private let bookmarkResolver: BookmarkResolver
    private let accessFactory: @Sendable (URL) -> SecurityScopedAccess

    init(projectBookmark: Data,
         outputDirectory: URL,
         fileManager: FileManager = .default,
         bookmarkResolver: BookmarkResolver = .live,
         accessFactory: @escaping @Sendable (URL) -> SecurityScopedAccess = { url in SecurityScopedAccess(url: url) }) {
        self.projectBookmark = projectBookmark
        self.outputDirectory = outputDirectory
        self.fileManager = fileManager
        self.bookmarkResolver = bookmarkResolver
        self.accessFactory = accessFactory
    }

    func openProjectScope() throws -> ScopedProject {
        guard !projectBookmark.isEmpty else { throw WorkerSandboxError.missingBookmark }
        let resolution: BookmarkResolution
        do {
            resolution = try bookmarkResolver.resolve(projectBookmark,
                                                      [.withSecurityScope, .withoutUI, .withoutMounting])
        } catch {
            throw WorkerSandboxError.bookmarkResolutionFailed(error.localizedDescription)
        }

        let access = accessFactory(resolution.url.standardizedFileURL)
        guard access.isActive else { throw WorkerSandboxError.securityScopeUnavailable }

        return ScopedProject(url: resolution.url.standardizedFileURL,
                             access: access,
                             bookmarkWasStale: resolution.isStale)
    }

    func ensureOutputDirectoryExists() throws {
        try fileManager.createDirectory(at: outputDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: nil)
    }

    struct ScopedProject {
        let url: URL
        let access: SecurityScopedAccess
        let bookmarkWasStale: Bool
    }
}
