// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem

// MARK: - Endpoint Management Preferences

/// Preferences view for managing AI provider endpoints.
public struct EndpointManagementPreferencesView: View {
    @AppStorage("selectedDefaultProvider") private var selectedDefaultProvider: String = ""
    @State private var providers: [ProviderConfiguration] = []
    @State private var showingAddProvider = false
    @State private var editingProvider: ProviderConfiguration?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            /// Header.
            HStack {
                Text("AI Provider Management")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("Add Provider") {
                    showingAddProvider = true
                }
                .buttonStyle(.borderedProminent)
            }

            /// Default Provider Selection.
            GroupBox("Default Provider") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Default Provider", selection: $selectedDefaultProvider) {
                        ForEach(providers.filter(\.isEnabled), id: \.providerId) { provider in
                            Text(provider.providerType.displayName).tag(provider.providerId)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("The default provider used when no specific model is requested.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }

            /// Provider List.
            GroupBox("Configured Providers") {
                if providers.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "network.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)

                        Text("No providers configured")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        Text("Add AI providers to enable multi-model support")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(providers, id: \.providerId) { provider in
                            ProviderConfigurationRow(
                                provider: provider,
                                onEdit: {
                                    editingProvider = provider
                                },
                                onToggle: { isEnabled in
                                    updateProviderEnabled(provider.providerId, isEnabled: isEnabled)
                                },
                                onDelete: {
                                    deleteProvider(provider.providerId)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            /// Load Balancing Settings.
            GroupBox("Load Balancing") {
                VStack(alignment: .leading, spacing: 12) {
                    /// Future feature: Load balancing configuration for multi-provider setups.
                    Text("Round-robin load balancing is enabled by default.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }

            Spacer()
        }
        .padding()
        .onAppear {
            loadProviders()
        }
        .sheet(isPresented: $showingAddProvider) {
            ProviderConfigurationSheet(
                provider: nil,
                onSave: { provider in
                    saveProvider(provider)
                    showingAddProvider = false
                },
                onCancel: {
                    showingAddProvider = false
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
    }

    // MARK: - Provider Management

    private func loadProviders() {
        providers = []

        for providerType in ProviderType.allCases {
            let providerId = providerType.defaultIdentifier
            if let config = loadProviderConfiguration(for: providerId) {
                providers.append(config)
            }
        }

        providers.sort { $0.providerType.displayName < $1.providerType.displayName }
    }

    private func saveProvider(_ provider: ProviderConfiguration) {
        let key = "provider_config_\(provider.providerId)"

        if let data = try? JSONEncoder().encode(provider) {
            UserDefaults.standard.set(data, forKey: key)

            /// Update local list.
            if let index = providers.firstIndex(where: { $0.providerId == provider.providerId }) {
                providers[index] = provider
            } else {
                providers.append(provider)
                providers.sort { $0.providerType.displayName < $1.providerType.displayName }
            }
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

    private func deleteProvider(_ providerId: String) {
        let key = "provider_config_\(providerId)"
        UserDefaults.standard.removeObject(forKey: key)

        providers.removeAll { $0.providerId == providerId }
    }
}

// MARK: - Provider Configuration Row

struct ProviderConfigurationRow: View {
    let provider: ProviderConfiguration
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    @State private var isEnabled: Bool

    init(provider: ProviderConfiguration, onEdit: @escaping () -> Void, onToggle: @escaping (Bool) -> Void, onDelete: @escaping () -> Void) {
        self.provider = provider
        self.onEdit = onEdit
        self.onToggle = onToggle
        self.onDelete = onDelete
        self._isEnabled = State(initialValue: provider.isEnabled)
    }

    var body: some View {
        HStack(spacing: 12) {
            /// Provider Type Icon.
            Image(systemName: providerIcon)
                .foregroundColor(providerColor)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.providerType.displayName)
                    .font(.headline)
                    .foregroundColor(isEnabled ? .primary : .secondary)

                Text("\(provider.models.count) model\(provider.models.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let baseURL = provider.baseURL {
                    Text(baseURL)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            /// Status indicator.
            Circle()
                .fill(isEnabled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            /// Controls.
            HStack(spacing: 4) {
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .scaleEffect(0.8)
                    .onChange(of: isEnabled) { _, newValue in
                        onToggle(newValue)
                    }

                Button("Edit") {
                    onEdit()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Button("Delete") {
                    onDelete()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.05))
        )
    }

    private var providerIcon: String {
        switch provider.providerType {
        case .openai: return "bubble.left"
        case .anthropic: return "message"
        case .githubCopilot: return "chevron.left.forwardslash.chevron.right"
        case .deepseek: return "magnifyingglass"
        case .localLlama: return "laptopcomputer"
        case .localMLX: return "flame"
        case .custom: return "gear"
        }
    }

    private var providerColor: Color {
        switch provider.providerType {
        case .openai: return .green
        case .anthropic: return .orange
        case .githubCopilot: return .purple
        case .deepseek: return .indigo
        case .localLlama: return .cyan
        case .localMLX: return .orange
        case .custom: return .gray
        }
    }
}

// MARK: - Provider Configuration Sheet

struct ProviderConfigurationSheet: View {
    let provider: ProviderConfiguration?
    let onSave: (ProviderConfiguration) -> Void
    let onCancel: () -> Void

    @State private var providerType: ProviderType = .openai
    @State private var providerId: String = ""
    @State private var isEnabled: Bool = true
    @State private var apiKey: String = ""
    @State private var baseURL: String = ""
    @State private var models: String = ""
    @State private var maxTokens: String = ""
    @State private var temperature: String = "0.7"
    @State private var timeoutSeconds: String = "30"
    @State private var retryCount: String = "2"

    /// MLX Configuration.
    @State private var mlxPreset: MLXPreset = .balanced
    @State private var customKVBits: String = "8"
    @State private var customKVGroupSize: String = "64"
    @State private var customMaxKVSize: String = ""
    @State private var customTopP: String = "0.95"
    @State private var customRepetitionPenalty: String = "1.1"
    @State private var customRepetitionContextSize: String = "20"

    enum MLXPreset: String, CaseIterable {
        case memoryOptimized = "Memory Optimized (16GB RAM)"
        case balanced = "Balanced (32GB+ RAM)"
        case highQuality = "High Quality (64GB+ RAM)"
        case custom = "Custom"

        func toMLXConfiguration() -> MLXConfiguration {
            switch self {
            case .memoryOptimized: return .memoryOptimized
            case .balanced: return .balanced
            case .highQuality: return .highQuality
            case .custom: return .balanced
            }
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Provider Information") {
                    Picker("Provider Type", selection: $providerType) {
                        /// Exclude local-llama and local-mlx since they must be managed via LocalModelManager.
                        ForEach(ProviderType.allCases.filter { $0 != .localLlama && $0 != .localMLX }, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .onChange(of: providerType) { _, newType in
                        if providerId.isEmpty || providerId == providerType.defaultIdentifier {
                            providerId = newType.defaultIdentifier
                        }
                        if baseURL.isEmpty {
                            baseURL = newType.defaultBaseURL ?? ""
                        }
                        if models.isEmpty {
                            models = newType.defaultModels.joined(separator: ", ")
                        }
                    }

                    TextField("Provider ID", text: $providerId)

                    Toggle("Enabled", isOn: $isEnabled)
                }

                if providerType.requiresApiKey {
                    Section("Authentication") {
                        SecureField("API Key", text: $apiKey)
                            .textContentType(.password)
                    }
                }

                Section("Configuration") {
                    TextField("Base URL", text: $baseURL)

                    TextField("Models (comma-separated)", text: $models, axis: .vertical)
                        .lineLimit(3)

                    TextField("Max Tokens", text: $maxTokens)

                    TextField("Temperature", text: $temperature)
                }

                Section("Advanced") {
                    TextField("Timeout (seconds)", text: $timeoutSeconds)

                    TextField("Retry Count", text: $retryCount)
                }

                /// MLX-specific configuration for local models.
                if providerType == .localMLX {
                    Section {
                        Picker("Memory Optimization Preset", selection: $mlxPreset) {
                            ForEach(MLXPreset.allCases, id: \.self) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .help("Choose preset based on available RAM. Memory optimization uses KV cache quantization to reduce memory usage.")

                        if mlxPreset == .custom {
                            TextField("KV Cache Bits (4 or 8, empty for no quantization)", text: $customKVBits)
                                .help("4-bit: ~75% memory savings, 8-bit: ~50% memory savings")

                            TextField("KV Group Size", text: $customKVGroupSize)
                                .help("Group size for quantization (default: 64)")

                            TextField("Max KV Cache Size (empty for unlimited)", text: $customMaxKVSize)
                                .help("Maximum tokens in KV cache before rotation")

                            TextField("Top-P Sampling", text: $customTopP)
                                .help("Nucleus sampling threshold (default: 0.95)")

                            TextField("Repetition Penalty", text: $customRepetitionPenalty)
                                .help("Penalty for token repetition (default: 1.1, empty to disable)")

                            TextField("Repetition Context Size", text: $customRepetitionContextSize)
                                .help("Number of recent tokens to check for repetition (default: 20)")
                        } else {
                            /// Show preset details.
                            let config = mlxPreset.toMLXConfiguration()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Preset Configuration:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if let kvBits = config.kvBits {
                                    Text("• KV Cache: \(kvBits)-bit quantization")
                                        .font(.caption)
                                } else {
                                    Text("• KV Cache: No quantization (highest quality)")
                                        .font(.caption)
                                }

                                Text("• Top-P: \(String(format: "%.2f", config.topP))")
                                    .font(.caption)

                                if let repPenalty = config.repetitionPenalty {
                                    Text("• Repetition Penalty: \(String(format: "%.1f", repPenalty))")
                                        .font(.caption)
                                }
                            }
                        }
                    } header: {
                        Label("MLX Optimization", systemImage: "flame")
                    } footer: {
                        Text("MLX optimization settings for local model inference on Apple Silicon. Higher memory optimization reduces quality slightly but enables larger models.")
                    }
                }
            }
            .navigationTitle(provider != nil ? "Edit Provider" : "Add Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveProvider()
                    }
                    .disabled(providerId.isEmpty || (providerType.requiresApiKey && apiKey.isEmpty))
                }
            }
        }
        .onAppear {
            loadProviderData()
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

            /// Load MLX configuration.
            if let mlxConfig = provider.mlxConfig {
                /// Determine if it's a preset or custom.
                if mlxConfig == .memoryOptimized {
                    mlxPreset = .memoryOptimized
                } else if mlxConfig == .balanced {
                    mlxPreset = .balanced
                } else if mlxConfig == .highQuality {
                    mlxPreset = .highQuality
                } else {
                    mlxPreset = .custom
                    customKVBits = mlxConfig.kvBits.map(String.init) ?? ""
                    customKVGroupSize = String(mlxConfig.kvGroupSize)
                    customMaxKVSize = mlxConfig.maxKVSize.map(String.init) ?? ""
                    customTopP = String(mlxConfig.topP)
                    customRepetitionPenalty = mlxConfig.repetitionPenalty.map { String($0) } ?? ""
                    customRepetitionContextSize = String(mlxConfig.repetitionContextSize)
                }
            }
        } else {
            /// Initialize with defaults for new provider.
            providerId = providerType.defaultIdentifier
            baseURL = providerType.defaultBaseURL ?? ""
            models = providerType.defaultModels.joined(separator: ", ")
        }
    }

    private func saveProvider() {
        let modelList = models
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        /// Build MLX configuration for local MLX providers.
        let mlxConfig: MLXConfiguration? = (providerType == .localMLX) ? {
            if mlxPreset == .custom {
                return MLXConfiguration(
                    kvBits: Int(customKVBits),
                    kvGroupSize: Int(customKVGroupSize) ?? 64,
                    quantizedKVStart: 0,
                    maxKVSize: Int(customMaxKVSize),
                    topP: Double(customTopP) ?? 0.95,
                    repetitionPenalty: Double(customRepetitionPenalty),
                    repetitionContextSize: Int(customRepetitionContextSize) ?? 20
                )
            } else {
                return mlxPreset.toMLXConfiguration()
            }
        }() : nil

        var config = ProviderConfiguration(
            providerId: providerId,
            providerType: providerType,
            isEnabled: isEnabled,
            baseURL: baseURL.isEmpty ? nil : baseURL,
            models: modelList,
            maxTokens: Int(maxTokens),
            temperature: Double(temperature),
            timeoutSeconds: Int(timeoutSeconds),
            retryCount: Int(retryCount),
            mlxConfig: mlxConfig
        )

        /// Store API key in Keychain (separate from configuration).
        config.apiKey = apiKey.isEmpty ? nil : apiKey

        onSave(config)
    }
}

#Preview {
    EndpointManagementPreferencesView()
}
