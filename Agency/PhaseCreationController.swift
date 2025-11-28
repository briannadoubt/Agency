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
    var pendingPlanTasks: [PlanTask] = []
    var lastPlanPath: URL?
    var lastPhaseURL: URL?
    var lastPlanTasks: [PlanTask] = []
    var isMaterializingCards: Bool = false

    private let executor: any AgentExecutor
    private let fileManager: FileManager
    private let cardCreator: CardCreator
    private let scanner: ProjectScanner

    init(executor: any AgentExecutor = CLIPhaseExecutor(),
         fileManager: FileManager = .default,
         cardCreator: CardCreator = CardCreator(),
         scanner: ProjectScanner = ProjectScanner()) {
        self.executor = executor
        self.fileManager = fileManager
        self.cardCreator = cardCreator
        self.scanner = scanner
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
        pendingPlanTasks = []
        lastPlanPath = nil
        lastPhaseURL = nil
        lastPlanTasks = []

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
                refreshPlanContext(projectSnapshot: projectSnapshot, label: trimmedLabel)
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

    func createCardsFromPlan(projectSnapshot: ProjectLoader.ProjectSnapshot) async {
        guard !isRunning, !isMaterializingCards else { return }
        guard let phaseURL = lastPhaseURL else {
            errorMessage = "No phase plan available to materialize."
            return
        }
        guard !pendingPlanTasks.isEmpty else {
            errorMessage = "All plan tasks already have cards."
            return
        }

        isMaterializingCards = true
        defer { isMaterializingCards = false }

        do {
            let snapshots = try scanner.scan(rootURL: projectSnapshot.rootURL)
            guard let phaseSnapshot = snapshots.first(where: { $0.phase.path.standardizedFileURL == phaseURL.standardizedFileURL }) else {
                errorMessage = "Phase directory not found on disk."
                return
            }

            var workingSnapshot = phaseSnapshot
            var createdTitles: [String] = []
            var skippedTitles: [String] = []

            for task in pendingPlanTasks {
                do {
                    let card = try await cardCreator.createCard(in: workingSnapshot,
                                                                title: task.title,
                                                                acceptanceCriteria: task.acceptanceCriteria,
                                                                notes: task.rationale,
                                                                includeHistoryEntry: true)
                    workingSnapshot = PhaseSnapshot(phase: workingSnapshot.phase,
                                                    cards: workingSnapshot.cards + [card])
                    createdTitles.append(task.title)
                } catch let error as CardCreationError {
                    if case .duplicateFilename = error {
                        skippedTitles.append(task.title)
                        continue
                    }
                    throw error
                }
            }

            pendingPlanTasks = try pendingTasks(from: lastPlanTasks,
                                                projectRoot: projectSnapshot.rootURL,
                                                phaseURL: phaseURL)

            if var state = runState {
                state.logs.append("Created \(createdTitles.count) cards from plan via UI.")
                if !skippedTitles.isEmpty {
                    state.logs.append("Skipped \(skippedTitles.count) tasks due to duplicates.")
                }
                runState = state
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshPlanContext(projectSnapshot: ProjectLoader.ProjectSnapshot, label: String) {
        guard let planURL = locatePlanArtifact(projectRoot: projectSnapshot.rootURL, label: label) else { return }
        lastPlanPath = planURL
        lastPhaseURL = planURL.deletingLastPathComponent().deletingLastPathComponent()

        do {
            let artifact = try PlanArtifact.load(from: planURL)
            lastPlanTasks = artifact.tasks
            pendingPlanTasks = try pendingTasks(from: artifact.tasks,
                                                projectRoot: projectSnapshot.rootURL,
                                                phaseURL: lastPhaseURL)

            if var state = runState {
                state.logs.append("Plan contains \(artifact.tasks.count) task(s); \(pendingPlanTasks.count) without cards.")
                runState = state
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func locatePlanArtifact(projectRoot: URL, label: String) -> URL? {
        let projectURL = projectRoot.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let targetSlug = slug(from: label)
        guard let contents = try? fileManager.contentsOfDirectory(at: projectURL,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles]) else { return nil }

        let candidates = contents.compactMap { url -> (Phase, URL)? in
            guard let phase = try? Phase(path: url), url.lastPathComponent.hasSuffix(targetSlug) else { return nil }
            return (phase, url)
        }.sorted { lhs, rhs in lhs.0.number < rhs.0.number }

        for (phase, url) in candidates.reversed() {
            let planURL = url
                .appendingPathComponent(CardStatus.backlog.folderName, isDirectory: true)
                .appendingPathComponent("\(phase.number).0-phase-plan.md")
            if fileManager.fileExists(atPath: planURL.path) {
                return planURL
            }
        }

        return nil
    }

    private func pendingTasks(from tasks: [PlanTask],
                              projectRoot: URL,
                              phaseURL: URL?) throws -> [PlanTask] {
        guard let phaseURL else { return tasks }
        let snapshots = try scanner.scan(rootURL: projectRoot)
        let phaseSnapshot = snapshots.first { $0.phase.path.standardizedFileURL == phaseURL.standardizedFileURL }
        let existingSlugs: Set<String> = Set(phaseSnapshot?.cards.map(\.slug) ?? [])

        return tasks.filter { !existingSlugs.contains(slug(from: $0.title)) }
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

        if autoCreateCards {
            args.append("--auto-create-cards")
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
