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
        let supervisorPlist = resourcesRoot.appendingPathComponent("AgentSupervisor.plist")
        let workerPlist = resourcesRoot.appendingPathComponent("AgentWorker.plist")

        #expect(FileManager.default.fileExists(atPath: supervisorPlist.path))
        #expect(FileManager.default.fileExists(atPath: workerPlist.path))

        let supervisor = NSDictionary(contentsOf: supervisorPlist) as? [String: Any]
        let worker = NSDictionary(contentsOf: workerPlist) as? [String: Any]

        #expect(supervisor?["Label"] as? String == "dev.agency.AgentSupervisor")
        #expect(worker?["Label"] as? String == "dev.agency.AgentWorker")
    }

    @Test func entitlementsContainRequiredCapabilities() throws {
        let resourcesRoot = try resourcesDirectory()
        let supervisor = resourcesRoot.appendingPathComponent("AgentSupervisor.entitlements")
        let worker = resourcesRoot.appendingPathComponent("AgentWorker.entitlements")

        for entitlementURL in [supervisor, worker] {
            let entitlements = NSDictionary(contentsOf: entitlementURL) as? [String: Any]
            #expect(entitlements?["com.apple.security.app-sandbox"] as? Bool == true)
            #expect(entitlements?["com.apple.security.files.bookmarks.app-scope"] as? Bool == true)
            #expect(entitlements?["com.apple.security.files.user-selected.read-write"] as? Bool == true)
            #expect(entitlements?["com.apple.security.network.client"] as? Bool == true)
        }
    }

    @Test func supervisorEnforcesCapabilitiesBeforeRegistering() async {
        let launcher = StubWorkerLauncher()
        let checklist = CapabilityChecklist { _ in false } // everything missing
        let supervisor = AgentSupervisor(launcher: launcher,
                                         backoffPolicy: WorkerBackoffPolicy(),
                                         capabilityChecklist: checklist)

        do {
            try supervisor.registerIfNeeded()
            #expect(false)
        } catch let error as AgentSupervisorError {
            if case .capabilitiesMissing(let missing) = error {
                #expect(!missing.isEmpty)
            } else {
                #expect(false)
            }
        } catch {
            #expect(false)
        }

        #expect(launcher.registerSupervisorCalls == 0)
        #expect(launcher.registerWorkerCalls == 0)
    }

    @Test func supervisorCachesEndpointsAndSupportsReconnectAndCancel() async throws {
        let runID = UUID()
        let request = WorkerRunRequest(runID: runID,
                                      flow: "test",
                                      cardRelativePath: "project/phase/card.md",
                                      projectBookmark: Data([0x01]),
                                      logDirectory: URL(fileURLWithPath: "/tmp/run-\(runID)"),
                                      outputDirectory: URL(fileURLWithPath: "/tmp/run-\(runID)"),
                                      allowNetwork: false,
                                      cliArgs: [])

        let expectedEndpoint = WorkerEndpoint(runID: runID,
                                              bootstrapName: "dev.agency.worker.\(runID.uuidString)")
        let launcher = StubWorkerLauncher { _ in expectedEndpoint }
        let supervisor = AgentSupervisor(launcher: launcher,
                                         backoffPolicy: WorkerBackoffPolicy(baseDelay: .seconds(1)),
                                         capabilityChecklist: CapabilityChecklist { _ in true })

        let endpoint = try await supervisor.launchWorker(request: request)
        #expect(endpoint == expectedEndpoint)
        #expect(supervisor.reconnect(to: runID) == expectedEndpoint)
        #expect(launcher.registerSupervisorCalls == 1)
        #expect(launcher.registerWorkerCalls == 1)

        await supervisor.cancelWorker(id: runID)
        #expect(launcher.canceledIDs.contains(runID))
        #expect(supervisor.reconnect(to: runID) == nil)
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

@MainActor
private final class StubWorkerLauncher: WorkerLaunching {
    var registerSupervisorCalls = 0
    var registerWorkerCalls = 0
    var canceledIDs: [UUID] = []
    private let endpointForRun: (UUID) -> WorkerEndpoint

    init(endpointForRun: ((UUID) -> WorkerEndpoint)? = nil) {
        if let endpointForRun {
            self.endpointForRun = endpointForRun
        } else {
            self.endpointForRun = { runID in
                WorkerEndpoint(runID: runID,
                               bootstrapName: "dev.agency.worker.\(runID.uuidString)")
            }
        }
    }

    func registerSupervisorPlistIfNeeded() throws {
        registerSupervisorCalls += 1
    }

    func registerWorkerPlistIfNeeded() throws {
        registerWorkerCalls += 1
    }

    func launch(request: WorkerRunRequest) async throws -> WorkerEndpoint {
        endpointForRun(request.runID)
    }

    func activeProcess(for runID: UUID) -> Process? {
        nil
    }

    func cancel(job: any JobHandle) async {
        canceledIDs.append(job.runID)
    }
}
