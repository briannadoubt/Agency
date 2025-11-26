import Foundation
import os.log
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// Encapsulates the SMAppService registration and per-run worker launch lifecycle.
@MainActor
final class WorkerLauncher {
    private enum Constants {
        static let supervisorPlist = "CodexSupervisor"
        static let workerPlist = "CodexWorker"
        static let workerBinaryName = "CodexWorker"
        static let workerLabelPrefix = "dev.agency.worker"
    }

    private let fileManager: FileManager
    private let logger = Logger(subsystem: "dev.agency.app", category: "WorkerLauncher")
    private var processes: [UUID: Process] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: Registration

    func registerSupervisorPlistIfNeeded() throws {
        try register(plistNamed: Constants.supervisorPlist)
    }

    func registerWorkerPlistIfNeeded() throws {
        try register(plistNamed: Constants.workerPlist)
    }

    private func register(plistNamed name: String) throws {
#if canImport(ServiceManagement)
        let service = SMAppService.agent(plistName: name)
        switch service.status {
        case .notRegistered:
            try service.register()
            logger.debug("Registered SMAppService plist \(name)")
        case .requiresApproval, .enabled:
            break
        case .notFound:
            throw CodexSupervisorError.registrationMissing(name)
        @unknown default:
            logger.warning("Unhandled SMAppService status for \(name)")
        }
#else
        logger.warning("ServiceManagement unavailable; unable to register \(name)")
        throw CodexSupervisorError.registrationMissing(name)
#endif
    }

    // MARK: Launching

    func launch(request: CodexRunRequest) async throws -> WorkerEndpoint {
        let endpoint = WorkerEndpoint(runID: request.runID,
                                      bootstrapName: bootstrapName(for: request.runID))

        guard let workerBinary = locateWorkerBinary() else {
            throw CodexSupervisorError.workerBinaryMissing
        }

        let payloadURL = try persistPayload(request: request)

        let process = Process()
        process.executableURL = workerBinary
        process.arguments = ["--run-id", request.runID.uuidString,
                             "--endpoint", endpoint.bootstrapName,
                             "--payload", payloadURL.path]
        process.environment = defaultEnvironment(for: request)

        do {
            try process.run()
            processes[request.runID] = process
        } catch {
            throw CodexSupervisorError.workerLaunchFailed(error.localizedDescription)
        }

        // Allow the worker to adopt the endpoint asynchronously; the app only needs the name to reconnect.
        return endpoint
    }

    func activeProcess(for runID: UUID) -> Process? {
        processes[runID]
    }

    func cancel(job: any JobHandle) async {
        if let process = processes[job.runID] {
            process.terminate()
            processes[job.runID] = nil
        }
    }

    // MARK: Helpers

    private func persistPayload(request: CodexRunRequest) throws -> URL {
        let payloadDirectory = request.logDirectory
        try fileManager.createDirectory(at: payloadDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: nil)
        let payloadURL = payloadDirectory.appendingPathComponent("worker.payload.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(request) else {
            throw CodexSupervisorError.payloadEncodingFailed
        }
        try data.write(to: payloadURL, options: .atomic)
        return payloadURL
    }

    private func defaultEnvironment(for request: CodexRunRequest) -> [String: String] {
        var environment: [String: String] = ProcessInfo.processInfo.environment
        environment["CODEX_RUN_ID"] = request.runID.uuidString
        environment["CODEX_ENDPOINT_NAME"] = bootstrapName(for: request.runID)
        environment["CODEX_LOG_DIRECTORY"] = request.logDirectory.path
        environment["CODEX_ALLOW_NETWORK"] = request.allowNetwork ? "1" : "0"
        environment["CODEX_PROJECT_BOOKMARK_BASE64"] = request.projectBookmark.base64EncodedString()
        environment["CODEX_CLI_ARGS"] = request.cliArgs.joined(separator: " ")
        return environment
    }

    private func bootstrapName(for runID: UUID) -> String {
        "\(Constants.workerLabelPrefix).\(runID.uuidString)"
    }

    private func locateWorkerBinary() -> URL? {
        let bundle = Bundle.main
        if let url = bundle.url(forAuxiliaryExecutable: Constants.workerBinaryName) {
            return url
        }

        // During development the worker binary may live alongside the main executable.
        if let executableURL = bundle.executableURL {
            let sibling = executableURL.deletingLastPathComponent().appendingPathComponent(Constants.workerBinaryName)
            if fileManager.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }

        return nil
    }
}

/// Jobs managed by the launcher conform to this protocol so cancellation remains testable without SMAppService.
protocol JobHandle {
    var runID: UUID { get }
}
