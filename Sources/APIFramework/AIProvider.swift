// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import SwiftUI
import ConfigurationSystem

// MARK: - Model Capabilities

/// Represents the capabilities and parameters of a loaded model.
public struct ModelCapabilities {
    public let contextSize: Int
    public let maxTokens: Int
    public let supportsStreaming: Bool
    public let providerType: String
    public let modelName: String

    public init(
        contextSize: Int,
        maxTokens: Int,
        supportsStreaming: Bool,
        providerType: String,
        modelName: String
    ) {
        self.contextSize = contextSize
        self.maxTokens = maxTokens
        self.supportsStreaming = supportsStreaming
        self.providerType = providerType
        self.modelName = modelName
    }
}

/// Protocol defining the interface for all AI provider implementations.
@MainActor
public protocol AIProvider {
    /// Unique identifier for this provider instance.
    var identifier: String { get }

    /// Provider configuration.
    var config: ProviderConfiguration { get }

    /// Process a chat completion request and return OpenAI-compatible response.
    func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse

    /// Process a streaming chat completion request.
    func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error>

    /// Get list of available models from this provider.
    func getAvailableModels() async throws -> ServerOpenAIModelsResponse

    /// Check if this provider supports a specific model.
    func supportsModel(_ model: String) -> Bool

    /// Validate provider configuration and authentication.
    func validateConfiguration() async throws -> Bool

    /// Load the model into memory and return its capabilities Only supported by local model providers (MLX, Llama) Remote providers should throw ProviderError.invalidRequest.
    func loadModel() async throws -> ModelCapabilities

    /// Check if the model is currently loaded in memory Always returns false for remote providers.
    func getLoadedStatus() async -> Bool

    /// Unload the model from memory No-op for remote providers.
    func unload() async
}

// MARK: - Load Balancing

/// Protocol for load balancing strategies.
@MainActor
public protocol LoadBalancer {
    func selectProvider(from providers: [AIProvider]) async -> AIProvider
}

/// Round-robin load balancing implementation.
public class RoundRobinLoadBalancer: LoadBalancer {
    private var currentIndex: Int = 0

    public init() {}

    public func selectProvider(from providers: [AIProvider]) async -> AIProvider {
        defer {
            currentIndex = (currentIndex + 1) % providers.count
        }
        return providers[currentIndex]
    }
}

/// Weighted round-robin load balancing Distributes requests across providers based on assigned weights.
public class WeightedLoadBalancer: LoadBalancer {
   private var weights: [String: Int] = [:]
   private var currentWeights: [String: Int] = [:]

   public init(weights: [String: Int] = [:]) {
       self.weights = weights
   }

   public func selectProvider(from providers: [AIProvider]) async -> AIProvider {
        // Weighted round-robin: track effective weights, select highest, decrement.
        // When all weights are depleted, reset to original weights.
        if currentWeights.isEmpty {
            for provider in providers {
                currentWeights[provider.identifier] = weights[provider.identifier] ?? 1
            }
        }
        
        // Find provider with highest current weight
        var bestProvider = providers[0]
        var bestWeight = currentWeights[bestProvider.identifier] ?? 0
        for provider in providers {
            let w = currentWeights[provider.identifier] ?? 0
            if w > bestWeight {
                bestWeight = w
                bestProvider = provider
            }
        }
        
        // Decrement selected provider's weight
        currentWeights[bestProvider.identifier] = bestWeight - 1
        
        // Check if all weights are zero, reset if so
        if currentWeights.values.allSatisfy({ $0 <= 0 }) {
            currentWeights.removeAll()
        }
        
        return bestProvider
   }
}

// MARK: - Provider Response Normalization

/// Utility for converting different provider response formats to OpenAI format.
public struct ResponseNormalizer {

    /// Normalize provider-specific response to OpenAI format.
    public static func normalizeResponse(
        providerResponse: Any,
        providerType: ProviderType,
        requestModel: String,
        requestId: String
    ) throws -> ServerOpenAIChatResponse {

        switch providerType {
        case .openai, .localLlama, .localMLX, .remoteLlama, .gemini, .openrouter, .minimax, .ollamaCloud, .zai, .zaiCoding:
            /// Already in OpenAI format or uses OpenAI format.
            if let openAIResponse = providerResponse as? ServerOpenAIChatResponse {
                return openAIResponse
            }

        case .githubCopilot:
            return try normalizeGitHubCopilotResponse(providerResponse, requestModel: requestModel, requestId: requestId)

        case .deepseek:
            return try normalizeDeepSeekResponse(providerResponse, requestModel: requestModel, requestId: requestId)

        case .custom:
            return try normalizeCustomResponse(providerResponse, requestModel: requestModel, requestId: requestId)
        }

        throw ProviderError.responseNormalizationFailed("Unsupported response format from \(providerType)")
    }

    // MARK: - Provider-Specific Normalization

    /// Normalize GitHub Copilot Chat responses to OpenAI format GitHub Copilot may use extended response fields not in the OpenAI spec.
   private static func normalizeGitHubCopilotResponse(_ response: Any, requestModel: String, requestId: String) throws -> ServerOpenAIChatResponse {
        // If response is already in OpenAI format, pass it through
        if let openAIResponse = response as? ServerOpenAIChatResponse {
            return openAIResponse
        }
        // Fallback: return a properly structured response indicating normalization is needed
        throw ProviderError.responseNormalizationFailed("GitHub Copilot response format not recognized - expected OpenAI-compatible format")
   }

    /// Normalize DeepSeek API responses to OpenAI format DeepSeek uses an OpenAI-compatible API but may have minor differences.
   private static func normalizeDeepSeekResponse(_ response: Any, requestModel: String, requestId: String) throws -> ServerOpenAIChatResponse {
        // DeepSeek uses OpenAI-compatible API - pass through if already in correct format
       if let openAIResponse = response as? ServerOpenAIChatResponse {
           return openAIResponse
       }

        throw ProviderError.responseNormalizationFailed("DeepSeek response format not recognized - expected OpenAI-compatible format")
   }

    /// Normalize custom provider responses to OpenAI format Users can configure arbitrary API endpoints as custom providers.
   private static func normalizeCustomResponse(_ response: Any, requestModel: String, requestId: String) throws -> ServerOpenAIChatResponse {
        // Custom providers should return OpenAI-compatible format
        if let openAIResponse = response as? ServerOpenAIChatResponse {
            return openAIResponse
        }
        throw ProviderError.responseNormalizationFailed("Custom provider response format not recognized - configure provider to use OpenAI-compatible format")
   }
}

// MARK: - Provider Errors

public enum ProviderError: LocalizedError {
    case authenticationFailed(String)
    case authRecoverable(String)  // Token was refreshed, caller should retry
    case invalidConfiguration(String)
    case networkError(String)
    case modelNotSupported(String)
    case responseNormalizationFailed(String)
    case rateLimitExceeded(String)
    case quotaExceeded(String)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"

        case .authRecoverable(let message):
            return "Authentication recovered: \(message)"

        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"

        case .networkError(let message):
            return "Network error: \(message)"

        case .modelNotSupported(let message):
            return "Model not supported: \(message)"

        case .responseNormalizationFailed(let message):
            return "Response normalization failed: \(message)"

        case .rateLimitExceeded(let message):
            return "Rate limit exceeded: \(message)"

        case .quotaExceeded(let message):
            return "Quota exceeded: \(message)"

        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        }
    }
    
    /// Whether this error indicates the token was refreshed and a retry should succeed
    public var isAuthRecoverable: Bool {
        if case .authRecoverable = self { return true }
        return false
    }
}
