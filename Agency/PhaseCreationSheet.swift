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
                PhaseErrorBanner(message: error) {
                    controller.errorMessage = nil
                }
            }

            PhaseRunStatusView(runState: controller.runState)

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
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small).fill(DesignTokens.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small).stroke(DesignTokens.Colors.strokeMuted))
        }
    }
}

private struct PhaseErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
            .fill(DesignTokens.Colors.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
            .stroke(DesignTokens.Colors.stroke, lineWidth: 1))
    }
}
