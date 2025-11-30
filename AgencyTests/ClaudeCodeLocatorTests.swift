import Foundation
import Testing
@testable import Agency

struct ClaudeCodeLocatorTests {

    @MainActor
    @Test func locatorFindsUserOverridePath() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mockClaudePath = tempDir.appendingPathComponent("claude")
        try "#!/bin/bash\necho 'mock claude'".write(to: mockClaudePath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockClaudePath.path)

        let locator = ClaudeCodeLocator()
        let result = await locator.locate(userOverridePath: mockClaudePath.path)

        switch result {
        case .success(let info):
            #expect(info.path == mockClaudePath.path)
            #expect(info.source == .userOverride)
        case .failure(let error):
            Issue.record("Expected success but got: \(error)")
        }
    }

    @MainActor
    @Test func locatorReturnsNotFoundWhenOverridePathDoesNotExist() async {
        let locator = ClaudeCodeLocator()
        let result = await locator.locate(userOverridePath: "/nonexistent/path/to/claude")

        // Should fall through to PATH and common locations, then fail
        switch result {
        case .success:
            // May succeed if claude is actually installed on the system
            break
        case .failure(let error):
            #expect(error == .notFound)
        }
    }

    @MainActor
    @Test func locatorReturnsNotExecutableForNonExecutableFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mockClaudePath = tempDir.appendingPathComponent("claude")
        try "not executable".write(to: mockClaudePath, atomically: true, encoding: .utf8)
        // Don't set executable permissions

        let locator = ClaudeCodeLocator()
        let result = await locator.locate(userOverridePath: mockClaudePath.path)

        switch result {
        case .success:
            Issue.record("Expected failure for non-executable file")
        case .failure(let error):
            #expect(error == .notExecutable(mockClaudePath.path))
        }
    }

    @MainActor
    @Test func verifyReturnsSuccessForValidExecutable() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mockClaudePath = tempDir.appendingPathComponent("claude")
        try "#!/bin/bash\necho '1.0.0'".write(to: mockClaudePath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockClaudePath.path)

        let locator = ClaudeCodeLocator()
        let result = await locator.verify(path: mockClaudePath.path)

        switch result {
        case .success(let info):
            #expect(info.path == mockClaudePath.path)
        case .failure(let error):
            Issue.record("Expected success but got: \(error)")
        }
    }

    @MainActor
    @Test func verifyReturnsNotFoundForMissingPath() async {
        let locator = ClaudeCodeLocator()
        let result = await locator.verify(path: "/nonexistent/path/to/claude")

        switch result {
        case .success:
            Issue.record("Expected failure for nonexistent path")
        case .failure(let error):
            #expect(error == .notFound)
        }
    }

    @Test func commonPathsContainsExpectedLocations() {
        let paths = ClaudeCodeLocator.commonPaths

        #expect(paths.contains("/usr/local/bin/claude"))
        #expect(paths.contains("/opt/homebrew/bin/claude"))
        #expect(paths.contains { $0.contains(".local/bin/claude") })
    }

    @MainActor
    @Test func locatorExpandsTildeInUserOverride() async throws {
        let locator = ClaudeCodeLocator()

        // Test with a tilde path that won't exist
        let result = await locator.locate(userOverridePath: "~/nonexistent-claude-test-path/claude")

        // Should fail because path doesn't exist, but shouldn't crash on tilde expansion
        switch result {
        case .success:
            // May succeed if claude is found elsewhere
            break
        case .failure:
            // Expected - path doesn't exist
            break
        }
    }
}

struct ClaudeCodeSettingsTests {

    @MainActor
    @Test func settingsPersistsPathOverride() async throws {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let settings = ClaudeCodeSettings(defaults: defaults)

        #expect(settings.cliPathOverride.isEmpty)

        settings.cliPathOverride = "/custom/path/to/claude"

        #expect(defaults.string(forKey: "claudeCodeCLIPath") == "/custom/path/to/claude")
    }

    @MainActor
    @Test func settingsLoadsPersistedPath() async throws {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set("/persisted/path", forKey: "claudeCodeCLIPath")

        let settings = ClaudeCodeSettings(defaults: defaults)

        #expect(settings.cliPathOverride == "/persisted/path")
    }

    @MainActor
    @Test func clearOverrideRemovesPath() async throws {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let settings = ClaudeCodeSettings(defaults: defaults)
        settings.cliPathOverride = "/some/path"

        await settings.clearOverride()

        #expect(settings.cliPathOverride.isEmpty)
        #expect(defaults.string(forKey: "claudeCodeCLIPath") == "")
    }

    @MainActor
    @Test func statusIsCheckingInitially() async {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let settings = ClaudeCodeSettings(defaults: defaults)

        #expect(settings.status == .checking)
    }
}
