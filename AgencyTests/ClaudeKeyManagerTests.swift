import Foundation
import Testing
@testable import Agency

struct ClaudeKeyManagerTests {

    // MARK: - Format Validation Tests

    @MainActor
    @Test func validateFormatAcceptsValidKey() {
        #expect(ClaudeKeyManager.validateFormat("sk-ant-api03-valid-key-here-1234567890"))
        #expect(ClaudeKeyManager.validateFormat("sk-ant-xxxxxxxxxxxxxxxxxxxxx"))
    }

    @MainActor
    @Test func validateFormatRejectsInvalidKey() {
        #expect(!ClaudeKeyManager.validateFormat("invalid-key"))
        #expect(!ClaudeKeyManager.validateFormat("sk-invalid"))
        #expect(!ClaudeKeyManager.validateFormat(""))
        #expect(!ClaudeKeyManager.validateFormat("sk-ant-")) // Too short
        #expect(!ClaudeKeyManager.validateFormat("  sk-ant-  ")) // Too short after trimming
    }

    @MainActor
    @Test func validateFormatHandlesWhitespace() {
        #expect(ClaudeKeyManager.validateFormat("  sk-ant-valid-key-12345  "))
    }

    // MARK: - Masking Tests

    @MainActor
    @Test func maskedHidesMiddleOfKey() {
        let key = "sk-ant-api03-abcdefghijklmnop"
        let masked = ClaudeKeyManager.masked(key)

        #expect(masked.hasPrefix("sk-ant-"))
        #expect(masked.hasSuffix("mnop"))
        #expect(masked.contains("..."))
        #expect(!masked.contains("abcdefghij"))
    }

    @MainActor
    @Test func maskedHandlesShortKeys() {
        let shortKey = "sk-ant-x"
        let masked = ClaudeKeyManager.masked(shortKey)

        #expect(masked == "****")
    }

    // MARK: - Constants Tests

    @Test func constantsAreCorrect() {
        #expect(ClaudeKeyManager.serviceName == "com.briannadoubt.Agency.anthropic-api-key")
        #expect(ClaudeKeyManager.accountName == "anthropic-api-key")
        #expect(ClaudeKeyManager.environmentVariable == "ANTHROPIC_API_KEY")
    }

    // MARK: - Error Description Tests

    @MainActor
    @Test func errorDescriptionsAreHelpful() {
        let invalidFormat = ClaudeKeyManager.KeyError.invalidFormat
        #expect(invalidFormat.errorDescription?.contains("sk-ant-") == true)

        let notFound = ClaudeKeyManager.KeyError.notFound
        #expect(notFound.errorDescription?.contains("not found") == true)

        let encodingError = ClaudeKeyManager.KeyError.encodingError
        #expect(encodingError.errorDescription?.contains("encode") == true || encodingError.errorDescription?.contains("decode") == true)
    }

    // MARK: - Keychain Integration Tests
    // Note: These tests actually interact with the Keychain.
    // They use a cleanup pattern to ensure test isolation.

    @MainActor
    @Test func saveAndRetrieveKey() throws {
        // Clean up any existing key first
        try? ClaudeKeyManager.delete()

        let testKey = "sk-ant-test-key-for-unit-testing-12345"

        // Save
        try ClaudeKeyManager.save(key: testKey)

        // Verify exists
        #expect(ClaudeKeyManager.exists())

        // Retrieve
        let retrieved = try ClaudeKeyManager.retrieve()
        #expect(retrieved == testKey)

        // Clean up
        try ClaudeKeyManager.delete()
        #expect(!ClaudeKeyManager.exists())
    }

    @MainActor
    @Test func saveRejectsInvalidKey() {
        do {
            try ClaudeKeyManager.save(key: "invalid-key")
            Issue.record("Should have thrown for invalid key")
        } catch let error as ClaudeKeyManager.KeyError {
            #expect(error == .invalidFormat)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor
    @Test func retrieveThrowsWhenNoKey() {
        // Ensure no key exists
        try? ClaudeKeyManager.delete()

        do {
            _ = try ClaudeKeyManager.retrieve()
            Issue.record("Should have thrown for missing key")
        } catch let error as ClaudeKeyManager.KeyError {
            #expect(error == .notFound)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor
    @Test func deleteSucceedsEvenWhenNoKey() throws {
        // Ensure no key exists
        try? ClaudeKeyManager.delete()

        // Delete again should not throw
        try ClaudeKeyManager.delete()
    }

    @MainActor
    @Test func existsReturnsFalseWhenNoKey() {
        // Ensure no key exists
        try? ClaudeKeyManager.delete()

        #expect(!ClaudeKeyManager.exists())
    }

    @MainActor
    @Test func saveOverwritesExistingKey() throws {
        // Clean up first
        try? ClaudeKeyManager.delete()

        let firstKey = "sk-ant-first-key-12345678901234"
        let secondKey = "sk-ant-second-key-1234567890123"

        try ClaudeKeyManager.save(key: firstKey)
        try ClaudeKeyManager.save(key: secondKey)

        let retrieved = try ClaudeKeyManager.retrieve()
        #expect(retrieved == secondKey)

        // Clean up
        try ClaudeKeyManager.delete()
    }

    @MainActor
    @Test func environmentWithKeyReturnsNilWhenNoKey() {
        // Ensure no key exists
        try? ClaudeKeyManager.delete()

        let env = ClaudeKeyManager.environmentWithKey()
        #expect(env == nil)
    }

    @MainActor
    @Test func environmentWithKeyIncludesAPIKey() throws {
        // Clean up first
        try? ClaudeKeyManager.delete()

        let testKey = "sk-ant-env-test-key-123456789012"
        try ClaudeKeyManager.save(key: testKey)

        let env = ClaudeKeyManager.environmentWithKey()
        #expect(env != nil)
        #expect(env?[ClaudeKeyManager.environmentVariable] == testKey)

        // Clean up
        try ClaudeKeyManager.delete()
    }
}
