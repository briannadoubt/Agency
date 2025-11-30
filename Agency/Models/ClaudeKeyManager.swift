import Foundation
import Security

/// Manages secure storage and retrieval of the Anthropic API key using macOS Keychain.
struct ClaudeKeyManager {
    /// The service identifier for Keychain storage.
    static let serviceName = "com.briannadoubt.Agency.anthropic-api-key"

    /// The account name for Keychain storage.
    static let accountName = "anthropic-api-key"

    /// Environment variable name for passing API key to subprocesses.
    static let environmentVariable = "ANTHROPIC_API_KEY"

    /// Errors that can occur during key management.
    enum KeyError: LocalizedError, Equatable {
        case invalidFormat
        case keychainError(OSStatus)
        case notFound
        case encodingError

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "Invalid API key format. Key should start with 'sk-ant-'."
            case .keychainError(let status):
                return "Keychain error: \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error (\(status))")"
            case .notFound:
                return "API key not found in Keychain."
            case .encodingError:
                return "Failed to encode/decode API key."
            }
        }
    }

    /// Validates that an API key has the expected format.
    static func validateFormat(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-ant-") && trimmed.count > 10
    }

    /// Saves an API key to the Keychain.
    /// - Parameter key: The API key to save.
    /// - Throws: `KeyError` if the key is invalid or Keychain operation fails.
    static func save(key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)

        guard validateFormat(trimmed) else {
            throw KeyError.invalidFormat
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw KeyError.encodingError
        }

        // First, try to delete any existing key
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Now add the new key
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status != errSecSuccess {
            throw KeyError.keychainError(status)
        }
    }

    /// Retrieves the API key from the Keychain.
    /// - Returns: The stored API key.
    /// - Throws: `KeyError` if the key is not found or Keychain operation fails.
    static func retrieve() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            throw KeyError.notFound
        }

        if status != errSecSuccess {
            throw KeyError.keychainError(status)
        }

        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw KeyError.encodingError
        }

        return key
    }

    /// Deletes the API key from the Keychain.
    /// - Throws: `KeyError` if the Keychain operation fails (not thrown for "not found").
    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]

        let status = SecItemDelete(query as CFDictionary)

        // errSecItemNotFound is acceptable - key was already deleted
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeyError.keychainError(status)
        }
    }

    /// Checks if an API key exists in the Keychain.
    /// - Returns: `true` if a key is stored, `false` otherwise.
    static func exists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Returns a masked version of the API key for display purposes.
    /// - Parameter key: The full API key.
    /// - Returns: A masked string showing only first and last 4 characters.
    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return "****" }
        let prefix = String(key.prefix(7)) // "sk-ant-"
        let suffix = String(key.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    /// Creates environment dictionary with the API key for subprocess execution.
    /// - Returns: Dictionary with ANTHROPIC_API_KEY set, or nil if key not found.
    static func environmentWithKey() -> [String: String]? {
        guard let key = try? retrieve() else { return nil }
        var env = ProcessInfo.processInfo.environment
        env[environmentVariable] = key
        return env
    }
}
