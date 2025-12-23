import SwiftUI

/// Settings view for configuring HTTP-based model providers.
struct HTTPProviderSettingsView: View {
    @State private var registry = ProviderRegistry.shared
    @State private var isRefreshing = false
    @State private var showAddProvider = false

    // Ollama-specific state
    @State private var ollamaEndpoint = OllamaProvider.defaultBaseURL.absoluteString
    @State private var ollamaModel = OllamaProvider.defaultModel
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var ollamaStatus: ProviderStatus = .checking

    // Custom provider state
    @State private var customProviders: [CustomProviderConfig] = []

    // Default provider per flow type
    @State private var defaultProviderForImplement: String = "claude-code"
    @State private var defaultProviderForReview: String = "claude-code"
    @State private var defaultProviderForResearch: String = "claude-code"
    @State private var defaultProviderForPlan: String = "claude-code"

    enum ProviderStatus: Equatable {
        case checking
        case available(version: String?)
        case unavailable(String)
    }

    var body: some View {
        Form {
            ollamaSection

            customProvidersSection

            defaultProviderSection

            providerSummarySection
        }
        .formStyle(.grouped)
        .task {
            await checkOllamaStatus()
            await loadCustomProviders()
            loadDefaultProviderPreferences()
        }
        .sheet(isPresented: $showAddProvider) {
            AddCustomProviderSheet(
                isPresented: $showAddProvider,
                onSave: { config in
                    customProviders.append(config)
                    saveCustomProviders()
                    registerCustomProvider(config)
                }
            )
        }
    }

    // MARK: - Ollama Section

    @ViewBuilder
    private var ollamaSection: some View {
        Section {
            ollamaStatusRow
            ollamaEndpointField
            ollamaModelPicker
        } header: {
            HStack {
                Text("Ollama (Local Models)")
                Spacer()
                if ollamaStatus == .checking || isLoadingModels {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } footer: {
            Text("Ollama runs LLMs locally on your machine. Install from ollama.ai")
        }
    }

    @ViewBuilder
    private var ollamaStatusRow: some View {
        HStack {
            statusIcon(for: ollamaStatus)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle(for: ollamaStatus))
                    .font(.headline)
                Text(statusMessage(for: ollamaStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") {
                Task { await checkOllamaStatus() }
            }
            .buttonStyle(.bordered)
            .disabled(ollamaStatus == .checking)
        }
    }

    @ViewBuilder
    private var ollamaEndpointField: some View {
        HStack {
            TextField("Endpoint URL", text: $ollamaEndpoint)
                .textFieldStyle(.roundedBorder)
            Button("Reset") {
                ollamaEndpoint = OllamaProvider.defaultBaseURL.absoluteString
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var ollamaModelPicker: some View {
        HStack {
            if availableModels.isEmpty {
                TextField("Model", text: $ollamaModel)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("Model", selection: $ollamaModel) {
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
            }
            Button("Load Models") {
                Task { await loadOllamaModels() }
            }
            .buttonStyle(.bordered)
            .disabled(ollamaStatus != .available(version: nil) && !case_available(ollamaStatus))
        }
    }

    private func case_available(_ status: ProviderStatus) -> Bool {
        if case .available = status { return true }
        return false
    }

    // MARK: - Custom Providers Section

    @ViewBuilder
    private var customProvidersSection: some View {
        Section {
            if customProviders.isEmpty {
                Text("No custom providers configured")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(customProviders) { config in
                    customProviderRow(config)
                }
                .onDelete { indices in
                    for index in indices {
                        let config = customProviders[index]
                        unregisterCustomProvider(config)
                    }
                    customProviders.remove(atOffsets: indices)
                    saveCustomProviders()
                }
            }

            Button {
                showAddProvider = true
            } label: {
                Label("Add Provider", systemImage: "plus")
            }
        } header: {
            Text("Custom OpenAI-Compatible Endpoints")
        } footer: {
            Text("Add endpoints for vLLM, llama.cpp, LM Studio, LocalAI, or other OpenAI-compatible servers.")
        }
    }

    @ViewBuilder
    private func customProviderRow(_ config: CustomProviderConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.headline)
                Text(config.endpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Model: \(config.model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if config.requiresApiKey {
                Image(systemName: HTTPKeyManager.exists(for: config.identifier) ? "key.fill" : "key")
                    .foregroundStyle(HTTPKeyManager.exists(for: config.identifier) ? .green : .orange)
            }
        }
    }

    // MARK: - Default Provider Section

    @ViewBuilder
    private var defaultProviderSection: some View {
        Section {
            defaultProviderPicker(
                title: "Implement",
                selection: $defaultProviderForImplement,
                flow: .implement
            )
            defaultProviderPicker(
                title: "Review",
                selection: $defaultProviderForReview,
                flow: .review
            )
            defaultProviderPicker(
                title: "Research",
                selection: $defaultProviderForResearch,
                flow: .research
            )
            defaultProviderPicker(
                title: "Plan",
                selection: $defaultProviderForPlan,
                flow: .plan
            )
        } header: {
            Text("Default Provider per Flow Type")
        } footer: {
            Text("Select which provider to use by default for each agent flow type.")
        }
    }

    @ViewBuilder
    private func defaultProviderPicker(
        title: String,
        selection: Binding<String>,
        flow: AgentFlow
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Claude Code (CLI)").tag("claude-code")

            if case_available(ollamaStatus) {
                Text("Ollama").tag("ollama")
            }

            ForEach(customProviders) { config in
                Text(config.name).tag(config.identifier)
            }
        }
        .pickerStyle(.menu)
        .onChange(of: selection.wrappedValue) { _, _ in
            saveDefaultProviderPreferences()
        }
    }

    // MARK: - Provider Summary Section

    @ViewBuilder
    private var providerSummarySection: some View {
        Section {
            ForEach(registry.providerSummaries.filter { $0.type == .http }, id: \.id) { summary in
                HStack {
                    Image(systemName: summary.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(summary.isAvailable ? .green : .red)
                    VStack(alignment: .leading) {
                        Text(summary.displayName)
                            .font(.headline)
                        if let endpoint = summary.endpoint {
                            Text(endpoint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let version = summary.version {
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Registered HTTP Providers")
        }
    }

    // MARK: - Status Helpers

    @ViewBuilder
    private func statusIcon(for status: ProviderStatus) -> some View {
        switch status {
        case .checking:
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unavailable:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func statusTitle(for status: ProviderStatus) -> String {
        switch status {
        case .checking: return "Checking..."
        case .available: return "Available"
        case .unavailable: return "Not Available"
        }
    }

    private func statusMessage(for status: ProviderStatus) -> String {
        switch status {
        case .checking: return "Checking Ollama status..."
        case .available(let version):
            if let v = version { return "Version \(v)" }
            return "Connected"
        case .unavailable(let message): return message
        }
    }

    // MARK: - Actions

    private func checkOllamaStatus() async {
        ollamaStatus = .checking

        guard let url = URL(string: ollamaEndpoint) else {
            ollamaStatus = .unavailable("Invalid URL")
            return
        }

        let provider = OllamaProvider(baseURL: url, model: ollamaModel)
        let result = await provider.checkHealth()

        switch result {
        case .success(let status):
            if status.isHealthy {
                ollamaStatus = .available(version: status.version)
                // Register the provider
                await MainActor.run {
                    registry.register(provider)
                }
                // Load models after successful connection
                await loadOllamaModels()
            } else {
                ollamaStatus = .unavailable(status.message ?? "Unknown error")
            }
        case .failure(let error):
            ollamaStatus = .unavailable(error.localizedDescription)
        }
    }

    private func loadOllamaModels() async {
        guard let url = URL(string: ollamaEndpoint) else { return }

        isLoadingModels = true
        let provider = OllamaProvider(baseURL: url, model: ollamaModel)
        let models = await provider.listModels()

        await MainActor.run {
            availableModels = models ?? []
            isLoadingModels = false
            if let first = models?.first, !models!.contains(ollamaModel) {
                ollamaModel = first
            }
        }
    }

    private func loadCustomProviders() async {
        // Load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: "HTTPCustomProviders"),
           let configs = try? JSONDecoder().decode([CustomProviderConfig].self, from: data) {
            await MainActor.run {
                customProviders = configs
                for config in configs {
                    registerCustomProvider(config)
                }
            }
        }
    }

    private func saveCustomProviders() {
        if let data = try? JSONEncoder().encode(customProviders) {
            UserDefaults.standard.set(data, forKey: "HTTPCustomProviders")
        }
    }

    private func registerCustomProvider(_ config: CustomProviderConfig) {
        guard let url = URL(string: config.endpoint) else { return }

        let auth: HTTPProviderAuth
        if config.requiresApiKey {
            auth = .bearer(keychain: config.identifier)
        } else {
            auth = .none
        }

        let endpoint = HTTPProviderEndpoint(
            baseURL: url,
            model: config.model,
            auth: auth
        )

        let provider = OpenAICompatibleProvider(
            identifier: config.identifier,
            displayName: config.name,
            endpoint: endpoint
        )

        registry.register(provider)
    }

    private func unregisterCustomProvider(_ config: CustomProviderConfig) {
        registry.unregister(identifier: config.identifier)
        try? HTTPKeyManager.delete(for: config.identifier)
    }

    private func loadDefaultProviderPreferences() {
        let defaults = UserDefaults.standard
        if let implement = defaults.string(forKey: "DefaultProviderImplement") {
            defaultProviderForImplement = implement
        }
        if let review = defaults.string(forKey: "DefaultProviderReview") {
            defaultProviderForReview = review
        }
        if let research = defaults.string(forKey: "DefaultProviderResearch") {
            defaultProviderForResearch = research
        }
        if let plan = defaults.string(forKey: "DefaultProviderPlan") {
            defaultProviderForPlan = plan
        }
    }

    private func saveDefaultProviderPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(defaultProviderForImplement, forKey: "DefaultProviderImplement")
        defaults.set(defaultProviderForReview, forKey: "DefaultProviderReview")
        defaults.set(defaultProviderForResearch, forKey: "DefaultProviderResearch")
        defaults.set(defaultProviderForPlan, forKey: "DefaultProviderPlan")
    }
}

// MARK: - Custom Provider Config

struct CustomProviderConfig: Identifiable, Codable {
    var id: String { identifier }
    let identifier: String
    let name: String
    let endpoint: String
    let model: String
    let requiresApiKey: Bool
}

// MARK: - Add Provider Sheet

struct AddCustomProviderSheet: View {
    @Binding var isPresented: Bool
    var onSave: (CustomProviderConfig) -> Void

    @State private var name = ""
    @State private var endpoint = "http://localhost:8080/v1"
    @State private var model = ""
    @State private var requiresApiKey = false
    @State private var apiKey = ""
    @State private var isTestingConnection = false
    @State private var connectionError: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Custom Provider")
                .font(.headline)
                .padding()

            Form {
                Section {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                    TextField("Endpoint URL", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model", text: $model)
                        .textFieldStyle(.roundedBorder)
                }

                Section {
                    Toggle("Requires API Key", isOn: $requiresApiKey)
                    if requiresApiKey {
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if let error = connectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .padding()

            Divider()

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Test Connection") {
                    Task { await testConnection() }
                }
                .disabled(endpoint.isEmpty || model.isEmpty || isTestingConnection)

                Button("Add") {
                    saveProvider()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || endpoint.isEmpty || model.isEmpty)
            }
            .padding()
        }
        .frame(width: 450, height: 400)
    }

    private func testConnection() async {
        isTestingConnection = true
        connectionError = nil

        guard let url = URL(string: endpoint) else {
            connectionError = "Invalid URL"
            isTestingConnection = false
            return
        }

        // For authenticated providers, temporarily save the API key to keychain for testing
        let testKeychainId = "test-connection-\(UUID().uuidString)"
        var auth: HTTPProviderAuth = .none

        if requiresApiKey {
            if apiKey.isEmpty {
                connectionError = "API key is required"
                isTestingConnection = false
                return
            }
            // Save the test API key temporarily
            do {
                try HTTPKeyManager.save(key: apiKey, for: testKeychainId)
                auth = .bearer(keychain: testKeychainId)
            } catch {
                connectionError = "Failed to prepare API key: \(error.localizedDescription)"
                isTestingConnection = false
                return
            }
        }

        let providerEndpoint = HTTPProviderEndpoint(baseURL: url, model: model, auth: auth)
        let provider = OpenAICompatibleProvider(
            identifier: "test",
            displayName: "Test",
            endpoint: providerEndpoint
        )

        let result = await provider.checkHealth()

        // Clean up temporary keychain entry
        if requiresApiKey {
            try? HTTPKeyManager.delete(for: testKeychainId)
        }

        await MainActor.run {
            isTestingConnection = false
            switch result {
            case .success(let status):
                if status.isHealthy {
                    connectionError = nil
                } else {
                    connectionError = status.message ?? "Connection failed"
                }
            case .failure(let error):
                connectionError = error.localizedDescription
            }
        }
    }

    private func saveProvider() {
        let identifier = name.lowercased().replacingOccurrences(of: " ", with: "-")

        // Save API key if provided
        if requiresApiKey && !apiKey.isEmpty {
            try? HTTPKeyManager.save(key: apiKey, for: identifier)
        }

        let config = CustomProviderConfig(
            identifier: identifier,
            name: name,
            endpoint: endpoint,
            model: model,
            requiresApiKey: requiresApiKey
        )

        onSave(config)
        isPresented = false
    }
}

#Preview {
    HTTPProviderSettingsView()
        .frame(width: 500, height: 700)
}
