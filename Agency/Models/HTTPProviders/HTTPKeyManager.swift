import Foundation
import Security

/// Manages secure storage and retrieval of API keys for HTTP providers using macOS Keychain.
struct HTTPKeyManager {
    /// Base service identifier for HTTP provider keys.
    private static let servicePrefix = "com.briannadoubt.Agency.http-provider"

    /// Errors that can occur during key management.
    enum KeyError: LocalizedError, Equatable {
        case keychainError(OSStatus)
        case notFound
        case encodingError

        var errorDescription: String? {
            switch self {
            case .keychainError(let status):
                return "Keychain error: \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error (\(status))")"
            case .notFound:
                return "API key not found in Keychain."
            case .encodingError:
                return "Failed to encode/decode API key."
            }
        }
    }

    /// Saves an API key to the Keychain for a specific provider.
    /// - Parameters:
    ///   - key: The API key to save.
    ///   - provider: The provider identifier.
    /// - Throws: `KeyError` if the Keychain operation fails.
    static func save(key: String, for provider: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = trimmed.data(using: .utf8) else {
            throw KeyError.encodingError
        }

        let service = "\(servicePrefix).\(provider)"

        // First, try to delete any existing key
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Now add the new key
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status != errSecSuccess {
            throw KeyError.keychainError(status)
        }
    }

    /// Retrieves an API key from the Keychain for a specific provider.
    /// - Parameter provider: The provider identifier.
    /// - Returns: The stored API key.
    /// - Throws: `KeyError` if the key is not found or Keychain operation fails.
    static func retrieve(for provider: String) throws -> String {
        let service = "\(servicePrefix).\(provider)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
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

    /// Deletes an API key from the Keychain for a specific provider.
    /// - Parameter provider: The provider identifier.
    /// - Throws: `KeyError` if the Keychain operation fails (not thrown for "not found").
    static func delete(for provider: String) throws {
        let service = "\(servicePrefix).\(provider)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider
        ]

        let status = SecItemDelete(query as CFDictionary)

        // errSecItemNotFound is acceptable - key was already deleted
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeyError.keychainError(status)
        }
    }

    /// Checks if an API key exists in the Keychain for a specific provider.
    /// - Parameter provider: The provider identifier.
    /// - Returns: `true` if a key is stored, `false` otherwise.
    static func exists(for provider: String) -> Bool {
        let service = "\(servicePrefix).\(provider)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Returns a masked version of an API key for display purposes.
    /// - Parameter key: The full API key.
    /// - Returns: A masked string showing only first 4 and last 4 characters.
    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return "****" }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        return "\(prefix)...\(suffix)"
    }
}
