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
        /// Weighted algorithm not yet implemented - using random selection Future: Track current weight per provider, select highest, decrement Reset when all weights depleted to prevent starvation.
        return providers.randomElement() ?? providers[0]
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
        case .openai, .localLlama, .localMLX, .gemini:
            /// Already in OpenAI format or uses OpenAI format.
            if let openAIResponse = providerResponse as? ServerOpenAIChatResponse {
                return openAIResponse
            }

        case .anthropic:
            return try normalizeAnthropicResponse(providerResponse, requestModel: requestModel, requestId: requestId)

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

    /// Normalize Anthropic Claude API responses to OpenAI format Anthropic uses a different response schema: - `content` array instead of single `message.content` - `stop_reason` instead of `finish_reason` - Different token counting structure This is currently a placeholder implementation.
    private static func normalizeAnthropicResponse(_ response: Any, requestModel: String, requestId: String) throws -> ServerOpenAIChatResponse {
        return ServerOpenAIChatResponse(
            id: "chatcmpl-\(requestId)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: requestModel,
            choices: [
                OpenAIChatChoice(
                    index: 0,
                    message: OpenAIChatMessage(role: "assistant", content: "Anthropic response (normalized)"),
                    finishReason: "stop"
                )
            ],
            usage: ServerOpenAIUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        )
    }

    /// Normalize GitHub Copilot Chat responses to OpenAI format GitHub Copilot may use extended response fields not in the OpenAI spec.
    private static func normalizeGitHubCopilotResponse(_ response: Any, requestModel: String, requestId: String) throws -> ServerOpenAIChatResponse {
        return ServerOpenAIChatResponse(
            id: "chatcmpl-\(requestId)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: requestModel,
            choices: [
                OpenAIChatChoice(
                    index: 0,
                    message: OpenAIChatMessage(role: "assistant", content: "GitHub Copilot response (normalized)"),
                    finishReason: "stop"
                )
            ],
            usage: ServerOpenAIUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        )
    }

    /// Normalize DeepSeek API responses to OpenAI format DeepSeek uses an OpenAI-compatible API but may have minor differences.
    private static func normalizeDeepSeekResponse(_ response: Any, requestModel: String, requestId: String) throws -> ServerOpenAIChatResponse {
        /// DeepSeek advertises OpenAI API compatibility.
        if let openAIResponse = response as? ServerOpenAIChatResponse {
            return openAIResponse
        }

        return ServerOpenAIChatResponse(
            id: "chatcmpl-\(requestId)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: requestModel,
            choices: [
                OpenAIChatChoice(
                    index: 0,
                    message: OpenAIChatMessage(role: "assistant", content: "DeepSeek response (normalized)"),
                    finishReason: "stop"
                )
            ],
            usage: ServerOpenAIUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        )
    }

    /// Normalize custom provider responses to OpenAI format Users can configure arbitrary API endpoints as custom providers.
    private static func normalizeCustomResponse(_ response: Any, requestModel: String, requestId: String) throws -> ServerOpenAIChatResponse {
        return ServerOpenAIChatResponse(
            id: "chatcmpl-\(requestId)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: requestModel,
            choices: [
                OpenAIChatChoice(
                    index: 0,
                    message: OpenAIChatMessage(role: "assistant", content: "Custom provider response (normalized)"),
                    finishReason: "stop"
                )
            ],
            usage: ServerOpenAIUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        )
    }
}

// MARK: - Provider Errors

public enum ProviderError: LocalizedError {
    case authenticationFailed(String)
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
}
