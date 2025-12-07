import SwiftUI
import Observation

struct PhaseCreationSheet: View {
    @Bindable var controller: PhaseCreationController
    let snapshot: ProjectLoader.ProjectSnapshot?
    let onCancel: () -> Void
    let onComplete: (Bool) -> Void

    @FocusState private var isLabelFocused: Bool

    private var trimmedLabel: String {
        controller.form.label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        snapshot != nil && !trimmedLabel.isEmpty && !controller.isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            header
            formFields

            if let error = controller.errorMessage {
                DismissibleBanner.warning(error) {
                    controller.errorMessage = nil
                }
            }

            PhaseRunStatusView(runState: controller.runState)
            if shouldOfferMaterializationCTA {
                materializationCTA
            }

            footerButtons
        }
        .padding(DesignTokens.Spacing.large)
        .frame(minWidth: 580, minHeight: 520)
        .background(DesignTokens.Colors.canvas)
        .onAppear {
            isLabelFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
            Text("Add Phase with Agent")
                .font(DesignTokens.Typography.titleLarge)
            Text("Provide a phase label and optional task hints. The agent will scaffold the phase, write a plan artifact, and stream logs here.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
    }

    private var formFields: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                Text("Phase label")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                TextField("e.g., Agent Planning", text: $controller.form.label)
                    .textFieldStyle(.roundedBorder)
                    .focused($isLabelFocused)
                    .accessibilityLabel("Phase label")
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                Text("Starter task hints (optional)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                TextEditor(text: $controller.form.taskHints)
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        .fill(DesignTokens.Colors.card))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        .stroke(DesignTokens.Colors.strokeMuted))
                    .accessibilityLabel("Starter task hints")
            }

            Toggle("Auto-create cards from plan (when available)", isOn: $controller.form.autoCreateCards)
                .toggleStyle(.switch)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .accessibilityLabel("Auto-create cards from plan")
        }
    }

    private var footerButtons: some View {
        HStack {
            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                submit()
            } label: {
                if controller.isRunning {
                    ProgressView()
                } else {
                    Label("Start Plan Flow", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
            .accessibilityLabel("Start plan flow")
        }
    }

    private var materializationCTA: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
            Text("Create cards from plan")
                .font(DesignTokens.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Button {
                createCardsFromPlan()
            } label: {
                if controller.isMaterializingCards {
                    ProgressView()
                } else {
                    Label("Create cards from plan (\(controller.pendingPlanTasks.count) pending)", systemImage: "rectangle.stack.badge.plus")
                }
            }
            .buttonStyle(.bordered)
            .disabled(snapshot == nil || controller.pendingPlanTasks.isEmpty || controller.isMaterializingCards)
            .accessibilityLabel("Create cards from plan")
        }
        .padding(.vertical, DesignTokens.Spacing.small)
    }

    private func submit() {
        guard let snapshot else {
            controller.errorMessage = "Load a project before creating a phase."
            return
        }

        Task {
            let success = await controller.startCreation(projectSnapshot: snapshot)
            await MainActor.run {
                onComplete(success)
            }
        }
    }

    private func createCardsFromPlan() {
        guard let snapshot else {
            controller.errorMessage = "Load a project before creating cards."
            return
        }

        Task {
            await controller.createCardsFromPlan(projectSnapshot: snapshot)
        }
    }

    private var shouldOfferMaterializationCTA: Bool {
        controller.runState?.phase == .succeeded &&
        !controller.pendingPlanTasks.isEmpty &&
        !controller.isRunning
    }
}

private struct PhaseRunStatusView: View {
    let runState: PhaseCreationController.RunState?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(spacing: DesignTokens.Spacing.small) {
                Label("Plan Flow", systemImage: "bolt.horizontal")
                    .font(DesignTokens.Typography.headline)
                Spacer()
                Text(statusLabel)
                    .font(DesignTokens.Typography.caption.weight(.semibold))
                    .padding(.horizontal, DesignTokens.Spacing.small)
                    .padding(.vertical, DesignTokens.Spacing.grid)
                    .background(Capsule().fill(DesignTokens.Colors.preferredAccent(for: colorScheme).opacity(0.14)))
            }

            if let runState {
                ProgressView(value: runState.progress)
                    .tint(DesignTokens.Colors.preferredAccent(for: colorScheme))
                if let summary = runState.summary {
                    Text(summary)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
                if let result = runState.result {
                    Text(detailText(from: result))
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
                RunLogView(logs: runState.logs)
            } else {
                Text("Logs and progress will appear here after you start the plan flow.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .padding(.vertical, DesignTokens.Spacing.small)
            }
        }
        .padding()
        .surfaceStyle(DesignTokens.Surfaces.mutedPanel)
    }

    private var statusLabel: String {
        guard let phase = runState?.phase else { return "Idle" }
        return phase.rawValue.capitalized
    }

    private func detailText(from result: WorkerRunResult) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let read = formatter.string(fromByteCount: result.bytesRead)
        let written = formatter.string(fromByteCount: result.bytesWritten)

        let duration: String
        if result.duration >= 1 {
            duration = String(format: "%.1fs", result.duration)
        } else {
            duration = String(format: "%.0fms", result.duration * 1000)
        }

        return "Exit \(result.exitCode) • \(duration) • read \(read) / wrote \(written)"
    }
}

private struct RunLogView: View {
    let logs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
            Text("Logs")
                .font(DesignTokens.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 200)
            .surfacePanel(style: .standard, radius: DesignTokens.Radius.small)
        }
    }
}

// Note: PhaseErrorBanner replaced by DismissibleBanner from Components/

#if DEBUG
struct PhaseCreationSheet_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        let controller = PhaseCreationController(executor: StubPreviewExecutor(),
                                                 cardCreator: CardCreator(),
                                                 scanner: ProjectScanner())
        controller.form.label = "Preview Phase"
        controller.form.taskHints = "Add tasks for preview"
        controller.pendingPlanTasks = [
            PlanTask(title: "Wire previews",
                     acceptanceCriteria: ["Show running state", "Show success state"],
                     rationale: "Preview data")
        ]
        controller.runState = PhaseCreationController.RunState(id: UUID(),
                                                               phase: .running,
                                                               progress: 0.4,
                                                               logs: ["Queued phase creation", "Running…"],
                                                               summary: "Working",
                                                               result: nil,
                                                               startedAt: .now,
                                                               finishedAt: nil)

        let phase = try! Phase(path: URL(fileURLWithPath: "/tmp/project/phase-1-preview"))
        let snapshot = ProjectLoader.ProjectSnapshot(rootURL: URL(fileURLWithPath: "/tmp"),
                                                     phases: [PhaseSnapshot(phase: phase, cards: [])],
                                                     validationIssues: [])

        return PhaseCreationSheet(controller: controller,
                                  snapshot: snapshot,
                                  onCancel: {},
                                  onComplete: { _ in })
        .frame(width: 640, height: 520)
    }

    private final class StubPreviewExecutor: AgentExecutor {
        func run(request: WorkerRunRequest,
                 logURL: URL,
                 outputDirectory: URL,
                 emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
            await emit(.progress(0.4, message: "Previewing…"))
            await emit(.finished(WorkerRunResult(status: .succeeded,
                                                 exitCode: 0,
                                                 duration: 0.5,
                                                 bytesRead: 0,
                                                 bytesWritten: 0,
                                                 summary: "Preview done")))
        }
    }
}
#endif
