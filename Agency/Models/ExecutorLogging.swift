import Foundation

/// Shared logging utilities used by all executor implementations.
/// Consolidates duplicated code for log directory preparation, event recording, and line appending.
struct ExecutorLogging {
    private let fileManager: FileManager
    private let dateFormatter: ISO8601DateFormatter

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.dateFormatter = ISO8601DateFormatter()
    }

    /// Creates the log directory for the given log file URL if it doesn't exist.
    func prepareLogDirectory(for logURL: URL) throws {
        let directory = logURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: nil)
    }

    /// Records a JSON event to the log file with timestamp and custom fields.
    func record(event: String, extra: [String: String], to logURL: URL) throws {
        let entry = ["timestamp": dateFormatter.string(from: .now),
                     "event": event]
            .merging(extra) { $1 }
        let data = try JSONSerialization.data(withJSONObject: entry)
        try appendLine(data, to: logURL)
    }

    /// Appends a data line followed by a newline to the specified file.
    /// Creates the file if it doesn't exist.
    func appendLine(_ data: Data, to url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(data)
        handle.write(Data([0x0a]))
    }

    /// Records a workerReady event with run ID and flow.
    func recordReady(runID: UUID, flow: String, to logURL: URL) throws {
        try record(event: "workerReady",
                   extra: ["runID": runID.uuidString, "flow": flow],
                   to: logURL)
    }

    /// Records a workerFinished event with the full result details.
    func recordFinished(result: WorkerRunResult, to logURL: URL) throws {
        try record(event: "workerFinished",
                   extra: ["status": result.status.rawValue,
                           "summary": result.summary,
                           "durationMs": String(Int(result.duration * 1000)),
                           "exitCode": String(result.exitCode),
                           "bytesRead": String(result.bytesRead),
                           "bytesWritten": String(result.bytesWritten)],
                   to: logURL)
    }

    /// Records a progress event with percentage and optional message.
    func recordProgress(percent: Double, message: String?, to logURL: URL) throws {
        var extra = ["percent": String(percent)]
        if let message {
            extra["message"] = message
        }
        try record(event: "progress", extra: extra, to: logURL)
    }

    /// Records a log message event.
    func recordLog(message: String, to logURL: URL) throws {
        try record(event: "log", extra: ["message": message], to: logURL)
    }
}
