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
        guard let choice = response.choices.first else {
            logger.debug("convertToStreamChunks: No choices in response, returning empty")
            return []
        }
        var chunks: [ServerOpenAIChatStreamChunk] = []

        // Get content and reasoning content from the message
        var mainContent = choice.message.content ?? ""
        let reasoningContent = choice.message.reasoningContent

        logger.debug("convertToStreamChunks: content=\(mainContent.prefix(100))..., reasoningContent=\(reasoningContent?.prefix(100) ?? "nil")")

        // Process reasoning content through ThinkTagFormatter like LlamaProvider does
        var formatter = ThinkTagFormatter(hideThinking: false)

        // If reasoning content exists and content is empty, use reasoning as thinking tool message
        // This handles llama.cpp servers that put content in reasoning_content field
        if let reasoning = reasoningContent, !reasoning.isEmpty {
            // Format reasoning through ThinkTagFormatter
            let (formattedReasoning, _) = formatter.processChunk(reasoning)
            let flushedReasoning = formatter.flushBuffer()
            let fullReasoning = formattedReasoning + flushedReasoning

            if !fullReasoning.isEmpty {
                // Yield reasoning as a thinking tool message to trigger thinking card UI
                chunks.append(ServerOpenAIChatStreamChunk(
                    id: response.id,
                    object: "chat.completion.chunk",
                    created: response.created,
                    model: response.model,
                    choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: nil))],
                    isToolMessage: true,
                    toolName: "thinking",
                    toolDetails: [fullReasoning]
                ))
            }

            // If there's also main content, keep it for later (after thinking)
            if mainContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // If content was empty and we had reasoning, the thinking IS the response
                // Don't add empty content, the thinking was the response
            }
        }

        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(role: "assistant", content: nil))]
        ))

        // Handle tool calls if present
        if let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty {
            for toolCall in toolCalls {
                chunks.append(ServerOpenAIChatStreamChunk(
                    id: response.id,
                    object: "chat.completion.chunk",
                    created: response.created,
                    model: response.model,
                    choices: [OpenAIChatStreamChoice(
                        index: 0,
                        delta: OpenAIChatDelta(
                            content: nil,
                            toolCalls: [
                                OpenAIToolCall(
                                    id: toolCall.id,
                                    type: "function",
                                    function: OpenAIFunctionCall(
                                        name: toolCall.function.name,
                                        arguments: toolCall.function.arguments
                                    )
                                )
                            ]
                        )
                    )]
                ))
            }

            // Final chunk with finish_reason="tool_calls"
            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "tool_calls")]
            ))
        } else {
            // Preserve newlines for proper markdown rendering
            let lines = mainContent.components(separatedBy: .newlines)
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty else { continue }

                let words = trimmedLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                for (index, word) in words.enumerated() {
                    let suffix = index < words.count - 1 ? " " : "\n"
                    chunks.append(ServerOpenAIChatStreamChunk(
                        id: response.id,
                        object: "chat.completion.chunk",
                        created: response.created,
                        model: response.model,
                        choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: word + suffix))]
                    ))
                }
            }

            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "stop")]
            ))
        }

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

        /// Create request body using shared builder (includes tools, tool_calls, tool_call_id).
        let requestBody = request.buildOpenAICompatibleRequestBody()

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        /// Set timeout (5 minutes minimum for tool-enabled requests).
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

// MARK: - MiniMax Provider

/// Provider for MiniMax AI API.
/// MiniMax uses OpenAI-compatible API format at https://api.minimax.io/v1
@MainActor
public class MiniMaxProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration
    private let logger = Logger(label: "com.sam.api.minimax")

    public init(config: ProviderConfiguration) {
        self.identifier = config.providerId
        self.config = config
        logger.debug("MiniMax Provider initialized")
    }

    /// MiniMax uses OpenAI-compatible SSE streaming.
    /// This implementation does proper SSE parsing for real-time token delivery.
    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        let requestId = UUID().uuidString
        logger.debug("MiniMax streaming: Starting SSE streaming [req:\(requestId.prefix(8))]")

        /// Validate API key.
        guard let apiKey = config.apiKey else {
            throw ProviderError.authenticationFailed("MiniMax API key not configured")
        }

        /// Build base URL.
        guard let baseURL = config.baseURL ?? ProviderType.minimax.defaultBaseURL else {
            throw ProviderError.invalidConfiguration("MiniMax base URL not configured")
        }

        /// MiniMax OpenAI-compatible endpoint for streaming.
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ProviderError.invalidConfiguration("Invalid MiniMax base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        /// Strip provider prefix from model name.
        let modelForAPI = request.model.contains("/")
            ? request.model.components(separatedBy: "/").last ?? request.model
            : request.model

        /// MiniMax temperature range: 0.01 to 1.0.
        let temperature = request.temperature ?? config.temperature ?? 0.7
        let clampedTemperature = min(max(temperature, 0.01), 1.0)

        /// MiniMax supports up to 131072 max output tokens.
        let requestMaxTokens = request.maxTokens ?? 0
        let configMaxTokens = config.maxTokens ?? 131072
        let effectiveMaxTokens = max(requestMaxTokens, configMaxTokens)

        /// Build request body with streaming enabled.
        var requestBody: [String: Any] = [
            "model": modelForAPI,
            "messages": buildMiniMaxMessages(from: request.messages, requestId: requestId),
            "max_tokens": effectiveMaxTokens,
            "temperature": clampedTemperature,
            "stream": true  /// Enable SSE streaming
        ]

        /// Add tools support if present.
        if let tools = request.tools, !tools.isEmpty {
            requestBody["tools"] = tools.map { tool -> [String: Any] in
                let parameters: Any
                if let parametersData = tool.function.parametersJson.data(using: .utf8),
                   let parsedParameters = try? JSONSerialization.jsonObject(with: parametersData) {
                    parameters = parsedParameters
                } else {
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
            logger.debug("MiniMax streaming: Added \(tools.count) tools [req:\(requestId.prefix(8))]")
        }

        /// Serialize request body.
        guard let requestBodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw ProviderError.networkError("Failed to serialize MiniMax request")
        }
        urlRequest.httpBody = requestBodyData

        /// Set timeout.
        let configuredTimeout = TimeInterval(config.timeoutSeconds ?? 300)
        urlRequest.timeoutInterval = max(configuredTimeout, 300)

        logger.debug("MiniMax streaming: Sending SSE request [req:\(requestId.prefix(8))]")

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    /// Check cancellation before HTTP request.
                    if Task.isCancelled {
                        self.logger.debug("TASK_CANCELLED: MiniMax streaming cancelled before start")
                        continuation.finish()
                        return
                    }

                    /// Perform streaming HTTP request.
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ProviderError.networkError("Invalid response type"))
                        return
                    }

                    /// Handle HTTP errors.
                    guard 200...299 ~= httpResponse.statusCode else {
                        var errorBody = ""
                        for try await byte in bytes {
                            errorBody.append(Character(UnicodeScalar(byte)))
                            if errorBody.count > 2000 { break }
                        }
                        self.logger.error("MiniMax streaming HTTP error [req:\(requestId.prefix(8))]: \(httpResponse.statusCode) - \(errorBody.prefix(500))")
                        continuation.finish(throwing: ProviderError.networkError("MiniMax API returned status \(httpResponse.statusCode)"))
                        return
                    }

                    /// Parse SSE stream.
                    var sseBuffer = Data()
                    var inThinking = false
                    var thinkingBuffer = ""

                    for try await byte in bytes {
                        /// Check cancellation in streaming loop.
                        if Task.isCancelled {
                            self.logger.debug("TASK_CANCELLED: MiniMax streaming cancelled")
                            continuation.finish()
                            return
                        }

                        sseBuffer.append(byte)

                        /// Process complete SSE events (ending with double newline).
                        /// Check for \n\n in the raw bytes to avoid UTF-8 decoding issues.
                        let doubleNewline = Data([0x0A, 0x0A])  // \n\n
                        while let range = sseBuffer.range(of: doubleNewline) {
                            let eventData = sseBuffer[sseBuffer.startIndex..<range.lowerBound]
                            sseBuffer = Data(sseBuffer[range.upperBound...])

                            /// Decode the complete event as UTF-8.
                            guard let eventText = String(data: Data(eventData), encoding: .utf8) else {
                                continue
                            }

                            /// Parse SSE data line.
                            if eventText.hasPrefix("data: ") {
                                let jsonString = String(eventText.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)

                                /// Skip [DONE] marker.
                                if jsonString == "[DONE]" {
                                    self.logger.debug("MiniMax streaming: Received [DONE]")
                                    continuation.finish()
                                    return
                                }

                                /// Parse chunk JSON using JSONSerialization for flexibility.
                                guard let data = jsonString.data(using: .utf8),
                                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                    self.logger.debug("MiniMax streaming: Failed to parse JSON: \(jsonString.prefix(100))")
                                    continue
                                }

                                /// Extract common fields.
                                let chunkId = json["id"] as? String ?? UUID().uuidString
                                let chunkModel = json["model"] as? String ?? modelForAPI
                                let created = json["created"] as? Int ?? Int(Date().timeIntervalSince1970)
                                let object = json["object"] as? String ?? "chat.completion.chunk"

                                /// Parse choices.
                                guard let choices = json["choices"] as? [[String: Any]] else {
                                    continue
                                }

                                for (index, choice) in choices.enumerated() {
                                    let choiceIndex = choice["index"] as? Int ?? index
                                    let finishReason = choice["finish_reason"] as? String

                                    /// Parse delta.
                                    guard let delta = choice["delta"] as? [String: Any] else {
                                        continue
                                    }

                                    /// Handle reasoning_details delta (when reasoning_split=true).
                                    /// Also handles OpenRouter-style reasoning_details.
                                    /// Uses separate path from <think> tag parsing since
                                    /// reasoning_details is already structured by the API.
                                    if let reasoningDetails = delta["reasoning_details"] as? [[String: Any]] {
                                        var reasoningText = ""
                                        for detail in reasoningDetails {
                                            if let text = detail["text"] as? String, !text.isEmpty {
                                                reasoningText += text
                                            }
                                        }
                                        if !reasoningText.isEmpty {
                                            let thinkingChunk = ServerOpenAIChatStreamChunk(
                                                id: chunkId,
                                                object: object,
                                                created: created,
                                                model: chunkModel,
                                                choices: [OpenAIChatStreamChoice(
                                                    index: choiceIndex,
                                                    delta: OpenAIChatDelta(),
                                                    finishReason: nil
                                                )],
                                                isToolMessage: true,
                                                toolName: "thinking",
                                                toolIcon: "brain.head.profile",
                                                toolStatus: "running",
                                                toolDetails: [reasoningText]
                                            )
                                            continuation.yield(thinkingChunk)
                                        }
                                    }

                                    /// Process text content with streaming-safe think tag handling.
                                    /// MiniMax M2.x models send thinking in <think>...</think> tags.
                                    /// Tags may arrive split across chunks, so we use a state machine:
                                    /// - inThinking: currently inside <think> block
                                    /// - thinkingBuffer: accumulated thinking text (for tag detection)
                                    if let content = delta["content"] as? String, !content.isEmpty {
                                        /// Append to working buffer for tag detection.
                                        var workBuffer = thinkingBuffer + content
                                        thinkingBuffer = ""

                                        if inThinking {
                                            /// Inside a <think> block - look for closing </think>.
                                            if let endRange = workBuffer.range(of: "</think>") {
                                                /// Found end of thinking. Extract thinking text,
                                                /// yield thinking card, then process remainder.
                                                let thinkText = String(workBuffer[..<endRange.lowerBound])
                                                let afterThink = String(workBuffer[endRange.upperBound...])
                                                    .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))

                                                /// Yield accumulated thinking as a tool message card.
                                                if !thinkText.isEmpty {
                                                    let thinkingChunk = ServerOpenAIChatStreamChunk(
                                                        id: chunkId,
                                                        object: object,
                                                        created: created,
                                                        model: chunkModel,
                                                        choices: [OpenAIChatStreamChoice(
                                                            index: choiceIndex,
                                                            delta: OpenAIChatDelta(),
                                                            finishReason: nil
                                                        )],
                                                        isToolMessage: true,
                                                        toolName: "thinking",
                                                        toolIcon: "brain.head.profile",
                                                        toolStatus: "complete",
                                                        toolDetails: [thinkText]
                                                    )
                                                    continuation.yield(thinkingChunk)
                                                }

                                                inThinking = false

                                                /// Yield any content after </think> as regular text.
                                                if !afterThink.isEmpty {
                                                    let contentChunk = ServerOpenAIChatStreamChunk(
                                                        id: chunkId,
                                                        object: object,
                                                        created: created,
                                                        model: chunkModel,
                                                        choices: [OpenAIChatStreamChoice(
                                                            index: choiceIndex,
                                                            delta: OpenAIChatDelta(content: afterThink),
                                                            finishReason: nil
                                                        )]
                                                    )
                                                    continuation.yield(contentChunk)
                                                }
                                            } else if workBuffer.hasSuffix("<") ||
                                                      workBuffer.hasSuffix("</") ||
                                                      workBuffer.hasSuffix("</t") ||
                                                      workBuffer.hasSuffix("</th") ||
                                                      workBuffer.hasSuffix("</thi") ||
                                                      workBuffer.hasSuffix("</thin") ||
                                                      workBuffer.hasSuffix("</think") {
                                                /// Possible partial </think> tag at end - buffer it.
                                                thinkingBuffer = workBuffer
                                            } else {
                                                /// Still thinking - keep accumulating.
                                                thinkingBuffer = workBuffer
                                            }
                                        } else {
                                            /// Not in thinking mode - look for opening <think>.
                                            if let startRange = workBuffer.range(of: "<think>") {
                                                /// Found opening tag. Yield any text before it.
                                                let beforeThink = String(workBuffer[..<startRange.lowerBound])
                                                let afterTag = String(workBuffer[startRange.upperBound...])

                                                if !beforeThink.isEmpty {
                                                    let contentChunk = ServerOpenAIChatStreamChunk(
                                                        id: chunkId,
                                                        object: object,
                                                        created: created,
                                                        model: chunkModel,
                                                        choices: [OpenAIChatStreamChoice(
                                                            index: choiceIndex,
                                                            delta: OpenAIChatDelta(content: beforeThink),
                                                            finishReason: nil
                                                        )]
                                                    )
                                                    continuation.yield(contentChunk)
                                                }

                                                inThinking = true

                                                /// Check if </think> is also in this chunk.
                                                if let endRange = afterTag.range(of: "</think>") {
                                                    let thinkText = String(afterTag[..<endRange.lowerBound])
                                                    let afterEnd = String(afterTag[endRange.upperBound...])
                                                        .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))

                                                    if !thinkText.isEmpty {
                                                        let thinkingChunk = ServerOpenAIChatStreamChunk(
                                                            id: chunkId,
                                                            object: object,
                                                            created: created,
                                                            model: chunkModel,
                                                            choices: [OpenAIChatStreamChoice(
                                                                index: choiceIndex,
                                                                delta: OpenAIChatDelta(),
                                                                finishReason: nil
                                                            )],
                                                            isToolMessage: true,
                                                            toolName: "thinking",
                                                            toolIcon: "brain.head.profile",
                                                            toolStatus: "complete",
                                                            toolDetails: [thinkText]
                                                        )
                                                        continuation.yield(thinkingChunk)
                                                    }

                                                    inThinking = false

                                                    if !afterEnd.isEmpty {
                                                        let contentChunk = ServerOpenAIChatStreamChunk(
                                                            id: chunkId,
                                                            object: object,
                                                            created: created,
                                                            model: chunkModel,
                                                            choices: [OpenAIChatStreamChoice(
                                                                index: choiceIndex,
                                                                delta: OpenAIChatDelta(content: afterEnd),
                                                                finishReason: nil
                                                            )]
                                                        )
                                                        continuation.yield(contentChunk)
                                                    }
                                                } else {
                                                    /// Still waiting for </think>.
                                                    thinkingBuffer = afterTag
                                                }
                                            } else if workBuffer.hasSuffix("<") ||
                                                      workBuffer.hasSuffix("<t") ||
                                                      workBuffer.hasSuffix("<th") ||
                                                      workBuffer.hasSuffix("<thi") ||
                                                      workBuffer.hasSuffix("<thin") ||
                                                      workBuffer.hasSuffix("<think") {
                                                /// Possible partial <think> tag at end.
                                                /// Buffer just the potential tag prefix.
                                                let partialLen = workBuffer.distance(
                                                    from: workBuffer.lastIndex(of: "<")!,
                                                    to: workBuffer.endIndex
                                                )
                                                let safeContent = String(workBuffer.dropLast(partialLen))
                                                thinkingBuffer = String(workBuffer.suffix(partialLen))

                                                if !safeContent.isEmpty {
                                                    let contentChunk = ServerOpenAIChatStreamChunk(
                                                        id: chunkId,
                                                        object: object,
                                                        created: created,
                                                        model: chunkModel,
                                                        choices: [OpenAIChatStreamChoice(
                                                            index: choiceIndex,
                                                            delta: OpenAIChatDelta(content: safeContent),
                                                            finishReason: nil
                                                        )]
                                                    )
                                                    continuation.yield(contentChunk)
                                                }
                                            } else {
                                                /// Normal content, no think tags.
                                                let contentChunk = ServerOpenAIChatStreamChunk(
                                                    id: chunkId,
                                                    object: object,
                                                    created: created,
                                                    model: chunkModel,
                                                    choices: [OpenAIChatStreamChoice(
                                                        index: choiceIndex,
                                                        delta: OpenAIChatDelta(content: workBuffer),
                                                        finishReason: nil
                                                    )]
                                                )
                                                continuation.yield(contentChunk)
                                            }
                                        }
                                    }

                                    /// Pass through tool call deltas incrementally.
                                    /// MiniMax (like all OpenAI-compatible APIs) sends tool calls
                                    /// across multiple chunks: first chunk has id+name, subsequent
                                    /// chunks have argument fragments. The orchestrator's
                                    /// StreamingToolCalls accumulator handles reassembly by index.
                                    if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                                        for toolCallData in toolCalls {
                                            let function = toolCallData["function"] as? [String: Any]
                                            let tcIndex = toolCallData["index"] as? Int
                                            let toolCallId = toolCallData["id"] as? String ?? ""
                                            let tcType = toolCallData["type"] as? String ?? ""
                                            let name = function?["name"] as? String ?? ""
                                            let arguments = function?["arguments"] as? String ?? ""

                                            let toolCallChunk = ServerOpenAIChatStreamChunk(
                                                id: chunkId,
                                                object: object,
                                                created: created,
                                                model: chunkModel,
                                                choices: [OpenAIChatStreamChoice(
                                                    index: choiceIndex,
                                                    delta: OpenAIChatDelta(
                                                        content: nil,
                                                        toolCalls: [OpenAIToolCall(
                                                            id: toolCallId,
                                                            type: tcType.isEmpty ? "function" : tcType,
                                                            function: OpenAIFunctionCall(
                                                                name: name,
                                                                arguments: arguments
                                                            ),
                                                            index: tcIndex
                                                        )]
                                                    ),
                                                    finishReason: nil
                                                )]
                                            )
                                            continuation.yield(toolCallChunk)
                                        }
                                    }

                                    /// If this choice has a finish reason, emit final chunk.
                                    /// Also complete any pending thinking.
                                    if let fr = finishReason, fr == "stop" || fr == "tool_calls" {
                                        /// Complete any pending thinking first.
                                        if inThinking && !thinkingBuffer.isEmpty {
                                            let finalThinkingChunk = ServerOpenAIChatStreamChunk(
                                                id: chunkId,
                                                object: object,
                                                created: created,
                                                model: chunkModel,
                                                choices: [OpenAIChatStreamChoice(
                                                    index: choiceIndex,
                                                    delta: OpenAIChatDelta(),
                                                    finishReason: nil
                                                )],
                                                isToolMessage: true,
                                                toolName: "thinking",
                                                toolIcon: "brain.head.profile",
                                                toolStatus: "completed",
                                                toolDetails: [thinkingBuffer]
                                            )
                                            continuation.yield(finalThinkingChunk)
                                            thinkingBuffer = ""
                                            inThinking = false
                                        }

                                        let finalChunk = ServerOpenAIChatStreamChunk(
                                            id: chunkId,
                                            object: object,
                                            created: created,
                                            model: chunkModel,
                                            choices: [OpenAIChatStreamChoice(
                                                index: choiceIndex,
                                                delta: OpenAIChatDelta(),
                                                finishReason: fr
                                            )]
                                        )
                                        continuation.yield(finalChunk)
                                    }
                                }
                            }
                        }
                    }

                    /// Stream ended normally.
                    self.logger.debug("MiniMax streaming: Stream ended [req:\(requestId.prefix(8))]")
                    continuation.finish()

                } catch {
                    self.logger.error("MiniMax streaming error [req:\(requestId.prefix(8))]: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Fallback: Convert non-streaming response to chunks (used for error recovery).
    private func convertToStreamChunks(_ response: ServerOpenAIChatResponse) -> [ServerOpenAIChatStreamChunk] {
        guard let choice = response.choices.first else {
            logger.debug("convertToStreamChunks: No choices in response, returning empty")
            return []
        }
        var chunks: [ServerOpenAIChatStreamChunk] = []

        // Get content and reasoning content from the message
        var mainContent = choice.message.content ?? ""
        let reasoningContent = choice.message.reasoningContent

        logger.debug("convertToStreamChunks: content=\(mainContent.prefix(100))..., reasoningContent=\(reasoningContent?.prefix(100) ?? "nil")")

        // Process reasoning content through ThinkTagFormatter like LlamaProvider does
        var formatter = ThinkTagFormatter(hideThinking: false)

        // If reasoning content exists and content is empty, use reasoning as thinking tool message
        // This handles llama.cpp servers that put content in reasoning_content field
        if let reasoning = reasoningContent, !reasoning.isEmpty {
            // Format reasoning through ThinkTagFormatter
            let (formattedReasoning, _) = formatter.processChunk(reasoning)
            let flushedReasoning = formatter.flushBuffer()
            let fullReasoning = formattedReasoning + flushedReasoning

            if !fullReasoning.isEmpty {
                // Yield reasoning as a thinking tool message to trigger thinking card UI
                chunks.append(ServerOpenAIChatStreamChunk(
                    id: response.id,
                    object: "chat.completion.chunk",
                    created: response.created,
                    model: response.model,
                    choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: nil))],
                    isToolMessage: true,
                    toolName: "thinking",
                    toolDetails: [fullReasoning]
                ))
            }

            // If there's also main content, keep it for later (after thinking)
            if mainContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // If content was empty and we had reasoning, the thinking IS the response
                // Don't add empty content, the thinking was the response
            }
        }

        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(role: "assistant", content: nil))]
        ))

        // Handle tool calls if present
        if let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty {
            for toolCall in toolCalls {
                chunks.append(ServerOpenAIChatStreamChunk(
                    id: response.id,
                    object: "chat.completion.chunk",
                    created: response.created,
                    model: response.model,
                    choices: [OpenAIChatStreamChoice(
                        index: 0,
                        delta: OpenAIChatDelta(
                            content: nil,
                            toolCalls: [
                                OpenAIToolCall(
                                    id: toolCall.id,
                                    type: "function",
                                    function: OpenAIFunctionCall(
                                        name: toolCall.function.name,
                                        arguments: toolCall.function.arguments
                                    )
                                )
                            ]
                        )
                    )]
                ))
            }

            // Final chunk with finish_reason="tool_calls"
            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "tool_calls")]
            ))
        } else {
            // Preserve newlines for proper markdown rendering
            let lines = mainContent.components(separatedBy: .newlines)
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty else { continue }

                let words = trimmedLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                for (index, word) in words.enumerated() {
                    let suffix = index < words.count - 1 ? " " : "\n"
                    chunks.append(ServerOpenAIChatStreamChunk(
                        id: response.id,
                        object: "chat.completion.chunk",
                        created: response.created,
                        model: response.model,
                        choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: word + suffix))]
                    ))
                }
            }

            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "stop")]
            ))
        }

        return chunks
    }

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        let requestId = UUID().uuidString
        logger.debug("Processing chat completion via MiniMax API [req:\(requestId.prefix(8))]")

        guard let apiKey = config.apiKey else {
            throw ProviderError.authenticationFailed("MiniMax API key not configured")
        }

        guard let baseURL = config.baseURL ?? ProviderType.minimax.defaultBaseURL else {
            throw ProviderError.invalidConfiguration("MiniMax base URL not configured")
        }

        /// MiniMax uses OpenAI-compatible API format.
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ProviderError.invalidConfiguration("Invalid MiniMax base URL: \(baseURL)")
        }
        
        logger.debug("MiniMax request URL: \(url.absoluteString)")
        logger.debug("MiniMax API key present: \(apiKey.isEmpty == false)")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        /// MiniMax has specific temperature range: 0.01 to 1.0
        let temperature = request.temperature ?? config.temperature ?? 0.7
        let clampedTemperature = min(max(temperature, 0.01), 1.0)

        /// MiniMax supports up to 131072 max output tokens with 200k context.
        /// Use the HIGHER of request.maxTokens or config.maxTokens to ensure
        /// we don't artificially limit MiniMax's capabilities.
        let requestMaxTokens = request.maxTokens ?? 0
        let configMaxTokens = config.maxTokens ?? 131072
        let effectiveMaxTokens = max(requestMaxTokens, configMaxTokens)

        /// Strip provider prefix from model name before sending to API User-facing: "minimax/MiniMax-M2.7" -> API expects: "MiniMax-M2.7".
        let modelForAPI = request.model.contains("/")
            ? request.model.components(separatedBy: "/").last ?? request.model
            : request.model

        /// Create request body using MiniMax-compatible format.
        /// MiniMax requires different tool message formatting:
        /// - Tool results: {"role": "tool", "content": [{"name": "...", "type": "text", "text": "..."}]}
        /// - Assistant with tool_calls: {"role": "assistant", "tool_calls": [...], "content": ""}
        /// See: https://platform.minimax.io/docs/guides/text-function-call
        var requestBody: [String: Any] = [
            "model": modelForAPI,
            "messages": buildMiniMaxMessages(from: request.messages, requestId: requestId),
            "max_tokens": effectiveMaxTokens,
            "temperature": clampedTemperature,
            "stream": false
        ]

        /// Add tools support if present (required for structured tool_calls).
        if let tools = request.tools, !tools.isEmpty {
            requestBody["tools"] = tools.map { tool in
                /// Parse the parametersJson back to object for the API.
                let parameters: Any
                if let parametersData = tool.function.parametersJson.data(using: .utf8),
                   let parsedParameters = try? JSONSerialization.jsonObject(with: parametersData) {
                    parameters = parsedParameters
                } else {
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
            logger.debug("Added \(tools.count) tools to MiniMax request [req:\(requestId.prefix(8))]")
        }

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        /// Set timeout (5 minutes minimum for tool-enabled requests).
        /// Even if config specifies lower timeout, enforce 300s minimum to prevent timeouts.
        let configuredTimeout = TimeInterval(config.timeoutSeconds ?? 300)
        urlRequest.timeoutInterval = max(configuredTimeout, 300)

        logger.debug("Sending request to MiniMax API [req:\(requestId.prefix(8))]")

        do {
            let requestBodyData = try JSONSerialization.data(withJSONObject: requestBody)
            urlRequest.httpBody = requestBodyData
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        do {
            logger.debug("MiniMax: Starting URLSession request...")
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            logger.debug("MiniMax: URLSession request completed")

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            logger.debug("MiniMax API response [req:\(requestId.prefix(8))]: \(httpResponse.statusCode)")

            guard 200...299 ~= httpResponse.statusCode else {
                if let errorData = String(data: data, encoding: .utf8) {
                    logger.error("MiniMax API error [req:\(requestId.prefix(8))]: \(errorData)")
                }
                throw ProviderError.networkError("MiniMax API returned status \(httpResponse.statusCode)")
            }

            /// Parse response.
            let minimaxResponse = try JSONDecoder().decode(ServerOpenAIChatResponse.self, from: data)
            logger.debug("MiniMax raw response: id=\(minimaxResponse.id), model=\(minimaxResponse.model), choices=\(minimaxResponse.choices.count)")
            if let firstChoice = minimaxResponse.choices.first {
                logger.debug("MiniMax choice: finish_reason=\(firstChoice.finishReason ?? "nil"), content_len=\(firstChoice.message.content?.count ?? 0), tool_calls=\(firstChoice.message.toolCalls?.count ?? 0)")
            }
            logger.debug("Successfully processed MiniMax response [req:\(requestId.prefix(8))]")

            return minimaxResponse

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("MiniMax API request failed [req:\(requestId.prefix(8))]: \(error)")
            throw ProviderError.networkError("Network error: \(error.localizedDescription)")
        }
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        let models = config.models.map { modelId in
            ServerOpenAIModel(
                id: modelId,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: "minimax"
            )
        }

        return ServerOpenAIModelsResponse(
            object: "list",
            data: models
        )
    }

    public func supportsModel(_ model: String) -> Bool {
        return config.models.contains(model) || model.hasPrefix("MiniMax-")
    }

    public func validateConfiguration() async throws -> Bool {
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("MiniMax API key is required")
        }

        return true
    }

    // MARK: - Message Transformation

    /// Build MiniMax-compatible messages array from OpenAI format.
    /// MiniMax requires different tool message formatting:
    /// - Tool results: {"role": "tool", "content": [{"name": "...", "type": "text", "text": "..."}]}
    /// - Assistant with tool_calls: {"role": "assistant", "tool_calls": [...], "content": ""}
    /// See: https://platform.minimax.io/docs/guides/text-function-call
    private func buildMiniMaxMessages(from messages: [OpenAIChatMessage], requestId: String) -> [[String: Any]] {
        // First pass: collect tool_call_id -> function_name mappings from assistant messages
        var toolCallIdToFunctionName: [String: String] = [:]
        for message in messages {
            if message.role == "assistant", let toolCalls = message.toolCalls {
                for tc in toolCalls {
                    toolCallIdToFunctionName[tc.id] = tc.function.name
                    logger.debug("MiniMax: Collected tool_call id=\(tc.id), name=\(tc.function.name)")
                }
            }
        }

        // MiniMax only supports ONE system message and it MUST be the first message.
        // Consolidate all system-role messages into a single system message.
        // Non-first system messages get merged into the first one.
        var systemParts: [String] = []
        var nonSystemMessages: [OpenAIChatMessage] = []

        for message in messages {
            if message.role == "system" {
                if let content = message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    systemParts.append(content)
                }
            } else {
                nonSystemMessages.append(message)
            }
        }

        var result: [[String: Any]] = []

        // Add consolidated system message first
        if !systemParts.isEmpty {
            let consolidatedSystem = systemParts.joined(separator: "\n\n")
            result.append([
                "role": "system",
                "content": consolidatedSystem
            ])
            logger.debug("MiniMax: Consolidated \(systemParts.count) system messages into 1 (\(consolidatedSystem.count) chars) [req:\(requestId.prefix(8))]")
        }

        // Process remaining non-system messages
        for message in nonSystemMessages {
            if message.role == "tool" {
                // MiniMax tool message format: content is an array of {name, type, text} objects
                var toolContent: [[String: Any]] = []

                let funcName: String
                if let toolCallId = message.toolCallId, let name = toolCallIdToFunctionName[toolCallId] {
                    funcName = name
                } else {
                    funcName = "unknown"
                }

                toolContent.append([
                    "name": funcName,
                    "type": "text",
                    "text": message.content ?? ""
                ])

                result.append([
                    "role": "tool",
                    "tool_call_id": message.toolCallId ?? "",
                    "content": toolContent
                ])

                logger.debug("MiniMax tool message: tool_call_id=\(message.toolCallId ?? "nil"), name=\(funcName), content_len=\(message.content?.count ?? 0)")
            } else {
                var msgDict: [String: Any] = [
                    "role": message.role,
                    "content": message.content ?? ""
                ]

                // Handle tool_calls for assistant messages
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    msgDict["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                        return [
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": tc.function.name,
                                "arguments": tc.function.arguments ?? "{}"
                            ]
                        ]
                    }
                    // Preserve content for assistant messages with tool_calls.
                    // MiniMax needs thinking content in round-trips.
                    if (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        msgDict["content"] = ""
                    }
                }

                result.append(msgDict)
            }
        }

        return result
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
        guard let choice = response.choices.first else {
            logger.debug("convertToStreamChunks: No choices in response, returning empty")
            return []
        }
        var chunks: [ServerOpenAIChatStreamChunk] = []

        // Get content and reasoning content from the message
        var mainContent = choice.message.content ?? ""
        let reasoningContent = choice.message.reasoningContent

        logger.debug("convertToStreamChunks: content=\(mainContent.prefix(100))..., reasoningContent=\(reasoningContent?.prefix(100) ?? "nil")")

        // Process reasoning content through ThinkTagFormatter like LlamaProvider does
        var formatter = ThinkTagFormatter(hideThinking: false)

        // If reasoning content exists and content is empty, use reasoning as thinking tool message
        // This handles llama.cpp servers that put content in reasoning_content field
        if let reasoning = reasoningContent, !reasoning.isEmpty {
            // Format reasoning through ThinkTagFormatter
            let (formattedReasoning, _) = formatter.processChunk(reasoning)
            let flushedReasoning = formatter.flushBuffer()
            let fullReasoning = formattedReasoning + flushedReasoning

            if !fullReasoning.isEmpty {
                // Yield reasoning as a thinking tool message to trigger thinking card UI
                chunks.append(ServerOpenAIChatStreamChunk(
                    id: response.id,
                    object: "chat.completion.chunk",
                    created: response.created,
                    model: response.model,
                    choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: nil))],
                    isToolMessage: true,
                    toolName: "thinking",
                    toolDetails: [fullReasoning]
                ))
            }

            // If there's also main content, keep it for later (after thinking)
            if mainContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // If content was empty and we had reasoning, the thinking IS the response
                // Don't add empty content, the thinking was the response
            }
        }

        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(role: "assistant", content: nil))]
        ))

        // Handle tool calls if present
        if let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty {
            for toolCall in toolCalls {
                chunks.append(ServerOpenAIChatStreamChunk(
                    id: response.id,
                    object: "chat.completion.chunk",
                    created: response.created,
                    model: response.model,
                    choices: [OpenAIChatStreamChoice(
                        index: 0,
                        delta: OpenAIChatDelta(
                            content: nil,
                            toolCalls: [
                                OpenAIToolCall(
                                    id: toolCall.id,
                                    type: "function",
                                    function: OpenAIFunctionCall(
                                        name: toolCall.function.name,
                                        arguments: toolCall.function.arguments
                                    )
                                )
                            ]
                        )
                    )]
                ))
            }

            // Final chunk with finish_reason="tool_calls"
            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "tool_calls")]
            ))
        } else {
            // Preserve newlines for proper markdown rendering
            let lines = mainContent.components(separatedBy: .newlines)
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty else { continue }

                let words = trimmedLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                for (index, word) in words.enumerated() {
                    let suffix = index < words.count - 1 ? " " : "\n"
                    chunks.append(ServerOpenAIChatStreamChunk(
                        id: response.id,
                        object: "chat.completion.chunk",
                        created: response.created,
                        model: response.model,
                        choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: word + suffix))]
                    ))
                }
            }

            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "stop")]
            ))
        }

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
        var requestBody: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map { message -> [String: Any] in
                var msgDict: [String: Any] = [
                    "role": message.role,
                    "content": message.content ?? ""
                ]

                // Include tool_calls if present (assistant messages with tool calls)
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    msgDict["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                        return [
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": tc.function.name,
                                "arguments": tc.function.arguments ?? "{}"
                            ]
                        ]
                    }
                }

                // Include tool_call_id for tool result messages
                if let toolCallId = message.toolCallId {
                    msgDict["tool_call_id"] = toolCallId
                }

                return msgDict
            },
            "max_tokens": request.maxTokens ?? config.maxTokens ?? 2048,
            "temperature": request.temperature ?? config.temperature ?? 0.7,
            "stream": false
        ]

        // Include tools if provided (required for llama.cpp servers to generate tool calls)
        if let tools = request.tools, !tools.isEmpty {
            requestBody["tools"] = tools.map { tool -> [String: Any] in
                let parameters: Any
                if let parametersData = tool.function.parametersJson.data(using: .utf8),
                   let parsedParameters = try? JSONSerialization.jsonObject(with: parametersData) {
                    parameters = parsedParameters
                } else {
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
            logger.debug("CustomProvider: Including \(tools.count) tools in request")
        }

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
            
            /// Filter out non-chat models (image/video generation, text-only)
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
        
        logger.info("Fetched capabilities for \(capabilities.count) Gemini chat models (filtered out non-chat models)")
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

        /// Stream text content - preserve newlines for markdown
        if let content = choice.message.content, !content.isEmpty {
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty else { continue }
                
                let words = trimmedLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                for (index, word) in words.enumerated() {
                    let suffix = index < words.count - 1 ? " " : "\n"
                    chunks.append(ServerOpenAIChatStreamChunk(
                        id: response.id,
                        object: "chat.completion.chunk",
                        created: response.created,
                        model: response.model,
                        choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: word + suffix))]
                    ))
                }
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

// MARK: - Ollama Cloud Provider

/// Ollama Cloud provider for cloud-hosted Ollama models.
@MainActor
public class OllamaCloudProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration
    private let logger = Logger(label: "com.sam.api.ollamaCloud")

    public init(config: ProviderConfiguration) {
        self.identifier = config.providerId
        self.config = config
        logger.debug("Ollama Cloud Provider initialized")
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    if Task.isCancelled {
                        self.logger.debug("TASK_CANCELLED: Ollama Cloud request cancelled before start")
                        continuation.finish()
                        return
                    }

                    let response = try await self.processChatCompletion(request)
                    let chunks = self.convertToStreamChunks(response)

                    for chunk in chunks {
                        if Task.isCancelled {
                            self.logger.debug("TASK_CANCELLED: Ollama Cloud streaming cancelled")
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

        if let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty {
            for toolCall in toolCalls {
                chunks.append(ServerOpenAIChatStreamChunk(
                    id: response.id,
                    object: "chat.completion.chunk",
                    created: response.created,
                    model: response.model,
                    choices: [OpenAIChatStreamChoice(
                        index: 0,
                        delta: OpenAIChatDelta(
                            content: nil,
                            toolCalls: [
                                OpenAIToolCall(
                                    id: toolCall.id,
                                    type: "function",
                                    function: OpenAIFunctionCall(
                                        name: toolCall.function.name,
                                        arguments: toolCall.function.arguments
                                    )
                                )
                            ]
                        )
                    )]
                ))
            }

            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "tool_calls")]
            ))
        } else {
            // Preserve newlines for proper markdown rendering
            // Split by lines, then split words, rejoin with newlines
            let lines = (choice.message.content ?? "").components(separatedBy: .newlines)
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty else { continue }
                
                let words = trimmedLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                for (index, word) in words.enumerated() {
                    let suffix = index < words.count - 1 ? " " : "\n"
                    chunks.append(ServerOpenAIChatStreamChunk(
                        id: response.id,
                        object: "chat.completion.chunk",
                        created: response.created,
                        model: response.model,
                        choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: word + suffix))]
                    ))
                }
            }

            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "stop")]
            ))
        }

        return chunks
    }

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        let requestId = UUID().uuidString
        logger.debug("Processing chat completion via Ollama Cloud API [req:\(requestId.prefix(8))]")

        guard let apiKey = config.apiKey else {
            throw ProviderError.authenticationFailed("Ollama Cloud API key not configured")
        }

        guard let baseURL = config.baseURL ?? ProviderType.ollamaCloud.defaultBaseURL else {
            throw ProviderError.invalidConfiguration("Ollama Cloud base URL not configured")
        }

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ProviderError.invalidConfiguration("Invalid Ollama Cloud base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let modelForAPI = request.model.contains("/")
            ? request.model.components(separatedBy: "/").last ?? request.model
            : request.model

        /// Create request body using shared builder (includes tools, tool_calls, tool_call_id).
        let requestBody = request.buildOpenAICompatibleRequestBody(modelOverride: modelForAPI)

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        let configuredTimeout = TimeInterval(config.timeoutSeconds ?? 300)
        urlRequest.timeoutInterval = max(configuredTimeout, 300)

        logger.debug("Sending request to Ollama Cloud API [req:\(requestId.prefix(8))]")

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            logger.debug("Ollama Cloud API response [req:\(requestId.prefix(8))]: \(httpResponse.statusCode)")

            guard 200...299 ~= httpResponse.statusCode else {
                if let errorData = String(data: data, encoding: .utf8) {
                    logger.error("Ollama Cloud API error [req:\(requestId.prefix(8))]: \(errorData)")
                }
                throw ProviderError.networkError("Ollama Cloud API returned status \(httpResponse.statusCode)")
            }

            let openAIResponse = try JSONDecoder().decode(ServerOpenAIChatResponse.self, from: data)
            logger.debug("Successfully processed Ollama Cloud response [req:\(requestId.prefix(8))]")

            return openAIResponse

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("Ollama Cloud API request failed [req:\(requestId.prefix(8))]: \(error)")
            throw ProviderError.networkError("Network error: \(error.localizedDescription)")
        }
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        let models = config.models.map { modelId in
            ServerOpenAIModel(
                id: modelId,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: "ollama"
            )
        }

        return ServerOpenAIModelsResponse(
            object: "list",
            data: models
        )
    }

    public func supportsModel(_ model: String) -> Bool {
        return config.models.contains(model) || model.contains("ollama")
    }

    public func validateConfiguration() async throws -> Bool {
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("Ollama Cloud API key is required")
        }

        return true
    }

    public func loadModel() async throws -> ModelCapabilities {
        throw ProviderError.invalidRequest("loadModel() not supported for remote providers")
    }

    public func getLoadedStatus() async -> Bool {
        return false
    }

    public func unload() async {
        // No-op for remote providers.
    }
}

// MARK: - Z.AI Provider

/// Z.AI provider with rate limit handling and thinking parameter support.
@MainActor
public class ZAIProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration
    private let logger = Logger(label: "com.sam.api.zai")

    /// Whether this is the coding variant
    private let isCodingPlan: Bool

    public init(config: ProviderConfiguration) {
        self.identifier = config.providerId
        self.config = config
        self.isCodingPlan = config.providerType == .zaiCoding
        logger.debug("Z.AI Provider initialized (coding: \(isCodingPlan))")
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    if Task.isCancelled {
                        self.logger.debug("TASK_CANCELLED: Z.AI request cancelled before start")
                        continuation.finish()
                        return
                    }

                    let response = try await self.processChatCompletion(request)
                    let chunks = self.convertToStreamChunks(response)

                    for chunk in chunks {
                        if Task.isCancelled {
                            self.logger.debug("TASK_CANCELLED: Z.AI streaming cancelled")
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

        if let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty {
            for toolCall in toolCalls {
                chunks.append(ServerOpenAIChatStreamChunk(
                    id: response.id,
                    object: "chat.completion.chunk",
                    created: response.created,
                    model: response.model,
                    choices: [OpenAIChatStreamChoice(
                        index: 0,
                        delta: OpenAIChatDelta(
                            content: nil,
                            toolCalls: [
                                OpenAIToolCall(
                                    id: toolCall.id,
                                    type: "function",
                                    function: OpenAIFunctionCall(
                                        name: toolCall.function.name,
                                        arguments: toolCall.function.arguments
                                    )
                                )
                            ]
                        )
                    )]
                ))
            }

            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "tool_calls")]
            ))
        } else {
            // Preserve newlines for proper markdown rendering
            // Split by lines, then split words, rejoin with newlines
            let lines = (choice.message.content ?? "").components(separatedBy: .newlines)
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty else { continue }
                
                let words = trimmedLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                for (index, word) in words.enumerated() {
                    let suffix = index < words.count - 1 ? " " : "\n"
                    chunks.append(ServerOpenAIChatStreamChunk(
                        id: response.id,
                        object: "chat.completion.chunk",
                        created: response.created,
                        model: response.model,
                        choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: word + suffix))]
                    ))
                }
            }

            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "stop")]
            ))
        }

        return chunks
    }

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        let requestId = UUID().uuidString
        logger.debug("Processing chat completion via Z.AI API [req:\(requestId.prefix(8))]")

        guard let apiKey = config.apiKey else {
            throw ProviderError.authenticationFailed("Z.AI API key not configured")
        }

        guard let baseURL = config.baseURL ?? (isCodingPlan ? ProviderType.zaiCoding.defaultBaseURL : ProviderType.zai.defaultBaseURL) else {
            throw ProviderError.invalidConfiguration("Z.AI base URL not configured")
        }

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ProviderError.invalidConfiguration("Invalid Z.AI base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let modelForAPI = request.model.contains("/")
            ? request.model.components(separatedBy: "/").last ?? request.model
            : request.model

        /// Create request body using shared builder (includes tools, tool_calls, tool_call_id).
        /// Z.AI uses max_completion_tokens (not max_tokens) and has specific sampling defaults.
        var requestBody = request.buildOpenAICompatibleRequestBody(
            modelOverride: modelForAPI,
            temperatureOverride: request.temperature ?? config.temperature ?? 1.0,
            extraFields: [
                "top_p": 0.95
            ]
        )

        // Z.AI uses max_completion_tokens instead of max_tokens
        requestBody.removeValue(forKey: "max_tokens")
        if let maxTokens = request.maxTokens ?? config.maxTokens {
            requestBody["max_completion_tokens"] = max(maxTokens, 2048)
        } else {
            requestBody["max_completion_tokens"] = 4096
        }

        // Enable thinking parameter for chain-of-thought (Z.AI specific)
        requestBody["thinking"] = ["type": "enabled"]

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        let configuredTimeout = TimeInterval(config.timeoutSeconds ?? 300)
        urlRequest.timeoutInterval = max(configuredTimeout, 300)

        logger.debug("Sending request to Z.AI API [req:\(requestId.prefix(8))]")

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            logger.debug("Z.AI API response [req:\(requestId.prefix(8))]: \(httpResponse.statusCode)")

            // Handle error responses
            guard 200...299 ~= httpResponse.statusCode else {
                if let errorData = String(data: data, encoding: .utf8) {
                    logger.error("Z.AI API error [req:\(requestId.prefix(8))]: \(errorData)")
                    // Check for Z.AI specific rate limit codes
                    if errorData.contains("1302") || errorData.contains("1303") || errorData.contains("1305") {
                        throw ProviderError.rateLimitExceeded("Z.AI rate limit exceeded")
                    }
                    if errorData.contains("1308") {
                        throw ProviderError.quotaExceeded("Z.AI usage limit exceeded")
                    }
                }
                throw ProviderError.networkError("Z.AI API returned status \(httpResponse.statusCode)")
            }

            let openAIResponse = try JSONDecoder().decode(ServerOpenAIChatResponse.self, from: data)
            logger.debug("Successfully processed Z.AI response [req:\(requestId.prefix(8))]")

            return openAIResponse

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("Z.AI API request failed [req:\(requestId.prefix(8))]: \(error)")
            throw ProviderError.networkError("Network error: \(error.localizedDescription)")
        }
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        let models = config.models.map { modelId in
            ServerOpenAIModel(
                id: modelId,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: "zai"
            )
        }

        return ServerOpenAIModelsResponse(
            object: "list",
            data: models
        )
    }

    public func supportsModel(_ model: String) -> Bool {
        return config.models.contains(model) || model.lowercased().contains("glm")
    }

    public func validateConfiguration() async throws -> Bool {
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("Z.AI API key is required")
        }

        return true
    }

    public func loadModel() async throws -> ModelCapabilities {
        throw ProviderError.invalidRequest("loadModel() not supported for remote providers")
    }

    public func getLoadedStatus() async -> Bool {
        return false
    }

    public func unload() async {
        // No-op for remote providers.
    }
}

// MARK: - Helper Methods

extension ProviderConfiguration {
    /// Whether this custom provider requires an API key.
    var requiresApiKey: Bool {
        return providerType.requiresApiKey || (customHeaders?["authorization"] != nil)
    }
}
