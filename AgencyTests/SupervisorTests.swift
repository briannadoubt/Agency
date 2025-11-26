import Foundation
import Testing
@testable import Agency

@MainActor
struct SupervisorTests {

    @Test func backoffCappedAtFiveMinutes() {
        let policy = WorkerBackoffPolicy(baseDelay: .seconds(30),
                                         multiplier: 2,
                                         jitter: 0,
                                         maxDelay: .seconds(300),
                                         maxRetries: 5)

        let delays = (1...6).map { policy.delay(forFailureCount: $0) }

        #expect(delays.first == .seconds(30))
        #expect(delays.last! <= .seconds(300))
    }

    @Test func capabilityChecklistSurfacesMissingEntitlements() async throws {
        let checklist = CapabilityChecklist { key in
            // Pretend only the sandbox entitlement is present.
            key == "com.apple.security.app-sandbox"
        }

        let missing = checklist.missingCapabilities([.appSandbox, .bookmarkScope, .userSelectedReadWrite])

        #expect(missing.contains(.bookmarkScope))
        #expect(missing.contains(.userSelectedReadWrite))
        #expect(!missing.contains(.appSandbox))
    }

    @Test func supervisorAndWorkerPlistsExist() throws {
        let resourcesRoot = try resourcesDirectory()
        let supervisorPlist = resourcesRoot.appendingPathComponent("CodexSupervisor.plist")
        let workerPlist = resourcesRoot.appendingPathComponent("CodexWorker.plist")

        #expect(FileManager.default.fileExists(atPath: supervisorPlist.path))
        #expect(FileManager.default.fileExists(atPath: workerPlist.path))

        let supervisor = NSDictionary(contentsOf: supervisorPlist) as? [String: Any]
        let worker = NSDictionary(contentsOf: workerPlist) as? [String: Any]

        #expect(supervisor?["Label"] as? String == "dev.agency.CodexSupervisor")
        #expect(worker?["Label"] as? String == "dev.agency.CodexWorker")
    }

    // MARK: Helpers

    private func resourcesDirectory(file: StaticString = #filePath) throws -> URL {
        let fileURL = URL(fileURLWithPath: String(describing: file))
        let repoRoot = fileURL
            .deletingLastPathComponent() // SupervisorTests.swift
            .deletingLastPathComponent() // AgencyTests/
        return repoRoot.appendingPathComponent("Agency/Resources", isDirectory: true)
    }
}
