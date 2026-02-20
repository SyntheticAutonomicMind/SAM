// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import APIFramework
import ConfigurationSystem
import Logging

/// Enhanced endpoint management view for configuring AI endpoints in preferences Adapted from SAM 1.0's excellent design.
struct EndpointManagementView: View {
    private static let logger = Logger(label: "com.sam.ui.endpointmanagement")
    @EnvironmentObject private var endpointManager: EndpointManager
    @State private var showingAddEndpoint = false
    @State private var editingProvider: ProviderConfiguration?
    @State private var showingDeleteConfirmation = false
    @State private var providerToDelete: ProviderConfiguration?
    @State private var providers: [ProviderConfiguration] = []
    @StateObject private var githubDeviceFlow = GitHubDeviceFlowService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                /// Header.
                headerSection

                /// Endpoints Management.
                endpointsSection

                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadProviders()
        }
        .sheet(isPresented: $showingAddEndpoint) {
            ProviderConfigurationSheet(
                provider: nil,
                onSave: { provider in
                    saveProvider(provider)
                    showingAddEndpoint = false
                },
                onCancel: {
                    showingAddEndpoint = false
                }
            )
        }
        .sheet(item: $editingProvider) { provider in
            ProviderConfigurationSheet(
                provider: provider,
                onSave: { updatedProvider in
                    saveProvider(updatedProvider)
                    editingProvider = nil
                },
                onCancel: {
                    editingProvider = nil
                }
            )
        }
        .alert("Delete Provider", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let provider = providerToDelete {
                    deleteProvider(provider)
                    providerToDelete = nil
                }
            }
        } message: {
            if let provider = providerToDelete {
                Text("Are you sure you want to delete the provider '\(provider.providerType.displayName)'? This action cannot be undone.")
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote Providers")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Configure AI provider endpoints for multi-model support")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var endpointsSection: some View {
        GroupBox("Configured Providers") {
            VStack(alignment: .leading, spacing: 12) {
                /// Header with add button.
                HStack {
                    Text("Manage AI providers for different services")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(action: { showingAddEndpoint = true }) {
                        HStack {
                            Image(systemName: "plus")
                            Text("Add Provider")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                /// Providers list.
                if providers.isEmpty {
                    emptyStateView
                } else {
                    providersListView
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No AI Services Configured")
                .font(.title3)
                .fontWeight(.medium)

            Text("Add AI services (like GitHub Copilot or OpenAI) to use different AI models and capabilities.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: { showingAddEndpoint = true }) {
                HStack {
                    Image(systemName: "plus")
                    Text("Add First AI Service")
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: 200)
    }

    private var providersListView: some View {
        LazyVStack(spacing: 8) {
            ForEach(providers, id: \.providerId) { provider in
                ProviderRowView(
                    provider: provider,
                    onEdit: {
                        editingProvider = provider
                    },
                    onDelete: {
                        providerToDelete = provider
                        showingDeleteConfirmation = true
                    },
                    onToggle: { isEnabled in
                        updateProviderEnabled(provider.providerId, isEnabled: isEnabled)
                    }
                )
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Provider Management

    private func loadProviders() {
        providers = []

        /// Load saved provider IDs first.
        let savedProviderIds = UserDefaults.standard.stringArray(forKey: "saved_provider_ids") ?? []

        for providerId in savedProviderIds {
            if let config = loadProviderConfiguration(for: providerId) {
                providers.append(config)
            }
        }

        /// Also check for default provider type configurations that might not be in saved list.
        for providerType in ProviderType.allCases {
            let defaultId = providerType.defaultIdentifier
            if !savedProviderIds.contains(defaultId), let config = loadProviderConfiguration(for: defaultId) {
                providers.append(config)
            }
        }

        providers.sort { $0.providerType.displayName < $1.providerType.displayName }
    }

    private func saveProvider(_ provider: ProviderConfiguration) {
        let key = "provider_config_\(provider.providerId)"

        if let data = try? JSONEncoder().encode(provider) {
            UserDefaults.standard.set(data, forKey: key)
            UserDefaults.standard.synchronize()

            /// Maintain a list of saved provider IDs for easier loading.
            var savedProviderIds = UserDefaults.standard.stringArray(forKey: "saved_provider_ids") ?? []
            if !savedProviderIds.contains(provider.providerId) {
                savedProviderIds.append(provider.providerId)
                UserDefaults.standard.set(savedProviderIds, forKey: "saved_provider_ids")
                UserDefaults.standard.synchronize()
            }

            /// Update local list.
            if let index = providers.firstIndex(where: { $0.providerId == provider.providerId }) {
                providers[index] = provider
            } else {
                providers.append(provider)
                providers.sort { $0.providerType.displayName < $1.providerType.displayName }
            }

            /// Save provider-specific last-used settings for auto-population.
            saveProviderDefaults(for: provider.providerType, from: provider)

            /// Notify EndpointManager to reload configurations.
            endpointManager.reloadProviderConfigurations()
        }
    }

    private func loadProviderConfiguration(for providerId: String) -> ProviderConfiguration? {
        let key = "provider_config_\(providerId)"

        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(ProviderConfiguration.self, from: data) else {
            return nil
        }

        return config
    }

    private func updateProviderEnabled(_ providerId: String, isEnabled: Bool) {
        if let index = providers.firstIndex(where: { $0.providerId == providerId }) {
            var provider = providers[index]
            provider.isEnabled = isEnabled
            saveProvider(provider)
        }
    }

    private func deleteProvider(_ provider: ProviderConfiguration) {
        let key = "provider_config_\(provider.providerId)"
        UserDefaults.standard.removeObject(forKey: key)

        providers.removeAll { $0.providerId == provider.providerId }

        /// Notify EndpointManager to reload configurations.
        endpointManager.reloadProviderConfigurations()
    }

    /// Get help text for API key field based on provider type.
    private func getAPIKeyHelpText(for type: ProviderType) -> String {
        switch type {
        case .openai:
            return "Get your API key from platform.openai.com"

        case .anthropic:
            return "Get your API key from console.anthropic.com"

        case .githubCopilot:
            return "Use your GitHub Copilot access token"

        case .deepseek:
            return "Get your API key from platform.deepseek.com"

        case .gemini:
            return "Get your API key from aistudio.google.com"

        case .openrouter:
            return "Get your API key from openrouter.ai/keys"

        case .localLlama:
            return "No API key required - local models loaded from ~/Library/Caches/sam/models"

        case .localMLX:
            return "No API key required - MLX models loaded from ~/Library/Caches/SAM/models"

        case .custom:
            return "Enter the API key for your custom provider"
        }
    }

    /// Save provider-specific defaults for auto-population.
    private func saveProviderDefaults(for type: ProviderType, from config: ProviderConfiguration) {
        let key = "provider_defaults_\(type.rawValue)"
        let defaults: [String: Any] = [
            "baseURL": config.baseURL ?? "",
            "models": config.models,
            "maxTokens": config.maxTokens ?? 2048,
            "temperature": config.temperature ?? 0.7,
            "timeoutSeconds": config.timeoutSeconds ?? 30
        ]
        UserDefaults.standard.set(defaults, forKey: key)
    }

    /// Load provider-specific defaults for auto-population.
    private func loadProviderDefaults(for type: ProviderType) -> [String: Any]? {
        let key = "provider_defaults_\(type.rawValue)"
        return UserDefaults.standard.dictionary(forKey: key)
    }
}

// MARK: - UI Setup

struct ProviderRowView: View {
    let provider: ProviderConfiguration
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void

    @State private var isEnabled: Bool

    init(provider: ProviderConfiguration, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void, onToggle: @escaping (Bool) -> Void) {
        self.provider = provider
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onToggle = onToggle
        self._isEnabled = State(initialValue: provider.isEnabled)
    }

    var body: some View {
        HStack(spacing: 12) {
            /// Provider type icon.
            Image(systemName: providerIcon)
                .foregroundColor(provider.providerType.iconColor)
                .font(.title3)

            /// Provider info.
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(provider.providerType.displayName)
                        .font(.headline)

                    if !isEnabled {
                        Text("DISABLED")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .clipShape(Capsule())
                    }
                }

                if let baseURL = provider.baseURL {
                    Text(baseURL)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    /// Status indicator.
                    HStack(spacing: 4) {
                        Image(systemName: isEnabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(isEnabled ? .green : .gray)
                        Text(isEnabled ? "Active" : "Disabled")
                            .font(.caption2)
                            .foregroundColor(isEnabled ? .green : .gray)
                    }

                    if !provider.models.isEmpty {
                        Text("• \(provider.models.count) model\(provider.models.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            /// Action buttons.
            HStack(spacing: 8) {
                /// Toggle enabled/disabled.
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .scaleEffect(0.8)
                    .onChange(of: isEnabled) { _, newValue in
                        onToggle(newValue)
                    }

                /// Edit button.
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Edit provider")

                /// Delete button.
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete provider")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private var providerIcon: String {
        switch provider.providerType {
        case .openai: return "bubble.left"
        case .anthropic: return "message"
        case .githubCopilot: return "arrow.triangle.branch"
        case .deepseek: return "magnifyingglass"
        case .gemini: return "globe"
        case .openrouter: return "arrow.triangle.merge"
        case .localLlama: return "laptopcomputer"
        case .localMLX: return "flame"
        case .custom: return "gear"
        }
    }
}

// MARK: - Provider Configuration Sheet

struct ProviderConfigurationSheet: View {
    private static let logger = Logger(label: "com.sam.ui.providerconfig")

    let provider: ProviderConfiguration?
    let onSave: (ProviderConfiguration) -> Void
    let onCancel: () -> Void

    @State private var providerType: ProviderType = .openai
    @State private var providerId: String = "openai"
    @State private var isEnabled: Bool = true
    @State private var apiKey: String = ""
    @State private var baseURL: String = ""
    @State private var models: String = ""
    @State private var maxTokens: String = "2048"
    @State private var temperature: String = "0.7"
    @State private var timeoutSeconds: String = "30"
    @State private var retryCount: String = "2"
    @State private var testingConnection = false
    @State private var connectionTestResult: String?
    @State private var isLoadingModels = false
    @State private var fetchedModels: [String] = []

    /// GitHub Device Flow states.
    @StateObject private var githubDeviceFlow = GitHubDeviceFlowService()
    @State private var showingDeviceFlow = false
    @State private var showManualTokenEntry = false

    var isEditing: Bool { provider != nil }
    var title: String { isEditing ? "Edit Provider" : "Add Provider" }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            /// Header.
            HStack {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
            }

            /// Form content.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    /// Basic Information.
                    GroupBox("Basic Information") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Provider Type")
                                    .font(.headline)
                                Picker("Type", selection: $providerType) {
                                    /// Exclude local-llama and local-mlx since they must be managed via LocalModelManager.
                                    ForEach(ProviderType.allCases.filter { $0 != .localLlama && $0 != .localMLX }, id: \.self) { type in
                                        HStack {
                                            Image(systemName: type.icon)
                                                .foregroundColor(type.iconColor)
                                            Text(type.displayName)
                                                .font(.system(.body, design: .monospaced))
                                        }
                                        .tag(type)
                                    }
                                }
                                .pickerStyle(.menu)
                                .disabled(isEditing)
                                .onChange(of: providerType) { _, newType in
                                    updateFieldsForProviderType(newType)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Provider ID")
                                    .font(.headline)
                                TextField("Unique identifier", text: $providerId)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(isEditing)
                            }

                            Toggle("Enabled", isOn: $isEnabled)
                        }
                        .padding()
                    }

                    /// Configuration.
                    GroupBox("Configuration") {
                        VStack(alignment: .leading, spacing: 12) {
                            if providerType.requiresApiKey {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("API Key")
                                        .font(.headline)

                                    /// GitHub Copilot: Show "Connect with GitHub" button by default.
                                    if providerType == .githubCopilot {
                                        if showManualTokenEntry || !apiKey.isEmpty {
                                            /// Manual token entry mode.
                                            SecureField("Enter your API key", text: $apiKey)
                                                .textFieldStyle(.roundedBorder)

                                            /// Only show toggle if no API key is configured.
                                            if apiKey.isEmpty {
                                                Button("Use GitHub Authentication") {
                                                    showManualTokenEntry = false
                                                }
                                                .buttonStyle(.link)
                                                .font(.caption)
                                                .help("Switch to GitHub device flow authentication")
                                            }
                                        } else {
                                            /// GitHub authentication mode.
                                            Button(action: { showingDeviceFlow = true }) {
                                                HStack {
                                                    Image(systemName: "arrow.triangle.branch")
                                                    Text("Connect with GitHub")
                                                }
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.large)
                                            .help("Authenticate with GitHub to get access token")

                                            Button("Use an existing token") {
                                                showManualTokenEntry = true
                                            }
                                            .buttonStyle(.link)
                                            .font(.caption)
                                            .help("Manually enter a GitHub token")
                                        }
                                    } else {
                                        /// Other providers: normal API key input.
                                        SecureField("Enter your API key", text: $apiKey)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    /// Provider-specific help text.
                                    if providerType == .githubCopilot && !apiKey.isEmpty {
                                        Text("Remove your existing key to re-authenticate using GitHub Authentication")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text(getAPIKeyHelpText(for: providerType))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Base URL")
                                    .font(.headline)
                                TextField("https://api.provider.com/v1", text: $baseURL)
                                    .textFieldStyle(.roundedBorder)

                                /// Show help text for default URLs.
                                if let defaultURL = providerType.defaultBaseURL {
                                    Text("Default: \(defaultURL)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Available Models")
                                        .font(.headline)

                                    Spacer()

                                    /// Fetch models button (only for remote providers with API key).
                                    if !baseURL.isEmpty &&
                                       (!providerType.requiresApiKey || !apiKey.isEmpty) {
                                        Button(action: fetchAvailableModels) {
                                            HStack {
                                                if isLoadingModels {
                                                    ProgressView()
                                                        .scaleEffect(0.8)
                                                } else {
                                                    Image(systemName: "arrow.down.circle")
                                                }
                                                Text("Fetch")
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(isLoadingModels)
                                        .controlSize(.small)
                                    }
                                }

                                TextField("Enter models separated by commas", text: $models, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(3)

                                if !fetchedModels.isEmpty {
                                    Text("Found \(fetchedModels.count) model\(fetchedModels.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("Example: gpt-4o, gpt-4o-mini, gpt-3.5-turbo")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                    }

                    /// Advanced Settings.
                    GroupBox("Advanced Settings") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Max Tokens")
                                        .font(.headline)
                                    TextField("e.g., 4096", text: $maxTokens)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Temperature")
                                        .font(.headline)
                                    TextField("e.g., 0.7", text: $temperature)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Timeout (seconds)")
                                        .font(.headline)
                                    TextField("e.g., 30", text: $timeoutSeconds)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Retry Count")
                                        .font(.headline)
                                    TextField("e.g., 2", text: $retryCount)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                        .padding()
                    }

                    /// Connection Testing.
                    GroupBox("Connection Test") {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Test Connection") {
                                testConnection()
                            }
                            .disabled(testingConnection || baseURL.isEmpty || (providerType.requiresApiKey && apiKey.isEmpty))
                            .buttonStyle(.borderedProminent)

                            if testingConnection {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Testing connection...")
                                        .font(.caption)
                                }
                            }

                            if let result = connectionTestResult {
                                Text(result)
                                    .font(.caption)
                                    .foregroundColor(result.contains("Success") ? .green : .red)
                            }
                        }
                        .padding()
                    }
                }
                .padding()
            }

            /// Footer buttons.
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Save Provider") {
                    saveProvider()
                }
                .disabled(providerId.isEmpty || (providerType.requiresApiKey && apiKey.isEmpty))
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 600, idealWidth: 700, maxWidth: 800,
               minHeight: 500, idealHeight: 700, maxHeight: .infinity)
        .onAppear {
            loadProviderData()
        }
        .sheet(isPresented: $showingDeviceFlow) {
            GitHubDeviceFlowSheet(deviceFlow: githubDeviceFlow) { token in
                apiKey = token
                showingDeviceFlow = false

                /// Auto-fetch models after successful authentication.
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    fetchAvailableModels()
                }
            }
        }
    }

    private func loadProviderData() {
        if let provider = provider {
            providerType = provider.providerType
            providerId = provider.providerId
            isEnabled = provider.isEnabled
            apiKey = provider.apiKey ?? ""
            baseURL = provider.baseURL ?? ""
            models = provider.models.joined(separator: ", ")
            maxTokens = provider.maxTokens.map(String.init) ?? ""
            temperature = provider.temperature.map { String($0) } ?? "0.7"
            timeoutSeconds = provider.timeoutSeconds.map(String.init) ?? "30"
            retryCount = provider.retryCount.map(String.init) ?? "2"
        } else {
            /// Initialize with defaults for new provider.
            /// Generate unique ID for new providers by adding timestamp suffix
            let timestamp = Int(Date().timeIntervalSince1970)
            providerId = "\(providerType.defaultIdentifier)-\(timestamp)"
            baseURL = providerType.defaultBaseURL ?? ""
            models = providerType.defaultModels.joined(separator: ", ")
        }
    }

    func testConnection() {
        testingConnection = true
        connectionTestResult = nil

        /// Simulate connection test (replace with actual implementation).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            testingConnection = false

            if providerType.requiresApiKey && apiKey.isEmpty {
                connectionTestResult = "ERROR: API key required"
            } else if baseURL.isEmpty {
                connectionTestResult = "ERROR: Base URL required"
            } else {
                connectionTestResult = "SUCCESS: Connection successful"
            }
        }
    }

    // MARK: - Helper Methods

    /// Update form fields when provider type changes.
    private func updateFieldsForProviderType(_ newType: ProviderType) {
        /// Only update fields if this is a new provider (not editing existing).
        guard provider == nil else {
            return
        }

        /// Load previously saved defaults for this provider type.
        let savedDefaults = loadProviderDefaults(for: newType)

        /// Update base URL - use saved default if available, then system default.
        if let savedBaseURL = savedDefaults?["baseURL"] as? String, !savedBaseURL.isEmpty {
            baseURL = savedBaseURL
        } else if let defaultURL = newType.defaultBaseURL {
            baseURL = defaultURL
        }

        /// Update models list - use saved default if available, then system default.
        if let savedModels = savedDefaults?["models"] as? [String], !savedModels.isEmpty {
            models = savedModels.joined(separator: ", ")
        } else {
            models = newType.defaultModels.joined(separator: ", ")
        }

        /// Update advanced settings with saved defaults.
        if let savedMaxTokens = savedDefaults?["maxTokens"] as? Int {
            maxTokens = String(savedMaxTokens)
        } else {
            maxTokens = "2048"
        }

        if let savedTemperature = savedDefaults?["temperature"] as? Double {
            temperature = String(savedTemperature)
        } else {
            temperature = "0.7"
        }

        if let savedTimeout = savedDefaults?["timeoutSeconds"] as? Int {
            timeoutSeconds = String(savedTimeout)
        } else {
            timeoutSeconds = "30"
        }

        /// Clear API key if not required.
        if !newType.requiresApiKey {
            apiKey = ""
        }

        /// Update provider ID to match the new type ONLY if this is a new provider being created
        /// Don't update if editing an existing provider (provider != nil)
        if provider == nil {
            let timestamp = Int(Date().timeIntervalSince1970)
            providerId = "\(newType.defaultIdentifier)-\(timestamp)"
        }
    }

    /// Save provider-specific defaults for next time.
    private func saveProviderDefaults(for providerType: ProviderType) {
        let defaults: [String: Any] = [
            "baseURL": baseURL,
            "models": models.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            "maxTokens": Int(maxTokens) ?? 2048,
            "temperature": Double(temperature) ?? 0.7,
            "timeoutSeconds": Int(timeoutSeconds) ?? 30
        ]

        UserDefaults.standard.set(defaults, forKey: "SAMProviderDefaults_\(providerType.rawValue)")
    }

    /// Load previously saved defaults for a provider type.
    private func loadProviderDefaults(for providerType: ProviderType) -> [String: Any]? {
        return UserDefaults.standard.dictionary(forKey: "SAMProviderDefaults_\(providerType.rawValue)")
    }

    /// Get help text for API key based on provider type.
    private func getAPIKeyHelpText(for providerType: ProviderType) -> String {
        switch providerType {
        case .openai:
            return "Create an API key at platform.openai.com/api-keys"

        case .anthropic:
            return "Create an API key in your Anthropic Console"

        case .githubCopilot:
            return "Authenticate with GitHub to automatically get your Copilot token"

        case .deepseek:
            return "Get your API key from DeepSeek's developer platform"

        case .gemini:
            return "Create an API key at aistudio.google.com"

        case .openrouter:
            return "Get your API key from openrouter.ai/keys - provides access to 400+ AI models"

        case .localLlama:
            return "No API key required for local models - models are loaded from ~/Library/Caches/sam/models"

        case .localMLX:
            return "No API key required for MLX models - models are loaded from ~/Library/Caches/SAM/models"

        case .custom:
            return "Enter the API key provided by your custom endpoint"
        }
    }

    /// Fetch available models from the provider's API.
    private func fetchAvailableModels() {
        guard !baseURL.isEmpty else { return }

        isLoadingModels = true
        fetchedModels = []

        Task {
            do {
                let models = try await fetchModelsFromProvider()
                await MainActor.run {
                    fetchedModels = models
                    /// Auto-populate the models field with fetched models.
                    self.models = models.joined(separator: ", ")
                    isLoadingModels = false
                }
            } catch {
                await MainActor.run {
                    /// Show error but don't clear existing models.
                    isLoadingModels = false
                    Self.logger.error("Failed to fetch models: \(error)")
                }
            }
        }
    }

    /// Actual API call to fetch models.
    private func fetchModelsFromProvider() async throws -> [String] {
        let modelsURL = baseURL.hasSuffix("/models") ? baseURL : "\(baseURL)/models"

        guard var url = URL(string: modelsURL) else {
            throw URLError(.badURL)
        }

        /// For Gemini, add API key as query parameter
        if providerType == .gemini && !apiKey.isEmpty {
            if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
                if let urlWithKey = components.url {
                    url = urlWithKey
                }
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        /// Add authentication if required.
        if providerType.requiresApiKey && !apiKey.isEmpty {
            switch providerType {
            case .openai, .deepseek, .custom:
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            case .openrouter:
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("https://www.syntheticautonomicmind.org", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("SAM", forHTTPHeaderField: "X-Title")

            case .anthropic:
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            case .githubCopilot:
                // Use CopilotTokenStore to get the exchanged session token (tid=...)
                // which provides full model access (42+ models)
                let copilotToken = try await CopilotTokenStore.shared.getCopilotToken()
                request.setValue("Bearer \(copilotToken)", forHTTPHeaderField: "Authorization")
                let samVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
                request.setValue("vscode/\(samVersion)", forHTTPHeaderField: "Editor-Version")
                request.setValue("copilot-chat/\(samVersion)", forHTTPHeaderField: "Editor-Plugin-Version")
                request.setValue("GitHubCopilotChat/\(samVersion)", forHTTPHeaderField: "User-Agent")

            case .gemini:
                /// Gemini uses API key as query parameter (already added to URL above)
                break

            case .localLlama, .localMLX:
                /// No authentication required for local providers.
                break
            }
        }

        /// Set timeout.
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }

        /// Parse response - support both OpenAI and llama.cpp formats.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        var modelIds: [String] = []

        /// Try OpenAI format first (data array).
        if let dataArray = json["data"] as? [[String: Any]] {
            for item in dataArray {
                if let id = item["id"] as? String {
                    modelIds.append(id)
                }
            }
        }
        /// Try Gemini format (models array with name field in format "models/model-name").
        else if providerType == .gemini, let modelsArray = json["models"] as? [[String: Any]] {
            for item in modelsArray {
                if let name = item["name"] as? String {
                    /// Gemini returns names like "models/gemini-pro" - extract just the model name
                    let modelName = name.replacingOccurrences(of: "models/", with: "")
                    modelIds.append(modelName)
                }
            }
        }
        /// Try llama.cpp format (models array).
        else if let modelsArray = json["models"] as? [[String: Any]] {
            for item in modelsArray {
                /// llama.cpp uses "model" or "name" field.
                let id = item["model"] as? String ?? item["name"] as? String ?? ""
                guard !id.isEmpty else { continue }

                /// Extract clean model name from path if needed.
                let cleanId = URL(fileURLWithPath: id).lastPathComponent
                modelIds.append(cleanId)
            }
        }

        return modelIds.sorted()
    }

    private func saveProvider() {
        let modelList = models
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var config = ProviderConfiguration(
            providerId: providerId,
            providerType: providerType,
            isEnabled: isEnabled,
            baseURL: baseURL.isEmpty ? nil : baseURL,
            models: modelList,
            maxTokens: Int(maxTokens) ?? 2048,
            temperature: Double(temperature) ?? 0.7,
            timeoutSeconds: Int(timeoutSeconds) ?? 30,
            retryCount: Int(retryCount) ?? 2
        )

        /// Store API key in Keychain (via computed property setter).
        config.apiKey = apiKey.isEmpty ? nil : apiKey

        onSave(config)
    }
}

#Preview {
    EndpointManagementView()
}
