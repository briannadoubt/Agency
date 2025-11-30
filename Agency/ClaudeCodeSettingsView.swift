import SwiftUI

/// Settings view for configuring Claude Code CLI integration.
struct ClaudeCodeSettingsView: View {
    @State private var settings = ClaudeCodeSettings.shared
    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section {
                statusRow
            } header: {
                Text("CLI Status")
            }

            Section {
                pathOverrideField
                clearOverrideButton
            } header: {
                Text("Custom Path")
            } footer: {
                Text("Leave empty to auto-detect. Common locations: /usr/local/bin/claude, ~/.local/bin/claude")
            }

            Section {
                installInstructionsRow
            } header: {
                Text("Installation")
            }
        }
        .formStyle(.grouped)
        .task {
            await settings.refreshStatus()
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                Text(settings.status.displayMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Refresh") {
                    Task {
                        isRefreshing = true
                        await settings.refreshStatus()
                        isRefreshing = false
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch settings.status {
        case .checking:
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notFound:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var statusTitle: String {
        switch settings.status {
        case .checking:
            return "Checking..."
        case .available:
            return "Available"
        case .notFound:
            return "Not Found"
        case .error:
            return "Error"
        }
    }

    @ViewBuilder
    private var pathOverrideField: some View {
        HStack {
            TextField("Custom CLI Path", text: $settings.cliPathOverride)
                .textFieldStyle(.roundedBorder)
            Button {
                selectFilePath()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var clearOverrideButton: some View {
        if !settings.cliPathOverride.isEmpty {
            Button("Clear Override") {
                Task {
                    await settings.clearOverride()
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var installInstructionsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("To install Claude Code CLI:")
                .font(.subheadline)
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 4) {
                instructionStep(1, "Install Node.js if not already installed")
                instructionStep(2, "Run: npm install -g @anthropic-ai/claude-code")
                instructionStep(3, "Verify: claude --version")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Open Installation Docs") {
                if let url = URL(string: "https://docs.anthropic.com/en/docs/claude-code") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func instructionStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
            Text(text)
        }
    }

    private func selectFilePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the Claude CLI executable"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            settings.cliPathOverride = url.path
        }
    }
}

#Preview {
    ClaudeCodeSettingsView()
        .frame(width: 500, height: 400)
}
