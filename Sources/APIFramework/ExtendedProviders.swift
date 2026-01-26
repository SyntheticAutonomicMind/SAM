// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConfigurationSystem
import Logging
@MainActor
public class DeepSeekProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration
    private let logger = Logger(label: "com.sam.api.deepseek")

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
    private let logger = Logger(label: "com.sam.api.customprovider")

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

// MARK: - Google Gemini Provider

/// Provider for Google Gemini API integration.
@MainActor
public class GeminiProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration
    private let logger = Logger(label: "com.sam.provider.gemini")
    
    /// Cache for model capabilities to avoid repeated API calls
    private static var modelCapabilitiesCache: [String: Bool] = [:]
    
    public init(config: ProviderConfiguration) {
        self.identifier = config.providerId
        self.config = config
        logger.debug("Gemini Provider initialized")
    }
    
    /// Check if a model supports function calling by querying the Gemini API
    /// This caches the result to avoid repeated API calls
    private func modelSupportsFunctionCalling(_ modelName: String) async -> Bool {
        /// Check cache first
        if let cached = Self.modelCapabilitiesCache[modelName] {
            return cached
        }
        
        guard let apiKey = config.apiKey,
              let baseURL = config.baseURL ?? ProviderType.gemini.defaultBaseURL else {
            logger.warning("Cannot query model capabilities - missing API key or base URL")
            return false
        }
        
        /// Query model metadata to check supported generation methods
        guard let url = URL(string: "\(baseURL)/models/\(modelName)?key=\(apiKey)") else {
            logger.warning("Invalid URL for model metadata: \(baseURL)/models/\(modelName)")
            return false
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  200...299 ~= httpResponse.statusCode else {
                logger.warning("Failed to fetch model metadata for \(modelName) - status: \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
                return false
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                /// According to Gemini API documentation, models that don't support function calling
                /// will return an error when tools are provided. Unfortunately, there's no explicit
                /// field in the model metadata that indicates function calling support.
                /// The supportedGenerationMethods field only indicates whether the model supports
                /// "generateContent" vs other methods, not whether it supports tools.
                ///
                /// As a heuristic, we'll assume support and cache the failure if we get a 400 error
                /// This will be updated in processChatCompletion if we get a function calling error
                
                /// Cache as true - will be updated to false if we get a 400 error
                Self.modelCapabilitiesCache[modelName] = true
                logger.debug("Model \(modelName) - assuming function calling support (will verify on first call)")
                return true
            }
            
            logger.warning("Could not parse model metadata for \(modelName)")
            return false
        } catch {
            logger.error("Error fetching model capabilities for \(modelName): \(error)")
            return false
        }
    }
    
    /// Fetch model capabilities (context sizes) from Gemini API
    /// Returns dictionary of modelId -> inputTokenLimit
    /// Uses the /v1beta/models endpoint to get all Gemini models and their metadata
    public func fetchModelCapabilities() async throws -> [String: Int] {
        guard let apiKey = config.apiKey,
              let baseURL = config.baseURL ?? ProviderType.gemini.defaultBaseURL else {
            throw ProviderError.authenticationFailed("Gemini API key or base URL not configured")
        }
        
        /// Query /v1beta/models endpoint to get all models
        guard let url = URL(string: "\(baseURL)/models?key=\(apiKey)") else {
            throw ProviderError.invalidConfiguration("Invalid Gemini models URL")
        }
        
        logger.debug("Fetching Gemini model capabilities from \(baseURL)/models")
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response from Gemini models endpoint")
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ProviderError.networkError("Gemini models endpoint returned \(httpResponse.statusCode): \(errorMessage)")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw ProviderError.networkError("Invalid JSON response from Gemini models endpoint")
        }
        
        var capabilities: [String: Int] = [:]
        
        for model in models {
            guard let name = model["name"] as? String else { continue }
            
            /// Strip "models/" prefix from name
            let modelId = name.replacingOccurrences(of: "models/", with: "")
            
            /// Filter out image/video generation models - these should be in Stable Diffusion UI
            /// Imagen models: imagen-*
            /// Veo models: veo-*
            /// Gemma models: gemma-* (text-only, not chat)
            let isImageModel = modelId.hasPrefix("imagen-") || 
                               modelId.hasPrefix("veo-") ||
                               modelId.hasPrefix("gemma-")
            
            if isImageModel {
                logger.debug("Skipping non-chat model: \(modelId)")
                continue
            }
            
            /// Get input token limit
            if let inputTokenLimit = model["inputTokenLimit"] as? Int {
                capabilities[modelId] = inputTokenLimit
                logger.debug("Gemini model \(modelId): \(inputTokenLimit) input tokens")
            }
        }
        
        logger.info("Fetched capabilities for \(capabilities.count) Gemini chat models (filtered out image/video generation models)")
        return capabilities
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    if Task.isCancelled {
                        self.logger.debug("TASK_CANCELLED: Gemini request cancelled before start")
                        continuation.finish()
                        return
                    }

                    let response = try await self.processChatCompletion(request)
                    let chunks = self.convertToStreamChunks(response)

                    for chunk in chunks {
                        if Task.isCancelled {
                            self.logger.debug("TASK_CANCELLED: Gemini streaming cancelled")
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

        /// Start with role chunk
        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(role: "assistant", content: nil))]
        ))

        /// Stream tool calls if present
        if let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty {
            for toolCall in toolCalls {
                chunks.append(ServerOpenAIChatStreamChunk(
                    id: response.id,
                    object: "chat.completion.chunk",
                    created: response.created,
                    model: response.model,
                    choices: [OpenAIChatStreamChoice(
                        index: 0,
                        delta: OpenAIChatDelta(toolCalls: [toolCall])
                    )]
                ))
            }
        }

        /// Stream text content if present
        if let content = choice.message.content, !content.isEmpty {
            let words = content.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            for word in words {
                chunks.append(ServerOpenAIChatStreamChunk(
                    id: response.id,
                    object: "chat.completion.chunk",
                    created: response.created,
                    model: response.model,
                    choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: word + " "))]
                ))
            }
        }

        /// Final chunk with finish reason
        /// CRITICAL: Set correct finish reason based on whether tool calls are present
        /// This determines whether AgentOrchestrator will execute tools or stop
        let finishReason = (choice.message.toolCalls != nil && !choice.message.toolCalls!.isEmpty) ? "tool_calls" : "stop"
        
        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: finishReason)]
        ))

        return chunks
    }

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        let requestId = UUID().uuidString
        logger.debug("Processing chat completion via Gemini API [req:\(requestId.prefix(8))]")

        guard let apiKey = config.apiKey else {
            throw ProviderError.authenticationFailed("Gemini API key not configured")
        }

        guard let baseURL = config.baseURL ?? ProviderType.gemini.defaultBaseURL else {
            throw ProviderError.invalidConfiguration("Gemini base URL not configured")
        }

        /// Strip provider prefix from model name before sending to API
        /// User-facing: "gemini/gemini-2.0-flash-exp" → API expects: "gemini-2.0-flash-exp"
        let modelForAPI = request.model.contains("/")
            ? request.model.components(separatedBy: "/").last ?? request.model
            : request.model

        /// Gemini uses a different endpoint structure: /models/{model}:generateContent
        guard let url = URL(string: "\(baseURL)/models/\(modelForAPI):generateContent") else {
            throw ProviderError.invalidConfiguration("Invalid Gemini URL: \(baseURL)/models/\(modelForAPI):generateContent")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        /// Convert OpenAI format to Gemini format using converter
        let conversionResult = GeminiMessageConverter.convert(messages: request.messages)

        /// Build Gemini request body
        var requestBody: [String: Any] = [
            "contents": conversionResult.contents
        ]

        /// Add system instruction if present
        if let systemInstruction = conversionResult.systemInstruction {
            requestBody["systemInstruction"] = systemInstruction
        }

        /// Add generation configuration
        var generationConfig: [String: Any] = [:]
        
        if let temperature = request.temperature ?? config.temperature {
            generationConfig["temperature"] = temperature
        }
        
        if let maxTokens = request.maxTokens ?? config.maxTokens {
            generationConfig["maxOutputTokens"] = max(maxTokens, 2048)
        } else {
            generationConfig["maxOutputTokens"] = 2048
        }

        if !generationConfig.isEmpty {
            requestBody["generationConfig"] = generationConfig
        }

        /// Add tools support if present and model supports it
        /// Query the API to check if the model supports function calling
        if let tools = request.tools, !tools.isEmpty {
            /// Check if model supports function calling (async query with caching)
            let modelSupportsTools = await modelSupportsFunctionCalling(modelForAPI)
            
            if modelSupportsTools {
                /// Convert OpenAI tool format to Gemini function declarations
                let geminiTools: [[String: Any]] = tools.map { tool in
                    var functionDeclaration: [String: Any] = [
                        "name": tool.function.name,
                        "description": tool.function.description
                    ]

                    /// Parse parameters JSON string to dictionary
                    if let parametersData = tool.function.parametersJson.data(using: .utf8),
                       let parameters = try? JSONSerialization.jsonObject(with: parametersData) as? [String: Any] {
                        functionDeclaration["parameters"] = parameters
                    }

                    return ["functionDeclarations": [functionDeclaration]]
                }

                requestBody["tools"] = geminiTools
                logger.debug("Added \(tools.count) tools to Gemini request [req:\(requestId.prefix(8))]")
            } else {
                logger.warning("Model \(modelForAPI) does not support function calling - skipping tools [req:\(requestId.prefix(8))]")
            }
        }

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        /// Add API key as query parameter (Gemini uses x-goog-api-key, not Bearer token)
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            if let urlWithKey = components.url {
                urlRequest.url = urlWithKey
            }
        }

        /// Set timeout (5 minutes minimum for tool-enabled requests)
        let configuredTimeout = TimeInterval(config.timeoutSeconds ?? 300)
        urlRequest.timeoutInterval = max(configuredTimeout, 300)

        logger.debug("Sending request to Gemini API [req:\(requestId.prefix(8))]")

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            logger.debug("Gemini API response [req:\(requestId.prefix(8))]: \(httpResponse.statusCode)")

            guard 200...299 ~= httpResponse.statusCode else {
                var errorMessage = "Gemini API returned status \(httpResponse.statusCode)"
                
                if let errorData = String(data: data, encoding: .utf8) {
                    logger.error("Gemini API error [req:\(requestId.prefix(8))]: \(errorData)")
                    
                    /// Check if this is a rate limit error (429)
                    if httpResponse.statusCode == 429 {
                        /// Parse retry delay from error response
                        if let retryDelay = parseRetryDelay(from: errorData) {
                            logger.info("Rate limit hit - retrying in \(retryDelay) seconds [req:\(requestId.prefix(8))]")
                            
                            /// Notify UI of rate limit
                            await MainActor.run {
                                NotificationCenter.default.post(
                                    name: .providerRateLimitHit,
                                    object: nil,
                                    userInfo: [
                                        "retryAfterSeconds": retryDelay,
                                        "providerName": "Gemini"
                                    ]
                                )
                            }
                            
                            /// Wait for the specified duration
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            
                            /// Notify UI that retry is starting
                            await MainActor.run {
                                NotificationCenter.default.post(name: .providerRateLimitRetrying, object: nil)
                            }
                            
                            /// Retry the request
                            logger.info("Retrying request after rate limit delay [req:\(requestId.prefix(8))]")
                            return try await processChatCompletion(request)
                        } else {
                            /// No retry timing available - use default backoff
                            logger.warning("Rate limit hit but no retry timing found - using 60s default [req:\(requestId.prefix(8))]")
                            
                            /// Notify UI of rate limit with default delay
                            await MainActor.run {
                                NotificationCenter.default.post(
                                    name: .providerRateLimitHit,
                                    object: nil,
                                    userInfo: [
                                        "retryAfterSeconds": 60.0,
                                        "providerName": "Gemini"
                                    ]
                                )
                            }
                            
                            try await Task.sleep(nanoseconds: 60_000_000_000)  /// 60 seconds
                            
                            /// Notify UI that retry is starting
                            await MainActor.run {
                                NotificationCenter.default.post(name: .providerRateLimitRetrying, object: nil)
                            }
                            
                            return try await processChatCompletion(request)
                        }
                    }
                    
                    /// Check if this is a function calling not supported error
                    if httpResponse.statusCode == 400 && errorData.contains("Function calling is not enabled") {
                        /// Cache that this model doesn't support function calling
                        Self.modelCapabilitiesCache[modelForAPI] = false
                        logger.warning("Model \(modelForAPI) doesn't support function calling - cached for future requests")
                        
                        /// Retry without tools if this was a tool-enabled request
                        if request.tools != nil && !request.tools!.isEmpty {
                            logger.info("Retrying request without tools [req:\(requestId.prefix(8))]")
                            /// Create new request without tools
                            let requestWithoutTools = OpenAIChatRequest(
                                model: request.model,
                                messages: request.messages,
                                temperature: request.temperature,
                                topP: request.topP,
                                repetitionPenalty: request.repetitionPenalty,
                                maxTokens: request.maxTokens,
                                stream: request.stream,
                                tools: nil,  /// Remove tools
                                samConfig: request.samConfig,
                                contextId: request.contextId,
                                enableMemory: request.enableMemory,
                                sessionId: request.sessionId,
                                conversationId: request.conversationId,
                                statefulMarker: request.statefulMarker,
                                iterationNumber: request.iterationNumber
                            )
                            return try await processChatCompletion(requestWithoutTools)
                        }
                    }
                    
                    errorMessage = errorData
                }
                throw ProviderError.networkError(errorMessage)
            }

            /// Parse Gemini response and convert to OpenAI format
            guard let geminiResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = geminiResponse["candidates"] as? [[String: Any]],
                  let candidate = candidates.first,
                  let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                throw ProviderError.networkError("Invalid Gemini response format")
            }

            /// Extract content blocks - Gemini returns array of parts
            var textContent = ""
            var toolCalls: [OpenAIToolCall] = []

            for part in parts {
                if let text = part["text"] as? String {
                    textContent += text
                } else if let functionCall = part["functionCall"] as? [String: Any],
                          let name = functionCall["name"] as? String,
                          let args = functionCall["args"] {
                    /// Convert Gemini functionCall to OpenAI tool_call format
                    let inputData = try? JSONSerialization.data(withJSONObject: args)
                    let inputString = inputData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                    /// Generate unique ID for tool call
                    let toolCallId = "\(name)_\(Int(Date().timeIntervalSince1970))"

                    let toolCall = OpenAIToolCall(
                        id: toolCallId,
                        type: "function",
                        function: OpenAIFunctionCall(name: name, arguments: inputString)
                    )
                    toolCalls.append(toolCall)
                    logger.debug("Converted Gemini functionCall '\(name)' to tool_call [req:\(requestId.prefix(8))]")
                }
            }

            /// Extract usage information
            var promptTokens = 0
            var completionTokens = 0
            if let usageMetadata = geminiResponse["usageMetadata"] as? [String: Any] {
                promptTokens = usageMetadata["promptTokenCount"] as? Int ?? 0
                completionTokens = usageMetadata["candidatesTokenCount"] as? Int ?? 0
            }

            /// Build assistant message
            let assistantMessage: OpenAIChatMessage
            if !toolCalls.isEmpty {
                assistantMessage = OpenAIChatMessage(
                    role: "assistant",
                    content: textContent.isEmpty ? nil : textContent,
                    toolCalls: toolCalls
                )
            } else {
                assistantMessage = OpenAIChatMessage(
                    role: "assistant",
                    content: textContent
                )
            }

            /// Extract finish reason
            let finishReason: String
            if let finishReasonRaw = candidate["finishReason"] as? String {
                /// Map Gemini finish reasons to OpenAI format
                switch finishReasonRaw {
                case "STOP": finishReason = "stop"
                case "MAX_TOKENS": finishReason = "length"
                case "SAFETY": finishReason = "content_filter"
                default: finishReason = "stop"
                }
            } else {
                finishReason = "stop"
            }

            /// Convert to OpenAI format
            let openAIResponse = ServerOpenAIChatResponse(
                id: "chatcmpl-gemini-\(requestId)",
                object: "chat.completion",
                created: Int(Date().timeIntervalSince1970),
                model: request.model,
                choices: [
                    OpenAIChatChoice(
                        index: 0,
                        message: assistantMessage,
                        finishReason: finishReason
                    )
                ],
                usage: ServerOpenAIUsage(
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    totalTokens: promptTokens + completionTokens
                )
            )

            logger.debug("Successfully processed Gemini response [req:\(requestId.prefix(8))] - text: \(textContent.count) chars, tools: \(toolCalls.count)")
            return openAIResponse

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("Gemini API request failed [req:\(requestId.prefix(8))]: \(error)")
            throw ProviderError.networkError("Network error: \(error.localizedDescription)")
        }
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        let models = config.models.map { modelId in
            ServerOpenAIModel(
                id: modelId,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: "google"
            )
        }

        return ServerOpenAIModelsResponse(
            object: "list",
            data: models
        )
    }

    public func supportsModel(_ model: String) -> Bool {
        return config.models.contains(model) || model.hasPrefix("gemini-")
    }

    public func validateConfiguration() async throws -> Bool {
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("Gemini API key is required")
        }

        return true
    }
    
    /// Parse retry delay from Gemini error response
    /// Checks both the error message ("Please retry in X.Xs") and RetryInfo details
    private func parseRetryDelay(from errorJson: String) -> Double? {
        /// Try parsing as JSON first to get structured retry info
        if let data = errorJson.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            
            /// Check for RetryInfo in details
            if let details = error["details"] as? [[String: Any]] {
                for detail in details {
                    if let type = detail["@type"] as? String,
                       type.contains("RetryInfo"),
                       let retryDelay = detail["retryDelay"] as? String {
                        /// Parse duration string like "21s" or "1.5s"
                        let seconds = retryDelay.replacingOccurrences(of: "s", with: "")
                        if let delay = Double(seconds) {
                            return delay
                        }
                    }
                }
            }
            
            /// Fallback: Parse from error message
            if let message = error["message"] as? String {
                /// Match pattern: "Please retry in XX.XXs"
                let pattern = #"retry in ([\d.]+)s"#
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                   let delayRange = Range(match.range(at: 1), in: message) {
                    let delayString = String(message[delayRange])
                    if let delay = Double(delayString) {
                        return delay
                    }
                }
            }
        }
        
        return nil
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
