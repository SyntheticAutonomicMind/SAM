// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConfigurationSystem
import Logging
@MainActor
public class DeepSeekProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration
    private let logger = Logger(label: "com.syntheticautonomicmind.sam.DeepSeekProvider")

    public init(config: ProviderConfiguration) {
        self.identifier = config.providerId
        self.config = config
        logger.debug("DeepSeek Provider initialized")
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    /// Check cancellation before HTTP request.
                    if Task.isCancelled {
                        self.logger.debug("TASK_CANCELLED: DeepSeek request cancelled before start")
                        continuation.finish()
                        return
                    }

                    let response = try await self.processChatCompletion(request)
                    let chunks = self.convertToStreamChunks(response)

                    for chunk in chunks {
                        /// Check cancellation in streaming loop.
                        if Task.isCancelled {
                            self.logger.debug("TASK_CANCELLED: DeepSeek streaming cancelled")
                            continuation.finish()
                            return
                        }

                        continuation.yield(chunk)
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func convertToStreamChunks(_ response: ServerOpenAIChatResponse) -> [ServerOpenAIChatStreamChunk] {
        guard let choice = response.choices.first else { return [] }
        var chunks: [ServerOpenAIChatStreamChunk] = []

        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(role: "assistant", content: nil))]
        ))

        let words = (choice.message.content ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        for word in words {
            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: word + " "))]
            ))
        }

        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "stop")]
        ))

        return chunks
    }

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        let requestId = UUID().uuidString
        logger.debug("Processing chat completion via DeepSeek API [req:\(requestId.prefix(8))]")

        guard let apiKey = config.apiKey else {
            throw ProviderError.authenticationFailed("DeepSeek API key not configured")
        }

        guard let baseURL = config.baseURL ?? ProviderType.deepseek.defaultBaseURL else {
            throw ProviderError.invalidConfiguration("DeepSeek base URL not configured")
        }

        /// DeepSeek uses OpenAI-compatible API format.
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ProviderError.invalidConfiguration("Invalid DeepSeek base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        /// Create request body.
        let requestBody: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map { message in
                [
                    "role": message.role,
                    "content": message.content
                ]
            },
            "max_tokens": request.maxTokens ?? config.maxTokens ?? 2048,
            "temperature": request.temperature ?? config.temperature ?? 0.7,
            "stream": false
        ]

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        /// Set timeout (5 minutes minimum for tool-enabled requests, especially 7B models).
        /// Even if config specifies lower timeout, enforce 300s minimum to prevent timeouts.
        let configuredTimeout = TimeInterval(config.timeoutSeconds ?? 300)
        urlRequest.timeoutInterval = max(configuredTimeout, 300)

        logger.debug("Sending request to DeepSeek API [req:\(requestId.prefix(8))]")

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            logger.debug("DeepSeek API response [req:\(requestId.prefix(8))]: \(httpResponse.statusCode)")

            guard 200...299 ~= httpResponse.statusCode else {
                if let errorData = String(data: data, encoding: .utf8) {
                    logger.error("DeepSeek API error [req:\(requestId.prefix(8))]: \(errorData)")
                }
                throw ProviderError.networkError("DeepSeek API returned status \(httpResponse.statusCode)")
            }

            /// Parse response.
            let deepseekResponse = try JSONDecoder().decode(ServerOpenAIChatResponse.self, from: data)
            logger.debug("Successfully processed DeepSeek response [req:\(requestId.prefix(8))]")

            return deepseekResponse

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("DeepSeek API request failed [req:\(requestId.prefix(8))]: \(error)")
            throw ProviderError.networkError("Network error: \(error.localizedDescription)")
        }
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        let models = config.models.map { modelId in
            ServerOpenAIModel(
                id: modelId,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: "deepseek"
            )
        }

        return ServerOpenAIModelsResponse(
            object: "list",
            data: models
        )
    }

    public func supportsModel(_ model: String) -> Bool {
        return config.models.contains(model) || model.hasPrefix("deepseek-")
    }

    public func validateConfiguration() async throws -> Bool {
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("DeepSeek API key is required")
        }

        /// FUTURE FEATURE: Real API validation Currently: Basic check (non-empty key) Future: Make test API call to validate key actually works Reason not implemented: Validation adds latency to preferences UI Alternative: Validation happens on first API call (error shows invalid key).
        return true
    }

    // MARK: - Lifecycle

    public func loadModel() async throws -> ModelCapabilities {
        throw ProviderError.invalidRequest("loadModel() not supported for remote providers")
    }

    public func getLoadedStatus() async -> Bool {
        return false
    }

    public func unload() async {
        /// No-op for remote providers.
    }
}

// MARK: - Supporting Types

public struct ModelStatus {
    public let id: String
    public let status: InstallationStatus
    public let progress: Float
    public let message: String

    public enum InstallationStatus: String, CaseIterable {
        case notInstalled = "not_installed"
        case downloading = "downloading"
        case installed = "installed"
        case error = "error"
    }
}

// MARK: - Custom Provider

/// Provider for custom/generic API endpoints.
@MainActor
public class CustomProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration
    private let logger = Logger(label: "com.syntheticautonomicmind.sam.CustomProvider")

    public init(config: ProviderConfiguration) {
        self.identifier = config.providerId
        self.config = config
        logger.debug("Custom Provider initialized for \(config.providerId)")
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    /// Check cancellation before HTTP request.
                    if Task.isCancelled {
                        self.logger.debug("TASK_CANCELLED: Custom provider request cancelled before start")
                        continuation.finish()
                        return
                    }

                    let response = try await self.processChatCompletion(request)
                    let chunks = self.convertToStreamChunks(response)

                    for chunk in chunks {
                        /// Check cancellation in streaming loop.
                        if Task.isCancelled {
                            self.logger.debug("TASK_CANCELLED: Custom provider streaming cancelled")
                            continuation.finish()
                            return
                        }

                        continuation.yield(chunk)
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func convertToStreamChunks(_ response: ServerOpenAIChatResponse) -> [ServerOpenAIChatStreamChunk] {
        guard let choice = response.choices.first else { return [] }
        var chunks: [ServerOpenAIChatStreamChunk] = []

        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(role: "assistant", content: nil))]
        ))

        let words = (choice.message.content ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        for word in words {
            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: word + " "))]
            ))
        }

        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "stop")]
        ))

        return chunks
    }

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        let requestId = UUID().uuidString
        logger.debug("Processing chat completion via custom provider '\(self.identifier)' [req:\(requestId.prefix(8))]")

        guard let baseURL = config.baseURL else {
            throw ProviderError.invalidConfiguration("Custom provider base URL not configured")
        }

        /// Custom providers assumed to be OpenAI-compatible (most common pattern).
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ProviderError.invalidConfiguration("Invalid custom provider base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        /// Add authentication if API key provided.
        if let apiKey = config.apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        /// Add any custom headers.
        if let customHeaders = config.customHeaders {
            for (key, value) in customHeaders {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        /// Create request body (OpenAI-compatible format).
        let requestBody: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map { message in
                [
                    "role": message.role,
                    "content": message.content
                ]
            },
            "max_tokens": request.maxTokens ?? config.maxTokens ?? 2048,
            "temperature": request.temperature ?? config.temperature ?? 0.7,
            "stream": false
        ]

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        /// Set timeout (5 minutes minimum for tool-enabled requests, especially 7B models).
        /// Even if config specifies lower timeout, enforce 300s minimum to prevent timeouts.
        let configuredTimeout = TimeInterval(config.timeoutSeconds ?? 300)
        urlRequest.timeoutInterval = max(configuredTimeout, 300)

        logger.debug("Sending request to custom provider '\(self.identifier)' [req:\(requestId.prefix(8))]")

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            logger.debug("Custom provider '\(self.identifier)' response [req:\(requestId.prefix(8))]: \(httpResponse.statusCode)")

            guard 200...299 ~= httpResponse.statusCode else {
                /// Try to parse error response to get detailed error message.
                var errorMessage = "Custom provider returned status \(httpResponse.statusCode)"
                if let errorData = String(data: data, encoding: .utf8) {
                    logger.error("Custom provider '\(self.identifier)' error [req:\(requestId.prefix(8))]: \(errorData)")

                    /// Try to extract error message from JSON response.
                    if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = errorJson["error"] as? [String: Any],
                       let message = error["message"] as? String {
                        errorMessage = "Custom provider error: \(message)"
                    } else {
                        /// Include raw error data if JSON parsing fails.
                        errorMessage = "Custom provider returned status \(httpResponse.statusCode): \(errorData.prefix(200))"
                    }
                }
                throw ProviderError.networkError(errorMessage)
            }

            /// Parse response (assuming OpenAI-compatible format).
            let customResponse = try JSONDecoder().decode(ServerOpenAIChatResponse.self, from: data)
            logger.debug("Successfully processed custom provider '\(self.identifier)' response [req:\(requestId.prefix(8))]")

            return customResponse

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("Custom provider '\(self.identifier)' request failed [req:\(requestId.prefix(8))]: \(error)")
            throw ProviderError.networkError("Network error: \(error.localizedDescription)")
        }
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        let models = config.models.map { modelId in
            ServerOpenAIModel(
                id: modelId,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: identifier
            )
        }

        return ServerOpenAIModelsResponse(
            object: "list",
            data: models
        )
    }

    public func supportsModel(_ model: String) -> Bool {
        return config.models.contains(model)
    }

    public func validateConfiguration() async throws -> Bool {
        guard let baseURL = config.baseURL, !baseURL.isEmpty else {
            throw ProviderError.invalidConfiguration("Custom provider requires base URL")
        }

        if config.requiresApiKey {
            guard let apiKey = config.apiKey, !apiKey.isEmpty else {
                throw ProviderError.authenticationFailed("Custom provider requires API key")
            }
        }

        /// Future feature: Custom validation logic based on provider configuration.
        return true
    }

    // MARK: - Model Capabilities Fetching

    /// Fetch model list from custom provider's /v1/models endpoint.
    /// Supports both OpenAI-compatible format and llama.cpp format.
    public func fetchModelCapabilities() async throws -> [String: Int] {
        logger.debug("Fetching model capabilities from custom provider '\(self.identifier)'")

        guard let baseURL = config.baseURL else {
            throw ProviderError.invalidConfiguration("Custom provider base URL not configured")
        }

        guard let url = URL(string: "\(baseURL)/models") else {
            throw ProviderError.invalidConfiguration("Invalid custom provider models URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        /// Add authentication if API key provided.
        if let apiKey = config.apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        /// Add custom headers if configured.
        if let customHeaders = config.customHeaders {
            for (key, value) in customHeaders {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        /// Use shorter timeout for model list (not generation).
        urlRequest.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Custom provider '\(self.identifier)' /models API error [\(httpResponse.statusCode)]: \(errorText.prefix(200))")
            throw ProviderError.networkError("Custom provider /models API returned status \(httpResponse.statusCode)")
        }

        /// Parse response - support both OpenAI and llama.cpp formats.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.responseNormalizationFailed("Failed to parse custom provider /models response")
        }

        var capabilities: [String: Int] = [:]

        /// Try OpenAI format first (data array).
        if let models = json["data"] as? [[String: Any]] {
            for model in models {
                guard let id = model["id"] as? String else { continue }
                /// OpenAI doesn't always provide context size - use sensible default.
                let contextSize = model["context_length"] as? Int ?? 8192
                capabilities[id] = contextSize
                logger.debug("Custom provider model '\(id)': \(contextSize) tokens")
            }
        }
        /// Try llama.cpp format (models array).
        else if let models = json["models"] as? [[String: Any]] {
            for model in models {
                /// llama.cpp uses "model" or "name" field.
                let id = model["model"] as? String ?? model["name"] as? String ?? ""
                guard !id.isEmpty else { continue }

                /// Extract clean model name from path if needed.
                let cleanId = URL(fileURLWithPath: id).lastPathComponent

                /// llama.cpp doesn't provide context size - use conservative default.
                /// Users can override in configuration if needed.
                let contextSize = 8192
                capabilities[cleanId] = contextSize
                logger.debug("Custom provider model '\(cleanId)': \(contextSize) tokens")
            }
        } else {
            logger.warning("Custom provider '\(self.identifier)' returned unknown /models format")
            throw ProviderError.responseNormalizationFailed("Unknown /models response format")
        }

        logger.debug("Successfully fetched \(capabilities.count) model(s) from custom provider '\(self.identifier)'")
        return capabilities
    }

    // MARK: - Lifecycle

    public func loadModel() async throws -> ModelCapabilities {
        throw ProviderError.invalidRequest("loadModel() not supported for remote providers")
    }

    public func getLoadedStatus() async -> Bool {
        return false
    }

    public func unload() async {
        /// No-op for remote providers.
    }
}

// MARK: - Helper Methods

extension ProviderConfiguration {
    /// Whether this custom provider requires an API key.
    var requiresApiKey: Bool {
        return providerType.requiresApiKey || (customHeaders?["authorization"] != nil)
    }
}

// MARK: - Helper Methods

/// Utility class for HTTP requests to provider APIs.
internal class ProviderHTTPClient {
    private let logger = Logger(label: "com.syntheticautonomicmind.sam.ProviderHTTPClient")

    /// Future feature: HTTP client implementation using URLSession or async-http-client Should handle: - Authentication (Bearer tokens, API keys, custom headers) - Request/response serialization - Error handling and retry logic - Timeout and connection management - Rate limiting.

    func post<T: Codable, R: Codable>(
        url: String,
        headers: [String: String],
        body: T,
        responseType: R.Type
    ) async throws -> R {
        /// Placeholder implementation.
        throw ProviderError.networkError("HTTP client not yet implemented")
    }

    func get<R: Codable>(
        url: String,
        headers: [String: String],
        responseType: R.Type
    ) async throws -> R {
        /// Placeholder implementation.
        throw ProviderError.networkError("HTTP client not yet implemented")
    }
}
