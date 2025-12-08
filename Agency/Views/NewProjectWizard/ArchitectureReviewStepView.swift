import SwiftUI

/// Architecture review step with editable markdown and preview sidebar.
struct ArchitectureReviewStepView: View {
    @Bindable var state: WizardState
    let onCreateProject: () -> Void
    let onSkip: () -> Void

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
                Text("Review Architecture")
                    .font(DesignTokens.Typography.headline)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Edit the technical design below to refine components and structure.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            Spacer()

            HStack(spacing: DesignTokens.Spacing.medium) {
                Button("Back") {
                    state.goBack()
                }
                .buttonStyle(.bordered)

                Button("Skip") {
                    onSkip()
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
                Text("ARCHITECTURE.MD")
                    .font(DesignTokens.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignTokens.Colors.textMuted)
            }
            .padding(.horizontal, DesignTokens.Spacing.medium)
            .padding(.top, DesignTokens.Spacing.medium)

            TextEditor(text: $state.architectureContent)
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
                        .foregroundStyle(.purple)
                    Text("Preview")
                        .font(DesignTokens.Typography.headline)
                        .foregroundStyle(.purple)
                }

                HStack {
                    Text("Sections:")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    Spacer()
                    Text("\(state.parsedComponentCount)")
                        .font(DesignTokens.Typography.headline.monospacedDigit())
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                }

                HStack {
                    Text("Characters:")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    Spacer()
                    Text("\(state.architectureContent.count)")
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
                    tipRow("Use ## headers for major sections.")
                    tipRow("Document key components and their responsibilities.")
                    tipRow("Architecture is optional but helps guide implementation.")
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
    state.architectureContent = """
    # Architecture: Demo

    ## Overview
    Technical architecture document.

    ## Components
    - Core module
    - UI layer

    ## Patterns
    - MVVM
    """
    return ArchitectureReviewStepView(state: state, onCreateProject: {}, onSkip: {})
        .frame(width: 700, height: 560)
        .background(DesignTokens.Colors.canvas)
}
