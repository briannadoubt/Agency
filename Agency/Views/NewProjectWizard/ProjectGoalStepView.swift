import SwiftUI

/// First wizard step: project name and goal input.
struct ProjectGoalStepView: View {
    @Bindable var state: WizardState
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case goal
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.large) {
            Spacer()

            // Header
            VStack(spacing: DesignTokens.Spacing.small) {
                Text("Let's build something new.")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Describe your vision, and we'll structure the roadmap.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            // Form
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                // Project Name
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                    Text("Project Name")
                        .font(DesignTokens.Typography.headline)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)

                    TextField("e.g., Quantum Analytics Dashboard", text: $state.projectName)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.body)
                        .padding(DesignTokens.Spacing.medium)
                        .background(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                                .fill(DesignTokens.Colors.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                                .stroke(
                                    focusedField == .name ? .green : DesignTokens.Colors.stroke,
                                    lineWidth: focusedField == .name ? 2 : 1
                                )
                        )
                        .focused($focusedField, equals: .name)
                }

                // Project Goal & Scope
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                    Text("Project Goal & Scope")
                        .font(DesignTokens.Typography.headline)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)

                    ZStack(alignment: .topLeading) {
                        if state.projectGoal.isEmpty {
                            Text("Describe the core features, tech stack, and goals...")
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(DesignTokens.Colors.textMuted)
                                .padding(.horizontal, DesignTokens.Spacing.medium)
                                .padding(.vertical, DesignTokens.Spacing.medium + 2)
                        }

                        TextEditor(text: $state.projectGoal)
                            .font(DesignTokens.Typography.body)
                            .scrollContentBackground(.hidden)
                            .padding(DesignTokens.Spacing.small)
                            .focused($focusedField, equals: .goal)
                    }
                    .frame(height: 160)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                            .fill(DesignTokens.Colors.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                            .stroke(
                                focusedField == .goal ? .green : DesignTokens.Colors.stroke,
                                lineWidth: focusedField == .goal ? 2 : 1
                            )
                    )
                }
            }
            .frame(maxWidth: 560)

            Spacer()

            // Action Button
            HStack {
                Spacer()

                Button {
                    state.currentStep = .generatingRoadmap
                } label: {
                    HStack(spacing: DesignTokens.Spacing.xSmall) {
                        Text("Generate Roadmap")
                            .font(DesignTokens.Typography.headline)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, DesignTokens.Spacing.large)
                    .padding(.vertical, DesignTokens.Spacing.medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                        .fill(state.canProceedFromGoal ? Color.green.opacity(0.85) : Color.green.opacity(0.4))
                )
                .disabled(!state.canProceedFromGoal)
            }
            .padding(.horizontal, DesignTokens.Spacing.large)
            .padding(.bottom, DesignTokens.Spacing.large)
        }
        .padding(.horizontal, DesignTokens.Spacing.xLarge)
        .onAppear {
            focusedField = .name
        }
    }
}

#Preview {
    ProjectGoalStepView(state: WizardState())
        .frame(width: 700, height: 560)
        .background(DesignTokens.Colors.canvas)
}
