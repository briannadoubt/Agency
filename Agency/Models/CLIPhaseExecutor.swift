import Foundation

/// CLI-backed executor that shells out to the phase scaffolding command for the `plan` flow.
struct CLIPhaseExecutor: AgentExecutor {
    private let fileManager: FileManager
    private let command: PhaseScaffoldingCommand

    init(fileManager: FileManager = .default,
         command: PhaseScaffoldingCommand = PhaseScaffoldingCommand()) {
        self.fileManager = fileManager
        self.command = command
    }

    func run(request: CodexRunRequest,
             logURL: URL,
             outputDirectory: URL,
             emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
        let start = Date()
        do {
            try prepareLogDirectory(for: logURL)
            try record(event: "workerReady",
                       extra: ["runID": request.runID.uuidString,
                               "flow": request.flow],
                       logURL: logURL)
            await emit(.log("CLI backend starting (\(request.flow))"))

            let cliStartMessage = "Invoking phase-scaffolding command…"
            try record(event: "progress",
                       extra: ["percent": "0.1", "message": cliStartMessage],
                       logURL: logURL)
            await emit(.progress(0.1, message: cliStartMessage))

            let output = await command.run(arguments: request.cliArgs, fileManager: fileManager)
            for line in output.stdout.split(whereSeparator: \.isNewline) {
                let message = String(line)
                try record(event: "log", extra: ["message": message], logURL: logURL)
                await emit(.log(message))
            }

            if let result = output.result, let planPath = result.planArtifact {
                try appendHistoryEntry(runID: request.runID,
                                       flow: request.flow,
                                       planPath: URL(fileURLWithPath: planPath))
            }

            let duration = Date().timeIntervalSince(start)
            let status: WorkerRunResult.Status = output.exitCode == 0 ? .succeeded : .failed
            let summary: String
            if let result = output.result, output.exitCode == 0 {
                summary = "Created phase-\(result.phaseNumber)-\(result.phaseSlug)"
            } else {
                summary = output.exitCode == 0 ? "Phase scaffolding completed" : "Phase scaffolding failed"
            }

            let result = WorkerRunResult(status: status,
                                         exitCode: Int32(output.exitCode),
                                         duration: duration,
                                         bytesRead: 0,
                                         bytesWritten: 0,
                                         summary: summary)

            try record(event: "workerFinished",
                       extra: ["status": result.status.rawValue,
                               "summary": summary,
                               "durationMs": String(Int(duration * 1000)),
                               "exitCode": String(output.exitCode),
                               "bytesRead": "0",
                               "bytesWritten": "0"],
                       logURL: logURL)
            await emit(.finished(result))
        } catch is CancellationError {
            let duration = Date().timeIntervalSince(start)
            let result = WorkerRunResult(status: .canceled,
                                         exitCode: 1,
                                         duration: duration,
                                         bytesRead: 0,
                                         bytesWritten: 0,
                                         summary: "Canceled")
            try? record(event: "workerFinished",
                        extra: ["status": result.status.rawValue,
                                "summary": result.summary,
                                "durationMs": String(Int(duration * 1000)),
                                "exitCode": "1",
                                "bytesRead": "0",
                                "bytesWritten": "0"],
                        logURL: logURL)
            await emit(.finished(result))
        } catch {
            let duration = Date().timeIntervalSince(start)
            let result = WorkerRunResult(status: .failed,
                                         exitCode: 1,
                                         duration: duration,
                                         bytesRead: 0,
                                         bytesWritten: 0,
                                         summary: error.localizedDescription)
            try? record(event: "workerFinished",
                        extra: ["status": result.status.rawValue,
                                "summary": result.summary,
                                "durationMs": String(Int(duration * 1000)),
                                "exitCode": "1",
                                "bytesRead": "0",
                                "bytesWritten": "0"],
                        logURL: logURL)
            await emit(.finished(result))
        }
    }

    // MARK: - Helpers

    private func prepareLogDirectory(for logURL: URL) throws {
        let directory = logURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func record(event: String, extra: [String: String], logURL: URL) throws {
        let entry = ["timestamp": ISO8601DateFormatter().string(from: .now),
                     "event": event]
            .merging(extra) { $1 }
        let data = try JSONSerialization.data(withJSONObject: entry)
        try appendLine(data, to: logURL)
    }

    private func appendLine(_ data: Data, to url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(data)
        handle.write(Data([0x0a]))
        try handle.close()
    }

    private func appendHistoryEntry(runID: UUID, flow: String, planPath: URL) throws {
        guard fileManager.fileExists(atPath: planPath.path) else { return }
        let contents = try String(contentsOf: planPath, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let entry = "- \(today): Run \(runID.uuidString) finished (\(flow))"

        if let historyIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("History:") == .orderedSame }) {
            var insertIndex = historyIndex + 1
            while insertIndex < lines.count && lines[insertIndex].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                insertIndex += 1
            }
            lines.insert(entry, at: insertIndex)
        } else {
            lines.append("")
            lines.append("History:")
            lines.append(entry)
        }

        let updated = lines.joined(separator: "\n")
        try updated.write(to: planPath, atomically: true, encoding: .utf8)
    }
}
