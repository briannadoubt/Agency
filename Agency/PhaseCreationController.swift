import Foundation
import Observation

@MainActor
@Observable
final class PhaseCreationController {
    struct Form {
        var label: String = ""
        var taskHints: String = ""
        var autoCreateCards: Bool = false
    }

    struct RunState: Identifiable {
        let id: UUID
        var phase: AgentRunPhase
        var progress: Double
        var logs: [String]
        var summary: String?
        var result: WorkerRunResult?
        var startedAt: Date
        var finishedAt: Date?
    }

    var form = Form()
    var runState: RunState?
    var errorMessage: String?

    private let executor: any AgentExecutor
    private let fileManager: FileManager

    init(executor: any AgentExecutor = CLIPhaseExecutor(),
         fileManager: FileManager = .default) {
        self.executor = executor
        self.fileManager = fileManager
    }

    var isRunning: Bool {
        guard let runState else { return false }
        return runState.phase == .queued || runState.phase == .running
    }

    func resetForm(keepAutoCreate: Bool = true) {
        let keepAuto = keepAutoCreate ? form.autoCreateCards : false
        form = Form(autoCreateCards: keepAuto)
    }

    func startCreation(projectSnapshot: ProjectLoader.ProjectSnapshot) async -> Bool {
        let trimmedLabel = form.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            errorMessage = "Phase label is required."
            return false
        }

        guard !isRunning else { return false }
        errorMessage = nil

        let hints = form.taskHints.trimmingCharacters(in: .whitespacesAndNewlines)
        let runID = UUID()
        let logDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("phase-creation-runs", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)

        let bookmarkData: Data
        do {
            bookmarkData = try bookmark(for: projectSnapshot.rootURL)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        let args = cliArguments(label: trimmedLabel,
                                taskHints: hints,
                                autoCreateCards: form.autoCreateCards,
                                projectRoot: projectSnapshot.rootURL)
        let request = CodexRunRequest(runID: runID,
                                      flow: AgentFlow.plan.rawValue,
                                      cardRelativePath: "phase-creation/\(slug(from: trimmedLabel))",
                                      projectBookmark: bookmarkData,
                                      logDirectory: logDirectory,
                                      outputDirectory: logDirectory,
                                      allowNetwork: false,
                                      cliArgs: args)

        do {
            let directories = try RunDirectories.prepare(for: request, fileManager: fileManager)
            let logURL = directories.logDirectory.appendingPathComponent("worker.log")

            runState = RunState(id: runID,
                                phase: .queued,
                                progress: 0.0,
                                logs: ["Queued phase creation for \"\(trimmedLabel)\""],
                                summary: nil,
                                result: nil,
                                startedAt: .now,
                                finishedAt: nil)

            await executor.run(request: request,
                               logURL: logURL,
                               outputDirectory: directories.outputDirectory) { [weak self] event in
                await self?.handle(event: event, runID: runID)
            }

            let phase = runState?.phase
            if phase == .succeeded {
                resetForm()
                return true
            } else if phase == .failed {
                if let summary = runState?.summary, !summary.isEmpty {
                    errorMessage = summary
                } else {
                    errorMessage = "Phase creation failed."
                }
            }

            return false
        } catch {
            errorMessage = error.localizedDescription
            runState = nil
            return false
        }
    }

    // MARK: - Internals

    private func handle(event: WorkerLogEvent, runID: UUID) {
        guard var state = runState, state.id == runID else { return }

        switch event {
        case .log(let line):
            if state.phase == .queued {
                state.phase = .running
            }
            state.logs.append(line)
        case .progress(let percent, let message):
            if state.phase == .queued {
                state.phase = .running
            }
            state.progress = max(state.progress, percent)
            if let message {
                state.logs.append(message)
            }
        case .finished(let result):
            state.result = result
            state.summary = result.summary
            state.progress = result.status == .succeeded ? 1.0 : state.progress
            state.phase = {
                switch result.status {
                case .succeeded: return .succeeded
                case .failed: return .failed
                case .canceled: return .canceled
                }
            }()
            state.finishedAt = .now
        }

        runState = state
    }

    private func bookmark(for url: URL) throws -> Data {
        try url.standardizedFileURL.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
    }

    private func cliArguments(label: String,
                              taskHints: String,
                              autoCreateCards: Bool,
                              projectRoot: URL) -> [String] {
        var args: [String] = [
            "--project-root", projectRoot.path,
            "--label", label,
            "--seed-plan"
        ]

        if !taskHints.isEmpty {
            args.append(contentsOf: ["--task-hints", taskHints])
        }

        args.append(contentsOf: ["--proposed-task", "Requested via UI plan flow"])

        if autoCreateCards {
            args.append(contentsOf: ["--proposed-task", "Auto-create cards from plan (requested)"])
        }

        return args
    }

    private func slug(from label: String) -> String {
        let lowered = label.lowercased()
        let replaced = lowered.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }

        var slug = String(replaced)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }

        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "phase" : slug
    }
}
