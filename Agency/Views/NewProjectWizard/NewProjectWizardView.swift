import SwiftUI
import AppKit

/// Main wizard container for creating a new project.
struct NewProjectWizardView: View {
    @State private var state = WizardState()
    @Environment(\.dismiss) private var dismiss

    let onProjectCreated: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader

            Divider()
                .opacity(0.5)

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 560)
        .background(DesignTokens.Colors.canvas)
    }

    // MARK: - Header

    private var wizardHeader: some View {
        HStack {
            HStack(spacing: DesignTokens.Spacing.small) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)

                Text("New Project")
                    .font(DesignTokens.Typography.headline)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(DesignTokens.Colors.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, DesignTokens.Spacing.large)
        .padding(.vertical, DesignTokens.Spacing.medium)
        .background(DesignTokens.Colors.surface.opacity(0.5))
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch state.currentStep {
        case .goalInput:
            ProjectGoalStepView(state: state)

        case .generatingRoadmap:
            if let error = state.roadmapError {
                ErrorStepView(
                    headline: "Roadmap generation failed",
                    error: error,
                    onRetry: {
                        state.roadmapError = nil
                        Task { await generateRoadmap() }
                    },
                    onBack: {
                        state.roadmapError = nil
                        state.currentStep = .goalInput
                    }
                )
            } else {
                GeneratingStepView(
                    icon: "sparkles",
                    headline: "Architecting your workflow...",
                    subtext: "Analyzing requirements, breaking down phases, and structuring initial tasks based on Markdown best practices."
                )
                .task {
                    await generateRoadmap()
                }
            }

        case .reviewRoadmap:
            RoadmapReviewStepView(state: state, onCreateProject: proceedToArchitecture)

        case .generatingArchitecture:
            if let error = state.architectureError {
                ErrorStepView(
                    headline: "Architecture generation failed",
                    error: error,
                    onRetry: {
                        state.architectureError = nil
                        Task { await generateArchitecture() }
                    },
                    onBack: {
                        state.architectureError = nil
                        state.currentStep = .reviewRoadmap
                    }
                )
            } else {
                GeneratingStepView(
                    icon: "sparkles",
                    headline: "Designing your architecture...",
                    subtext: "Analyzing components, defining patterns, and documenting the technical structure."
                )
                .task {
                    await generateArchitecture()
                }
            }

        case .reviewArchitecture:
            ArchitectureReviewStepView(state: state, onCreateProject: proceedToScaffolding, onSkip: skipArchitecture)

        case .scaffolding:
            if let error = state.scaffoldingError {
                ErrorStepView(
                    headline: "Project creation failed",
                    error: error,
                    onRetry: {
                        state.scaffoldingError = nil
                        proceedToScaffolding()
                    },
                    onBack: {
                        state.scaffoldingError = nil
                        state.currentStep = state.skipArchitecture ? .reviewRoadmap : .reviewArchitecture
                    }
                )
            } else {
                ScaffoldingStepView()
                    .task {
                        await scaffoldProject()
                    }
            }

        case .complete:
            CompletionStepView(projectURL: state.createdProjectURL) {
                if let url = state.createdProjectURL {
                    onProjectCreated(url)
                }
                dismiss()
            }
        }
    }

    // MARK: - Actions

    private func generateRoadmap() async {
        // TODO: Integrate with RoadmapGenerator in 11.3
        // For now, simulate generation
        try? await Task.sleep(for: .seconds(2))

        await MainActor.run {
            state.roadmapContent = """
            # Project: \(state.projectName)
            Owner: system
            Status: planning

            # Overview
            \(state.projectGoal)

            # Phase 1: Foundation & Setup
            - [ ] Initialize repository and project structure
            - [ ] Configure build tools and linting
            - [ ] Set up core architecture

            # Phase 2: Core Features
            - [ ] Implement primary functionality
            - [ ] Create main user interface
            - [ ] Develop data models and storage

            # Phase 3: Polish & Launch
            - [ ] Add error handling and edge cases
            - [ ] Write documentation
            - [ ] Prepare for release
            """
            state.currentStep = .reviewRoadmap
        }
    }

    private func proceedToArchitecture() {
        state.currentStep = .generatingArchitecture
    }

    private func generateArchitecture() async {
        // TODO: Integrate with ArchitectureGenerator in 11.4
        // For now, simulate generation
        try? await Task.sleep(for: .seconds(2))

        await MainActor.run {
            state.architectureContent = """
            # Architecture: \(state.projectName)

            ## Overview
            This document describes the technical architecture for \(state.projectName).

            ## Components
            - **Core Module** - Business logic and data models
            - **UI Layer** - User interface components
            - **Data Layer** - Persistence and networking

            ## Patterns
            - MVVM architecture for UI binding
            - Repository pattern for data access
            - Dependency injection for testability

            ## File Structure
            ```
            src/
            ├── models/
            ├── views/
            ├── services/
            └── utils/
            ```

            ## Dependencies
            - List key dependencies here
            """
            state.currentStep = .reviewArchitecture
        }
    }

    private func skipArchitecture() {
        state.skipArchitecture = true
        state.architectureContent = ""
        proceedToScaffolding()
    }

    private func proceedToScaffolding() {
        // Show folder picker first
        let panel = NSOpenPanel()
        panel.title = "Choose Project Location"
        panel.message = "Select where to create the '\(state.projectName)' folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        // Default to Documents or home
        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            panel.directoryURL = documentsURL
        }

        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task { @MainActor in
                    self.state.projectLocation = url
                    self.state.currentStep = .scaffolding
                }
            }
            // If canceled, stay on current step
        }
    }

    private func scaffoldProject() async {
        guard let location = state.projectLocation else {
            state.scaffoldingError = "No location selected"
            return
        }

        let scaffolder = ProjectScaffolder()

        do {
            let result = try scaffolder.scaffold(
                projectName: state.projectName,
                location: location,
                roadmapContent: state.roadmapContent,
                architectureContent: state.skipArchitecture ? nil : state.architectureContent
            )

            await MainActor.run {
                state.createdProjectURL = result.projectURL
                state.currentStep = .complete
            }
        } catch {
            await MainActor.run {
                state.scaffoldingError = error.localizedDescription
            }
        }
    }
}

// MARK: - Error Step View

struct ErrorStepView: View {
    let headline: String
    let error: String
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.large) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            VStack(spacing: DesignTokens.Spacing.small) {
                Text(headline)
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text(error)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            HStack(spacing: DesignTokens.Spacing.medium) {
                Button("Go Back") {
                    onBack()
                }
                .buttonStyle(.bordered)

                Button {
                    onRetry()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Generating Step View

struct GeneratingStepView: View {
    let icon: String
    let headline: String
    let subtext: String

    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.large) {
            ZStack {
                Circle()
                    .stroke(DesignTokens.Colors.stroke, lineWidth: 3)
                    .frame(width: 80, height: 80)

                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(rotation))

                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.green)
            }
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }

            VStack(spacing: DesignTokens.Spacing.small) {
                Text(headline)
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text(subtext)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Scaffolding Step View

struct ScaffoldingStepView: View {
    var body: some View {
        VStack(spacing: DesignTokens.Spacing.large) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.blue)

            VStack(spacing: DesignTokens.Spacing.small) {
                Text("Scaffolding project files...")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Generating .md files, creating folder structure, and initializing the board.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Completion Step View

struct CompletionStepView: View {
    let projectURL: URL?
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.large) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            VStack(spacing: DesignTokens.Spacing.small) {
                Text("Project created!")
                    .font(DesignTokens.Typography.titleLarge)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                if let url = projectURL {
                    Text(url.path)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
            }

            Button {
                onOpen()
            } label: {
                Label("Open Project", systemImage: "folder")
                    .font(DesignTokens.Typography.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    NewProjectWizardView { _ in }
}
