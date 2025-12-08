import Foundation
import os.log

/// A completed agent run record for history tracking.
struct CompletedRunRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let cardPath: String
    let cardTitle: String?
    let flow: String
    let pipeline: String?
    let startedAt: Date
    let completedAt: Date
    let duration: TimeInterval
    let status: WorkerRunResult.Status
    let exitCode: Int32
    let bytesRead: Int64
    let bytesWritten: Int64
    let summary: String

    init(
        id: UUID = UUID(),
        cardPath: String,
        cardTitle: String? = nil,
        flow: String,
        pipeline: String? = nil,
        startedAt: Date,
        completedAt: Date,
        duration: TimeInterval,
        status: WorkerRunResult.Status,
        exitCode: Int32,
        bytesRead: Int64,
        bytesWritten: Int64,
        summary: String
    ) {
        self.id = id
        self.cardPath = cardPath
        self.cardTitle = cardTitle
        self.flow = flow
        self.pipeline = pipeline
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.duration = duration
        self.status = status
        self.exitCode = exitCode
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.summary = summary
    }
}

/// Aggregate metrics computed from run history.
struct RunHistoryMetrics: Sendable {
    let totalRuns: Int
    let successfulRuns: Int
    let failedRuns: Int
    let canceledRuns: Int
    let successRate: Double
    let totalDuration: TimeInterval
    let averageDuration: TimeInterval
    let totalBytesRead: Int64
    let totalBytesWritten: Int64

    init(records: [CompletedRunRecord]) {
        self.totalRuns = records.count
        self.successfulRuns = records.filter { $0.status == .succeeded }.count
        self.failedRuns = records.filter { $0.status == .failed }.count
        self.canceledRuns = records.filter { $0.status == .canceled }.count
        self.successRate = totalRuns > 0 ? Double(successfulRuns) / Double(totalRuns) : 0
        self.totalDuration = records.reduce(0) { $0 + $1.duration }
        self.averageDuration = totalRuns > 0 ? totalDuration / Double(totalRuns) : 0
        self.totalBytesRead = records.reduce(0) { $0 + $1.bytesRead }
        self.totalBytesWritten = records.reduce(0) { $0 + $1.bytesWritten }
    }

    static var empty: RunHistoryMetrics {
        RunHistoryMetrics(records: [])
    }
}

/// Filter criteria for run history queries.
struct RunHistoryFilter: Sendable {
    var startDate: Date?
    var endDate: Date?
    var flow: String?
    var status: WorkerRunResult.Status?
    var cardPathContains: String?

    init(
        startDate: Date? = nil,
        endDate: Date? = nil,
        flow: String? = nil,
        status: WorkerRunResult.Status? = nil,
        cardPathContains: String? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.flow = flow
        self.status = status
        self.cardPathContains = cardPathContains
    }

    func matches(_ record: CompletedRunRecord) -> Bool {
        if let startDate, record.completedAt < startDate {
            return false
        }
        if let endDate, record.completedAt > endDate {
            return false
        }
        if let flow, record.flow != flow {
            return false
        }
        if let status, record.status != status {
            return false
        }
        if let cardPathContains, !record.cardPath.localizedCaseInsensitiveContains(cardPathContains) {
            return false
        }
        return true
    }
}

/// Persists completed run history to disk.
@MainActor
final class RunHistoryStore {
    static let shared = RunHistoryStore()

    private let historyURL: URL
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "dev.agency.app", category: "RunHistoryStore")
    private let maxRecords: Int

    /// In-memory cache of records for fast access.
    private var cachedRecords: [CompletedRunRecord]?

    init(directory: URL? = nil, fileManager: FileManager = .default, maxRecords: Int = 1000) {
        let baseDirectory = directory ?? Self.defaultDirectory
        self.historyURL = baseDirectory.appendingPathComponent("run-history.json")
        self.fileManager = fileManager
        self.maxRecords = maxRecords
    }

    private static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Agency", isDirectory: true)
    }

    // MARK: - Public API

    /// Adds a completed run to the history.
    func addRecord(_ record: CompletedRunRecord) throws {
        var records = try loadRecords()
        records.insert(record, at: 0)

        // Trim to max records
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }

        try saveRecords(records)
        cachedRecords = records
        logger.debug("Added run record for \(record.cardPath)")
    }

    /// Creates and adds a record from run information.
    func addRecord(
        runID: UUID,
        cardPath: String,
        cardTitle: String?,
        flow: String,
        pipeline: String?,
        startedAt: Date,
        result: WorkerRunResult
    ) throws {
        let record = CompletedRunRecord(
            id: runID,
            cardPath: cardPath,
            cardTitle: cardTitle,
            flow: flow,
            pipeline: pipeline,
            startedAt: startedAt,
            completedAt: Date(),
            duration: result.duration,
            status: result.status,
            exitCode: result.exitCode,
            bytesRead: result.bytesRead,
            bytesWritten: result.bytesWritten,
            summary: result.summary
        )
        try addRecord(record)
    }

    /// Returns all records, optionally filtered.
    func records(filter: RunHistoryFilter? = nil) throws -> [CompletedRunRecord] {
        let allRecords = try loadRecords()
        guard let filter else { return allRecords }
        return allRecords.filter { filter.matches($0) }
    }

    /// Returns recent records up to a limit.
    func recentRecords(limit: Int = 50) throws -> [CompletedRunRecord] {
        let allRecords = try loadRecords()
        return Array(allRecords.prefix(limit))
    }

    /// Computes aggregate metrics for the given filter.
    func metrics(filter: RunHistoryFilter? = nil) throws -> RunHistoryMetrics {
        let filtered = try records(filter: filter)
        return RunHistoryMetrics(records: filtered)
    }

    /// Clears all history.
    func clear() {
        try? fileManager.removeItem(at: historyURL)
        cachedRecords = nil
        logger.info("Cleared run history")
    }

    /// Clears records older than the specified date.
    func clearOlderThan(_ date: Date) throws {
        var records = try loadRecords()
        let originalCount = records.count
        records.removeAll { $0.completedAt < date }
        try saveRecords(records)
        cachedRecords = records
        let removed = originalCount - records.count
        if removed > 0 {
            logger.info("Cleared \(removed) run records older than \(date)")
        }
    }

    // MARK: - Private

    private func loadRecords() throws -> [CompletedRunRecord] {
        if let cached = cachedRecords {
            return cached
        }

        guard fileManager.fileExists(atPath: historyURL.path) else {
            cachedRecords = []
            return []
        }

        let data = try Data(contentsOf: historyURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([CompletedRunRecord].self, from: data)
        cachedRecords = records
        return records
    }

    private func saveRecords(_ records: [CompletedRunRecord]) throws {
        let directory = historyURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(records)
        try data.write(to: historyURL, options: .atomic)
    }
}
