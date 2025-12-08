import SwiftUI

/// Roadmap review step with editable markdown and preview sidebar.
struct RoadmapReviewStepView: View {
    @Bindable var state: WizardState
    let onCreateProject: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            reviewHeader

            Divider()
                .opacity(0.5)

            // Content
            HStack(spacing: 0) {
                // Left: Editor
                editorPanel
                    .frame(maxWidth: .infinity)

                Divider()
                    .opacity(0.5)

                // Right: Preview & Tips
                sidebarPanel
                    .frame(width: 240)
            }
        }
    }

    // MARK: - Header

    private var reviewHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review Roadmap")
                    .font(DesignTokens.Typography.headline)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Edit the markdown plan below to refine phases and tasks.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            Spacer()

            HStack(spacing: DesignTokens.Spacing.medium) {
                Button("Back") {
                    state.goBack()
                }
                .buttonStyle(.bordered)

                Button {
                    onCreateProject()
                } label: {
                    HStack(spacing: DesignTokens.Spacing.xSmall) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Create Project")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.large)
        .padding(.vertical, DesignTokens.Spacing.medium)
    }

    // MARK: - Editor Panel

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(spacing: DesignTokens.Spacing.xSmall) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Colors.textMuted)
                Text("ROADMAP.MD")
                    .font(DesignTokens.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignTokens.Colors.textMuted)
            }
            .padding(.horizontal, DesignTokens.Spacing.medium)
            .padding(.top, DesignTokens.Spacing.medium)

            TextEditor(text: $state.roadmapContent)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(DesignTokens.Spacing.small)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        .fill(DesignTokens.Colors.surface)
                )
                .padding(.horizontal, DesignTokens.Spacing.medium)
                .padding(.bottom, DesignTokens.Spacing.medium)
        }
        .background(DesignTokens.Colors.canvas)
    }

    // MARK: - Sidebar Panel

    private var sidebarPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            // Preview Card
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                HStack(spacing: DesignTokens.Spacing.xSmall) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.blue)
                    Text("Preview")
                        .font(DesignTokens.Typography.headline)
                        .foregroundStyle(.blue)
                }

                HStack {
                    Text("Phases:")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    Spacer()
                    Text("\(state.parsedPhaseCount)")
                        .font(DesignTokens.Typography.headline.monospacedDigit())
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                }

                HStack {
                    Text("Tasks:")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    Spacer()
                    Text("\(state.parsedTaskCount)")
                        .font(DesignTokens.Typography.headline.monospacedDigit())
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                }
            }
            .padding(DesignTokens.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                    .fill(DesignTokens.Colors.surface)
            )

            // Tips Card
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Text("Tips")
                    .font(DesignTokens.Typography.headline)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                    tipRow("Use # Phase X: Name to define columns.")
                    tipRow("Use - [ ] Task Name to create cards.")
                    tipRow("The structure will be automatically parsed into the filesystem.")
                }
            }
            .padding(DesignTokens.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                    .fill(DesignTokens.Colors.surface)
            )

            Spacer()
        }
        .padding(DesignTokens.Spacing.medium)
        .background(DesignTokens.Colors.canvas.opacity(0.5))
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xSmall) {
            Text("•")
                .foregroundStyle(DesignTokens.Colors.textMuted)
            Text(text)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
    }
}

#Preview {
    let state = WizardState()
    state.roadmapContent = """
    # Project: Demo
    Owner: system
    Status: planning

    # Phase 1: Foundation
    - [ ] Initialize project
    - [ ] Set up build tools

    # Phase 2: Features
    - [ ] Build core module
    - [ ] Create UI
    """
    return RoadmapReviewStepView(state: state, onCreateProject: {})
        .frame(width: 700, height: 560)
        .background(DesignTokens.Colors.canvas)
}
