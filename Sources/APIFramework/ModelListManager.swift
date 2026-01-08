// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import SwiftUI
import Logging

private let logger = Logger(label: "com.sam.modellist")

/// Simple structure to represent SD model info without importing StableDiffusionIntegration
public struct SDModelInfo {
    public let id: String
    
    public init(id: String) {
        self.id = id
    }
}

/// Protocol for SD model providers (to avoid circular dependency)
@MainActor
public protocol SDModelProvider {
    func getSDModelList() -> [SDModelInfo]
}

/// Centralized manager for available models list across the application.
/// Provides a single source of truth for model availability with automatic refresh capabilities.
@MainActor
public class ModelListManager: ObservableObject {
    /// Shared singleton instance
    public static let shared = ModelListManager()
    
    /// Published list of all available models (remote + local LLM + SD)
    @Published public private(set) var availableModels: [String] = []
    
    /// Loading state indicator
    @Published public private(set) var isLoading: Bool = false
    
    /// Last refresh timestamp
    @Published public private(set) var lastRefresh: Date?
    
    /// Dependencies
    private var endpointManager: EndpointManager?
    
    /// SD model provider (injected to avoid circular dependency)
    public var sdModelProvider: SDModelProvider?
    
    /// Cache duration - refresh if older than this
    private let cacheValidityDuration: TimeInterval = 30.0 // 30 seconds
    
    /// Private init for singleton
    private init() {
        // Dependencies are injected after initialization
        
        // Setup notification observers for automatic refresh
        setupNotificationObservers()
    }
    
    /// Initialize the manager with required dependencies
    public func initialize(endpointManager: EndpointManager) {
        logger.info("Initializing ModelListManager with EndpointManager")
        self.endpointManager = endpointManager
        
        // Trigger initial refresh with a small delay to allow providers to finish loading
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await refresh(force: true)
        }
    }
    
    /// Setup notification observers to auto-refresh on model changes
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: .endpointManagerDidUpdateModels,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh(force: true)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .stableDiffusionModelInstalled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh(force: true)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .aliceModelsLoaded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logger.info("ALICE models loaded, refreshing available models list")
            Task { @MainActor in
                await self?.refresh(force: true)
            }
        }
    }
    
    /// Refresh the available models list
    /// - Parameter force: If true, refresh regardless of cache age. If false, use cache if recent.
    public func refresh(force: Bool = false) async {
        // Check if manager is initialized
        guard let endpointManager = endpointManager else {
            logger.warning("ModelListManager not initialized - call initialize(endpointManager:) first")
            return
        }
        
        // Check if we need to refresh based on cache age
        if !force, let lastRefresh = lastRefresh {
            let age = Date().timeIntervalSince(lastRefresh)
            if age < cacheValidityDuration {
                logger.debug("Using cached model list (age: \(String(format: "%.1f", age))s)")
                return
            }
        }
        
        guard !isLoading else {
            logger.debug("Model refresh already in progress, skipping")
            return
        }
        
        logger.info("Refreshing available models list")
        isLoading = true
        
        do {
            // Fetch GitHub Copilot model capabilities (including billing) BEFORE loading models
            // FORCE fresh fetch to ensure billing data is populated (not from capabilities cache)
            do {
                // Clear the static capabilities cache to force a fresh API call with billing data
                // This is needed because the cache check happens before billing data is populated
                _ = try await endpointManager.clearGitHubCopilotCapabilitiesCache()
                _ = try await endpointManager.getGitHubCopilotModelCapabilities()
                logger.debug("Fetched GitHub Copilot capabilities with billing info")
            } catch {
                logger.warning("Failed to fetch GitHub capabilities: \(error)")
            }
            
            // Get models from endpoint manager
            let modelsResponse = try await endpointManager.getAvailableModels()
            logger.debug("EndpointManager getAvailableModels returned \(modelsResponse.data.count) model(s)")
            
            // Deduplicate models based on base model ID
            var seenBaseIds = Set<String>()
            var uniqueModelIds: [String] = []
            
            for modelId in modelsResponse.data.map({ $0.id }) {
                let key = canonicalBaseId(from: modelId)
                if !seenBaseIds.contains(key) {
                    seenBaseIds.insert(key)
                    uniqueModelIds.append(modelId)
                }
            }
            
            // Filter out non-chat models
            let chatModelsOnly = uniqueModelIds.filter { modelId in
                let baseId = modelId.split(separator: "/").last.map(String.init) ?? modelId
                let isNonChatModel = baseId.hasPrefix("imagen-") ||
                                   baseId.hasPrefix("veo-") ||
                                   baseId.hasPrefix("gemma-")
                
                if isNonChatModel {
                    logger.debug("Filtering non-chat model from picker: \(modelId)")
                }
                
                return !isNonChatModel
            }
            
            // Sort models: Free (0x) first, then Premium, both alphabetical within tier
            let sortedModels = chatModelsOnly.sorted { model1, model2 in
                let base1 = model1.split(separator: "/").last.map(String.init) ?? model1
                let base2 = model2.split(separator: "/").last.map(String.init) ?? model2
                
                let billing1 = endpointManager.getGitHubCopilotModelBillingInfo(modelId: base1)
                let billing2 = endpointManager.getGitHubCopilotModelBillingInfo(modelId: base2)
                
                let isFree1 = !(billing1?.isPremium ?? false)
                let isFree2 = !(billing2?.isPremium ?? false)
                
                // Free models come first
                if isFree1 != isFree2 {
                    return isFree1
                }
                
                // Within same tier, sort alphabetically
                return model1.lowercased() < model2.lowercased()
            }
            
            // Add Stable Diffusion models (local + ALICE remote)
            var sdModelIds: [String] = []
            
            if let sdProvider = sdModelProvider {
                let localSDModels = sdProvider.getSDModelList()
                sdModelIds = localSDModels.map { "sd/\($0.id)" }
            }
            
            // Add ALICE remote SD models if connected
            if let aliceProvider = ALICEProvider.shared, aliceProvider.isHealthy {
                let aliceSDModels = aliceProvider.availableModels.map { model -> String in
                    let normalizedId = model.id.replacingOccurrences(of: "/", with: "-")
                    return "alice-\(normalizedId)"
                }
                sdModelIds.append(contentsOf: aliceSDModels)
            }
            
            // Filter out any stable-diffusion/* models from LLM list
            let llmModelsOnly = sortedModels.filter { !$0.hasPrefix("stable-diffusion/") }
            
            // Combine all models
            let allModels = llmModelsOnly + sdModelIds
            logger.info("Loaded \(allModels.count) total models (\(llmModelsOnly.count) LLM, \(sdModelIds.count) SD)")
            
            // Update published properties
            self.availableModels = allModels
            self.lastRefresh = Date()
            self.isLoading = false
            
        } catch {
            logger.error("Failed to refresh models: \(error)")
            
            // Fallback to default models on error
            self.availableModels = ["sam-assistant", "sam-default", "gpt-4", "gpt-3.5-turbo"]
            self.lastRefresh = Date()
            self.isLoading = false
        }
    }
    
    /// Get canonical base ID from a model ID (for deduplication)
    private func canonicalBaseId(from modelId: String) -> String {
        // Take the last path component (strip provider prefix if present)
        var baseId = modelId.split(separator: "/").last.map(String.init) ?? modelId
        
        // Remove date patterns like -2024-05-13
        if let range = baseId.range(of: "-\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) {
            baseId = String(baseId[..<range.lowerBound])
        }
        
        // Remove provider-style suffixes such as '-copilot' or ' copilot'
        if let range = baseId.range(of: "(-|\\s)?copilot.*$", options: .regularExpression) {
            baseId = String(baseId[..<range.lowerBound])
        }
        
        // Normalize common version format mistakes like 'gpt-41' -> 'gpt-4.1'
        if baseId.lowercased().hasPrefix("gpt-") && !baseId.contains(".") {
            let suffix = baseId.dropFirst(4) // skip "gpt-"
            if suffix.count >= 2 {
                let first = suffix.prefix(1)
                let second = suffix[suffix.index(suffix.startIndex, offsetBy: 1)]
                if first.rangeOfCharacter(from: .decimalDigits) != nil && String(second).rangeOfCharacter(from: .decimalDigits) != nil {
                    // Insert dot between first and remaining digits
                    let rest = suffix.dropFirst(1)
                    baseId = "gpt-\(first).\(rest)"
                }
            }
        }
        
        return baseId.lowercased()
    }
}
