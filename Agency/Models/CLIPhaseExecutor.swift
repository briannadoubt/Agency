import Foundation

/// CLI-backed executor that shells out to the phase scaffolding command for the `plan` flow.
struct CLIPhaseExecutor: AgentExecutor {
    private let fileManager: FileManager
    private let command: PhaseScaffoldingCommand
    private let logging: ExecutorLogging

    init(fileManager: FileManager = .default,
         command: PhaseScaffoldingCommand = PhaseScaffoldingCommand(),
         logging: ExecutorLogging = ExecutorLogging()) {
        self.fileManager = fileManager
        self.command = command
        self.logging = logging
    }

    func run(request: WorkerRunRequest,
             logURL: URL,
             outputDirectory: URL,
             emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
        let start = Date()
        do {
            try logging.prepareLogDirectory(for: logURL)
            try logging.recordReady(runID: request.runID, flow: request.flow, to: logURL)
            await emit(.log("CLI backend starting (\(request.flow))"))

            let cliStartMessage = "Invoking phase-scaffolding command…"
            try logging.recordProgress(percent: 0.1, message: cliStartMessage, to: logURL)
            await emit(.progress(0.1, message: cliStartMessage))

            let output = await command.run(arguments: request.cliArgs, fileManager: fileManager)
            for line in output.stdout.split(whereSeparator: \.isNewline) {
                let message = String(line)
                try logging.recordLog(message: message, to: logURL)
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

            try logging.recordFinished(result: result, to: logURL)
            await emit(.finished(result))
        } catch is CancellationError {
            let duration = Date().timeIntervalSince(start)
            let result = WorkerRunResult(status: .canceled,
                                         exitCode: 1,
                                         duration: duration,
                                         bytesRead: 0,
                                         bytesWritten: 0,
                                         summary: "Canceled")
            try? logging.recordFinished(result: result, to: logURL)
            await emit(.finished(result))
        } catch {
            let duration = Date().timeIntervalSince(start)
            let result = WorkerRunResult(status: .failed,
                                         exitCode: 1,
                                         duration: duration,
                                         bytesRead: 0,
                                         bytesWritten: 0,
                                         summary: error.localizedDescription)
            try? logging.recordFinished(result: result, to: logURL)
            await emit(.finished(result))
        }
    }

    // MARK: - Helpers

    private func appendHistoryEntry(runID: UUID, flow: String, planPath: URL) throws {
        guard fileManager.fileExists(atPath: planPath.path) else { return }
        let contents = try String(contentsOf: planPath, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let today = DateFormatters.dateString(from: Date())
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
