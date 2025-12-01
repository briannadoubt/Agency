import SwiftUI

/// Settings view for configuring Claude Code CLI integration.
struct ClaudeCodeSettingsView: View {
    @State private var settings = ClaudeCodeSettings.shared
    @State private var isRefreshing = false

    // API Key state
    @State private var apiKeyInput = ""
    @State private var hasStoredKey = false
    @State private var maskedKey = ""
    @State private var keyError: String?
    @State private var keySaveSuccess = false
    @State private var isTestingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?

    enum ConnectionTestResult: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section {
                statusRow
            } header: {
                Text("CLI Status")
            }

            Section {
                apiKeySection
            } header: {
                Text("API Key")
            } footer: {
                Text("Your API key is stored securely in the macOS Keychain.")
            }

            Section {
                pathOverrideField
                clearOverrideButton
            } header: {
                Text("Custom CLI Path")
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
            refreshKeyStatus()
        }
    }

    // MARK: - CLI Status

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

    // MARK: - API Key Section

    @ViewBuilder
    private var apiKeySection: some View {
        if hasStoredKey {
            storedKeyRow
        } else {
            newKeyInputRow
        }

        if let error = keyError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }

        if keySaveSuccess {
            Text("API key saved successfully.")
                .font(.caption)
                .foregroundStyle(.green)
        }

        if let result = connectionTestResult {
            connectionTestResultRow(result)
        }

        testConnectionButton
    }

    @ViewBuilder
    private var storedKeyRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("API Key")
                    .font(.subheadline)
                Text(maskedKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer()
            Button("Remove") {
                removeKey()
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    @ViewBuilder
    private var newKeyInputRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Enter API Key (sk-ant-...)", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .onChange(of: apiKeyInput) { _, _ in
                    keyError = nil
                    keySaveSuccess = false
                    connectionTestResult = nil
                }

            HStack {
                Button("Save Key") {
                    saveKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyInput.isEmpty)

                if !ClaudeKeyManager.validateFormat(apiKeyInput) && !apiKeyInput.isEmpty {
                    Text("Key should start with 'sk-ant-'")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var testConnectionButton: some View {
        HStack {
            Button {
                testConnection()
            } label: {
                if isTestingConnection {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Test Connection")
                }
            }
            .buttonStyle(.bordered)
            .disabled(!hasStoredKey || !settings.status.isAvailable || isTestingConnection)

            if !hasStoredKey {
                Text("Save an API key first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !settings.status.isAvailable {
                Text("CLI not available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func connectionTestResultRow(_ result: ConnectionTestResult) -> some View {
        HStack {
            switch result {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connection successful")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failure(let message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Path Override

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

    // MARK: - Installation Instructions

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

    // MARK: - Actions

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

    private func refreshKeyStatus() {
        hasStoredKey = ClaudeKeyManager.exists()
        if hasStoredKey, let key = try? ClaudeKeyManager.retrieve() {
            maskedKey = ClaudeKeyManager.masked(key)
        } else {
            maskedKey = ""
        }
    }

    private func saveKey() {
        keyError = nil
        keySaveSuccess = false
        connectionTestResult = nil

        do {
            try ClaudeKeyManager.save(key: apiKeyInput)
            keySaveSuccess = true
            apiKeyInput = ""
            refreshKeyStatus()
        } catch let error as ClaudeKeyManager.KeyError {
            keyError = error.localizedDescription
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeKey() {
        keyError = nil
        keySaveSuccess = false
        connectionTestResult = nil

        do {
            try ClaudeKeyManager.delete()
            refreshKeyStatus()
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func testConnection() {
        guard let cliPath = settings.status.path else { return }

        isTestingConnection = true
        connectionTestResult = nil

        Task {
            let result = await performConnectionTest(cliPath: cliPath)
            await MainActor.run {
                connectionTestResult = result
                isTestingConnection = false
            }
        }
    }

    private func performConnectionTest(cliPath: String) async -> ConnectionTestResult {
        guard let environment = ClaudeKeyManager.environmentWithKey() else {
            return .failure("No API key available")
        }

        let runner = ProcessRunner()
        // Use a longer timeout for connection test (60 seconds) since Claude needs time to respond
        let output = await runner.run(
            command: cliPath,
            arguments: ["-p", "Say 'Connection successful' and nothing else", "--max-turns", "1"],
            environment: environment,
            timeout: 60
        )

        if output.exitCode == 0 {
            return .success
        } else {
            let errorMessage = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if errorMessage.isEmpty {
                return .failure("CLI exited with code \(output.exitCode)")
            }
            return .failure(errorMessage.prefix(100).description)
        }
    }
}

#Preview {
    ClaudeCodeSettingsView()
        .frame(width: 500, height: 600)
}
