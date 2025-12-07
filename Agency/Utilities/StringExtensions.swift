import Foundation

extension String {
    /// Returns a copy of the string with leading and trailing whitespace and newlines removed.
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
