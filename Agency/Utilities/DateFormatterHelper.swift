import Foundation

/// Provides cached DateFormatter instances for common date formats.
/// Avoids repeated DateFormatter creation which is expensive.
enum DateFormatters {
    /// ISO8601 date-only formatter (yyyy-MM-dd) for history entries and logs.
    private nonisolated(unsafe) static let iso8601Date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// ISO8601 date formatter for directory names (yyyyMMdd).
    private nonisolated(unsafe) static let iso8601DateCompact: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    /// Returns today's date as an ISO8601 date string (yyyy-MM-dd).
    nonisolated static func todayString() -> String {
        iso8601Date.string(from: Date())
    }

    /// Returns a date string for the given date in ISO8601 format (yyyy-MM-dd).
    nonisolated static func dateString(from date: Date) -> String {
        iso8601Date.string(from: date)
    }

    /// Returns a compact date string for the given date (yyyyMMdd), useful for directory names.
    nonisolated static func compactDateString(from date: Date) -> String {
        iso8601DateCompact.string(from: date)
    }
}
