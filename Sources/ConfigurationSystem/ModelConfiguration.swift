// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Model configuration system for managing model-specific behavior
/// Replaces hardcoded model detection logic with JSON-driven configuration

private let logger = Logger(label: "com.sam.modelconfig")

// MARK: - Configuration Models

public struct PromptFormat: Codable {
    public let useXMLTags: Bool
    public let requiredTags: [String]
    public let continuationSignalRequired: Bool

    enum CodingKeys: String, CodingKey {
        case useXMLTags = "use_xml_tags"
        case requiredTags = "required_tags"
        case continuationSignalRequired = "continuation_signal_required"
    }
}

public struct ModelConfig: Codable {
    public let provider: String
    public let deltaMode: String
    public let promptFormat: PromptFormat
    public let supportsStatefulMarker: Bool
    public let contextWindow: Int
    public let requiresAlternatingMessages: Bool

    enum CodingKeys: String, CodingKey {
        case provider
        case deltaMode = "delta_mode"
        case promptFormat = "prompt_format"
        case supportsStatefulMarker = "supports_stateful_marker"
        case contextWindow = "context_window"
        case requiresAlternatingMessages = "requires_alternating_messages"
    }

    /// Check if this model uses cumulative deltas (like Claude)
    public var isCumulativeDelta: Bool {
        return deltaMode.lowercased() == "cumulative"
    }

    /// Check if this model needs XML tag formatting
    public var usesXMLTags: Bool {
        return promptFormat.useXMLTags
    }
}

public struct ModelProviderDefaults: Codable {
    public let deltaMode: String
    public let supportsStreaming: Bool
    public let supportsStatefulMarker: Bool

    enum CodingKeys: String, CodingKey {
        case deltaMode = "delta_mode"
        case supportsStreaming = "supports_streaming"
        case supportsStatefulMarker = "supports_stateful_marker"
    }
}

public struct ModelConfigurationData: Codable {
    public let modelConfigurations: [String: ModelConfig]
    public let providerDefaults: [String: ModelProviderDefaults]
    public let modelFamilyPatterns: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case modelConfigurations = "model_configurations"
        case providerDefaults = "provider_defaults"
        case modelFamilyPatterns = "model_family_patterns"
    }
}

// MARK: - Model Configuration Manager

public class ModelConfigurationManager {
    nonisolated(unsafe) public static let shared = ModelConfigurationManager()

    private var configData: ModelConfigurationData?

    private init() {
        loadConfiguration()
    }

    /// Load model configuration from JSON file
    private func loadConfiguration() {
        let fileName = "model_config"
        let fileExtension = "json"

        var configURL: URL?

        /// Priority 1: Try Bundle.main (production build)
        if let bundlePath = Bundle.main.path(forResource: fileName, ofType: fileExtension) {
            configURL = URL(fileURLWithPath: bundlePath)
            logger.debug("Found model config in bundle: \(bundlePath)")
        }

        /// Priority 2: Try development path (Sources/ConfigurationSystem/Resources/)
        if configURL == nil {
            let currentDirectory = FileManager.default.currentDirectoryPath
            let devPath = "\(currentDirectory)/Sources/ConfigurationSystem/Resources/\(fileName).\(fileExtension)"
            let devURL = URL(fileURLWithPath: devPath)

            if FileManager.default.fileExists(atPath: devPath) {
                configURL = devURL
                logger.debug("Found model config in development path: \(devPath)")
            }
        }

        guard let url = configURL else {
            logger.error("Failed to find model config file in bundle or development path")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            configData = try decoder.decode(ModelConfigurationData.self, from: data)
            logger.info("Loaded model configuration: \(configData?.modelConfigurations.count ?? 0) models from \(url.path)")
        } catch {
            logger.error("Failed to load model configuration from \(url): \(error)")
        }
    }

    /// Get configuration for a specific model
    /// - Parameter modelName: Full model name (e.g., "github_copilot/claude-sonnet-4.5")
    /// - Returns: ModelConfig if found, otherwise nil
    public func getConfiguration(for modelName: String) -> ModelConfig? {
        guard let configData = configData else {
            logger.warning("Model configuration not loaded, using fallback detection")
            return nil
        }

        /// Extract model name without provider prefix
        let normalizedName: String
        if modelName.contains("/") {
            normalizedName = modelName.components(separatedBy: "/").last ?? modelName
        } else {
            normalizedName = modelName
        }

        /// Try exact match first
        if let config = configData.modelConfigurations[normalizedName] {
            logger.debug("Found exact config match for: \(normalizedName)")
            return config
        }

        /// Try partial match using model family patterns
        for (family, patterns) in configData.modelFamilyPatterns {
            for pattern in patterns {
                if normalizedName.localizedCaseInsensitiveContains(pattern) {
                    logger.debug("Matched model \(normalizedName) to family: \(family)")
                    /// Find any model in config that matches this family
                    for (configModelName, config) in configData.modelConfigurations {
                        if configModelName.localizedCaseInsensitiveContains(pattern) {
                            logger.debug("Using config from \(configModelName) for \(normalizedName)")
                            return config
                        }
                    }
                }
            }
        }

        logger.warning("No configuration found for model: \(modelName), will use fallback logic")
        return nil
    }

    /// Check if model uses cumulative deltas (for streaming)
    /// - Parameter modelName: Full model name
    /// - Returns: true if cumulative (like Claude), false if incremental (like GPT)
    public func isCumulativeDeltaModel(_ modelName: String) -> Bool {
        if let config = getConfiguration(for: modelName) {
            return config.isCumulativeDelta
        }

        /// CRITICAL: GitHub Copilot models are ALWAYS incremental
        /// Even Claude models accessed through GitHub Copilot use incremental deltas
        /// because the GitHub Copilot proxy transforms them
        if modelName.contains("github_copilot/") || modelName.contains("github-copilot/") {
            return false  // GitHub Copilot uses incremental deltas for ALL models
        }

        /// Fallback to hardcoded detection if config not available
        /// This applies to direct Claude API calls (not through GitHub Copilot)
        return modelName.localizedCaseInsensitiveContains("claude") ||
               modelName.localizedCaseInsensitiveContains("sonnet") ||
               modelName.localizedCaseInsensitiveContains("haiku") ||
               modelName.localizedCaseInsensitiveContains("opus")
    }

    /// Check if model needs XML tag formatting in system prompt
    /// - Parameter modelName: Full model name
    /// - Returns: true if XML tags needed (like Claude), false otherwise
    public func usesXMLTags(_ modelName: String) -> Bool {
        if let config = getConfiguration(for: modelName) {
            return config.usesXMLTags
        }

        /// Fallback: Claude models use XML tags
        return modelName.localizedCaseInsensitiveContains("claude") ||
               modelName.localizedCaseInsensitiveContains("sonnet") ||
               modelName.localizedCaseInsensitiveContains("haiku") ||
               modelName.localizedCaseInsensitiveContains("opus")
    }

    /// Get provider defaults for a given provider
    /// - Parameter provider: Provider name (e.g., "github_copilot")
    /// - Returns: ModelProviderDefaults if found, otherwise nil
    public func getProviderDefaults(for provider: String) -> ModelProviderDefaults? {
        return configData?.providerDefaults[provider]
    }

    /// Get context window for a model
    /// - Parameter modelName: Full model name
    /// - Returns: Context window size if found in config, otherwise nil
    public func getContextWindow(for modelName: String) -> Int? {
        if let config = getConfiguration(for: modelName) {
            return config.contextWindow
        }
        return nil
    }
}
