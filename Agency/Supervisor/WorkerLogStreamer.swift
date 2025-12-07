import Foundation
import os.log

enum WorkerLogEvent: Equatable {
    case log(String)
    case progress(Double, message: String?)
    case finished(WorkerRunResult)
}

/// Abstraction for streaming worker logs; allows testing failure paths without touching the real file watcher.
protocol WorkerLogStreaming {
    func stream(logURL: URL) -> AsyncThrowingStream<WorkerLogEvent, Error>
    func readAllEvents(logURL: URL) throws -> [WorkerLogEvent]
}

enum WorkerLogStreamError: LocalizedError {
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "Worker log file never appeared."
        }
    }
}

struct WorkerLogStreamer {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "WorkerLogStreamer")

    /// Streams events as they are appended to the worker log file.
    func stream(logURL: URL) -> AsyncThrowingStream<WorkerLogEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await waitForFile(at: logURL)
                    let handle = try FileHandle(forReadingFrom: logURL)
                    defer {
                        do {
                            try handle.close()
                        } catch {
                            Self.logger.warning("Failed to close log file handle: \(error.localizedDescription)")
                        }
                    }

                    var buffer = Data()
                    for try await byte in handle.bytes {
                        if Task.isCancelled { break }
                        if byte == 0x0a {
                            if let event = parseEvent(from: buffer) {
                                continuation.yield(event)
                            }
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }

                    if !buffer.isEmpty, let event = parseEvent(from: buffer) {
                        continuation.yield(event)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Reads the entire log file and returns the parsed events in order.
    /// Useful as a fallback when streaming misses events (e.g., sandboxed tests).
    func readAllEvents(logURL: URL) throws -> [WorkerLogEvent] {
        let data = try Data(contentsOf: logURL)
        return parseEvents(in: data)
    }

    // MARK: - Helpers

    private func waitForFile(at url: URL, timeout: TimeInterval = 5.0) async throws {
        let start = Date()
        while !FileManager.default.fileExists(atPath: url.path) {
            try Task.checkCancellation()
            if Date().timeIntervalSince(start) > timeout {
                throw WorkerLogStreamError.fileMissing
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func parseEvent(from data: Data) -> WorkerLogEvent? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseJSONEvent(object)
        }

        if let text = String(data: data, encoding: .utf8) {
            return .log(text)
        }

        return nil
    }

    private func parseEvents(in data: Data) -> [WorkerLogEvent] {
        let lines = data.split(separator: 0x0a).map { Data($0) }
        return lines.compactMap(parseEvent(from:))
    }

    private func parseJSONEvent(_ object: [String: Any]) -> WorkerLogEvent? {
        let event = object["event"] as? String
        let message = object["message"] as? String ?? object["summary"] as? String

        if event == "progress" || object["percent"] != nil {
            let percent = double(from: object["percent"]) ?? 0
            return .progress(percent, message: message)
        }

        if event == "workerFinished" || object["status"] != nil {
            let status = WorkerRunResult.Status(rawValue: (object["status"] as? String ?? "").lowercased()) ?? .failed
            let exitCode = Int32(int(from: object["exitCode"]) ?? 0)
            let durationMs = double(from: object["durationMs"]) ?? 0
            let bytesRead = Int64(int(from: object["bytesRead"]) ?? 0)
            let bytesWritten = Int64(int(from: object["bytesWritten"]) ?? 0)
            let result = WorkerRunResult(status: status,
                                         exitCode: exitCode,
                                         duration: durationMs / 1000,
                                         bytesRead: bytesRead,
                                         bytesWritten: bytesWritten,
                                         summary: message ?? status.rawValue.capitalized)
            return .finished(result)
        }

        if let message {
            return .log(message)
        }

        return nil
    }

    private func double(from value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Int32 { return Double(value) }
        if let value = value as? Int64 { return Double(value) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func int(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int32 { return Int(value) }
        if let value = value as? Int64 { return Int(value) }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

extension WorkerLogStreamer: WorkerLogStreaming { }
