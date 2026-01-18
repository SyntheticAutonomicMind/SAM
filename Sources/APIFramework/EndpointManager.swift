// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConversationEngine
import ConfigurationSystem
import MCPFramework
import Logging
import Training
extension Notification.Name {
    /// Posted when providers/endpoints are reloaded and available models may have changed.
    public static let endpointManagerDidReloadProviders = Notification.Name("com.sam.endpointmanager.providersReloaded")

    /// Posted when local models are scanned and new models are available.
    public static let endpointManagerDidUpdateModels = Notification.Name("com.sam.endpointmanager.modelsUpdated")

    /// Posted when a new Stable Diffusion model is downloaded and installed.
    public static let stableDiffusionModelInstalled = Notification.Name("com.sam.sd.modelInstalled")

    /// Posted when ALICE remote models are loaded and available.
    public static let aliceModelsLoaded = Notification.Name("com.sam.alice.modelsLoaded")
    
    /// Posted when a provider hits rate limit and is waiting to retry.
    /// userInfo contains: "retryAfterSeconds" (Double), "providerName" (String)
    public static let providerRateLimitHit = Notification.Name("com.sam.provider.rateLimitHit")
    
    /// Posted when rate limit retry is complete and request is being retried.
    public static let providerRateLimitRetrying = Notification.Name("com.sam.provider.rateLimitRetrying")
}

/// Comprehensive endpoint manager for multi-provider AI integrations Handles routing requests to different AI providers (OpenAI, Anthropic, GitHub Copilot, DeepSeek, custom) with fallback chains, load balancing, and response normalization to OpenAI format.
@MainActor
public class EndpointManager: ObservableObject {
    private let logger = Logging.Logger(label: "com.sam.endpointmanager")

    /// Provider instances.
    private var providers: [String: AIProvider] = [:]
    private var providerConfigs: [String: ProviderConfiguration] = [:]

    /// Local model manager.
    private var localModelManager: LocalModelManager?

    /// Track currently active local model provider for lifecycle management.
    private var activeLocalProvider: (identifier: String, provider: Any)?

    /// Load balancing and fallback.
    private var loadBalancer: LoadBalancer = RoundRobinLoadBalancer()
    private var fallbackChains: [String: [String]] = [:]

    /// Model loading state tracking (for local models).
    @Published public var modelLoadingStatus: [String: ModelLoadingState] = [:]

    /// Simple boolean properties for UI reactivity (SwiftUI observes these better than dictionaries).
    @Published public var isAnyModelLoading: Bool = false
    @Published public var currentLoadingModelName: String?

    public enum ModelLoadingState: Equatable {
        case notLoaded
        case loading(modelName: String)
        case loaded
    }

    /// Billing lookup cache to reduce log spam and provider calls
    /// Cache expires after 10 minutes
    private var billingCache: [String: (result: (isPremium: Bool, multiplier: Double?)?, timestamp: Date)] = [:]
    private let billingCacheExpiration: TimeInterval = 600  /// 10 minutes

    /// Dependencies.
    private let conversationManager: ConversationManager

    public init(conversationManager: ConversationManager) {
        self.conversationManager = conversationManager
        setupProviders()
        loadProviderConfigurations()
        logger.debug("DEBUG: loadProviderConfigurations completed")
        logger.debug("EndpointManager initialized with \(self.providers.count) providers")

        /// Prefetch GitHub Copilot billing data so it's available when user opens model picker
        prefetchGitHubCopilotBillingData()

        /// Listen for local model changes to enable hot reload
        NotificationCenter.default.addObserver(
            forName: .localModelsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.logger.info("Hot reload: Local models changed, reloading provider configurations")
                self.reloadProviderConfigurations()
            }
        }
        
        /// Listen for LoRA adapter changes
        NotificationCenter.default.addObserver(
            forName: .loraAdaptersDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract values outside Task to avoid concurrency issues
            var adapterId: String?
            var adapterName: String?
            var baseModelId: String?
            
            if let adapter = notification.object as? LoRAAdapter {
                adapterId = adapter.id
                adapterName = adapter.metadata.adapterName
                baseModelId = adapter.baseModelId
            }
            
            Task { @MainActor in
                guard let self = self, let localModelManager = self.localModelManager else { return }
                
                /// Register adapter with LocalModelManager
                /// CRITICAL: Use adapter ID as modelName to match ModelListManager format (lora/{uuid})
                if let aid = adapterId, let aname = adapterName {
                    let adapterDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                        .appendingPathComponent("SAM/adapters/\(aid)")
                    localModelManager.registerModel(
                        provider: "lora",
                        modelName: aid,  // Use UUID, not adapter name
                        path: adapterDir.path,
                        sizeBytes: nil,
                        quantization: "lora"
                    )
                    self.logger.info("Registered LoRA adapter: \(aname) (ID: \(aid))")
                }
                
                /// Trigger provider reload to create/remove providers
                self.reloadProviderConfigurations()
            }
        }
    }

    // MARK: - Public Interface

    /// Get model capabilities (context sizes) from GitHub Copilot API Returns dictionary of modelId -> max_input_tokens.
    public func getGitHubCopilotModelCapabilities() async throws -> [String: Int]? {
        guard let githubProvider = providers.values.first(where: { $0.config.providerType == .githubCopilot }) as? GitHubCopilotProvider else {
            return nil
        }

        return try await githubProvider.fetchModelCapabilities()
    }
    
    /// Check if GitHub Copilot provider has authentication configured
    /// Returns true if device flow token or manual API key is available
    public func hasGitHubCopilotAuthentication() async -> Bool {
        guard let githubProvider = providers.values.first(where: { $0.config.providerType == .githubCopilot }) as? GitHubCopilotProvider else {
            return false
        }
        
        return await githubProvider.hasAuthentication()
    }
    
    /// Clear the GitHub Copilot capabilities cache to force a fresh fetch
    public func clearGitHubCopilotCapabilitiesCache() async throws {
        guard let githubProvider = providers.values.first(where: { $0.config.providerType == .githubCopilot }) as? GitHubCopilotProvider else {
            return
        }
        
        await githubProvider.clearCapabilitiesCache()
    }
    
    /// Get model capabilities (context sizes) from Gemini API Returns dictionary of modelId -> inputTokenLimit.
    public func getGeminiModelCapabilities() async throws -> [String: Int]? {
        guard let geminiProvider = providers.values.first(where: { $0.config.providerType == .gemini }) as? GeminiProvider else {
            return nil
        }

        return try await geminiProvider.fetchModelCapabilities()
    }

    /// Get comprehensive model capabilities for API exposure
    /// Returns contextWindow, maxCompletionTokens, maxRequestTokens, and billing info for a given model
    /// This enables clients like CLIO to right-size their API requests and track premium usage
    public func getModelCapabilityData(for modelId: String) async -> (contextWindow: Int?, maxCompletionTokens: Int?, maxRequestTokens: Int?, isPremium: Bool?, premiumMultiplier: Double?) {
        // Normalize model ID (remove provider prefix if present)
        let normalizedId = modelId.contains("/") ? String(modelId.split(separator: "/").last ?? "") : modelId
        
        // Try to get capabilities from various sources
        var contextWindow: Int? = nil
        var maxCompletionTokens: Int? = nil
        var isPremium: Bool? = nil
        var premiumMultiplier: Double? = nil
        
        // 1. Check GitHub Copilot models
        if modelId.hasPrefix("github_copilot/") {
            if let capabilities = try? await getGitHubCopilotModelCapabilities() {
                contextWindow = capabilities[normalizedId] ?? capabilities[modelId]
            }
            // Get billing info for GitHub Copilot models
            if let billing = getGitHubCopilotModelBillingInfo(modelId: normalizedId) ?? getGitHubCopilotModelBillingInfo(modelId: modelId) {
                isPremium = billing.isPremium
                premiumMultiplier = billing.multiplier
            }
        }
        
        // 2. Check Gemini models
        if modelId.hasPrefix("gemini/") {
            if let capabilities = try? await getGeminiModelCapabilities() {
                contextWindow = capabilities[normalizedId] ?? capabilities[modelId]
            }
        }
        
        // 3. Check local models (MLX/GGUF)
        if isLocalModel(modelId) {
            contextWindow = await getLocalModelContextSize(modelName: modelId)
        }
        
        // 4. Apply known defaults for popular models
        if contextWindow == nil {
            contextWindow = getDefaultContextWindow(for: modelId)
        }
        
        // Calculate maxCompletionTokens (typically reserve for output)
        if let context = contextWindow {
            // Reserve 25% for output, 75% for input (reasonable default)
            maxCompletionTokens = context / 4
        }
        
        // Calculate maxRequestTokens (input limit)
        let maxRequestTokens: Int? = if let context = contextWindow, let completion = maxCompletionTokens {
            context - completion
        } else {
            nil
        }
        
        return (contextWindow, maxCompletionTokens, maxRequestTokens, isPremium, premiumMultiplier)
    }
    
    /// Get default context window for known model patterns
    private func getDefaultContextWindow(for modelId: String) -> Int? {
        let normalized = modelId.lowercased()
        
        // GitHub Copilot models
        if normalized.contains("gpt-4.1") || normalized.contains("gpt-4-turbo") {
            return 128_000  // 128k
        }
        if normalized.contains("gpt-4o") {
            return 128_000  // 128k
        }
        if normalized.contains("gpt-4") {
            return 8_192    // 8k for base GPT-4
        }
        if normalized.contains("gpt-3.5-turbo") {
            return 16_385   // 16k
        }
        if normalized.contains("o1") || normalized.contains("o3") {
            return 200_000  // 200k for reasoning models
        }
        
        // Anthropic models
        if normalized.contains("claude-3.5") || normalized.contains("claude-3-5") {
            return 200_000  // 200k
        }
        if normalized.contains("claude-3") {
            return 200_000  // 200k for Claude 3 family
        }
        
        // Gemini models
        if normalized.contains("gemini-2") || normalized.contains("gemini-1.5") {
            return 2_000_000  // 2M tokens
        }
        if normalized.contains("gemini") {
            return 1_000_000  // 1M default for Gemini
        }
        
        // DeepSeek models
        if normalized.contains("deepseek") {
            return 64_000  // 64k
        }
        
        // OpenAI models
        if normalized.contains("openai/gpt") {
            return 128_000  // Default to newer models
        }
        
        return nil  // Unknown model
    }

    /// Get billing information for a specific GitHub Copilot model
    /// Returns (isPremium, multiplier) tuple or nil if not available
    /// Cached for 10 minutes to reduce log spam and provider calls
    public func getGitHubCopilotModelBillingInfo(modelId: String) -> (isPremium: Bool, multiplier: Double?)? {
        /// Check cache first
        if let cached = billingCache[modelId] {
            /// Check if cache is still valid (within 10 minutes)
            if Date().timeIntervalSince(cached.timestamp) < billingCacheExpiration {
                return cached.result
            }
        }

        /// Cache miss or expired - fetch from provider
        guard let githubProvider = providers.values.first(where: { $0.config.providerType == .githubCopilot }) as? GitHubCopilotProvider else {
            /// Cache the nil result to avoid repeated provider lookups
            billingCache[modelId] = (result: nil, timestamp: Date())
            return nil
        }

        let result = githubProvider.getModelBillingInfo(modelId: modelId)

        /// Cache the result (whether nil or valid)
        billingCache[modelId] = (result: result, timestamp: Date())

        return result
    }

    /// Get current quota information from GitHub Copilot provider
    /// Returns quota info for display in UI, or nil if not available
    public func getGitHubCopilotQuotaInfo() -> GitHubCopilotProvider.QuotaInfo? {
        guard let githubProvider = providers.values.first(where: { $0.config.providerType == .githubCopilot }) as? GitHubCopilotProvider else {
            return nil
        }
        return githubProvider.currentQuotaInfo
    }

    /// Prefetch GitHub Copilot billing data in the background
    /// Called at startup and when providers are reloaded to ensure billing info is cached
    /// before the user opens the model picker
    public func prefetchGitHubCopilotBillingData() {
        Task {
            do {
                _ = try await getGitHubCopilotModelCapabilities()
                logger.debug("Successfully prefetched GitHub Copilot billing data")
            } catch {
                logger.debug("GitHub Copilot billing prefetch skipped: \(error.localizedDescription)")
            }
        }
    }

    /// Get max context size for a local model by reading its config files Returns context size in tokens, or nil if unable to determine.
    public func getLocalModelContextSize(modelName: String) async -> Int? {
        let modelsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sam/models")

        /// Model name might be just "Qwen3-8B-MLX-8bit" or full path "lmstudio-community/Qwen3-8B-MLX-8bit"
        /// We need to search all provider directories for the model config.
        let fileManager = FileManager.default

        /// First, try the modelName as a full path (if it contains a provider prefix)
        if modelName.contains("/") {
            let modelDir = modelsDir.appendingPathComponent(modelName)
            let fullConfigPath = modelDir.appendingPathComponent("config.json")

            /// Try MLX config.json first
            if fileManager.fileExists(atPath: fullConfigPath.path) {
                if let contextSize = readMLXConfigContextSize(from: fullConfigPath, modelName: modelName) {
                    return contextSize
                }
            }

            /// Check if this is a GGUF model directory (contains .gguf files)
            if fileManager.fileExists(atPath: modelDir.path) {
                if let ggufContextSize = checkForGGUFModel(in: modelDir, modelName: modelName) {
                    return ggufContextSize
                }
            }
        }

        /// Search all provider directories for the model
        do {
            let providers = try fileManager.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: [.isDirectoryKey])
            for providerDir in providers {
                guard providerDir.hasDirectoryPath else { continue }
                /// Skip hidden directories
                guard !providerDir.lastPathComponent.hasPrefix(".") else { continue }

                /// Check if this provider has a model matching our modelName
                let strippedModelName = modelName.components(separatedBy: "/").last ?? modelName
                let modelDir = providerDir.appendingPathComponent(strippedModelName)
                let configPath = modelDir.appendingPathComponent("config.json")

                if fileManager.fileExists(atPath: configPath.path) {
                    if let contextSize = readMLXConfigContextSize(from: configPath, modelName: modelName) {
                        return contextSize
                    }
                }

                /// Check if it's a GGUF model
                if fileManager.fileExists(atPath: modelDir.path) {
                    if let ggufContextSize = checkForGGUFModel(in: modelDir, modelName: modelName) {
                        return ggufContextSize
                    }
                }

                /// Also check for subdirectories matching model name (case-insensitive)
                if let subDirs = try? fileManager.contentsOfDirectory(at: providerDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                    for subDir in subDirs {
                        if subDir.lastPathComponent.lowercased() == strippedModelName.lowercased() {
                            let configPath = subDir.appendingPathComponent("config.json")
                            if fileManager.fileExists(atPath: configPath.path) {
                                if let contextSize = readMLXConfigContextSize(from: configPath, modelName: modelName) {
                                    return contextSize
                                }
                            }
                            /// Check for GGUF files in this subdirectory
                            if let ggufContextSize = checkForGGUFModel(in: subDir, modelName: modelName) {
                                return ggufContextSize
                            }
                        }
                    }
                }
            }
        } catch {
            logger.warning("LOCAL_MODEL_CONTEXT: Failed to enumerate model directories: \(error)")
        }

        /// Try GGUF model - check if file name ends in .gguf
        if modelName.lowercased().hasSuffix(".gguf") {
            logger.debug("LOCAL_MODEL_CONTEXT: GGUF model \(modelName) - using default 32768 (32k) tokens")
            return 32768
        }

        logger.warning("LOCAL_MODEL_CONTEXT: Unable to determine context size for \(modelName)")
        return nil
    }

    /// Check if a directory contains GGUF files and return default context size
    private func checkForGGUFModel(in directory: URL, modelName: String) -> Int? {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }

        let ggufFiles = contents.filter { $0.pathExtension.lowercased() == "gguf" }
        if !ggufFiles.isEmpty {
            /// GGUF model found - use a reasonable default
            /// Most modern models (Qwen3, Llama 3, Mistral) support 32k+ context
            /// Using 32k as safe default - user can adjust via optimization presets
            logger.debug("LOCAL_MODEL_CONTEXT: Found GGUF model in \(directory.lastPathComponent) - using 32768 (32k) tokens default")
            return 32768
        }
        return nil
    }

    /// Helper to read max_position_embeddings from MLX config.json
    private func readMLXConfigContextSize(from configPath: URL, modelName: String) -> Int? {
        do {
            let data = try Data(contentsOf: configPath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let maxPos = json["max_position_embeddings"] as? Int {
                logger.debug("LOCAL_MODEL_CONTEXT: Read \(modelName) context size: \(maxPos) tokens from MLX config at \(configPath.path)")
                return maxPos
            }
        } catch {
            logger.warning("LOCAL_MODEL_CONTEXT: Failed to read MLX config for \(modelName): \(error)")
        }
        return nil
    }

    /// Check if a model is a local model (MLX or GGUF) Returns true for local models, false for API-based models.
    public func isLocalModel(_ modelId: String) -> Bool {
        /// LoRA adapters are always local
        if modelId.hasPrefix("lora/") {
            return true
        }
        
        guard let providerType = getProviderTypeForModel(modelId) else {
            return false
        }

        /// Check if it's an MLX or Llama provider.
        return providerType.contains("MLXProvider") || providerType.contains("LlamaProvider")
    }

    /// Load a local model into memory and return its capabilities.
    public func loadLocalModel(_ modelId: String) async throws -> ModelCapabilities {
        logger.info("ENDPOINT_MANAGER: Loading local model: \(modelId)")

        guard let provider = providers[modelId] else {
            logger.error("ENDPOINT_MANAGER: No provider found for modelId: \(modelId)")
            logger.debug("ENDPOINT_MANAGER: Available providers: \(providers.keys.joined(separator: ", "))")
            throw EndpointManagerError.noProviderAvailable(model: modelId)
        }

        logger.debug("ENDPOINT_MANAGER: Found provider: \(type(of: provider)) for model: \(modelId)")

        /// Update loading state.
        await MainActor.run {
            modelLoadingStatus[modelId] = .loading(modelName: modelId)
            isAnyModelLoading = true
            currentLoadingModelName = modelId
            objectWillChange.send()
        }

        do {
            let capabilities = try await provider.loadModel()

            /// Update state to loaded.
            await MainActor.run {
                modelLoadingStatus[modelId] = .loaded
                isAnyModelLoading = false
                currentLoadingModelName = nil
                objectWillChange.send()
            }

            logger.debug("ENDPOINT_MANAGER: Model loaded successfully: \(modelId)")
            return capabilities
        } catch {
            /// Reset state on error.
            await MainActor.run {
                modelLoadingStatus[modelId] = .notLoaded
                isAnyModelLoading = false
                currentLoadingModelName = nil
                objectWillChange.send()
            }

            logger.error("ENDPOINT_MANAGER: Failed to load model \(modelId): \(error)")
            throw error
        }
    }

    /// Eject (unload) a local model from memory.
    public func ejectLocalModel(_ modelId: String) async {
        logger.info("ENDPOINT_MANAGER: Ejecting local model: \(modelId)")

        guard let provider = providers[modelId] else {
            logger.warning("ENDPOINT_MANAGER: No provider found for model: \(modelId)")
            return
        }

        await provider.unload()
        await MainActor.run {
            modelLoadingStatus[modelId] = .notLoaded
            objectWillChange.send()
        }

        logger.info("ENDPOINT_MANAGER: Model ejected: \(modelId)")
    }

    /// Get the loading status of a model.
    public func getModelLoadingStatus(_ modelId: String) async -> Bool {
        guard let provider = providers[modelId] else {
            return false
        }

        return await provider.getLoadedStatus()
    }

    /// Process NON-STREAMING chat completion (INTERNAL USE ONLY) ERROR: WARNING: This is for internal tool processing only, NOT user-facing responses SAM uses streaming-first architecture - user responses should use processStreamingChatCompletion.
    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        let requestId = UUID().uuidString.prefix(8)
        logger.warning("ENDPOINT_MANAGER: NON-STREAMING request [req:\(requestId)] - internal use only for model: \(request.model)")
        logger.error("ENDPOINT_MANAGER_DEBUG: Processing chat completion [req:\(requestId)] for model: \(request.model)")

        /// Debug: List all available providers and their models.
        logger.error("ENDPOINT_MANAGER_DEBUG: Available providers: \(self.providers.keys.sorted().joined(separator: ", "))")
        for (id, provider) in self.providers where provider.config.isEnabled {
            logger.error("ENDPOINT_MANAGER_DEBUG: Provider \(id) supports models: \(provider.config.models.joined(separator: ", "))")
        }

        guard let provider = try await selectProvider(for: request.model, requestId: String(requestId)) else {
            logger.error("ENDPOINT_MANAGER_DEBUG: No provider available for model: \(request.model)")
            throw EndpointManagerError.noProviderAvailable(model: request.model)
        }

        logger.error("ENDPOINT_MANAGER_DEBUG: Selected provider \(provider.identifier) (type: \(type(of: provider))) for model: \(request.model)")

        do {
            let response = try await provider.processChatCompletion(request)
            logger.debug("Successfully processed request [req:\(requestId)] via \(provider.identifier)")
            return response
        } catch {
            logger.error("Provider \(provider.identifier) failed for request [req:\(requestId)]: \(error)")

            /// Try fallback providers.
            if let fallbackProvider = try await selectFallbackProvider(for: request.model, excluding: provider.identifier, requestId: String(requestId)) {
                logger.debug("Attempting fallback to \(fallbackProvider.identifier) for request [req:\(requestId)]")
                return try await fallbackProvider.processChatCompletion(request)
            }

            throw error
        }
    }

    /// Process streaming chat completion request with automatic provider routing ARCHITECTURAL DESIGN: This method implements the core streaming logic for SAM's provider architecture.
    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        let requestId = UUID().uuidString.prefix(8)
        logger.debug("Processing streaming chat completion [req:\(requestId)] with provider-level streaming")

        guard let provider = try await selectProvider(for: request.model, requestId: String(requestId)) else {
            throw EndpointManagerError.noProviderAvailable(model: request.model)
        }

        logger.debug("Selected provider \(provider.identifier) for streaming model: \(request.model)")

        do {
            return try await provider.processStreamingChatCompletion(request)
        } catch {
            logger.error("Provider \(provider.identifier) failed for streaming request [req:\(requestId)]: \(error)")

            /// Try fallback providers for streaming.
            if let fallbackProvider = try await selectFallbackProvider(for: request.model, excluding: provider.identifier, requestId: String(requestId)) {
                logger.debug("Attempting streaming fallback to \(fallbackProvider.identifier) for request [req:\(requestId)]")
                return try await fallbackProvider.processStreamingChatCompletion(request)
            }

            throw error
        }
    }

    /// Get list of available models from all providers.
    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        var allModels: [ServerOpenAIModel] = []

        for (_, provider) in providers {
            do {
                let providerModels = try await provider.getAvailableModels()

                /// For remote providers (OpenAI, Anthropic, etc.), prefix models with normalized provider name For local providers, they already return provider/model format.
                let providerType = provider.config.providerType
                let shouldPrefixModels = ![.localLlama, .localMLX].contains(providerType)

                if shouldPrefixModels {
                    let normalizedProviderName = providerType.normalizedProviderName
                    let prefixedModels = providerModels.data.map { model -> ServerOpenAIModel in
                        /// Only prefix if not already prefixed.
                        let newId = model.id.contains("/") ? model.id : "\(normalizedProviderName)/\(model.id)"
                        return ServerOpenAIModel(
                            id: newId,
                            object: model.object,
                            created: model.created,
                            ownedBy: model.ownedBy
                        )
                    }
                    allModels.append(contentsOf: prefixedModels)
                } else {
                    allModels.append(contentsOf: providerModels.data)
                }
            } catch {
                logger.warning("Failed to get models from \(provider.identifier): \(error)")
                /// Continue with other providers.
            }
        }

        logger.info("Retrieved \(allModels.count) total models from \(self.providers.count) providers")

        return ServerOpenAIModelsResponse(
            object: "list",
            data: allModels.sorted { $0.id < $1.id }
        )
    }

    /// Update provider configuration and reload if necessary.
    public func updateProviderConfiguration(_ config: ProviderConfiguration, for providerId: String) {
        logger.debug("Updating configuration for provider: \(providerId)")

        providerConfigs[providerId] = config
        saveProviderConfiguration(config, for: providerId)

        /// Recreate provider with new configuration.
        if let providerType = getProviderType(for: providerId) {
            providers[providerId] = createProvider(type: providerType, config: config)
            logger.debug("Recreated provider \(providerId) with updated configuration")
        }
    }

    // MARK: - Provider Management

    private func setupProviders() {
        logger.debug("Setting up AI providers")

        /// Initialize local model manager.
        localModelManager = LocalModelManager()

        /// Migrate existing models to type/provider/model structure.
        if localModelManager != nil {
            /// Models have already been migrated to provider/model structure by migrate_models.sh No need for runtime migration anymore.
        }

        /// Load providers from configuration or create defaults.
        logger.debug("Loading providers with default configurations")
        for providerType in ProviderType.allCases {
            let providerId = providerType.defaultIdentifier
            logger.debug("Setting up provider: \(providerId)")

            /// Load saved configuration or create default.
            var config = loadProviderConfiguration(for: providerId) ?? createDefaultConfiguration(for: providerType)

            /// For local llama, populate models from LocalModelManager.
            if providerType == .localLlama, let modelManager = localModelManager {
                config.models = modelManager.getAvailableModels()
                logger.debug("Found \(config.models.count) local GGUF models")
            }

            /// Only create provider if it has API key or doesn't require one.
            let requiresKey = providerType.requiresApiKey
            if !requiresKey || config.apiKey != nil {
                /// For local llama, create one provider per model using registry identifiers.
                if providerType == .localLlama {
                    if let modelManager = localModelManager {
                        let registryModels = modelManager.getAllRegistryModels()
                        /// Filter for GGUF files only (llama.cpp provider).
                        let ggufModels = registryModels.filter { $0.path.lowercased().hasSuffix(".gguf") }
                        if ggufModels.isEmpty {
                            logger.warning("Local llama provider enabled but no GGUF models found in registry at \(LocalModelManager.modelsDirectory.path)")
                        } else {
                            logger.debug("Found \(ggufModels.count) GGUF models for llama.cpp provider (filtered from \(registryModels.count) total)")
                            for model in ggufModels {
                                let providerIdentifier = model.identifier
                                /// Create provider-specific config with single model.
                                let providerSpecificConfig = ProviderConfiguration(
                                    providerId: providerIdentifier,
                                    providerType: .localLlama,
                                    isEnabled: config.isEnabled,
                                    baseURL: nil,
                                    models: [providerIdentifier],
                                    maxTokens: config.maxTokens,
                                    temperature: config.temperature,
                                    customHeaders: config.customHeaders,
                                    timeoutSeconds: config.timeoutSeconds,
                                    retryCount: config.retryCount
                                )
                                let provider = LlamaProvider(
                                    config: providerSpecificConfig,
                                    modelPath: model.path,
                                    onModelLoadingStarted: { @MainActor [weak self] providerId, modelName in
                                        self?.notifyModelLoadingStarted(providerId: providerId, modelName: modelName)
                                    },
                                    onModelLoadingCompleted: { @MainActor [weak self] providerId in
                                        self?.notifyModelLoadingCompleted(providerId: providerId)
                                    }
                                )
                                providers[providerIdentifier] = provider
                                logger.debug("Local GGUF model provider loaded: \(providerIdentifier) at \(model.path)")
                            }
                        }
                    } else {
                        logger.error("Local llama provider requested but LocalModelManager not initialized")
                    }
                /// For local MLX, create one provider per model using registry identifiers.
                } else if providerType == .localMLX {
                    if let modelManager = localModelManager {
                        let registryModels = modelManager.getAllRegistryModels()
                        /// Filter for SafeTensors files and diffusers directories (MLX provider).
                        let mlxModels = registryModels.filter {
                            $0.path.lowercased().hasSuffix(".safetensors") ||
                            $0.quantization == "diffusers"
                        }
                        if mlxModels.isEmpty {
                            logger.warning("Local MLX provider enabled but no SafeTensors or diffusers models found in registry at \(LocalModelManager.modelsDirectory.path)")
                        } else {
                            logger.debug("Found \(mlxModels.count) models for MLX provider (filtered from \(registryModels.count) total)")
                            for model in mlxModels {
                                let providerIdentifier = model.identifier
                                /// Create provider-specific config with single model.
                                let providerSpecificConfig = ProviderConfiguration(
                                    providerId: providerIdentifier,
                                    providerType: .localMLX,
                                    isEnabled: config.isEnabled,
                                    baseURL: nil,
                                    models: [providerIdentifier],
                                    maxTokens: config.maxTokens,
                                    temperature: config.temperature,
                                    customHeaders: config.customHeaders,
                                    timeoutSeconds: config.timeoutSeconds,
                                    retryCount: config.retryCount
                                )
                                /// For MLX models: Use parent directory (not individual file path)
                                /// For diffusers models: Path is already the directory
                                /// For safetensors files: Use parent directory containing all model files
                                let modelDirectory: String
                                if model.quantization == "diffusers" {
                                    /// Path is already the model directory
                                    modelDirectory = model.path
                                } else {
                                    /// For .safetensors files, get parent directory
                                    modelDirectory = URL(fileURLWithPath: model.path).deletingLastPathComponent().path
                                }
                                let provider = MLXProvider(
                                    config: providerSpecificConfig,
                                    modelPath: modelDirectory,
                                    onModelLoadingStarted: { @MainActor [weak self] providerId, modelName in
                                        self?.notifyModelLoadingStarted(providerId: providerId, modelName: modelName)
                                    },
                                    onModelLoadingCompleted: { @MainActor [weak self] providerId in
                                        self?.notifyModelLoadingCompleted(providerId: providerId)
                                    }
                                )
                                providers[providerIdentifier] = provider
                                logger.debug("Local model provider loaded: \(providerIdentifier) (\(model.quantization)) at \(modelDirectory)")
                            }
                        }
                    } else {
                        logger.error("Local MLX provider requested but LocalModelManager not initialized")
                    }
                } else {
                    providers[providerId] = createProvider(type: providerType, config: config)
                    logger.debug("Provider \(providerId) loaded with \(config.models.count) models (enabled: \(config.isEnabled))")
                }
            } else {
                logger.debug("Provider \(providerId) not loaded - requires API key")
            }
        }

        logger.debug("Setup complete. Active providers: \(self.providers.keys.sorted().joined(separator: ", "))")
    }

    /// Fetch model capabilities from GitHub Copilot /models API and update TokenCounter This provides accurate context sizes for all GitHub Copilot models.
    private func fetchGitHubCopilotModelCapabilities() async {
        logger.debug("Fetching model capabilities from GitHub Copilot API")

        /// Find GitHub Copilot provider.
        guard let githubProvider = providers.values.first(where: { $0.config.providerType == .githubCopilot }) as? GitHubCopilotProvider else {
            logger.warning("GitHub Copilot provider not available - skipping model capabilities fetch")
            return
        }

        do {
            let capabilities = try await githubProvider.fetchModelCapabilities()

            /// Get tokenCounter from AgentOrchestrator We need to pass this to AgentOrchestrator's tokenCounter.
            logger.debug("Fetched capabilities for \(capabilities.count) models from GitHub Copilot API")

            /// Log API-provided context sizes (especially important discrepancies).
            for (modelId, contextSize) in capabilities.sorted(by: { $0.key < $1.key }) {
                logger.debug("  Model '\(modelId)': \(contextSize) tokens (from API)")

                /// Highlight important discrepancies.
                if modelId.contains("claude-3.5") && contextSize != 200000 {
                    logger.warning("  claude-3.5-sonnet: API reports \(contextSize) tokens (not hardcoded 200k!)")
                }
            }

            /// Note: TokenCounter instance is in AgentOrchestrator We'll need to update AgentOrchestrator to call this.

        } catch {
            logger.error("Failed to fetch GitHub Copilot model capabilities: \(error)")
            logger.warning("Falling back to hardcoded context sizes")
        }
    }

    private func createDefaultConfiguration(for providerType: ProviderType) -> ProviderConfiguration {
        logger.debug("Creating default configuration for \(providerType.defaultIdentifier)")

        switch providerType {
        case .githubCopilot:
            return ProviderConfiguration(
                providerId: "github-copilot",
                providerType: .githubCopilot,
                isEnabled: false,
                baseURL: "https://api.githubcopilot.com",
                models: []
            )

        case .openai:
            return ProviderConfiguration(
                providerId: "openai",
                providerType: .openai,
                isEnabled: false,
                baseURL: "https://api.openai.com/v1",
                models: []
            )

        case .anthropic:
            return ProviderConfiguration(
                providerId: "anthropic",
                providerType: .anthropic,
                isEnabled: false,
                baseURL: "https://api.anthropic.com/v1",
                models: []
            )

        case .deepseek:
            return ProviderConfiguration(
                providerId: "deepseek",
                providerType: .deepseek,
                isEnabled: false,
                baseURL: "https://api.deepseek.com/v1",
                models: []
            )

        case .gemini:
            return ProviderConfiguration(
                providerId: "gemini",
                providerType: .gemini,
                isEnabled: false,
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                models: []
            )

        case .localLlama:
            return ProviderConfiguration(
                providerId: "local-llama",
                providerType: .localLlama,
                isEnabled: true,
                baseURL: nil,
                models: []
            )

        case .localMLX:
            return ProviderConfiguration(
                providerId: "local-mlx",
                providerType: .localMLX,
                isEnabled: true,
                baseURL: nil,
                models: []
            )

        case .custom:
            return ProviderConfiguration(
                providerId: "custom",
                providerType: .custom,
                isEnabled: false,
                baseURL: nil,
                models: []
            )
        }
    }

    private func createProvider(type: ProviderType, config: ProviderConfiguration) -> AIProvider? {
        switch type {
        case .openai:
            return OpenAIProvider(config: config)

        case .anthropic:
            return AnthropicProvider(config: config)

        case .githubCopilot:
            return GitHubCopilotProvider(config: config)

        case .deepseek:
            return DeepSeekProvider(config: config)

        case .gemini:
            return GeminiProvider(config: config)

        case .localLlama:
            /// Local llama providers must specify model path - use addLocalModelProvider() instead.
            /// Don't crash - log error and skip this provider.
            logger.error("ENDPOINT_ERROR: local-llama provider '\(config.providerId)' in ConfiguredEndpoints is invalid")
            logger.error("ENDPOINT_ERROR: Local llama providers must be added via LocalModelManager.addLocalModelProvider()")
            logger.error("ENDPOINT_ERROR: Skipping this provider - please reconfigure through Preferences UI")
            return nil

        case .localMLX:
            /// Local MLX providers must specify model path - use addLocalModelProvider() instead.
            /// Don't crash - log error and skip this provider.
            logger.error("ENDPOINT_ERROR: local-mlx provider '\(config.providerId)' in ConfiguredEndpoints is invalid")
            logger.error("ENDPOINT_ERROR: Local MLX providers must be added via LocalModelManager.addLocalModelProvider()")
            logger.error("ENDPOINT_ERROR: Skipping this provider - please reconfigure through Preferences UI")
            return nil

        case .custom:
            return CustomProvider(config: config)
        }
    }
    // MARK: - Provider Selection

    private func selectProvider(for model: String, requestId: String) async throws -> AIProvider? {
        logger.debug("SELECT_PROVIDER: Searching for provider for model '\(model)' [req:\(requestId)]")

        /// Handle provider-prefixed models: "github_copilot/gpt-4" → provider="github_copilot", modelName="gpt-4" Local models use full path matching: "lmstudio-community_Qwen2.5-Coder-7B-Instruct-MLX-4bit".
        let (providerHint, modelForMatching): (String?, String)

        if model.contains("/") {
            let parts = model.components(separatedBy: "/")
            if parts.count == 2 {
                /// Format: "provider/model" - extract both parts.
                providerHint = parts[0]
                modelForMatching = parts[1]
                logger.debug("SELECT_PROVIDER: Detected provider hint '\(providerHint!)' for model '\(modelForMatching)' [req:\(requestId)]")
            } else {
                /// Unusual format, use full string.
                providerHint = nil
                modelForMatching = model
            }
        } else {
            /// No provider prefix, use model name as-is.
            providerHint = nil
            modelForMatching = model
        }

        /// If we have a provider hint, try to find that specific provider first.
        if let hint = providerHint, let provider = providers[hint] {
            if provider.config.isEnabled && provider.config.models.contains(modelForMatching) {
                logger.debug("Found provider '\(hint)' for model '\(modelForMatching)' via provider hint [req:\(requestId)]")

                /// Handle local model switching with proper unloading.
                if let llamaProvider = provider as? LlamaProvider {
                    logger.debug("PROVIDER_TYPE: LlamaProvider detected, calling handleLocalModelSwitch")
                    await handleLocalModelSwitch(to: provider.identifier, provider: llamaProvider)
                } else if let mlxProvider = provider as? MLXProvider {
                    logger.debug("PROVIDER_TYPE: MLXProvider detected, calling handleLocalModelSwitch")
                    await handleLocalModelSwitch(to: provider.identifier, provider: mlxProvider)
                } else {
                    logger.debug("PROVIDER_TYPE: Remote provider (\(type(of: provider)))")
                }

                return provider
            } else {
                logger.warning("Provider hint '\(hint)' found but doesn't support model '\(modelForMatching)' [req:\(requestId)]")
            }
        }

        /// Check for direct model mapping (for models without provider prefix or when hint didn't work).
        for provider in providers.values {
            if provider.config.isEnabled && provider.config.models.contains(modelForMatching) {
                logger.debug("Found direct provider \(provider.identifier) for model \(modelForMatching) [req:\(requestId)]")

                /// Handle local model switching with proper unloading.
                if let llamaProvider = provider as? LlamaProvider {
                    logger.debug("PROVIDER_TYPE: LlamaProvider detected, calling handleLocalModelSwitch")
                    await handleLocalModelSwitch(to: provider.identifier, provider: llamaProvider)
                } else if let mlxProvider = provider as? MLXProvider {
                    logger.debug("PROVIDER_TYPE: MLXProvider detected, calling handleLocalModelSwitch")
                    await handleLocalModelSwitch(to: provider.identifier, provider: mlxProvider)
                } else {
                    logger.debug("PROVIDER_TYPE: Remote provider (\(type(of: provider)))")
                }

                return provider
            }
        }

        /// Check for pattern matching (e.g., "gpt-*" -> OpenAI).
        let matchedProviders = providers.values.filter { provider in
            provider.config.isEnabled && provider.supportsModel(model)
        }

        if matchedProviders.isEmpty {
            logger.warning("No provider found for model \(model) [req:\(requestId)]")
            return nil
        }

        /// Use load balancer for multiple matches.
        let selectedProvider = await loadBalancer.selectProvider(from: matchedProviders)
        logger.debug("Load balancer selected \(selectedProvider.identifier) for model \(model) [req:\(requestId)]")

        /// Handle local model switching with proper unloading.
        if let llamaProvider = selectedProvider as? LlamaProvider {
            await handleLocalModelSwitch(to: selectedProvider.identifier, provider: llamaProvider)
        } else if let mlxProvider = selectedProvider as? MLXProvider {
            await handleLocalModelSwitch(to: selectedProvider.identifier, provider: mlxProvider)
        }

        return selectedProvider
    }

    /// Handle switching between local models with proper resource cleanup CRITICAL: Prevents multiple models from being loaded simultaneously (causes swap usage).
    private func handleLocalModelSwitch(to newIdentifier: String, provider: LlamaProvider) async {
        /// Check if we're switching to a different local model.
        if let (activeId, activeProvider) = activeLocalProvider {
            if activeId != newIdentifier {
                logger.debug("MODEL_SWITCH: Unloading \(activeId) before loading \(newIdentifier)")
                if let llamaProv = activeProvider as? LlamaProvider {
                    await llamaProv.unload()
                } else if let mlxProv = activeProvider as? MLXProvider {
                    await mlxProv.unload()
                }
                activeLocalProvider = (newIdentifier, provider)
            } else {
                logger.debug("MODEL_SWITCH: Same model \(newIdentifier), no unload needed")
            }
        } else {
            logger.debug("MODEL_SWITCH: First local model load: \(newIdentifier)")
            activeLocalProvider = (newIdentifier, provider)
        }
    }

    /// Handle switching between MLX models with proper resource cleanup.
    private func handleLocalModelSwitch(to newIdentifier: String, provider: MLXProvider) async {
        /// Check if we're switching to a different local model.
        if let (activeId, activeProvider) = activeLocalProvider {
            if activeId != newIdentifier {
                logger.debug("MODEL_SWITCH: Unloading \(activeId) before loading \(newIdentifier)")
                if let llamaProv = activeProvider as? LlamaProvider {
                    await llamaProv.unload()
                } else if let mlxProv = activeProvider as? MLXProvider {
                    await mlxProv.unload()
                }
                activeLocalProvider = (newIdentifier, provider)
            } else {
                logger.debug("MODEL_SWITCH: Same model \(newIdentifier), no unload needed")
            }
        } else {
            logger.debug("MODEL_SWITCH: First local model load: \(newIdentifier)")
            activeLocalProvider = (newIdentifier, provider)
        }
    }

    /// Cancel ongoing generation for local models (called when user presses stop).
    public func cancelLocalModelGeneration() async {
        if let (identifier, provider) = activeLocalProvider {
            logger.debug("CANCEL_LOCAL_GENERATION: Cancelling generation for \(identifier)")
            if let llamaProv = provider as? LlamaProvider {
                await llamaProv.cancelGeneration()
            } else if let mlxProv = provider as? MLXProvider {
                await mlxProv.cancelGeneration()
            }
        }
    }

    /// Get the identifier of the currently active local model provider (if any).
    public func getActiveLocalModelIdentifier() -> String? {
        return activeLocalProvider?.identifier
    }

    /// Unload all local models (called on app cleanup or manual memory management).
    public func unloadAllLocalModels() async {
        logger.debug("UNLOAD_ALL_LOCAL: Unloading all local model providers")
        for (identifier, provider) in providers {
            if let llamaProvider = provider as? LlamaProvider {
                logger.debug("Unloading llama model: \(identifier)")
                await llamaProvider.unload()
            } else if let mlxProvider = provider as? MLXProvider {
                logger.debug("Unloading MLX model: \(identifier)")
                await mlxProvider.unload()
            }
        }
        activeLocalProvider = nil
    }

    private func selectFallbackProvider(for model: String, excluding excludedProviderId: String, requestId: String) async throws -> AIProvider? {
        /// Check fallback chain configuration.
        if let fallbackIds = fallbackChains[model] ?? fallbackChains["*"] {
            for fallbackId in fallbackIds {
                if fallbackId != excludedProviderId,
                   let fallbackProvider = providers[fallbackId],
                   fallbackProvider.config.isEnabled && fallbackProvider.supportsModel(model) {
                    logger.debug("Using fallback provider \(fallbackId) for model \(model) [req:\(requestId)]")
                    return fallbackProvider
                }
            }
        }

        /// If no specific fallback chain, try any other suitable provider.
        for provider in providers.values {
            if provider.identifier != excludedProviderId &&
               provider.config.isEnabled &&
               provider.supportsModel(model) {
                logger.debug("Using general fallback provider \(provider.identifier) for model \(model) [req:\(requestId)]")
                return provider
            }
        }

        return nil
    }

    // MARK: - Configuration Management

    private func loadProviderConfigurations() {
        logger.debug("Loading provider configurations from UserDefaults")

        for providerType in ProviderType.allCases {
            let providerId = providerType.defaultIdentifier
            if let config = loadProviderConfiguration(for: providerId) {
                providerConfigs[providerId] = config
                logger.debug("Loaded configuration for \(providerId)")
            }
        }

        /// Load fallback chains.
        if let fallbackData = UserDefaults.standard.data(forKey: "providerFallbackChains"),
           let chains = try? JSONDecoder().decode([String: [String]].self, from: fallbackData) {
            fallbackChains = chains
            logger.debug("Loaded fallback chains for \(chains.count) models/patterns")
        }
    }

    private func loadProviderConfiguration(for providerId: String) -> ProviderConfiguration? {
        let key = "provider_config_\(providerId)"
        logger.debug("Looking for UserDefaults key: \(key)")

        guard let data = UserDefaults.standard.data(forKey: key) else {
            logger.debug("No data found in UserDefaults for key: \(key)")
            return nil
        }

        guard let config = try? JSONDecoder().decode(ProviderConfiguration.self, from: data) else {
            logger.error("Failed to decode config data for key: \(key)")
            return nil
        }

        logger.debug("Successfully loaded config for \(providerId): \(config.models.count) models")
        return config
    }

    private func saveProviderConfiguration(_ config: ProviderConfiguration, for providerId: String) {
        let key = "provider_config_\(providerId)"

        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
            logger.debug("Saved configuration for provider \(providerId)")
        } else {
            logger.error("Failed to encode configuration for provider \(providerId)")
        }
    }

    /// Get provider instance by ID Used for dynamic model capability fetching.
    public func getProvider(id: String) -> AIProvider? {
        return providers[id]
    }

    private func getProviderType(for providerId: String) -> ProviderType? {
        return ProviderType.allCases.first { $0.defaultIdentifier == providerId }
    }

    /// Reload provider configurations from UserDefaults Call this when provider configurations are updated from the preferences CRITICAL PATTERN: This method ensures consistency between API server and UI components.
    public func reloadProviderConfigurations() {
        logger.debug("Reloading provider configurations...")

        /// No longer manually scanning for models here - the file system watcher in LocalModelManager handles this automatically.

        /// Clear billing cache when providers are reloaded
        billingCache.removeAll()
        logger.debug("Cleared billing cache (provider reload)")

        /// Clear ALL providers including local models - we'll recreate them from current registry
        /// This enables hot reload when new local models are downloaded
        providers.removeAll()
        logger.debug("Cleared all providers for rebuild")

        /// Load providers using default identifiers.
        for providerType in ProviderType.allCases {
            let providerId = providerType.defaultIdentifier

            /// Load saved configuration or create default.
            var config = loadProviderConfiguration(for: providerId) ?? createDefaultConfiguration(for: providerType)

            /// For local llama, populate models from LocalModelManager.
            if providerType == .localLlama, let modelManager = localModelManager {
                config.models = modelManager.getAvailableModels()
                logger.debug("Found \(config.models.count) local GGUF models")
            }

            /// Only create provider if it has API key or doesn't require one.
            let requiresKey = providerType.requiresApiKey
            if !requiresKey || config.apiKey != nil {
                /// For local llama, create one provider per model using registry identifiers.
                if providerType == .localLlama {
                    if let modelManager = localModelManager {
                        let registryModels = modelManager.getAllRegistryModels()
                        /// Filter for GGUF files only (llama.cpp provider).
                        let ggufModels = registryModels.filter { $0.path.lowercased().hasSuffix(".gguf") }
                        logger.debug("Hot reload: Found \(ggufModels.count) GGUF models for llama.cpp provider")
                        for model in ggufModels {
                            let providerIdentifier = model.identifier
                            /// Create provider-specific config with single model.
                            let providerSpecificConfig = ProviderConfiguration(
                                providerId: providerIdentifier,
                                providerType: .localLlama,
                                isEnabled: config.isEnabled,
                                baseURL: nil,
                                models: [providerIdentifier],
                                maxTokens: config.maxTokens,
                                temperature: config.temperature,
                                customHeaders: config.customHeaders,
                                timeoutSeconds: config.timeoutSeconds,
                                retryCount: config.retryCount
                            )
                            let provider = LlamaProvider(
                                config: providerSpecificConfig,
                                modelPath: model.path,
                                onModelLoadingStarted: { @MainActor [weak self] providerId, modelName in
                                    self?.notifyModelLoadingStarted(providerId: providerId, modelName: modelName)
                                },
                                onModelLoadingCompleted: { @MainActor [weak self] providerId in
                                    self?.notifyModelLoadingCompleted(providerId: providerId)
                                }
                            )
                            providers[providerIdentifier] = provider
                            logger.debug("Hot reload: Created GGUF model provider: \(providerIdentifier)")
                        }
                    }
                /// For local MLX, create one provider per model using registry identifiers.
                } else if providerType == .localMLX {
                    if let modelManager = localModelManager {
                        let registryModels = modelManager.getAllRegistryModels()
                        /// Filter for SafeTensors files and diffusers directories (MLX provider).
                        let mlxModels = registryModels.filter {
                            $0.path.lowercased().hasSuffix(".safetensors") ||
                            $0.quantization == "diffusers"
                        }
                        logger.debug("Hot reload: Found \(mlxModels.count) SafeTensors/diffusers models for MLX provider")
                        for model in mlxModels {
                            let providerIdentifier = model.identifier
                            /// Create provider-specific config with single model.
                            let providerSpecificConfig = ProviderConfiguration(
                                providerId: providerIdentifier,
                                providerType: .localMLX,
                                isEnabled: config.isEnabled,
                                baseURL: nil,
                                models: [providerIdentifier],
                                maxTokens: config.maxTokens,
                                temperature: config.temperature,
                                customHeaders: config.customHeaders,
                                timeoutSeconds: config.timeoutSeconds,
                                retryCount: config.retryCount
                            )
                            /// For MLX models: Use parent directory (not individual file path)
                            /// For diffusers models: Path is already the directory
                            /// For safetensors files: Use parent directory containing all model files
                            let modelDirectory: String
                            if model.quantization == "diffusers" {
                                /// Path is already the model directory
                                modelDirectory = model.path
                            } else {
                                /// For .safetensors files, get parent directory
                                modelDirectory = URL(fileURLWithPath: model.path).deletingLastPathComponent().path
                            }
                            let provider = MLXProvider(
                                config: providerSpecificConfig,
                                modelPath: modelDirectory,
                                onModelLoadingStarted: { @MainActor [weak self] providerId, modelName in
                                    self?.notifyModelLoadingStarted(providerId: providerId, modelName: modelName)
                                },
                                onModelLoadingCompleted: { @MainActor [weak self] providerId in
                                    self?.notifyModelLoadingCompleted(providerId: providerId)
                                }
                            )
                            providers[providerIdentifier] = provider
                            logger.debug("Hot reload: Created MLX model provider: \(providerIdentifier)")
                        }
                        
                        /// Also handle LoRA adapters (quantization == "lora")
                        let loraAdapters = registryModels.filter { $0.quantization == "lora" }
                        logger.debug("Hot reload: Found \(loraAdapters.count) LoRA adapters in registry")
                        
                        /// Also scan adapters directory for any unregistered adapters
                        let adaptersDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                            .appendingPathComponent("SAM/adapters")
                        if FileManager.default.fileExists(atPath: adaptersDir.path) {
                            let adapterDirs = (try? FileManager.default.contentsOfDirectory(at: adaptersDir, includingPropertiesForKeys: nil)) ?? []
                            for adapterDir in adapterDirs where adapterDir.hasDirectoryPath {
                                let adapterId = adapterDir.lastPathComponent
                                /// Check if already registered
                                if loraAdapters.contains(where: { $0.path == adapterDir.path }) {
                                    continue  // Already in registry
                                }
                                
                                /// Load metadata to get adapter name and base model
                                let metadataPath = adapterDir.appendingPathComponent("metadata.json")
                                guard let metadataData = try? Data(contentsOf: metadataPath),
                                      let metadataDict = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
                                      let adapterName = metadataDict["adapterName"] as? String,
                                      let baseModelId = metadataDict["baseModelId"] as? String else {
                                    logger.warning("Hot reload: Failed to load metadata for unregistered adapter: \(adapterId)")
                                    continue
                                }
                                
                                /// Register with LocalModelManager
                                modelManager.registerModel(
                                    provider: "lora",
                                    modelName: adapterId,
                                    path: adapterDir.path,
                                    sizeBytes: nil,
                                    quantization: "lora"
                                )
                                logger.debug("Hot reload: Registered unregistered LoRA adapter: \(adapterName)")
                            }
                        }
                        
                        /// Create providers for all LoRA adapters (both registry and newly discovered)
                        let allLoraAdapters = modelManager.getAllRegistryModels().filter { $0.quantization == "lora" }
                        for adapter in allLoraAdapters {
                            /// Parse adapter metadata to get base model
                            let adapterPath = URL(fileURLWithPath: adapter.path)
                            let metadataPath = adapterPath.appendingPathComponent("metadata.json")
                            guard let metadataData = try? Data(contentsOf: metadataPath),
                                  let metadataDict = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
                                  let baseModelId = metadataDict["baseModelId"] as? String,
                                  let adapterName = metadataDict["adapterName"] as? String else {
                                logger.warning("Hot reload: Failed to load metadata for adapter: \(adapter.identifier)")
                                continue
                            }
                            
                            /// Extract adapter UUID from path (last path component)
                            let adapterId = adapterPath.lastPathComponent
                            
                            /// Find base model in registry to get its path
                            guard let baseModel = registryModels.first(where: { $0.identifier == baseModelId }) else {
                                logger.warning("Hot reload: Base model not found for LoRA adapter: \(adapterName) (base: \(baseModelId))")
                                continue
                            }
                            
                            /// Create provider identifier for this LoRA adapter
                            /// Use lora/{uuid} format to match ModelListManager
                            let providerIdentifier = "lora/\(adapterId)"
                            
                            /// Create provider-specific config
                            let providerSpecificConfig = ProviderConfiguration(
                                providerId: providerIdentifier,
                                providerType: .localMLX,
                                isEnabled: config.isEnabled,
                                baseURL: nil,
                                models: [providerIdentifier],
                                maxTokens: config.maxTokens,
                                temperature: config.temperature,
                                customHeaders: config.customHeaders,
                                timeoutSeconds: config.timeoutSeconds,
                                retryCount: config.retryCount
                            )
                            
                            /// Get base model directory
                            let baseModelDirectory: String
                            if baseModel.quantization == "diffusers" {
                                baseModelDirectory = baseModel.path
                            } else {
                                baseModelDirectory = URL(fileURLWithPath: baseModel.path).deletingLastPathComponent().path
                            }
                            
                            /// Create MLXProvider with LoRA adapter ID
                            let provider = MLXProvider(
                                config: providerSpecificConfig,
                                modelPath: baseModelDirectory,
                                loraAdapterId: adapterId,  // Pass adapter UUID
                                onModelLoadingStarted: { @MainActor [weak self] providerId, modelName in
                                    self?.notifyModelLoadingStarted(providerId: providerId, modelName: modelName)
                                },
                                onModelLoadingCompleted: { @MainActor [weak self] providerId in
                                    self?.notifyModelLoadingCompleted(providerId: providerId)
                                }
                            )
                            providers[providerIdentifier] = provider
                            logger.debug("Hot reload: Created LoRA provider: \(providerIdentifier) (adapter: \(adapterName), base: \(baseModelId))")
                        }
                    }
                } else {
                    providers[providerId] = createProvider(type: providerType, config: config)
                    providerConfigs[providerId] = config
                    logger.debug("Recreated provider \(providerId) with updated configuration")
                }
            }
        }

        /// Also check saved_provider_ids for any custom provider IDs.
        if let savedProviderIds = UserDefaults.standard.stringArray(forKey: "saved_provider_ids") {
            for savedProviderId in savedProviderIds {
                /// Skip if we already loaded this provider.
                if providers[savedProviderId] != nil {
                    continue
                }

                /// Try to load configuration for this custom ID.
                if let config = loadProviderConfiguration(for: savedProviderId) {
                    providers[savedProviderId] = createProvider(type: config.providerType, config: config)
                    providerConfigs[savedProviderId] = config
                    logger.debug("Recreated custom provider \(savedProviderId) with updated configuration")
                }
            }
        }

        logger.debug("Provider reload complete. Active providers: \(self.providers.keys.sorted().joined(separator: ", "))")

        /// Prefetch GitHub Copilot billing data for the newly loaded providers
        prefetchGitHubCopilotBillingData()

        /// Post notification so UI components can update their model lists This enables hot-reloading without requiring SAM restart.
        NotificationCenter.default.post(name: .endpointManagerDidReloadProviders, object: self)
        logger.debug("Posted endpointManagerDidReloadProviders notification")
    }
}

// MARK: - Errors

enum EndpointManagerError: LocalizedError {
    case noProviderAvailable(model: String)
    case providerConfigurationError(String)
    case providerAuthenticationError(String)

    var errorDescription: String? {
        switch self {
        case .noProviderAvailable(let model):
            return "No provider available for model: \(model)"

        case .providerConfigurationError(let message):
            return "Provider configuration error: \(message)"

        case .providerAuthenticationError(let message):
            return "Provider authentication error: \(message)"
        }
    }
}

// MARK: - Protocol Conformance

extension EndpointManager: ConversationEngine.AIProviderProtocol {
    public func processStreamingChatCompletion(_ messages: [ConversationEngine.ChatMessage], model: String, temperature: Double, sessionId: String?) async throws -> AsyncThrowingStream<ConversationEngine.ChatResponseChunk, Error> {
        /// Convert ConversationEngine.ChatMessage to OpenAIChatMessage.
        let openAIMessages = messages.map { message in
            OpenAIChatMessage(role: message.role, content: message.content)
        }

        /// Create OpenAI request.
        let request = OpenAIChatRequest(
            model: model,
            messages: openAIMessages,
            temperature: temperature,
            maxTokens: nil,
            stream: true,
            tools: nil,
            samConfig: nil,
            contextId: sessionId,
            enableMemory: true,
            sessionId: sessionId
        )

        /// Call the existing streaming method.
        let openAIStream = try await processStreamingChatCompletion(request)

        /// Convert OpenAI stream to ConversationEngine format.
        return AsyncThrowingStream<ConversationEngine.ChatResponseChunk, Error> { continuation in
            Task {
                do {
                    for try await chunk in openAIStream {
                        if let content = chunk.choices.first?.delta.content {
                            let responseChunk = ConversationEngine.ChatResponseChunk(content: content)
                            continuation.yield(responseChunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Model Loading State Management

    /// Notify that a model is starting to load (call from provider before loading).
    @MainActor
    public func notifyModelLoadingStarted(providerId: String, modelName: String) {
        logger.debug("MODEL_LOADING_STARTED: \(modelName) (provider: \(providerId))")
        modelLoadingStatus[providerId] = .loading(modelName: modelName)
        /// Update simple boolean properties for UI reactivity.
        isAnyModelLoading = true
        currentLoadingModelName = modelName
        logger.debug("MODEL_LOADING: Set isAnyModelLoading=true, currentLoadingModelName=\(modelName)")

        /// Force SwiftUI update for dictionary change
        objectWillChange.send()
    }

    /// Notify that a model has finished loading (call from provider after loading).
    @MainActor
    public func notifyModelLoadingCompleted(providerId: String) {
        logger.debug("MODEL_LOADING_COMPLETED: provider \(providerId)")
        modelLoadingStatus[providerId] = .loaded
        /// Update simple boolean properties for UI reactivity.
        isAnyModelLoading = false
        currentLoadingModelName = nil
        logger.debug("MODEL_LOADING: Set isAnyModelLoading=false, currentLoadingModelName=nil")

        /// Force SwiftUI update for dictionary change
        objectWillChange.send()
    }

    /// Get current loading state for a provider.
    public func getModelLoadingState(providerId: String) -> ModelLoadingState {
        return modelLoadingStatus[providerId] ?? .notLoaded
    }

    /// Get the provider type (MLX, llama, etc.) for a given model identifier For local models, the model identifier IS the provider identifier Returns nil if model/provider not found.
    public func getProviderTypeForModel(_ modelId: String) -> String? {
        /// Strip provider prefix (e.g., "github_copilot/gpt-4.1" -> "gpt-4.1") This prevents "No provider found" warnings for prefixed model IDs.
        let modelWithoutPrefix = modelId.components(separatedBy: "/").last ?? modelId

        /// For local models, modelId == providerId, so check directly.
        if let provider = providers[modelId] {
            return String(describing: type(of: provider))
        }

        /// For remote models, check which provider has this model in its config Try both original modelId and stripped version.
        for (providerId, config) in providerConfigs {
            if config.models.contains(modelId) || config.models.contains(modelWithoutPrefix) {
                if let provider = providers[providerId] {
                    return String(describing: type(of: provider))
                }
            }
        }

        /// Only log warning if we couldn't find the model even after stripping prefix.
        if modelId == modelWithoutPrefix {
            logger.warning("No provider found for model: \(modelId)")
        }
        return nil
    }
}

// MARK: - Protocol Conformance

extension EndpointManager: EndpointManagerProtocol {
    public func getEndpointInfo() -> [[String: Any]] {
        return providerConfigs.map { (providerId, config) in
            [
                "providerId": providerId,
                "isEnabled": config.isEnabled,
                "models": config.models,
                "hasProvider": providers[providerId] != nil
            ]
        }
    }
}
