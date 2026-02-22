// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConversationEngine
import ConfigurationSystem
import Logging
@MainActor
public class OpenAIProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration
    private let logger = Logging.Logger(label: "com.sam.provider.openai")

    public init(config: ProviderConfiguration) {
        self.identifier = config.providerId
        self.config = config
        logger.debug("OpenAI Provider initialized")
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        /// Fallback streaming implementation for providers without native SSE support.
        /// Simulates streaming by chunking the non-streaming response.
        /// Real SSE streaming is implemented in providers that support it (MLX, GitHub Copilot, etc.).
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    /// Check cancellation before HTTP request.
                    if Task.isCancelled {
                        self.logger.debug("TASK_CANCELLED: OpenAI request cancelled before start")
                        continuation.finish()
                        return
                    }

                    let response = try await self.processChatCompletion(request)
                    let chunks = self.convertToStreamChunks(response)

                    for chunk in chunks {
                        /// Check cancellation in streaming loop.
                        if Task.isCancelled {
                            self.logger.debug("TASK_CANCELLED: OpenAI streaming cancelled")
                            continuation.finish()
                            return
                        }

                        continuation.yield(chunk)
                        /// Add small delay to simulate streaming.
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

        /// First chunk with role.
        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(
                index: 0,
                delta: OpenAIChatDelta(role: "assistant", content: nil)
            )]
        ))

        /// Split content into words for streaming simulation.
        let words = (choice.message.content ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        for word in words {
            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(
                    index: 0,
                    delta: OpenAIChatDelta(content: word + " ")
                )]
            ))
        }

        /// Final chunk.
        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(
                index: 0,
                delta: OpenAIChatDelta(),
                finishReason: "stop"
            )]
        ))

        return chunks
    }

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        let requestId = UUID().uuidString
        logger.debug("Processing chat completion via OpenAI API [req:\(requestId.prefix(8))]")

        guard let apiKey = config.apiKey else {
            throw ProviderError.authenticationFailed("OpenAI API key not configured")
        }

        guard let baseURL = config.baseURL ?? ProviderType.openai.defaultBaseURL else {
            throw ProviderError.invalidConfiguration("OpenAI base URL not configured")
        }

        /// Prepare OpenAI API request.
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ProviderError.invalidConfiguration("Invalid OpenAI base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        /// Strip provider prefix from model name before sending to API User-facing: "openai/gpt-4" → API expects: "gpt-4".
        let modelForAPI = request.model.contains("/")
            ? request.model.components(separatedBy: "/").last ?? request.model
            : request.model

        /// Create request body.
        let requestBody: [String: Any] = [
            "model": modelForAPI,
            "messages": request.messages.map { message in
                [
                    "role": message.role,
                    "content": message.content
                ]
            },
            /// CRITICAL: Ensure max_tokens is at least 2048 to prevent truncated responses
            "max_tokens": max(request.maxTokens ?? config.maxTokens ?? 4096, 2048),
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

        logger.debug("Sending request to OpenAI API [req:\(requestId.prefix(8))]")

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            logger.debug("OpenAI API response [req:\(requestId.prefix(8))]: \(httpResponse.statusCode)")

            guard 200...299 ~= httpResponse.statusCode else {
                if let errorData = String(data: data, encoding: .utf8) {
                    logger.error("OpenAI API error [req:\(requestId.prefix(8))]: \(errorData)")
                }
                throw ProviderError.networkError("OpenAI API returned status \(httpResponse.statusCode)")
            }

            /// Parse response.
            let openaiResponse = try JSONDecoder().decode(ServerOpenAIChatResponse.self, from: data)
            logger.debug("Successfully processed OpenAI response [req:\(requestId.prefix(8))]")

            return openaiResponse

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("OpenAI API request failed [req:\(requestId.prefix(8))]: \(error)")
            throw ProviderError.networkError("Network error: \(error.localizedDescription)")
        }
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        let models = config.models.map { modelId in
            ServerOpenAIModel(
                id: modelId,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: "openai"
            )
        }

        return ServerOpenAIModelsResponse(
            object: "list",
            data: models
        )
    }

    public func supportsModel(_ model: String) -> Bool {
        return config.models.contains(model) || model.hasPrefix("gpt-")
    }

    public func validateConfiguration() async throws -> Bool {
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("OpenAI API key is required")
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

    // MARK: - Model Capabilities Fetching

    /// Fetch model capabilities from OpenAI /v1/models API Returns dictionary of modelId -> max_tokens (context size).
    public func fetchModelCapabilities() async throws -> [String: Int] {
        logger.debug("Fetching model capabilities from OpenAI /v1/models API")

        guard let apiKey = config.apiKey else {
            throw ProviderError.authenticationFailed("OpenAI API key not configured")
        }

        guard let baseURL = config.baseURL ?? ProviderType.openai.defaultBaseURL else {
            throw ProviderError.invalidConfiguration("OpenAI base URL not configured")
        }

        guard let url = URL(string: "\(baseURL)/models") else {
            throw ProviderError.invalidConfiguration("Invalid OpenAI models URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("OpenAI /models API error [\(httpResponse.statusCode)]: \(errorText.prefix(200))")
            throw ProviderError.networkError("OpenAI /models API returned status \(httpResponse.statusCode)")
        }

        /// Parse response.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            throw ProviderError.responseNormalizationFailed("Failed to parse OpenAI /models response")
        }

        /// Build capabilities dictionary.
        var capabilities: [String: Int] = [:]
        for model in models {
            guard let id = model["id"] as? String else { continue }

            /// OpenAI doesn't always include max_tokens in /models response We'll use known values or defaults based on model name.
            let contextSize: Int
            let idLower = id.lowercased()

            if idLower.contains("gpt-4-turbo") || idLower.contains("gpt-4-1106") || idLower.contains("gpt-4.1") {
                contextSize = 128000
            } else if idLower.contains("gpt-4") {
                contextSize = 8192
            } else if idLower.contains("gpt-3.5-turbo-16k") {
                contextSize = 16385
            } else if idLower.contains("gpt-3.5") {
                contextSize = 4096
            } else if idLower.contains("o1") || idLower.contains("o3") {
                contextSize = 128000
            } else {
                contextSize = 8192
            }

            capabilities[id] = contextSize
            logger.debug("OpenAI model '\(id)': \(contextSize) tokens")
        }

        logger.debug("Successfully fetched \(capabilities.count) OpenAI model capabilities")
        return capabilities
    }

    public func unload() async {
        /// No-op for remote providers.
    }
}

// MARK: - Anthropic Provider

/// Provider for Anthropic Claude API integration.
@MainActor
public class AnthropicProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration
    private let logger = Logging.Logger(label: "com.sam.provider.anthropic")

    public init(config: ProviderConfiguration) {
        self.identifier = config.providerId
        self.config = config
        logger.debug("Anthropic Provider initialized")
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    /// Check cancellation before HTTP request.
                    if Task.isCancelled {
                        self.logger.debug("TASK_CANCELLED: Anthropic request cancelled before start")
                        continuation.finish()
                        return
                    }

                    let response = try await self.processChatCompletion(request)
                    let chunks = self.convertToStreamChunks(response)

                    for chunk in chunks {
                        /// Check cancellation in streaming loop.
                        if Task.isCancelled {
                            self.logger.debug("TASK_CANCELLED: Anthropic streaming cancelled")
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
            choices: [OpenAIChatStreamChoice(
                index: 0,
                delta: OpenAIChatDelta(role: "assistant", content: nil)
            )]
        ))

        let words = (choice.message.content ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        for word in words {
            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(
                    index: 0,
                    delta: OpenAIChatDelta(content: word + " ")
                )]
            ))
        }

        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(
                index: 0,
                delta: OpenAIChatDelta(),
                finishReason: "stop"
            )]
        ))

        return chunks
    }

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        let requestId = UUID().uuidString
        logger.debug("Processing chat completion via Anthropic API [req:\(requestId.prefix(8))]")

        guard let apiKey = config.apiKey else {
            throw ProviderError.authenticationFailed("Anthropic API key not configured")
        }

        guard let baseURL = config.baseURL ?? ProviderType.anthropic.defaultBaseURL else {
            throw ProviderError.invalidConfiguration("Anthropic base URL not configured")
        }

        /// Anthropic uses Messages API (not OpenAI-compatible).
        guard let url = URL(string: "\(baseURL)/messages") else {
            throw ProviderError.invalidConfiguration("Invalid Anthropic base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        /// Convert OpenAI format to Anthropic format using proper converter.
        let conversionResult = AnthropicMessageConverter.convertMessages(request.messages)
        let anthropicMessages = conversionResult.messages
        let systemMessage = conversionResult.systemMessage

        /// Validate converted messages.
        if !AnthropicMessageConverter.validateMessages(anthropicMessages) {
            logger.error("Message validation failed - messages do not meet Anthropic requirements [req:\(requestId.prefix(8))]")
            throw ProviderError.invalidRequest("Messages do not meet Anthropic format requirements")
        }

        /// Strip provider prefix from model name before sending to API User-facing: "anthropic/claude-3-opus" → API expects: "claude-3-opus".
        let modelForAPI = request.model.contains("/")
            ? request.model.components(separatedBy: "/").last ?? request.model
            : request.model

        /// Create Anthropic request body.
        var requestBody: [String: Any] = [
            "model": modelForAPI,
            "messages": anthropicMessages,
            /// CRITICAL: Ensure max_tokens is at least 2048 to prevent truncated responses
            "max_tokens": max(request.maxTokens ?? config.maxTokens ?? 4096, 2048)
        ]

        if let system = systemMessage {
            requestBody["system"] = system
        }

        if let temperature = request.temperature ?? config.temperature {
            requestBody["temperature"] = temperature
        }

        /// Add tools support if present.
        if let tools = request.tools, !tools.isEmpty {
            /// Convert OpenAI tool format to Anthropic format.
            let anthropicTools: [[String: Any]] = tools.map { tool in
                var anthropicTool: [String: Any] = [
                    "name": tool.function.name,
                    "description": tool.function.description
                ]

                /// Parse parameters JSON string to dictionary.
                if let parametersData = tool.function.parametersJson.data(using: .utf8),
                   let parameters = try? JSONSerialization.jsonObject(with: parametersData) as? [String: Any] {
                    anthropicTool["input_schema"] = parameters
                }

                return anthropicTool
            }

            requestBody["tools"] = anthropicTools
            logger.debug("Added \(tools.count) tools to Anthropic request [req:\(requestId.prefix(8))]")
        }

        /// Future feature: Beta features support (thinking, cache control) Requires configuration flags and thinking budget calculation.

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        /// Set timeout (5 minutes minimum for tool-enabled requests, especially 7B models).
        /// Even if config specifies lower timeout, enforce 300s minimum to prevent timeouts.
        let configuredTimeout = TimeInterval(config.timeoutSeconds ?? 300)
        urlRequest.timeoutInterval = max(configuredTimeout, 300)

        logger.debug("Sending request to Anthropic API [req:\(requestId.prefix(8))]")

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            logger.debug("Anthropic API response [req:\(requestId.prefix(8))]: \(httpResponse.statusCode)")

            guard 200...299 ~= httpResponse.statusCode else {
                if let errorData = String(data: data, encoding: .utf8) {
                    logger.error("Anthropic API error [req:\(requestId.prefix(8))]: \(errorData)")
                }
                throw ProviderError.networkError("Anthropic API returned status \(httpResponse.statusCode)")
            }

            /// Parse Anthropic response and convert to OpenAI format.
            let anthropicResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let anthropicResponse = anthropicResponse,
                  let content = anthropicResponse["content"] as? [[String: Any]] else {
                throw ProviderError.networkError("Invalid Anthropic response format")
            }

            /// Extract content blocks - Anthropic returns array of content blocks.
            var textContent = ""
            var toolCalls: [OpenAIToolCall] = []

            for block in content {
                if let type = block["type"] as? String {
                    switch type {
                    case "text":
                        if let text = block["text"] as? String {
                            textContent += text
                        }
                    case "tool_use":
                        /// Convert Anthropic tool_use to OpenAI tool_call format.
                        if let id = block["id"] as? String,
                           let name = block["name"] as? String,
                           let input = block["input"] {
                            /// Convert input to JSON string.
                            let inputData = try? JSONSerialization.data(withJSONObject: input)
                            let inputString = inputData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                            let toolCall = OpenAIToolCall(
                                id: id,
                                type: "function",
                                function: OpenAIFunctionCall(name: name, arguments: inputString)
                            )
                            toolCalls.append(toolCall)
                        }
                    case "thinking":
                        /// Thinking blocks - log but don't include in response for now.
                        if let thinking = block["thinking"] as? String {
                            logger.debug("Anthropic thinking block: \(thinking.prefix(100))... [req:\(requestId.prefix(8))]")
                        }
                    default:
                        logger.warning("Unknown Anthropic content block type: \(type) [req:\(requestId.prefix(8))]")
                    }
                }
            }

            /// Extract usage information.
            var promptTokens = 0
            var completionTokens = 0
            if let usage = anthropicResponse["usage"] as? [String: Any] {
                promptTokens = usage["input_tokens"] as? Int ?? 0
                completionTokens = usage["output_tokens"] as? Int ?? 0
            }

            /// Build assistant message with proper content and tool calls.
            let assistantMessage: OpenAIChatMessage
            if !toolCalls.isEmpty {
                /// If we have tool calls, content might be empty.
                assistantMessage = OpenAIChatMessage(
                    role: "assistant",
                    content: textContent.isEmpty ? nil : textContent,
                    toolCalls: toolCalls
                )
            } else {
                /// Regular text response.
                assistantMessage = OpenAIChatMessage(
                    role: "assistant",
                    content: textContent
                )
            }

            /// Convert to OpenAI format.
            let openAIResponse = ServerOpenAIChatResponse(
                id: anthropicResponse["id"] as? String ?? "chatcmpl-anthropic-\(requestId)",
                object: "chat.completion",
                created: Int(Date().timeIntervalSince1970),
                model: request.model,
                choices: [
                    OpenAIChatChoice(
                        index: 0,
                        message: assistantMessage,
                        finishReason: anthropicResponse["stop_reason"] as? String ?? "stop"
                    )
                ],
                usage: ServerOpenAIUsage(
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    totalTokens: promptTokens + completionTokens
                )
            )

            logger.debug("Successfully processed Anthropic response [req:\(requestId.prefix(8))] - text: \(textContent.count) chars, tools: \(toolCalls.count)")
            return openAIResponse

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("Anthropic API request failed [req:\(requestId.prefix(8))]: \(error)")
            throw ProviderError.networkError("Network error: \(error.localizedDescription)")
        }
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        let models = config.models.map { modelId in
            ServerOpenAIModel(
                id: modelId,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: "anthropic"
            )
        }

        return ServerOpenAIModelsResponse(
            object: "list",
            data: models
        )
    }

    public func supportsModel(_ model: String) -> Bool {
        /// Only match models explicitly listed in config DO NOT use pattern matching (e.g., hasPrefix("claude-")) Prevents conflicts when Claude is available via multiple providers (Copilot + Anthropic) Pattern matching was causing Anthropic provider to intercept "claude-*" requests intended for GitHub Copilot provider.
        return config.models.contains(model)
    }

    public func validateConfiguration() async throws -> Bool {
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("Anthropic API key is required")
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

// MARK: - GitHub Copilot Provider

/// Provider for GitHub Copilot API integration.
@MainActor
/// GitHub Copilot Provider - BREAKTHROUGH INTEGRATION WITH TOOL SUPPORT MAJOR ACHIEVEMENTS IN THIS SESSION: This provider represents a significant breakthrough in SAM development.
public class GitHubCopilotProvider: AIProvider, ObservableObject {
    public let identifier: String
    public var config: ProviderConfiguration
    private let logger = Logging.Logger(label: "com.sam.provider.github")

    /// Cache for model capabilities (context sizes) - static to survive provider recreations
    private static var modelCapabilitiesCache: [String: Int]?
    private static var modelCapabilitiesCacheTime: Date?

    /// Cache for model billing information (premium status + multipliers).
    private var modelBillingCache: [String: (isPremium: Bool, multiplier: Double?)]?

    private let cacheValidityDuration: TimeInterval = 3600

    /// Rate limiter to prevent hitting GitHub Copilot API rate limits
    /// Minimum interval increases after 429 errors (exponential backoff)
    private var lastRequestTime: Date?
    private var minimumRequestInterval: TimeInterval = 3.0
    private var consecutiveRateLimitErrors: Int = 0
    private let baseInterval: TimeInterval = 3.0
    private let maxInterval: TimeInterval = 60.0

    /// RATE LIMIT BARRIER: When set, ALL requests must wait until this time
    /// This is set after a 429 error to ensure the FULL backoff period is respected
    /// before any subsequent request is attempted (fixes the "immediate retry after 429" bug)
    private var rateLimitedUntil: Date?

    /// Cache persistence paths
    private let billingCachePath: URL = {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("sam")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        return configDir.appendingPathComponent("github_copilot_billing_cache.json")
    }()

    private let quotaCachePath: URL = {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("sam")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        return configDir.appendingPathComponent("github_copilot_quota_cache.json")
    }()

    /// Token counter for context management (CRITICAL for Claude 400 fix).
    private let tokenCounter = TokenCounter()

    public init(config: ProviderConfiguration) {
        self.identifier = config.providerId
        self.config = config
        logger.debug("GitHub Copilot Provider initialized")

        /// Load cached data on init
        loadBillingCache()
        loadQuotaCache()
    }

    /// Get API key - tries Copilot token first, falls back to config API key
    /// Both device flow tokens (via CopilotTokenStore) and manual API keys support billing data
    private func getAPIKey() async throws -> String {
        // Try Copilot token first (from device flow - preferred)
        do {
            let token = try await CopilotTokenStore.shared.getCopilotToken()
            logger.debug("Using GitHub token from device flow")
            return token
        } catch {
            logger.debug("Device flow token unavailable: \(error.localizedDescription)")
        }
        
        // Fall back to manual API key
        guard let apiKey = config.apiKey else {
            throw ProviderError.authenticationFailed("GitHub Copilot API key not configured. Please sign in with GitHub or provide an API key in Preferences.")
        }
        
        logger.debug("Using manually configured API key")
        return apiKey
    }
    
    /// Check if authentication is available (device flow token or manual API key)
    /// Used to avoid unnecessary API calls when not authenticated
    public func hasAuthentication() async -> Bool {
        // Check device flow token
        if let _ = try? await CopilotTokenStore.shared.getCopilotToken() {
            return true
        }
        
        // Check manual API key
        return config.apiKey != nil
    }

    /// Fetch model capabilities from GitHub Copilot /models API Returns dictionary of modelId -> max_input_tokens (context size) **Why needed**: GitHub Copilot doesn't include model capabilities in main API responses.
    public func fetchModelCapabilities() async throws -> [String: Int] {
        /// Check cache first.
        if let cache = Self.modelCapabilitiesCache,
           let cacheTime = Self.modelCapabilitiesCacheTime,
           Date().timeIntervalSince(cacheTime) < cacheValidityDuration {
            logger.debug("Returning cached model capabilities (\(cache.count) models)")
            return cache
        }

        logger.info("Fetching model capabilities from GitHub Copilot /models API")

        let apiKey = try await getAPIKey()

        let baseURL: String
        let configuredURL = config.baseURL
        if let url = configuredURL, url != "https://api.githubcopilot.com" {
            // User has explicitly configured a non-default URL - respect it
            baseURL = url
        } else {
            // Use user-specific endpoint from profile (e.g. api.individual.githubcopilot.com)
            // Falls back to api.githubcopilot.com if profile not yet fetched
            baseURL = await CopilotUserAPIClient.shared.getCopilotBaseURL()
        }
        let modelsURL = "\(baseURL)/models"

        guard let url = URL(string: modelsURL) else {
            throw ProviderError.invalidConfiguration("Invalid GitHub Copilot models URL: \(modelsURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData  // Disable caching
        urlRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        /// Add GitHub Copilot headers.
        let samVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
        /// GitHub Copilot API requires "vscode/" prefix for Editor-Version header per API specification.
        urlRequest.setValue("vscode/\(samVersion)", forHTTPHeaderField: "Editor-Version")
        urlRequest.setValue("GitHubCopilotChat/\(samVersion)", forHTTPHeaderField: "User-Agent")

        /// Additional headers required for billing metadata (is_premium, multiplier)
        /// GitHub Copilot API billing metadata requirements
        urlRequest.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        urlRequest.setValue("model-access", forHTTPHeaderField: "OpenAI-Intent")
        urlRequest.setValue("2025-05-01", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            #if DEBUG
            /// Save raw response to file for debugging (debug builds only)
            let debugPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/sam/debug_github_models_response.json")
            try? data.write(to: debugPath)
            #endif

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            /// Handle different HTTP status codes appropriately.
            guard 200...299 ~= httpResponse.statusCode else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "No error details available"
                logger.error("GitHub Copilot /models API error status=\(httpResponse.statusCode): \(errorMessage.prefix(500))")

                switch httpResponse.statusCode {
                case 429:
                    /// Respect Retry-After header if present
                    let retryAfterValue = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    if let retryAfter = retryAfterValue, let seconds = Int(retryAfter) {
                        throw ProviderError.rateLimitExceeded("GitHub Copilot /models API rate limit exceeded. Try again in \(seconds) seconds.")
                    } else {
                        throw ProviderError.rateLimitExceeded("GitHub Copilot /models API rate limit exceeded. Try again in 60 seconds.")
                    }

                case 400:
                    throw ProviderError.invalidRequest("GitHub Copilot /models API bad request (400). Details: \(errorMessage.prefix(200))")

                case 401, 403:
                    // Attempt token recovery before failing
                    if let freshToken = await CopilotTokenStore.shared.attemptTokenRecovery() {
                        logger.info("Token recovered after \(httpResponse.statusCode) on /models, retrying")
                        var retryRequest = URLRequest(url: urlRequest.url!)
                        retryRequest.httpMethod = urlRequest.httpMethod
                        retryRequest.allHTTPHeaderFields = urlRequest.allHTTPHeaderFields
                        retryRequest.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
                        let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                        if let retryHttp = retryResponse as? HTTPURLResponse, 200...299 ~= retryHttp.statusCode {
                            let decoder = JSONDecoder()
                            let modelsResponse = try decoder.decode(GitHubCopilotModelsResponse.self, from: retryData)
                            // Continue processing below (need to break out of guard)
                            // For simplicity, recurse by calling fetchModelCapabilities again
                            // Token is now fresh so it should succeed
                            Self.modelCapabilitiesCache = nil  // Clear cache to force refetch
                            Self.modelCapabilitiesCacheTime = nil
                            return try await fetchModelCapabilities()
                        }
                    }
                    throw ProviderError.authenticationFailed("GitHub Copilot /models API authentication failed (\(httpResponse.statusCode)). Check API key validity.")

                default:
                    throw ProviderError.networkError("GitHub Copilot /models API returned status \(httpResponse.statusCode): \(errorMessage.prefix(200))")
                }
            }

            let decoder = JSONDecoder()
            let modelsResponse = try decoder.decode(GitHubCopilotModelsResponse.self, from: data)

            /// DEBUG: Log raw JSON for first model to see what API is returning
            if let firstModelData = String(data: data, encoding: .utf8)?.prefix(2000) {
                logger.debug("RAW API RESPONSE (first 2000 chars): \(firstModelData)")
            }

            /// Build capabilities dictionary.
            var capabilities: [String: Int] = [:]
            var billingInfo: [String: (isPremium: Bool, multiplier: Double?)] = [:]

            for model in modelsResponse.data {
                if let maxInputTokens = model.maxInputTokens {
                    capabilities[model.id] = maxInputTokens

                    /// Store billing information using computed properties
                    billingInfo[model.id] = (isPremium: model.isPremium, multiplier: model.premiumMultiplier)
                    
                    /// DEBUG: Log billing data for first few models
                    if billingInfo.count <= 5 {
                        logger.debug("BILLING: \(model.id) - isPremium=\(model.isPremium), multiplier=\(model.premiumMultiplier?.description ?? "nil"), raw_billing=\(model.billing != nil ? "present" : "nil")")
                    }
                }
            }

            logger.info("Successfully fetched capabilities for \(capabilities.count) models")

            /// Update caches.
            Self.modelCapabilitiesCache = capabilities
            modelBillingCache = billingInfo
            Self.modelCapabilitiesCacheTime = Date()

            /// Update config.models with fresh model list from API
            /// Filter to only include models with policy.state="enabled" or no policy (backwards compatibility)
            /// This prevents disabled/unconfigured models (Gemini, Grok) from appearing in model picker
            let availableModels = modelsResponse.data.filter { $0.isAvailable }
            let modelIds = availableModels.map { $0.id }

            let filteredCount = modelsResponse.data.count - availableModels.count
            if filteredCount > 0 {
                logger.info("Filtered out \(filteredCount) disabled/unconfigured models")
                let disabledModels = modelsResponse.data.filter { !$0.isAvailable }.map { $0.id }
                logger.debug("Disabled models: \(disabledModels.joined(separator: ", "))")
            }

            config.models = modelIds
            logger.info("Updated config.models with \(modelIds.count) available models from API")

            /// Persist billing data to disk
            saveBillingCache()

            /// Persist updated configuration with new model list
            saveProviderConfiguration()

            return capabilities

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("Failed to fetch model capabilities: \(error)")
            throw ProviderError.networkError("Failed to fetch model capabilities: \(error.localizedDescription)")
        }
    }
    
    /// Clear the capabilities cache to force a fresh fetch next time
    public func clearCapabilitiesCache() {
        Self.modelCapabilitiesCache = nil
        Self.modelCapabilitiesCacheTime = nil
        logger.debug("Cleared capabilities cache - next fetch will be fresh from API")
    }

    /// Load billing cache from disk
    private func loadBillingCache() {
        guard FileManager.default.fileExists(atPath: billingCachePath.path) else {
            logger.debug("No billing cache file found, will fetch fresh data")
            return
        }

        do {
            let data = try Data(contentsOf: billingCachePath)
            let decoder = JSONDecoder()
            let cache = try decoder.decode([String: BillingCacheEntry].self, from: data)

            /// Convert from codable format to internal format
            var billingInfo: [String: (isPremium: Bool, multiplier: Double?)] = [:]
            for (key, entry) in cache {
                billingInfo[key] = (isPremium: entry.isPremium, multiplier: entry.multiplier)
            }

            modelBillingCache = billingInfo
            logger.debug("Loaded billing cache with \(billingInfo.count) models from disk")
        } catch {
            logger.warning("Failed to load billing cache: \(error)")
        }
    }

    /// Save billing cache to disk
    private func saveBillingCache() {
        guard let billingCache = modelBillingCache else {
            return
        }

        do {
            /// Convert to codable format
            var cache: [String: BillingCacheEntry] = [:]
            for (key, value) in billingCache {
                cache[key] = BillingCacheEntry(isPremium: value.isPremium, multiplier: value.multiplier)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cache)

            try data.write(to: billingCachePath, options: .atomic)
            logger.debug("Saved billing cache with \(cache.count) models to disk")
        } catch {
            logger.error("Failed to save billing cache: \(error)")
        }
    }

    /// Load quota cache from disk
    private func loadQuotaCache() {
        guard FileManager.default.fileExists(atPath: quotaCachePath.path) else {
            logger.debug("No quota cache file found")
            return
        }

        do {
            let data = try Data(contentsOf: quotaCachePath)
            let decoder = JSONDecoder()
            let quotaInfo = try decoder.decode(QuotaInfo.self, from: data)

            /// Update on main thread (check if already on main thread to avoid deadlock)
            if Thread.isMainThread {
                self.currentQuotaInfo = quotaInfo
                logger.debug("Loaded quota cache from disk: \(quotaInfo.used)/\(quotaInfo.entitlement)")
            } else {
                DispatchQueue.main.sync {
                    self.currentQuotaInfo = quotaInfo
                    logger.debug("Loaded quota cache from disk: \(quotaInfo.used)/\(quotaInfo.entitlement)")
                }
            }
        } catch {
            logger.error("Failed to load quota cache: \(error)")
        }
    }

    /// Save quota cache to disk
    private func saveQuotaCache() {
        guard let quotaInfo = currentQuotaInfo else {
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(quotaInfo)

            try data.write(to: quotaCachePath, options: .atomic)
            logger.debug("Saved quota cache to disk")
        } catch {
            logger.error("Failed to save quota cache: \(error)")
        }
    }

    /// Save provider configuration to UserDefaults
    private func saveProviderConfiguration() {
        let key = "provider_config_\(identifier)"

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(config)
            UserDefaults.standard.set(data, forKey: key)
            logger.debug("Saved provider configuration with \(config.models.count) models")
        } catch {
            logger.error("Failed to save provider configuration: \(error)")
        }
    }

    /// Get billing information for a specific model
    public func getModelBillingInfo(modelId: String) -> (isPremium: Bool, multiplier: Double?)? {
        return modelBillingCache?[modelId]
    }

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        /// Use shared implementation with streaming disabled.
        return try await processGitHubCopilotRequest(request, streaming: false)
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        /// Use Responses API for models that support it (gpt-4, gpt-4.1, gpt-4-turbo) This fixes billing bug where gpt-4.1 requests were using Chat Completions API.
        if useResponsesApi(for: request.model) {
            logger.debug("Using Responses API for GitHub Copilot (supports statefulMarker)")
            return try await processStreamingResponsesAPI(request)
        } else {
            logger.debug("Using Chat Completions API for GitHub Copilot (legacy, no statefulMarker)")
            return try await processStreamingChatCompletionsAPI(request)
        }
    }

    /// Process streaming chat completion via Chat Completions API (legacy) NOTE: This API does NOT support statefulMarker - use Responses API instead.
    private func processStreamingChatCompletionsAPI(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        let requestId = UUID().uuidString
        logger.debug("Processing streaming chat completion via GitHub Copilot Chat Completions API [req:\(requestId.prefix(8))]")

        /// RATE LIMIT BARRIER: If we're rate limited, wait until the barrier time
        /// This ensures the FULL backoff period is respected after a 429 error
        if let rateLimitBarrier = rateLimitedUntil {
            let waitTime = rateLimitBarrier.timeIntervalSinceNow
            if waitTime > 0 {
                logger.warning("RATE_LIMIT_BARRIER: Rate limited, waiting \(String(format: "%.1f", waitTime))s before next request [req:\(requestId.prefix(8))]")
                try await Task.sleep(for: .seconds(waitTime))
            }
            rateLimitedUntil = nil  // Clear after waiting
        }

        /// RATE LIMITING: Enforce minimum interval between API requests to prevent 429 errors
        if let lastRequest = lastRequestTime {
            let timeSinceLastRequest = Date().timeIntervalSince(lastRequest)
            if timeSinceLastRequest < minimumRequestInterval {
                let waitTime = minimumRequestInterval - timeSinceLastRequest
                logger.info("RATE_LIMIT: Waiting \(String(format: "%.1f", waitTime))s before next API request (min interval: \(minimumRequestInterval)s)")
                try await Task.sleep(for: .seconds(waitTime))
            }
        }
        lastRequestTime = Date()

        let apiKey = try await getAPIKey()

        let urlRequest = try await createGitHubCopilotRequest(request, apiKey: apiKey, streaming: true)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    /// Check cancellation before HTTP request.
                    if Task.isCancelled {
                        self.logger.debug("TASK_CANCELLED: GitHub Copilot request cancelled before start")
                        continuation.finish()
                        return
                    }

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ProviderError.networkError("Invalid response type"))
                        return
                    }

                    /// Handle different HTTP status codes appropriately.
                    guard 200...299 ~= httpResponse.statusCode else {
                        /// Note: In streaming mode, error body is not yet available at this point.
                        let statusCode = httpResponse.statusCode

                        switch statusCode {
                        case 429:
                            /// EXPONENTIAL BACKOFF: Increase interval after rate limit errors
                            self.consecutiveRateLimitErrors += 1

                            /// PREFER Retry-After header if provided by the server
                            var waitInterval: TimeInterval
                            if let retryAfterHeader = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                               let retryAfterSeconds = Double(retryAfterHeader) {
                                /// Server explicitly told us how long to wait
                                waitInterval = retryAfterSeconds
                                self.logger.info("RATE_LIMIT: Using Retry-After header value: \(retryAfterSeconds)s")
                            } else {
                                /// No Retry-After header - use exponential backoff
                                waitInterval = min(self.maxInterval, self.baseInterval * pow(2, Double(self.consecutiveRateLimitErrors)))
                                self.logger.info("RATE_LIMIT: No Retry-After header, using exponential backoff: \(waitInterval)s")
                            }

                            self.minimumRequestInterval = max(self.baseInterval, waitInterval)
                            /// SET RATE LIMIT BARRIER: Next request must wait the FULL backoff period
                            self.rateLimitedUntil = Date().addingTimeInterval(waitInterval)
                            self.logger.warning("GitHub Copilot rate limit exceeded (429) [req:\(requestId.prefix(8))]. Setting rate limit barrier for \(waitInterval)s (error count: \(self.consecutiveRateLimitErrors))")
                            continuation.finish(throwing: ProviderError.rateLimitExceeded("GitHub Copilot rate limit exceeded. Waiting \(Int(waitInterval))s before next request."))
                            return

                        case 400:
                            /// Bad request - try to read error body for details
                            var errorBody = ""
                            for try await chunk in bytes {
                                errorBody.append(Character(UnicodeScalar(chunk)))
                                if errorBody.count > 2000 { break }
                            }
                            self.logger.error("GitHub Copilot bad request (400) [req:\(requestId.prefix(8))]. Error details: \(errorBody.prefix(1000))")
                            continuation.finish(throwing: ProviderError.invalidRequest("GitHub Copilot rejected request (400). Details: \(errorBody.prefix(500))"))
                            return

                        case 401, 403:
                            /// Authentication failure - attempt token recovery before giving up
                            self.logger.warning("GitHub Copilot authentication failed (\(statusCode)) [req:\(requestId.prefix(8))], attempting token recovery...")
                            if let _ = await CopilotTokenStore.shared.attemptTokenRecovery() {
                                self.logger.info("Token recovered after \(statusCode), signaling retry [req:\(requestId.prefix(8))]")
                                continuation.finish(throwing: ProviderError.authRecoverable("Token refreshed after \(statusCode). Retry the request."))
                            } else {
                                self.logger.error("Token recovery failed [req:\(requestId.prefix(8))]")
                                continuation.finish(throwing: ProviderError.authenticationFailed("GitHub Copilot authentication failed (\(statusCode)). Check API key validity."))
                            }
                            return

                        case 500...599:
                            /// Server errors - retry might help.
                            self.logger.warning("GitHub Copilot server error (\(statusCode)) [req:\(requestId.prefix(8))]. Retry may succeed.")
                            continuation.finish(throwing: ProviderError.networkError("GitHub Copilot server error (\(statusCode)). Temporary issue, retry may succeed."))
                            return

                        default:
                            self.logger.error("GitHub Copilot API error (\(statusCode)) [req:\(requestId.prefix(8))]")
                            continuation.finish(throwing: ProviderError.networkError("GitHub Copilot API returned status \(statusCode)"))
                            return
                        }
                    }

                    /// SUCCESS: Request passed status check - reset rate limit tracking
                    self.consecutiveRateLimitErrors = max(0, self.consecutiveRateLimitErrors - 1)
                    if self.consecutiveRateLimitErrors == 0 {
                        self.minimumRequestInterval = self.baseInterval
                    }

                    /// PREMIUM QUOTA TRACKING: Extract quota information from response headers.
                    await processGitHubCopilotQuotaHeaders(httpResponse.allHeaderFields, requestId: requestId)

                    var incompleteBuffer = ""
                    var byteBuffer: [UInt8] = []

                    for try await byte in bytes {
                        /// Check cancellation in streaming loop.
                        if Task.isCancelled {
                            self.logger.debug("TASK_CANCELLED: GitHub Copilot streaming cancelled")
                            continuation.finish()
                            return
                        }

                        /// Accumulate bytes.
                        byteBuffer.append(byte)

                        /// Try to decode accumulated bytes.
                        if let char = String(bytes: byteBuffer, encoding: .utf8) {
                            /// Successfully decoded!.
                            incompleteBuffer.append(char)
                            byteBuffer.removeAll(keepingCapacity: true)
                        }
                        /// If decoding fails, continue accumulating bytes (multi-byte UTF-8 characters need all bytes before decoding succeeds).

                        /// Process complete SSE events (ending with double newline).
                        while incompleteBuffer.contains("\n\n") {
                            if let doubleNewlineRange = incompleteBuffer.range(of: "\n\n") {
                                let completeEvent = String(incompleteBuffer[..<doubleNewlineRange.lowerBound])

                                /// Remove processed event from buffer.
                                let beforeLength = incompleteBuffer.count
                                incompleteBuffer = String(incompleteBuffer[doubleNewlineRange.upperBound...])
                                let afterLength = incompleteBuffer.count
                                if beforeLength == afterLength {
                                    self.logger.error("SSE_BUFFER_NOT_CONSUMED: Buffer size unchanged!")
                                }

                                /// Process the complete SSE event.
                                let lines = completeEvent.components(separatedBy: "\n")
                                self.logger.debug("SSE_EVENT_PARSE: Processing \(lines.count) lines")

                                for line in lines {
                                    if line.hasPrefix("data: ") {
                                        let jsonString = String(line.dropFirst(6))
                                        self.logger.debug("SSE_DATA_LINE: \(jsonString.prefix(100))")

                                        if jsonString.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                                            self.logger.debug("SSE_DONE: Received [DONE] signal")
                                            continuation.finish()
                                            return
                                        }

                                        if !jsonString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                           let jsonData = jsonString.data(using: .utf8) {
                                            do {
                                                /// Log RAW JSON before any processing.
                                                self.logger.debug("RAW_API_JSON: \(jsonString)")

                                                let copilotChunk = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]

                                                /// Log extracted content from JSON - CHECK FOR ESCAPING HERE.
                                                if let choices = copilotChunk?["choices"] as? [[String: Any]],
                                                   let firstChoice = choices.first,
                                                   let delta = firstChoice["delta"] as? [String: Any],
                                                   let content = delta["content"] as? String {
                                                    let preview = String(content.prefix(200))
                                                    let hasEscapedSlash = content.contains("\\/")
                                                    let hasEscapedQuote = content.contains("\\\"")
                                                    self.logger.debug("RAW_CONTENT_FROM_JSON: len=\(content.count) hasSlash=\(hasEscapedSlash) hasQuote=\(hasEscapedQuote) preview='\(preview)'")
                                                }

                                                if let chunk = self.transformCopilotStreamChunk(copilotChunk, requestId: requestId) {
                                                    self.logger.error("SSE_BEFORE_YIELD: chunkId=\(chunk.id) content=\(chunk.choices.first?.delta.content?.prefix(50) ?? "nil")")
                                                    continuation.yield(chunk)
                                                    self.logger.error("SSE_AFTER_YIELD: chunkId=\(chunk.id)")
                                                }
                                            } catch {
                                                self.logger.warning("Failed to parse streaming chunk: \(error)")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Shared Implementation

    private func processGitHubCopilotRequest(_ request: OpenAIChatRequest, streaming: Bool) async throws -> ServerOpenAIChatResponse {
        let requestId = UUID().uuidString
        logger.debug("Processing GitHub Copilot API request [req:\(requestId.prefix(8))], streaming: \(streaming)")

        let apiKey = try await getAPIKey()

        let urlRequest = try await createGitHubCopilotRequest(request, apiKey: apiKey, streaming: streaming)

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            logger.debug("GitHub Copilot API response [req:\(requestId.prefix(8))]: \(httpResponse.statusCode)")

            /// PREMIUM QUOTA TRACKING: Extract quota information from response headers.
            await processGitHubCopilotQuotaHeaders(httpResponse.allHeaderFields, requestId: requestId)

            /// Handle different HTTP status codes appropriately.
            guard 200...299 ~= httpResponse.statusCode else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "No error details available"
                logger.error("GitHub Copilot API error [req:\(requestId.prefix(8))] status=\(httpResponse.statusCode): \(errorMessage.prefix(500))")

                switch httpResponse.statusCode {
                case 429:
                    /// PREFER Retry-After header if provided by the server
                    var waitInterval: TimeInterval
                    if let retryAfterHeader = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                       let retryAfterSeconds = Double(retryAfterHeader) {
                        waitInterval = retryAfterSeconds
                        logger.info("RATE_LIMIT: Using Retry-After header value: \(retryAfterSeconds)s")
                    } else {
                        waitInterval = 60.0  // Default to 60s if no header
                        logger.info("RATE_LIMIT: No Retry-After header, using default: \(waitInterval)s")
                    }
                    logger.warning("GitHub Copilot rate limit exceeded [req:\(requestId.prefix(8))]. Wait \(Int(waitInterval))s before retry")
                    throw ProviderError.rateLimitExceeded("GitHub Copilot rate limit exceeded. Wait \(Int(waitInterval))s before retry. Details: \(errorMessage)")

                case 400:
                    logger.error("GitHub Copilot bad request (400) [req:\(requestId.prefix(8))]. Possible causes: payload too large, invalid tool schema, or malformed request. Details: \(errorMessage.prefix(500))")
                    throw ProviderError.invalidRequest("GitHub Copilot rejected request (400). This often indicates payload size limits or invalid parameters. Consider reducing conversation history or tool count. Details: \(errorMessage.prefix(200))")

                case 401, 403:
                    // Attempt token recovery before failing
                    // The Copilot session token may have expired between getCopilotToken() and the request
                    if let freshToken = await CopilotTokenStore.shared.attemptTokenRecovery() {
                        logger.info("Token recovered after \(httpResponse.statusCode), retrying request [req:\(requestId.prefix(8))]")
                        // Retry with fresh token
                        var retryRequest = urlRequest
                        retryRequest.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
                        let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                        if let retryHttp = retryResponse as? HTTPURLResponse, 200...299 ~= retryHttp.statusCode {
                            await processGitHubCopilotQuotaHeaders(retryHttp.allHeaderFields, requestId: requestId)
                            return try parseGitHubCopilotResponse(retryData, requestId: requestId)
                        }
                        // Retry also failed - fall through to error
                        logger.error("Token recovery retry also failed (\((retryResponse as? HTTPURLResponse)?.statusCode ?? 0)) [req:\(requestId.prefix(8))]")
                    }
                    throw ProviderError.authenticationFailed("GitHub Copilot authentication failed (\(httpResponse.statusCode)). Check API key validity.")

                case 500...599:
                    logger.warning("GitHub Copilot server error (\(httpResponse.statusCode)) [req:\(requestId.prefix(8))]. Retry may succeed.")
                    throw ProviderError.networkError("GitHub Copilot server error (\(httpResponse.statusCode)). Temporary issue, retry may succeed.")

                default:
                    throw ProviderError.networkError("GitHub Copilot API returned status \(httpResponse.statusCode): \(errorMessage.prefix(200))")
                }
            }

            return try parseGitHubCopilotResponse(data, requestId: requestId)

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("GitHub Copilot API request failed [req:\(requestId.prefix(8))]: \(error)")
            throw ProviderError.networkError("Network error: \(error.localizedDescription)")
        }
    }

    /// Enforce message alternation (required by GitHub Copilot)
    /// Merges consecutive same-role messages to prevent token counting errors
    private func enforceMessageAlternation(_ messages: [OpenAIChatMessage]) -> [OpenAIChatMessage] {
        guard !messages.isEmpty else {
            return messages
        }

        var result: [OpenAIChatMessage] = []
        var currentMessage: OpenAIChatMessage?

        for message in messages {
            if let current = currentMessage {
                if current.role == message.role {
                    /// Same role - merge content
                    let mergedContent: String?
                    if let currentContent = current.content, let newContent = message.content {
                        mergedContent = currentContent + "\n\n" + newContent
                    } else if let currentContent = current.content {
                        mergedContent = currentContent
                    } else if let newContent = message.content {
                        mergedContent = newContent
                    } else {
                        mergedContent = nil
                    }

                    /// Merge tool_calls if both have them
                    var mergedToolCalls: [OpenAIToolCall]? = current.toolCalls
                    if let newToolCalls = message.toolCalls {
                        if mergedToolCalls != nil {
                            mergedToolCalls?.append(contentsOf: newToolCalls)
                        } else {
                            mergedToolCalls = newToolCalls
                        }
                    }

                    /// Create merged message using appropriate initializer
                    if let toolCalls = mergedToolCalls, !toolCalls.isEmpty {
                        currentMessage = OpenAIChatMessage(
                            role: current.role,
                            content: mergedContent,
                            toolCalls: toolCalls
                        )
                    } else if let toolCallId = current.toolCallId ?? message.toolCallId, let content = mergedContent {
                        currentMessage = OpenAIChatMessage(
                            role: current.role,
                            content: content,
                            toolCallId: toolCallId
                        )
                    } else if let content = mergedContent {
                        currentMessage = OpenAIChatMessage(
                            role: current.role,
                            content: content
                        )
                    } else {
                        /// No content and no tool calls - use empty content
                        currentMessage = OpenAIChatMessage(
                            role: current.role,
                            content: ""
                        )
                    }

                    logger.debug("MESSAGE_ALTERNATION: Merged consecutive \(current.role) messages")
                } else {
                    /// Different role - save current and start new
                    result.append(current)
                    currentMessage = message
                }
            } else {
                currentMessage = message
            }
        }

        /// Add the last message
        if let final = currentMessage {
            result.append(final)
        }

        return result
    }

    /// Truncate messages for Chat Completions API to fit within Claude token limits Uses actual TokenCounter for accurate token counting instead of estimation.
    private func truncateMessagesForChatCompletions(
        _ messages: [OpenAIChatMessage],
        statefulMarker: String?,
        modelName: String,
        systemPrompt: String,
        tools: [OpenAITool]?
    ) async -> [OpenAIChatMessage] {
        logger.debug("TRUNCATE_ENTRY: Processing \(messages.count) messages for model=\(modelName)")

        /// Fetch API-provided context size for model (when available) Falls back to hardcoded if API doesn't provide maxInputTokens.
        var apiMaxInputTokens: Int?
        do {
            let capabilities = try await fetchModelCapabilities()
            apiMaxInputTokens = capabilities[modelName]
            if let maxTokens = apiMaxInputTokens {
                logger.debug("API_CAPABILITIES: Model '\(modelName)' has \(maxTokens) input tokens (from GitHub API)")
            } else {
                logger.debug("API_CAPABILITIES: Model '\(modelName)' not found in API capabilities - will use hardcoded fallback")
            }
        } catch {
            logger.warning("API_CAPABILITIES: Failed to fetch from API - using hardcoded fallback. Error: \(error)")
        }

        /// Use TokenCounter to calculate ACTUAL available budget This accounts for system prompt, tools, and model-specific limits.
        let tokenBudget = await tokenCounter.calculateTokenBudget(
            modelName: modelName,
            systemPrompt: systemPrompt,
            tools: tools,
            model: nil,
            isLocal: false,
            apiMaxInputTokens: apiMaxInputTokens
        )

        logger.info("TOKEN_BUDGET: Available \(tokenBudget) tokens for conversation (model=\(modelName))")

        /// If we have a stateful marker, we can truncate more aggressively because GitHub already has the previous context.
        if let marker = statefulMarker {
            logger.debug("STATEFUL_TRUNCATION: marker=\(marker.prefix(20))... - can truncate earlier messages")
        }

        /// Always include system messages (they're critical and already counted in budget).
        let systemMessages = messages.filter { $0.role == "system" }
        let nonSystemMessages = messages.filter { $0.role != "system" }

        var includedMessages = systemMessages
        var totalTokens = 0

        logger.debug("SYSTEM_MESSAGES: \(systemMessages.count) messages (already in budget)")

        /// Add non-system messages from newest to oldest (reverse order) This ensures we keep the most recent context.
        for msg in nonSystemMessages.reversed() {
            /// Use actual token counter for precise measurement.
            let messageTokens = await tokenCounter.countTokens(
                message: msg,
                model: nil,
                isLocal: false
            )

            if totalTokens + messageTokens <= tokenBudget {
                includedMessages.insert(msg, at: systemMessages.count)
                totalTokens += messageTokens
            } else {
                logger.warning("TRUNCATED: Dropping older message (role=\(msg.role), ~\(messageTokens) tokens) - would exceed budget")
                /// Continue checking remaining messages - maybe smaller ones will fit.
            }
        }

        /// CRITICAL: Ensure at least one non-system message is included (prevents "messages: at least one message is required" 400 error)
        /// If token budget was too tight and only system messages remain, force-include the newest user message.
        let hasNonSystemMessage = includedMessages.contains { $0.role != "system" }
        if !hasNonSystemMessage && !nonSystemMessages.isEmpty {
            /// Find the newest user message
            if let newestUserMessage = nonSystemMessages.reversed().first(where: { $0.role == "user" }) {
                includedMessages.append(newestUserMessage)
                logger.warning("EMERGENCY_INCLUDE: No non-system messages fit budget - force-including newest user message to prevent 400 error")
            } else if let anyMessage = nonSystemMessages.last {
                /// No user message found - include the most recent message of any type
                includedMessages.append(anyMessage)
                logger.warning("EMERGENCY_INCLUDE: No user messages available - force-including latest message (role=\(anyMessage.role)) to prevent 400 error")
            }
        }

        logger.info("TRUNCATION_RESULT: \(messages.count) → \(includedMessages.count) messages, \(totalTokens)/\(tokenBudget) tokens used")

        return includedMessages
    }

    private func createGitHubCopilotRequest(_ request: OpenAIChatRequest, apiKey: String, streaming: Bool) async throws -> URLRequest {
        let baseURL: String
        let configuredURL = config.baseURL
        if let url = configuredURL, url != "https://api.githubcopilot.com" {
            baseURL = url
        } else {
            baseURL = await CopilotUserAPIClient.shared.getCopilotBaseURL()
        }
        let fullURL: String
        if baseURL.hasSuffix("/chat/completions") {
            fullURL = baseURL
        } else {
            fullURL = "\(baseURL)/chat/completions"
        }

        guard let url = URL(string: fullURL) else {
            throw ProviderError.invalidConfiguration("Invalid GitHub Copilot base URL: \(fullURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let samVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
        let requestId = UUID().uuidString
        urlRequest.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        urlRequest.setValue("conversational", forHTTPHeaderField: "X-Interaction-Type")
        urlRequest.setValue("conversational", forHTTPHeaderField: "OpenAI-Intent")
        urlRequest.setValue("2025-05-01", forHTTPHeaderField: "X-GitHub-Api-Version")
        /// GitHub Copilot API requires "vscode/" prefix for Editor-Version header per API specification.
        urlRequest.setValue("vscode/\(samVersion)", forHTTPHeaderField: "Editor-Version")
        urlRequest.setValue("copilot-chat/\(samVersion)", forHTTPHeaderField: "Editor-Plugin-Version")
        urlRequest.setValue("GitHubCopilotChat/\(samVersion)", forHTTPHeaderField: "User-Agent")

        /// Set X-Initiator based on iteration number iteration 0 = user-initiated (charges premium quota) iteration 1+ = agent-initiated tool continuation (no additional charge).
        let initiator = (request.iterationNumber ?? 0) == 0 ? "user" : "agent"
        urlRequest.setValue(initiator, forHTTPHeaderField: "X-Initiator")
        logger.debug("X-Initiator: \(initiator) (iteration: \(request.iterationNumber ?? 0))")

        /// YARN (YaRN Context Processor) handles all context management BEFORE provider
        /// Provider should NEVER re-truncate - trust YARN compression output
        /// See AgentOrchestrator.processAllMessagesWithYARN() for context management
        let modelWithoutPrefix = request.model.components(separatedBy: "/").last ?? request.model
        
        /// Use messages as-is from YARN processing (no provider-level truncation)
        /// YARN has already compressed context to fit model limits (see AgentOrchestrator line 5202-5218)
        logger.debug("CHAT_COMPLETIONS: Using YARN-processed messages (\(request.messages.count) messages)")
        
        if let marker = request.statefulMarker {
            logger.debug("CHAT_COMPLETIONS: Including stateful marker for context continuation: \(marker.prefix(20))...")
        }

        /// FILTER OUT TOOL RESULT PREVIEW MESSAGES
        /// These are UI-only messages that should NEVER be sent to the API
        /// They contain markers like [TOOL_RESULT_STORED] and [TOOL_RESULT_PREVIEW]
        let filteredMessages = request.messages.filter { message in
            guard let content = message.content else { return true }
            let isToolResultPreview = content.contains("[TOOL_RESULT_STORED]") || content.contains("[TOOL_RESULT_PREVIEW]")
            if isToolResultPreview {
                logger.debug("FILTER_PREVIEW: Removing tool result preview message (role=\(message.role))")
            }
            return !isToolResultPreview
        }
        
        /// NOTE: Message alternation is handled in AgentOrchestrator.ensureMessageAlternation()
        /// before reaching this provider. Doing it here would cause double-merging and lose context.
        /// The orchestrator version preserves tool messages and has better logging.

        let messages = filteredMessages.map { message in
            var messageDict: [String: Any] = [
                "role": message.role
            ]

            /// Include content if it exists (can be null for assistant messages with tool_calls).
            /// CRITICAL FIX: Trim trailing whitespace to prevent GitHub Copilot API rejection
            /// Claude models sometimes append newlines which cause "trailing whitespace" errors
            if let content = message.content {
                let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                /// Only include content if it's not empty after trimming
                if !trimmedContent.isEmpty {
                    messageDict["content"] = trimmedContent
                }
            }

            /// Include tool_calls for assistant messages (CRITICAL for GitHub Copilot).
            if let toolCalls = message.toolCalls {
                messageDict["tool_calls"] = toolCalls.map { toolCall in
                    [
                        "id": toolCall.id,
                        "type": toolCall.type,
                        "function": [
                            "name": toolCall.function.name,
                            "arguments": toolCall.function.arguments
                        ]
                    ]
                }
            }

            /// Include tool_call_id for tool messages (CRITICAL for GitHub Copilot).
            if let toolCallId = message.toolCallId {
                messageDict["tool_call_id"] = toolCallId
            }

            return messageDict
        }

        /// Log the messages being sent to GitHub Copilot API.
        logger.debug("Sending \(messages.count) messages to GitHub Copilot API:")
        for (index, message) in messages.enumerated() {
            let role = (message["role"] as? String) ?? "unknown"
            let contentString = message["content"] as? String ?? ""
            let content = String(contentString.prefix(100))
            logger.debug("  Message \(index + 1): \(role): \(content)\(content.count >= 100 ? "..." : "")")
        }

        /// Strip provider prefix from model name before sending to API User-facing: "github_copilot/gpt-4" → API expects: "gpt-4".
        let modelForAPI = request.model.contains("/")
            ? request.model.components(separatedBy: "/").last ?? request.model
            : request.model

        var requestBody: [String: Any] = [
            "model": modelForAPI,
            "messages": messages,
            /// CRITICAL: Ensure max_tokens is at least 2048 to prevent truncated responses
            "max_tokens": max(request.maxTokens ?? config.maxTokens ?? 4096, 2048),
            "temperature": request.temperature ?? config.temperature ?? 0.7,
            "stream": streaming
        ]

        if let conversationId = request.conversationId {
            requestBody["copilot_thread_id"] = conversationId
            logger.debug("Including copilot_thread_id: \(conversationId) for session continuity")
        } else if let sessionId = request.sessionId {
            requestBody["copilot_thread_id"] = sessionId
            logger.debug("Including copilot_thread_id (from sessionId): \(sessionId) for session continuity")
        } else {
            logger.warning("No conversationId or sessionId provided - GitHub Copilot will treat this as a new session (premium request will increment)")
        }

        if let responseId = request.statefulMarker {
            requestBody["previous_response_id"] = responseId
            logger.debug("Including previous_response_id: \(responseId.prefix(20))... for conversation continuity")
        } else {
            logger.debug("No previous_response_id available - this is first request in conversation or using non-GitHub provider")
        }

        /// Include tools in GitHub Copilot API request if they exist HARD LIMIT: GitHub Copilot enforces maximum 128 tools per request GitHub Copilot enforces maximum 128 tools per request.
        if let tools = request.tools {
            let MAX_TOOLS = 128

            /// Determine which tools are actually referenced in the messages (YARN-processed).
            let referencedToolNames = Set(request.messages.compactMap { msg -> [String]? in
                guard let toolCalls = msg.toolCalls else { return nil }
                return toolCalls.map { $0.function.name }
            }.flatMap { $0 })

            var toolsToSend: [OpenAITool] = []
            if !referencedToolNames.isEmpty {
                toolsToSend = tools.filter { referencedToolNames.contains($0.function.name) }
                logger.debug("FILTER_TOOLS: Including only referenced tools (\(toolsToSend.count)): \(toolsToSend.map { $0.function.name }.joined(separator: ", "))")
            } else {
                /// Send ALL tools on first request (when no tools referenced yet) Previous code sent ZERO tools which made LLM think tools unavailable!.
                toolsToSend = Array(tools.prefix(MAX_TOOLS))
                if tools.count > 0 {
                    logger.debug("FILTER_TOOLS: No referenced tools in messages (first request?) - sending ALL tools (\(toolsToSend.count)/\(tools.count))")
                }
            }

            if toolsToSend.count > MAX_TOOLS {
                toolsToSend = Array(toolsToSend.prefix(MAX_TOOLS))
                logger.warning("TOOL_LIMIT: GitHub Copilot request has >\(MAX_TOOLS) referenced tools, limiting to \(MAX_TOOLS)")
            }

            if !toolsToSend.isEmpty {
                requestBody["tools"] = toolsToSend.map { tool in
                    /// Parse the parametersJson back to object for the API CRITICAL: Must be an object, NOT a JSON string.
                    let parameters: Any
                    if let parametersData = tool.function.parametersJson.data(using: .utf8),
                       let parsedParameters = try? JSONSerialization.jsonObject(with: parametersData) {
                        parameters = parsedParameters
                    } else {
                        logger.warning("Failed to parse parametersJson for tool \(tool.function.name), using empty object")
                        parameters = [:]
                    }

                    return [
                        "type": tool.type,
                        "function": [
                            "name": tool.function.name,
                            "description": tool.function.description,
                            "parameters": parameters
                        ]
                    ]
                }
                logger.debug("Including \(toolsToSend.count) tools in GitHub Copilot API request")

                /// Debug: Log the exact tools being sent.
                for (index, tool) in toolsToSend.enumerated() {
                    logger.debug("Tool \(index + 1): \(tool.function.name) - \(tool.function.description)")
                    logger.debug("Tool \(index + 1) parameters: \(tool.function.parametersJson.prefix(500))")
                }
            } else {
                logger.debug("No referenced tools included in GitHub Copilot API request to minimize payload size")
            }
        } else {
            logger.debug("No tools to include in GitHub Copilot API request")
        }

        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        urlRequest.httpBody = requestData
        /// TIMEOUT INCREASED: 60s → 180s to handle batched tool operations and Claude's slower response time
        /// Claude models through GitHub Copilot can take significant time with large contexts
        urlRequest.timeoutInterval = TimeInterval(config.timeoutSeconds ?? 180)

        /// Debug: Log the complete request body for GitHub Copilot API debugging.
        if let requestString = String(data: requestData, encoding: .utf8) {
            logger.debug("Complete GitHub Copilot API request: \(requestString)")
        }

        return urlRequest
    }

    /// GitHub Copilot Response Parser - CRITICAL TOOL SUPPORT BREAKTHROUGH MAJOR BREAKTHROUGH ACHIEVED: This method represents a key breakthrough in GitHub Copilot integration discovered during this session.
    private func parseGitHubCopilotResponse(_ data: Data, requestId: String) throws -> ServerOpenAIChatResponse {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let responseDict = json,
              let id = responseDict["id"] as? String,
              let model = responseDict["model"] as? String,
              let choicesArray = responseDict["choices"] as? [[String: Any]],
              let usageDict = responseDict["usage"] as? [String: Any] else {
            throw ProviderError.responseNormalizationFailed("Invalid GitHub Copilot response structure")
        }

        let choices: [OpenAIChatChoice] = try choicesArray.enumerated().map { (index, choiceDict) in
            guard let messageDict = choiceDict["message"] as? [String: Any],
                  let role = messageDict["role"] as? String,
                  let finishReason = choiceDict["finish_reason"] as? String else {
                throw ProviderError.responseNormalizationFailed("Invalid choice format in GitHub Copilot response")
            }

            /// Handle tool calls - content can be null when tool_calls are present.
            let content = messageDict["content"] as? String
            var toolCalls: [OpenAIToolCall]?

            /// Parse tool_calls array if present (for GitHub Copilot tool usage).
            if let toolCallsArray = messageDict["tool_calls"] as? [[String: Any]] {
                toolCalls = try toolCallsArray.map { toolCallDict in
                    guard let id = toolCallDict["id"] as? String,
                          let type = toolCallDict["type"] as? String,
                          let functionDict = toolCallDict["function"] as? [String: Any],
                          let functionName = functionDict["name"] as? String,
                          let functionArguments = functionDict["arguments"] as? String else {
                        throw ProviderError.responseNormalizationFailed("Invalid tool_calls format in GitHub Copilot response")
                    }

                    return OpenAIToolCall(
                        id: id,
                        type: type,
                        function: OpenAIFunctionCall(
                            name: functionName,
                            arguments: functionArguments
                        )
                    )
                }
                logger.debug("GitHub Copilot returned \(toolCalls?.count ?? 0) tool calls")
            }

            let chatMessage = OpenAIChatMessage(role: role, content: content, toolCalls: toolCalls)

            /// Log message structure to verify tool calls are preserved.
            logger.debug("DEBUG_TOOL_CALLS: Created OpenAIChatMessage - role=\(role), content=\(content ?? "nil"), toolCalls.count=\(chatMessage.toolCalls?.count ?? 0)")

            return OpenAIChatChoice(
                index: choiceDict["index"] as? Int ?? index,
                message: chatMessage,
                finishReason: finishReason
            )
        }

        let usage = ServerOpenAIUsage(
            promptTokens: usageDict["prompt_tokens"] as? Int ?? 0,
            completionTokens: usageDict["completion_tokens"] as? Int ?? 0,
            totalTokens: usageDict["total_tokens"] as? Int ?? 0
        )

        /// Store response ID as statefulMarker for conversation continuity This is used as 'previous_response_id' in subsequent GitHub Copilot requests.
        logger.debug("GitHub Copilot response ID (statefulMarker): \(id.prefix(20))...")
        logger.debug("DEBUG_CHOICES: GitHub Copilot returned \(choices.count) choices")
        for (idx, choice) in choices.enumerated() {
            logger.debug("DEBUG_CHOICES: Choice \(idx): finishReason=\(choice.finishReason), content=\(choice.message.content?.prefix(50) ?? "nil"), toolCalls=\(choice.message.toolCalls?.count ?? 0)")
        }

        return ServerOpenAIChatResponse(
            id: id,
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: model,
            choices: choices,
            usage: usage,
            statefulMarker: id
        )
    }

    private func transformCopilotStreamChunk(_ copilotChunk: [String: Any]?, requestId: String) -> ServerOpenAIChatStreamChunk? {
        guard let chunk = copilotChunk,
              let id = chunk["id"] as? String,
              let model = chunk["model"] as? String,
              let choicesArray = chunk["choices"] as? [[String: Any]] else {
            return nil
        }

        let choices: [OpenAIChatStreamChoice] = choicesArray.enumerated().compactMap { (index, choiceDict) in
            let deltaDict = choiceDict["delta"] as? [String: Any]
            let finishReason = choiceDict["finish_reason"] as? String

            /// Log delta structure to understand tool_calls format.
            if let delta = deltaDict {
                if delta.keys.contains("tool_calls") {
                    logger.debug("DEBUG: Found tool_calls in delta: \(delta["tool_calls"] ?? "nil")")
                }
            }

            /// Parse tool calls from delta if present CRITICAL: GitHub Copilot sends tool calls incrementally across chunks First chunk: id, type, name, partial arguments Subsequent chunks: only index and partial arguments We must accept partial data and let StreamingToolCalls accumulate it.
            var toolCalls: [OpenAIToolCall]?
            if let toolCallsArray = deltaDict?["tool_calls"] as? [[String: Any]] {
                logger.debug("DEBUG: Parsing \(toolCallsArray.count) tool call delta(s) from chunk")
                toolCalls = toolCallsArray.map { toolCallDict in
                    /// Extract index (critical for accumulation).
                    let index = toolCallDict["index"] as? Int

                    /// Extract fields that may be present.
                    let id = toolCallDict["id"] as? String ?? ""
                    let type = toolCallDict["type"] as? String ?? "function"

                    /// Function data may be partial.
                    let functionDict = toolCallDict["function"] as? [String: Any]
                    let name = functionDict?["name"] as? String ?? ""
                    let arguments = functionDict?["arguments"] as? String ?? ""

                    if !id.isEmpty || !name.isEmpty || !arguments.isEmpty {
                        logger.debug("DEBUG: Tool call delta - index:\(index ?? -1) id:\(id.isEmpty ? "none" : id) name:\(name.isEmpty ? "none" : name) args:\(arguments.count) chars")
                    }

                    return OpenAIToolCall(
                        id: id,
                        type: type,
                        function: OpenAIFunctionCall(name: name, arguments: arguments),
                        index: index
                    )
                }
            }

            /// Include statefulMarker (response ID) in finish chunk This allows AgentOrchestrator to capture it for next iteration.
            let statefulMarker: String? = (finishReason == "stop" || finishReason == "tool_calls") ? id : nil
            if let marker = statefulMarker {
                logger.debug("GitHub Copilot streaming chunk response ID (statefulMarker): \(marker.prefix(20))...")
            }

            /// Log raw content from SSE to investigate spacing issues and ESCAPING.
            let rawContent = deltaDict?["content"] as? String
            if let content = rawContent, !content.isEmpty {
                /// Log first 100 chars with spaces explicitly marked.
                let debugContent = content.prefix(100).replacingOccurrences(of: " ", with: "␣")
                let hasEscapedSlash = content.contains("\\/")
                let hasEscapedQuote = content.contains("\\\"")
                logger.debug("SSE_CONTENT_DEBUG: len=\(content.count) hasSlash=\(hasEscapedSlash) hasQuote=\(hasEscapedQuote) preview='\(debugContent)'")
            }

            let delta = OpenAIChatDelta(
                role: deltaDict?["role"] as? String,
                content: rawContent,
                toolCalls: toolCalls,
                statefulMarker: statefulMarker
            )

            return OpenAIChatStreamChoice(
                index: choiceDict["index"] as? Int ?? index,
                delta: delta,
                finishReason: finishReason
            )
        }

        return ServerOpenAIChatStreamChunk(
            id: id,
            object: "chat.completion.chunk",
            created: Int(Date().timeIntervalSince1970),
            model: model,
            choices: choices
        )
    }

    // MARK: - GitHub Copilot Responses API Support

    /// Determines whether to use Responses API vs standard Chat Completions API **CURRENT STATUS**: Responses API DISABLED - GitHub Copilot doesn't support it for current models **Investigation Results** - Tested with gpt-4.1: GitHub returned "model not supported via Responses API" - GitHub /models API doesn't return supported_endpoints field - Chat Completions API with previous_response_id WORKS for session continuity **Decision**: Use Chat Completions API exclusively - Simpler codebase (one API instead of two) - Works with ALL models - Session continuity via copilot_thread_id + previous_response_id **Future**: Re-enable if GitHub adds Responses API support for models.
    private func useResponsesApi(for model: String) -> Bool {
        /// DISABLED: No models currently support Responses API.
        let responsesApiModels: [String] = []

        let modelWithoutPrefix = model.components(separatedBy: "/").last ?? model
        let isSupported = responsesApiModels.contains(modelWithoutPrefix)

        if isSupported {
            logger.debug("Model \(model) supports Responses API - will use /responses endpoint")
        } else {
            logger.debug("Model \(model) uses Chat Completions API - will use /chat/completions endpoint")
        }
        return isSupported
    }

    /// Process streaming chat completion via Responses API CRITICAL: Responses API returns statefulMarker in response.completed event's response.id field.
    public func processStreamingResponsesAPI(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        let requestId = UUID().uuidString
        logger.debug("Processing streaming chat completion via GitHub Copilot Responses API [req:\(requestId.prefix(8))]")

        /// RATE LIMIT BARRIER: If we're rate limited, wait until the barrier time
        /// This ensures the FULL backoff period is respected after a 429 error
        if let rateLimitBarrier = rateLimitedUntil {
            let waitTime = rateLimitBarrier.timeIntervalSinceNow
            if waitTime > 0 {
                logger.warning("RATE_LIMIT_BARRIER: Rate limited, waiting \(String(format: "%.1f", waitTime))s before next request [req:\(requestId.prefix(8))]")
                try await Task.sleep(for: .seconds(waitTime))
            }
            rateLimitedUntil = nil  // Clear after waiting
        }

        /// RATE LIMITING: Enforce minimum interval between API requests to prevent 429 errors
        /// GitHub Copilot has aggressive rate limits during high-frequency usage
        if let lastRequest = lastRequestTime {
            let timeSinceLastRequest = Date().timeIntervalSince(lastRequest)
            if timeSinceLastRequest < minimumRequestInterval {
                let waitTime = minimumRequestInterval - timeSinceLastRequest
                logger.info("RATE_LIMIT: Waiting \(String(format: "%.1f", waitTime))s before next API request (min interval: \(minimumRequestInterval)s)")
                try await Task.sleep(for: .seconds(waitTime))
            }
        }
        lastRequestTime = Date()

        let apiKey = try await getAPIKey()

        let urlRequest = try await createResponsesAPIRequest(request, apiKey: apiKey)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    /// Check cancellation before HTTP request.
                    if Task.isCancelled {
                        self.logger.debug("TASK_CANCELLED: GitHub Copilot Responses API request cancelled before start")
                        continuation.finish()
                        return
                    }

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ProviderError.networkError("Invalid response type"))
                        return
                    }

                    /// Handle different HTTP status codes appropriately.
                    guard 200...299 ~= httpResponse.statusCode else {
                        /// Read error response body for debugging.
                        var errorBody = ""
                        for try await byte in bytes {
                            if let char = String(bytes: [byte], encoding: .utf8) {
                                errorBody.append(char)
                            }
                        }

                        self.logger.error("GitHub Copilot Responses API error [req:\(requestId.prefix(8))] status=\(httpResponse.statusCode): \(errorBody.prefix(500))")

                        switch httpResponse.statusCode {
                        case 429:
                            /// EXPONENTIAL BACKOFF: Increase interval after rate limit errors
                            self.consecutiveRateLimitErrors += 1

                            /// PREFER Retry-After header if provided by the server
                            var waitInterval: TimeInterval
                            if let retryAfterHeader = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                               let retryAfterSeconds = Double(retryAfterHeader) {
                                /// Server explicitly told us how long to wait
                                waitInterval = retryAfterSeconds
                                self.logger.info("RATE_LIMIT: Using Retry-After header value: \(retryAfterSeconds)s")
                            } else {
                                /// No Retry-After header - use exponential backoff
                                waitInterval = min(self.maxInterval, self.baseInterval * pow(2, Double(self.consecutiveRateLimitErrors)))
                                self.logger.info("RATE_LIMIT: No Retry-After header, using exponential backoff: \(waitInterval)s")
                            }

                            self.minimumRequestInterval = max(self.baseInterval, waitInterval)
                            /// SET RATE LIMIT BARRIER: Next request must wait the FULL backoff period
                            self.rateLimitedUntil = Date().addingTimeInterval(waitInterval)
                            self.logger.warning("GitHub Copilot Responses API rate limit exceeded [req:\(requestId.prefix(8))]. Setting rate limit barrier for \(waitInterval)s (error count: \(self.consecutiveRateLimitErrors))")
                            continuation.finish(throwing: ProviderError.rateLimitExceeded("GitHub Copilot Responses API rate limit exceeded. Waiting \(Int(waitInterval))s before next request. Details: \(errorBody)"))
                            return

                        case 400:
                            self.logger.error("GitHub Copilot Responses API bad request (400) [req:\(requestId.prefix(8))]. Possible causes: payload too large, invalid tool schema, or malformed request. Details: \(errorBody.prefix(500))")
                            continuation.finish(throwing: ProviderError.invalidRequest("GitHub Copilot Responses API rejected request (400). This often indicates payload size limits or invalid parameters. Consider reducing conversation history or tool count. Details: \(errorBody.prefix(200))"))
                            return

                        case 401, 403:
                            /// Authentication failure - attempt token recovery before giving up
                            self.logger.warning("GitHub Copilot Responses API authentication failed (\(httpResponse.statusCode)) [req:\(requestId.prefix(8))], attempting token recovery...")
                            if let _ = await CopilotTokenStore.shared.attemptTokenRecovery() {
                                self.logger.info("Token recovered after \(httpResponse.statusCode) on Responses API, signaling retry [req:\(requestId.prefix(8))]")
                                continuation.finish(throwing: ProviderError.authRecoverable("Token refreshed after \(httpResponse.statusCode). Retry the request."))
                            } else {
                                self.logger.error("Token recovery failed for Responses API [req:\(requestId.prefix(8))]")
                                continuation.finish(throwing: ProviderError.authenticationFailed("GitHub Copilot Responses API authentication failed (\(httpResponse.statusCode)). Check API key validity."))
                            }
                            return

                        case 500...599:
                            self.logger.warning("GitHub Copilot Responses API server error (\(httpResponse.statusCode)) [req:\(requestId.prefix(8))]. Retry may succeed.")
                            continuation.finish(throwing: ProviderError.networkError("GitHub Copilot Responses API server error (\(httpResponse.statusCode)). Temporary issue, retry may succeed."))
                            return

                        default:
                            continuation.finish(throwing: ProviderError.networkError("GitHub Copilot Responses API returned status \(httpResponse.statusCode): \(errorBody.prefix(200))"))
                            return
                        }
                    }

                    /// SUCCESS: Request passed status check - reset rate limit tracking
                    self.consecutiveRateLimitErrors = max(0, self.consecutiveRateLimitErrors - 1)
                    if self.consecutiveRateLimitErrors == 0 {
                        self.minimumRequestInterval = self.baseInterval
                    }

                    var incompleteBuffer = ""
                    var textAccumulator = ""

                    for try await byte in bytes {
                        /// Check cancellation in streaming loop.
                        if Task.isCancelled {
                            self.logger.debug("TASK_CANCELLED: GitHub Copilot Responses API streaming cancelled")
                            continuation.finish()
                            return
                        }

                        if let char = String(bytes: [byte], encoding: .utf8) {
                            incompleteBuffer.append(char)
                        }

                        /// Process complete SSE events (ending with double newline).
                        while incompleteBuffer.contains("\n\n") {
                            if let doubleNewlineRange = incompleteBuffer.range(of: "\n\n") {
                                let completeEvent = String(incompleteBuffer[..<doubleNewlineRange.lowerBound])

                                /// Remove processed event from buffer.
                                incompleteBuffer = String(incompleteBuffer[doubleNewlineRange.upperBound...])

                                /// Process the complete SSE event.
                                let lines = completeEvent.components(separatedBy: "\n")
                                for line in lines {
                                    if line.hasPrefix("data: ") {
                                        let jsonString = String(line.dropFirst(6))

                                        if jsonString.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                                            continuation.finish()
                                            return
                                        }

                                        if !jsonString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                           let jsonData = jsonString.data(using: .utf8) {
                                            do {
                                                let decoder = JSONDecoder()
                                                let event = try decoder.decode(ResponsesStreamEvent.self, from: jsonData)

                                                /// Transform Responses API event to Chat Completions format.
                                                if let chunk = self.transformResponsesEvent(event, requestId: requestId, textAccumulator: &textAccumulator) {
                                                    continuation.yield(chunk)
                                                }
                                            } catch {
                                                self.logger.warning("Failed to parse Responses API event: \(error)")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Transform Responses API event to Chat Completions stream chunk **Why needed**: GitHub Copilot Responses API uses different event format than Chat Completions **Key differences**: - Responses API: `type`, `code`, `content`, `created` fields, nested structures - Chat Completions API: `choices[].delta.content`, flat structure **What this does**: 1.
    private func transformResponsesEvent(_ event: ResponsesStreamEvent, requestId: String, textAccumulator: inout String) -> ServerOpenAIChatStreamChunk? {
        let id = requestId
        let model = config.models.first ?? "gpt-4"

        switch event {
        case .error(let errorEvent):
            logger.error("Responses API error: \(errorEvent.message)")
            /// Return error as empty chunk with finish reason.
            let delta = OpenAIChatDelta(role: nil, content: "", toolCalls: nil, statefulMarker: nil)
            let choice = OpenAIChatStreamChoice(index: 0, delta: delta, finishReason: "error")
            return ServerOpenAIChatStreamChunk(id: id, object: "chat.completion.chunk", created: Int(Date().timeIntervalSince1970), model: model, choices: [choice])

        case .outputTextDelta(let textEvent):
            /// Accumulate text.
            textAccumulator += textEvent.delta

            /// Yield delta with incremental text.
            let delta = OpenAIChatDelta(role: nil, content: textEvent.delta, toolCalls: nil, statefulMarker: nil)
            let choice = OpenAIChatStreamChoice(index: 0, delta: delta, finishReason: nil)
            return ServerOpenAIChatStreamChunk(id: id, object: "chat.completion.chunk", created: Int(Date().timeIntervalSince1970), model: model, choices: [choice])

        case .outputItemAdded(let addedEvent):
            if addedEvent.item.type == "function_call", let name = addedEvent.item.name {
                logger.debug("Responses API: Tool call started - \(name)")
                /// Yield delta with tool call start (just name, no full call yet).
                let toolCall = OpenAIToolCall(id: "", type: "function", function: OpenAIFunctionCall(name: name, arguments: ""))
                let delta = OpenAIChatDelta(role: nil, content: nil, toolCalls: [toolCall], statefulMarker: nil)
                let choice = OpenAIChatStreamChoice(index: 0, delta: delta, finishReason: nil)
                return ServerOpenAIChatStreamChunk(id: id, object: "chat.completion.chunk", created: Int(Date().timeIntervalSince1970), model: model, choices: [choice])
            }
            return nil

        case .outputItemDone(let doneEvent):
            if doneEvent.item.type == "function_call",
               let callId = doneEvent.item.callId,
               let name = doneEvent.item.name,
               let arguments = doneEvent.item.arguments {
                logger.debug("Responses API: Tool call completed - \(name) with callId: \(callId)")
                /// Yield delta with complete tool call.
                let toolCall = OpenAIToolCall(id: callId, type: "function", function: OpenAIFunctionCall(name: name, arguments: arguments))
                let delta = OpenAIChatDelta(role: nil, content: nil, toolCalls: [toolCall], statefulMarker: nil)
                let choice = OpenAIChatStreamChoice(index: 0, delta: delta, finishReason: nil)
                return ServerOpenAIChatStreamChunk(id: id, object: "chat.completion.chunk", created: Int(Date().timeIntervalSince1970), model: model, choices: [choice])
            }
            return nil

        case .completed(let completedEvent):
            /// Extract statefulMarker from response.id for session continuity.
            let statefulMarker = completedEvent.response.id
            logger.debug("SUCCESS: Responses API completed with statefulMarker: \(statefulMarker.prefix(20))...")

            /// Yield final chunk with statefulMarker and finish reason.
            let delta = OpenAIChatDelta(role: nil, content: "", toolCalls: nil, statefulMarker: statefulMarker)
            let choice = OpenAIChatStreamChoice(index: 0, delta: delta, finishReason: "stop")
            return ServerOpenAIChatStreamChunk(id: id, object: "chat.completion.chunk", created: Int(Date().timeIntervalSince1970), model: model, choices: [choice])
        }
    }

    /// Create Responses API request
    ///
    /// Builds URLRequest for GitHub Copilot's extended Responses API endpoint.
    ///
    /// Key differences from Chat Completions API:
    /// - Endpoint: `/responses` instead of `/chat/completions`
    /// - Supports response_id tracking for conversation continuity
    /// - Different request/response structure (nested items, event streaming)
    ///
    /// Request structure follows GitHub Copilot Responses API specification.
    private func createResponsesAPIRequest(_ request: OpenAIChatRequest, apiKey: String) async throws -> URLRequest {
        let baseURL: String
        let configuredURL = config.baseURL
        if let url = configuredURL, url != "https://api.githubcopilot.com" {
            baseURL = url
        } else {
            baseURL = await CopilotUserAPIClient.shared.getCopilotBaseURL()
        }
        let fullURL: String
        if baseURL.hasSuffix("/responses") {
            fullURL = baseURL
        } else {
            fullURL = "\(baseURL)/responses"
        }

        guard let url = URL(string: fullURL) else {
            throw ProviderError.invalidConfiguration("Invalid GitHub Copilot base URL: \(fullURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        /// GitHub Copilot API requires specific headers (see Chat Completions API for full explanation).
        let samVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
        let requestId = UUID().uuidString
        urlRequest.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        urlRequest.setValue("conversational", forHTTPHeaderField: "X-Interaction-Type")
        urlRequest.setValue("conversational", forHTTPHeaderField: "OpenAI-Intent")
        urlRequest.setValue("2025-05-01", forHTTPHeaderField: "X-GitHub-Api-Version")
        urlRequest.setValue("SAM/\(samVersion)", forHTTPHeaderField: "Editor-Version")
        urlRequest.setValue("sam-copilot/\(samVersion)", forHTTPHeaderField: "Editor-Plugin-Version")
        urlRequest.setValue("GitHubCopilotChat/\(samVersion)", forHTTPHeaderField: "User-Agent")

        /// Strip provider prefix from model name for Responses API GitHub Copilot Responses API expects "gpt-4.1" not "github_copilot/gpt-4.1".
        let modelWithoutPrefix = request.model.components(separatedBy: "/").last ?? request.model

        logger.debug("DEBUG_TRACE: About to convert messages for Responses API [req:\(requestId.prefix(8))] model=\(modelWithoutPrefix) messageCount=\(request.messages.count) hasMarker=\(request.statefulMarker != nil)")

        /// Convert OpenAIChatRequest to Responses API format CRITICAL: Extract system prompt for token counting.
        let systemPrompt = request.messages.first(where: { $0.role == "system" })?.content ?? ""
        logger.debug("DEBUG_TRACE: System prompt length: \(systemPrompt.count) chars")

        /// Token-aware message conversion to prevent Claude 400 errors.
        logger.debug("DEBUG_TRACE: Calling convertMessagesToResponsesInput...")
        let result = try await convertMessagesToResponsesInput(
            request.messages,
            statefulMarker: request.statefulMarker,
            modelName: modelWithoutPrefix,
            systemPrompt: systemPrompt,
            tools: request.tools
        )
        let input = result.input
        logger.debug("DEBUG_TRACE: convertMessagesToResponsesInput completed, input has \(input.count) messages, previousResponseId=\(result.previousResponseId?.prefix(20) ?? "nil")")

        /// Convert tools to Responses API format.
        var tools: [ResponsesFunctionTool]?
        if let requestTools = request.tools {
            tools = requestTools.map { tool in
                /// Parse parametersJson to dictionary.
                let parametersData = tool.function.parametersJson.data(using: .utf8) ?? Data()
                let parameters = (try? JSONSerialization.jsonObject(with: parametersData) as? [String: Any]) ?? [:]

                return ResponsesFunctionTool(
                    name: tool.function.name,
                    description: tool.function.description,
                    parameters: parameters
                )
            }
        }

        let responsesRequest = ResponsesRequest(
            model: modelWithoutPrefix,
            input: input,
            previousResponseId: result.previousResponseId,
            stream: true,
            tools: tools,
            topP: request.temperature,
            maxOutputTokens: request.maxTokens,
            toolChoice: nil,
            store: false
        )

        /// Track what we're sending to GitHub.
        logger.debug("RESPONSES_API_REQUEST: model=\(modelWithoutPrefix) (original: \(request.model)), input.count=\(input.count), previousResponseId=\(result.previousResponseId?.prefix(20) ?? "nil")")
        if let prevId = result.previousResponseId {
            logger.warning("WARNING: BILLING_DEBUG: Sending previousResponseId=\(prevId.prefix(20))... with \(input.count) input items - GitHub should recognize session continuity")
        } else {
            logger.debug("INFO: BILLING_DEBUG: No previousResponseId - GitHub will treat as NEW premium session")
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        urlRequest.httpBody = try encoder.encode(responsesRequest)
        /// Increased timeout to 180s for Claude models which can be slow with large contexts
        urlRequest.timeoutInterval = TimeInterval(config.timeoutSeconds ?? 180)

        /// Debug logging.
        if let requestData = urlRequest.httpBody, let requestString = String(data: requestData, encoding: .utf8) {
            logger.debug("Responses API request: \(requestString)")
        }

        return urlRequest
    }

    /// Convert OpenAI messages to Responses API input array **Why needed**: Responses API uses different message structure than Chat Completions **Key transformations**: - OpenAI format: `messages: [{role, content}]` (flat array) - Responses API: `input: [{type, payload: {role, content}}]` (nested structure) **Message truncation (FUTURE)**: When statefulMarker provided, should truncate to only messages after that response.
    private func convertMessagesToResponsesInput(
        _ messages: [OpenAIChatMessage],
        statefulMarker: String?,
        modelName: String,
        systemPrompt: String,
        tools: [OpenAITool]?
    ) async throws -> (input: [ResponsesInputItem], previousResponseId: String?) {
        /// FIRST LINE: Prove function is being called.
        logger.debug("FUNCTION_ENTRY: convertMessagesToResponsesInput called with \(messages.count) messages")

        var previousResponseId: String?

        /// Track what we're receiving.
        logger.debug("RESPONSES_API_CONVERT: Received \(messages.count) messages, statefulMarker=\(statefulMarker?.prefix(20) ?? "nil")")

        /// Fetch API-provided context size for model (when available).
        var apiMaxInputTokens: Int?
        do {
            let capabilities = try await fetchModelCapabilities()
            apiMaxInputTokens = capabilities[modelName]
            if let maxTokens = apiMaxInputTokens {
                logger.debug("API_CAPABILITIES: Model '\(modelName)' has \(maxTokens) input tokens (from GitHub API)")
            } else {
                logger.debug("API_CAPABILITIES: Model '\(modelName)' not found in API capabilities - will use hardcoded fallback")
            }
        } catch {
            logger.warning("API_CAPABILITIES: Failed to fetch from API - using hardcoded fallback. Error: \(error)")
        }

        /// FIX (resolves Claude 400 errors): Token-aware message truncation Implements claude-sonnet.md spec for proper context management.
        let tokenBudget = await tokenCounter.calculateTokenBudget(
            modelName: modelName,
            systemPrompt: systemPrompt,
            tools: tools,
            model: nil,
            isLocal: false,
            apiMaxInputTokens: apiMaxInputTokens
        )

        logger.info("TOKEN_BUDGET: Available \(tokenBudget) tokens for conversation (model=\(modelName))")

        /// Filter out system messages (already counted in base budget).
        let messagesToProcess = messages.filter { $0.role != "system" }

        if let marker = statefulMarker {
            previousResponseId = marker
            logger.debug("RESPONSES_API: Using previousResponseId: \(marker.prefix(20))...")
        }

        /// Count tokens and truncate from OLDEST messages first Keep newest messages (most relevant context) within budget.
        var totalTokens = 0
        var messagesToInclude: [OpenAIChatMessage] = []

        /// Iterate BACKWARDS from newest to oldest to preserve recent context.
        for message in messagesToProcess.reversed() {
            let messageTokens = await tokenCounter.countTokens(
                message: message,
                model: nil,
                isLocal: false
            )

            if totalTokens + messageTokens <= tokenBudget {
                messagesToInclude.insert(message, at: 0)
                totalTokens += messageTokens
            } else {
                /// Would exceed budget - continue checking if smaller messages fit.
                logger.warning("TOKEN_TRUNCATE: Dropping message (role=\(message.role), \(messageTokens) tokens) - would exceed budget")
                /// Continue to try other messages - don't break!
            }
        }

        /// CRITICAL: Ensure at least one message is included (prevents "messages: at least one message is required" 400 error)
        /// If token budget was too tight and nothing fit, force-include the newest user message.
        if messagesToInclude.isEmpty && !messagesToProcess.isEmpty {
            /// Find the newest user message (iterating backwards since we need newest first)
            if let newestUserMessage = messagesToProcess.reversed().first(where: { $0.role == "user" }) {
                messagesToInclude.append(newestUserMessage)
                logger.warning("EMERGENCY_INCLUDE: No messages fit budget - force-including newest user message to prevent 400 error")
            } else if let anyMessage = messagesToProcess.last {
                /// No user message found - include the most recent message of any type
                messagesToInclude.append(anyMessage)
                logger.warning("EMERGENCY_INCLUDE: No user messages available - force-including latest message (role=\(anyMessage.role)) to prevent 400 error")
            }
        }

        let droppedCount = messagesToProcess.count - messagesToInclude.count
        if droppedCount > 0 {
            logger.warning("CONTEXT_MANAGEMENT: Dropped \(droppedCount) oldest messages to fit \(tokenBudget) token budget")
            logger.info("CONTEXT_PRESERVED: Keeping \(messagesToInclude.count) most recent messages (\(totalTokens) tokens)")
        } else {
            logger.debug("CONTEXT_OK: All \(messagesToInclude.count) messages fit within budget (\(totalTokens)/\(tokenBudget) tokens)")
        }

        /// Convert messages to Responses API format.
        var input: [ResponsesInputItem] = []

        for message in messagesToInclude {
            switch message.role {
            case "user":
                if let content = message.content {
                    let contentItem = ResponsesTextContent(text: content)
                    let messageItem = ResponsesInputMessage(role: "user", content: [.text(contentItem)])
                    input.append(.message(messageItem))
                }

            case "assistant":
                /// Assistant messages with tool calls.
                if let toolCalls = message.toolCalls {
                    for toolCall in toolCalls {
                        let functionCallItem = ResponsesFunctionCallInput(
                            name: toolCall.function.name,
                            arguments: toolCall.function.arguments,
                            callId: toolCall.id
                        )
                        input.append(.functionCall(functionCallItem))
                    }
                }

                /// Assistant messages with content.
                if let content = message.content, !content.isEmpty {
                    let contentItem = ResponsesTextContent(text: content)
                    let messageItem = ResponsesInputMessage(role: "assistant", content: [.text(contentItem)])
                    input.append(.message(messageItem))
                }

            case "tool":
                /// Tool result messages.
                if let toolCallId = message.toolCallId, let content = message.content {
                    let outputItem = ResponsesFunctionCallOutputInput(
                        callId: toolCallId,
                        output: content
                    )
                    input.append(.functionCallOutput(outputItem))
                }

            default:
                logger.warning("Unknown message role: \(message.role)")
            }
        }

        logger.debug("RESPONSES_API_OUTPUT: Converted \(messagesToInclude.count) messages to \(input.count) input items")
        return (input: input, previousResponseId: previousResponseId)
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        let models = config.models.map { modelId in
            ServerOpenAIModel(
                id: modelId,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: "github"
            )
        }

        return ServerOpenAIModelsResponse(
            object: "list",
            data: models
        )
    }

    public func supportsModel(_ model: String) -> Bool {
        return config.models.contains(model) || model.hasPrefix("copilot-")
    }

    public func validateConfiguration() async throws -> Bool {
        // Try to get API key (either Copilot token or manual key)
        _ = try await getAPIKey()
        return true
    }

    // MARK: - Premium Quota Tracking

    /// Quota information structure for UI display
    public struct QuotaInfo: Codable {
        public let entitlement: Int
        public let used: Int
        public let percentRemaining: Double
        public let overageUsed: Double
        public let overagePermitted: Bool
        public let resetDate: String
        
        // New fields from CopilotUserAPI (optional for backward compatibility)
        public let overageCount: Int?
        public let login: String?
        public let copilotPlan: String?
        public let remaining: Int?  // Direct remaining count from user API

        public var available: Int {
            // Use direct remaining if available (more accurate), otherwise calculate
            if let remaining = remaining {
                return remaining
            }
            return max(0, entitlement - used)
        }
        
        /// Percent used for UI display (convenience computed property)
        public var percentUsed: Double {
            return 100.0 - percentRemaining
        }

        public init(entitlement: Int, used: Int, percentRemaining: Double, overageUsed: Double, overagePermitted: Bool, resetDate: String, overageCount: Int? = nil, login: String? = nil, copilotPlan: String? = nil, remaining: Int? = nil) {
            self.entitlement = entitlement
            self.used = used
            self.percentRemaining = percentRemaining
            self.overageUsed = overageUsed
            self.overagePermitted = overagePermitted
            self.resetDate = resetDate
            self.overageCount = overageCount
            self.login = login
            self.copilotPlan = copilotPlan
            self.remaining = remaining
        }
        
        /// Create QuotaInfo from CopilotUserResponse premium quota
        public static func from(userResponse: CopilotUserResponse) -> QuotaInfo? {
            guard let premium = userResponse.premiumQuota else { return nil }
            
            return QuotaInfo(
                entitlement: premium.entitlement,
                used: premium.used,
                percentRemaining: premium.percentRemaining,
                overageUsed: Double(premium.overageCount ?? 0),
                overagePermitted: premium.overagePermitted ?? false,
                resetDate: userResponse.quotaResetDateUTC ?? "unknown",
                overageCount: premium.overageCount,
                login: userResponse.login,
                copilotPlan: userResponse.copilotPlan,
                remaining: premium.remaining
            )
        }
    }

    /// Current quota information (updated after each API call)
    @Published public private(set) var currentQuotaInfo: QuotaInfo?

    /// Static variable to track last known premium quota for delta detection.
    @MainActor
    private static var lastPremiumQuotaUsed: Int?
    // NSLock removed - using @MainActor isolation instead

    /// Process GitHub Copilot quota headers from API response **Purpose**: Extract and track premium model usage to warn users before quota exhaustion **Quota headers GitHub returns**: - `x-quota-snapshot-premium_models`: Premium model usage (GPT-4, etc.) - `x-quota-snapshot-premium_interactions`: Alternative header for premium usage - `x-quota-snapshot-chat`: Free tier usage (GPT-3.5, etc.) **Header format** (URL-encoded key=value pairs): `"ent=100&ov=0.0&ovPerm=true&rem=75.5&rst=2025-11-01T00:00:00Z"` **Fields**: - `ent`: Entitlement (total quota limit for billing period) - `rem`: Remaining quota - `ov`: Overage used (beyond entitlement) - `ovPerm`: Overage permitted (can user go over limit?) - `rst`: Reset time (when quota resets) **Why tracking matters**: Users often don't know they're approaching quota limits.
    private func processGitHubCopilotQuotaHeaders(_ headers: [AnyHashable: Any], requestId: String) async {
        /// Check for premium quota headers.
        let quotaHeader = headers["x-quota-snapshot-premium_models"] as? String
            ?? headers["x-quota-snapshot-premium_interactions"] as? String
            ?? headers["x-quota-snapshot-chat"] as? String

        guard let quotaHeader = quotaHeader else {
            /// No quota information in response - this is normal for some requests.
            return
        }

        /// Parse URL encoded string into key-value pairs.
        guard let components = URLComponents(string: "http://dummy.com?\(quotaHeader)") else {
            logger.warning("Failed to parse quota header format")
            return
        }

        var quotaInfo: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                quotaInfo[item.name] = value
            }
        }

        /// Extract quota values.
        let entitlement = Int(quotaInfo["ent"] ?? "0") ?? 0
        let overageUsed = Double(quotaInfo["ov"] ?? "0.0") ?? 0.0
        let overagePermitted = quotaInfo["ovPerm"] == "true"
        let percentRemaining = Double(quotaInfo["rem"] ?? "0.0") ?? 0.0
        let resetDate = quotaInfo["rst"] ?? "unknown"

        /// Calculate used based on entitlement and remaining.
        let used = max(0, Int(Double(entitlement) * (1.0 - percentRemaining / 100.0)))

        /// Calculate delta (change from last request) for premium quota tracking.
        /// Update published quota info for UI display
        let deltaInfo = await MainActor.run { () -> String in
            var delta = ""
            if let lastUsed = GitHubCopilotProvider.lastPremiumQuotaUsed {
                let change = used - lastUsed
                if change > 0 {
                    delta = " [+\(change) PREMIUM REQUEST CHARGED]"
                } else if change < 0 {
                    delta = " [WARNING: \(change) - quota decreased?]"
                } else {
                    delta = " [SUCCESS: +0 - NO CHARGE (session continuity working!)]"
                }
            } else {
                delta = " [Initial request - baseline established]"
            }
            GitHubCopilotProvider.lastPremiumQuotaUsed = used

            self.currentQuotaInfo = QuotaInfo(
                entitlement: entitlement,
                used: used,
                percentRemaining: percentRemaining,
                overageUsed: overageUsed,
                overagePermitted: overagePermitted,
                resetDate: resetDate
            )
            return delta
        }

        /// Save to cache for next session
        saveQuotaCache()

        /// Log quota information.
        logger.debug("GitHub Copilot Premium Quota [req:\(requestId.prefix(8))]:")
        logger.debug(" - Entitlement: \(entitlement == -1 ? "Unlimited" : "\(entitlement)")")
        logger.debug(" - Used: \(used)\(deltaInfo)")
        logger.debug(" - Remaining: \(String(format: "%.1f%%", percentRemaining))")
        logger.debug(" - Overage: \(String(format: "%.1f", overageUsed)) (permitted: \(overagePermitted))")
        logger.debug(" - Reset Date: \(resetDate)")

        /// Calculate human-readable quota status.
        let available = entitlement == -1 ? "unlimited" : "\(max(0, entitlement - used))"
        logger.debug(" - Status: \(used)/\(entitlement == -1 ? "∞" : "\(entitlement)") premium requests used (\(available) available)")
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
