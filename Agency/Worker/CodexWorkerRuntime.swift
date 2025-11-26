import Foundation
import os.log

/// Lightweight runtime used by the worker helper executable. This file deliberately avoids a `@main`
/// entry so the code can live in the primary target until the helper target is wired up in Xcode.
struct CodexWorkerRuntime {
    let payload: CodexRunRequest
    let endpointName: String
    let logDirectory: URL
    let allowNetwork: Bool

    private let logger = Logger(subsystem: "dev.agency.worker", category: "runtime")

    func run() async {
        do {
            try record(event: "workerReady", extra: ["runID": payload.runID.uuidString])
            // In the real helper this is where Codex CLI would run. Here we simulate fast completion.
            try await Task.sleep(for: .milliseconds(10))
            try record(event: "workerFinished",
                       extra: ["status": WorkerRunResult.Status.succeeded.rawValue,
                               "card": payload.cardRelativePath])
        } catch {
            logger.error("Worker runtime failed: \(error.localizedDescription)")
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

        let allowNetwork = env["CODEX_ALLOW_NETWORK"] == "1"
        return CodexWorkerRuntime(payload: payload,
                                  endpointName: endpointName,
                                  logDirectory: URL(fileURLWithPath: logPath),
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
                        allowNetwork: false,
                        cliArgs: [])
    }
}

