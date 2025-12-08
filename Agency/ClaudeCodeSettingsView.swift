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

    // Bookmark state
    @State private var hasBookmark = false
    @State private var bookmarkPath: String?
    @State private var bookmarkError: String?
    @State private var showBookmarkError = false

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
                cliSelectionSection
            } header: {
                Text("CLI Location")
            } footer: {
                if hasBookmark {
                    Text("Using saved CLI location. This persists across app launches.")
                } else {
                    Text("Select the Claude CLI executable to use. Required for sandboxed App Store apps.")
                }
            }

            Section {
                installInstructionsRow
            } header: {
                Text("Installation")
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshBookmarkStatus()
            await settings.refreshStatus()
            refreshKeyStatus()
        }
        .alert("Bookmark Error", isPresented: $showBookmarkError) {
            Button("OK") { }
        } message: {
            Text(bookmarkError ?? "Unknown error saving bookmark")
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
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Refresh") {
                    Task {
                        isRefreshing = true
                        await refreshBookmarkStatus()
                        await settings.refreshStatus()
                        isRefreshing = false
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusMessage: String {
        switch settings.status {
        case .notFound where !hasBookmark:
            return "Select the Claude CLI below to grant access. Sandboxed apps require manual selection."
        default:
            return settings.status.displayMessage
        }
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

    // MARK: - CLI Selection

    @ViewBuilder
    private var cliSelectionSection: some View {
        if hasBookmark, let path = bookmarkPath {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected CLI")
                        .font(.subheadline)
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Change...") {
                    selectFilePath()
                }
                .buttonStyle(.bordered)
                Button {
                    clearBookmark()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack {
                Text("No CLI selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select Claude CLI...") {
                    selectFilePath()
                }
                .buttonStyle(.borderedProminent)
            }
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
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the folder containing the Claude CLI (e.g., /opt/homebrew/bin)"
        panel.prompt = "Select Folder"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")

        if panel.runModal() == .OK, let folderURL = panel.url {
            // Check if claude exists in this folder
            let claudeURL = folderURL.appendingPathComponent("claude")
            guard FileManager.default.fileExists(atPath: claudeURL.path) else {
                bookmarkError = "No 'claude' executable found in the selected folder"
                showBookmarkError = true
                return
            }

            // In sandboxed apps, we must access the security-scoped resource
            // before creating a bookmark - do this synchronously
            let didStartAccessing = folderURL.startAccessingSecurityScopedResource()

            do {
                // Create bookmark for the folder (not the symlink)
                let bookmarkData = try folderURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )

                // Now save it async, but store the claude path
                Task {
                    await saveBookmarkData(bookmarkData, for: claudeURL, folder: folderURL)
                }
            } catch {
                bookmarkError = error.localizedDescription
                showBookmarkError = true
            }

            if didStartAccessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
    }

    private func saveBookmarkData(_ data: Data, for cliURL: URL, folder folderURL: URL) async {
        do {
            try await CLIBookmarkStore.shared.saveBookmarkData(data, cliPath: cliURL.path, folderURL: folderURL)
            await refreshBookmarkStatus()
            await settings.refreshStatus()
        } catch {
            await MainActor.run {
                bookmarkError = error.localizedDescription
                showBookmarkError = true
            }
        }
    }

    private func refreshBookmarkStatus() async {
        hasBookmark = await CLIBookmarkStore.shared.hasBookmark
        if hasBookmark {
            bookmarkPath = await CLIBookmarkStore.shared.getCLIPath()
        } else {
            bookmarkPath = nil
        }
    }

    private func clearBookmark() {
        Task {
            await CLIBookmarkStore.shared.clearBookmark()
            await refreshBookmarkStatus()
            await settings.refreshStatus()
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

        // Check if CLI was found via bookmark
        let isBookmark: Bool
        if case .available(_, _, let source) = settings.status {
            isBookmark = source == .bookmark
        } else {
            isBookmark = false
        }

        isTestingConnection = true
        connectionTestResult = nil

        Task {
            let result = await performConnectionTest(cliPath: cliPath)
            // Stop accessing bookmark after test completes
            if isBookmark {
                await CLIBookmarkStore.shared.stopAccessing()
            }
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
            timeout: .seconds(60)
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
