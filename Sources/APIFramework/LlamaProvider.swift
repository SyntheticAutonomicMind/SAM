// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import SwiftUI
import ConfigurationSystem
import Logging

private let providerLogger = Logging.Logger(label: "com.sam.llama.LlamaProvider")

/// Local AI provider using llama.cpp for on-device inference.
@MainActor
public class LlamaProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration

    private var llamaContext: LlamaContext?
    private let modelPath: String

    /// Track conversation ID to detect conversation switches When conversation changes, KV cache must be cleared to prevent context leak.
    private var currentConversationId: String?

    /// OPTIMIZATION: Per-conversation KV cache storage (PRIORITY 1) Similar to MLX's implementation, cache KV state for up to 5 conversations This prevents expensive KV cache rebuild when switching between conversations Performance: 5 seconds → 500ms conversation switch time (10x improvement).
    public struct KVCacheState: Sendable {
        let stateData: Data
        let tokens: [Int32]
        let nCur: Int32
        let nDecode: Int32
        let timestamp: Date

        init(stateData: Data, tokens: [Int32], nCur: Int32, nDecode: Int32) {
            self.stateData = stateData
            self.tokens = tokens
            self.nCur = nCur
            self.nDecode = nDecode
            self.timestamp = Date()
        }
    }

    private var conversationCaches: [String: KVCacheState] = [:]
    private let maxCachedConversations = 5  // Conservative for llama.cpp's larger memory footprint

    /// Model loading notifications (optional callback to EndpointManager).
    private var onModelLoadingStarted: ((String, String) -> Void)?
    private var onModelLoadingCompleted: ((String) -> Void)?

    public init(config: ProviderConfiguration, modelPath: String, onModelLoadingStarted: ((String, String) -> Void)? = nil, onModelLoadingCompleted: ((String) -> Void)? = nil) {
        self.identifier = config.providerId
        self.config = config
        self.modelPath = modelPath
        self.onModelLoadingStarted = onModelLoadingStarted
        self.onModelLoadingCompleted = onModelLoadingCompleted
        providerLogger.info("LlamaProvider initialized for model: \(modelPath)")
    }

    // MARK: - Protocol Conformance

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        providerLogger.debug("Processing chat completion request")

        /// Initialize context if needed.
        if llamaContext == nil {
            /// Notify model loading started.
            let modelName = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
            onModelLoadingStarted?(identifier, modelName)
            providerLogger.info("MODEL_LOADING: Starting to load \(modelName)")

            llamaContext = try LlamaContext.create_context(path: modelPath)

            /// Notify model loading completed.
            onModelLoadingCompleted?(identifier)
            providerLogger.info("MODEL_LOADING: Completed loading \(modelName)")
        }

        guard let context = llamaContext else {
            throw LlamaError.couldNotInitializeContext
        }

        /// OPTIMIZATION: Per-conversation KV cache (PRIORITY 1) Instead of clearing on every conversation switch, save/restore KV state Performance: 5 seconds → 500ms (10x improvement) for conversation switching.
        let requestConversationId = request.conversationId ?? request.sessionId ?? request.contextId
        if let convId = requestConversationId {
            if currentConversationId != convId {
                providerLogger.info("CONVERSATION_SWITCH: Switching from \(currentConversationId ?? "none") to \(convId)")

                /// Save current conversation's KV cache before switching.
                if let currentId = currentConversationId {
                    await saveCurrentKVCacheState(for: currentId)
                }

                /// Restore new conversation's KV cache OR clear if not cached.
                if await restoreKVCacheState(for: convId) {
                    providerLogger.info("CONVERSATION_SWITCH: Restored cached KV state for \(convId)")
                } else {
                    providerLogger.info("CONVERSATION_SWITCH: No cache found for \(convId), starting fresh")
                    await context.clear()
                }

                currentConversationId = convId
            } else {
                providerLogger.debug("Same conversation (\(convId)), KV cache preserved for efficiency")
            }
        }

        /// Always clear KV cache at START of request if no conversation ID provided If previous request crashed, KV cache persists with stale position This causes "sequence positions remain consecutive" error.
        if requestConversationId == nil {
            await context.clear()
            providerLogger.debug("No conversation ID provided - cleared KV cache as safety measure")
        }

        /// REASONING CONTROL: Prepend /nothink instruction if reasoning disabled **What is reasoning**: Some models (DeepSeek-R1, QwQ) generate internal <think> tags showing step-by-step reasoning before final answer.
        var modifiedMessages = request.messages
        let reasoningEnabled = request.samConfig?.enableReasoning ?? true
        if !reasoningEnabled, let lastUserMessageIndex = modifiedMessages.lastIndex(where: { $0.role == "user" }) {
            if let lastUserContent = modifiedMessages[lastUserMessageIndex].content {
                /// Prepend /nothink with instruction to ignore if model doesn't understand.
                let modifiedContent = "/nothink (ignore this if you don't understand it)\n\n\(lastUserContent)"
                modifiedMessages[lastUserMessageIndex] = OpenAIChatMessage(role: "user", content: modifiedContent)
                providerLogger.info("REASONING: Disabled - prepended /nothink instruction to user message")
            }
        }

        /// Format messages with tools if provided.
        let chatMessages = prepareMessages(modifiedMessages, tools: request.tools)

        /// Use llama.cpp's chat template for proper formatting.
        let prompt = await context.format_chat(messages: chatMessages)
        providerLogger.debug("Formatted prompt with chat template: \(prompt.prefix(200))...")

        /// Set max tokens limit before starting generation.
        /// Use request.maxTokens if provided, otherwise default to 4096.
        let maxTokensLimit = request.maxTokens ?? 4096
        await context.setMaxTokensLimit(maxTokensLimit)
        providerLogger.info("LLAMA_GENERATION: maxTokensLimit=\(maxTokensLimit)")

        /// Initialize completion.
        await context.completion_init(text: prompt)

        /// Generate response with timeout protection.
        var fullResponse = ""
        let startTime = Date()
        let maxGenerationTime: TimeInterval = 300
        var tokenCount = 0
        let maxTokens = maxTokensLimit  // Use the same limit as set in context

        while await !context.is_done {
            /// Check timeout.
            if Date().timeIntervalSince(startTime) > maxGenerationTime {
                providerLogger.error("ERROR: GENERATION_TIMEOUT: Stopping after \(maxGenerationTime)s")
                await context.clear()
                throw LlamaError.generationTimeout
            }

            /// Check token limit.
            tokenCount += 1
            if tokenCount > maxTokens {
                providerLogger.error("ERROR: TOKEN_LIMIT: Stopping after \(tokenCount) tokens")
                await context.clear()
                throw LlamaError.tokenLimitExceeded
            }

            let token = await context.completion_loop()
            fullResponse += token
        }

        /// Clear context for next request.
        await context.clear()

        providerLogger.info("Generated response: \(fullResponse.count) characters")

        /// Log performance metrics.
        let metrics = await context.getPerformanceMetrics()
        providerLogger.info("PERFORMANCE: \(String(format: "%.2f", metrics.tokensPerSecond)) tokens/sec, \(metrics.tokensGenerated) tokens in \(String(format: "%.2f", metrics.totalTime))s")

        /// Strip EOS tokens (Qwen uses <|im_end|>, others may use different tokens).
        let cleanedResponse = fullResponse
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<|endoftext|>", with: "")
            .replacingOccurrences(of: "</s>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        /// Parse tool calls from response if present.
        let (cleanedContent, toolCalls) = parseToolCalls(from: cleanedResponse)

        /// Process think tags using universal formatter.
        /// ALWAYS show reasoning if model produces <think> tags (don't hide them).
        /// The /nothink instruction tells the model NOT to use thinking, but if it does anyway, show it.
        var formatter = ThinkTagFormatter(hideThinking: false)
        let (formattedContent, _) = formatter.processChunk(cleanedContent)
        let finalContent = formattedContent + formatter.flushBuffer()

        let finishReason = toolCalls != nil ? "tool_calls" : "stop"

        /// Create OpenAI-compatible response.
        let response = ServerOpenAIChatResponse(
            id: "chatcmpl-\(UUID().uuidString)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: request.model,
            choices: [
                OpenAIChatChoice(
                    index: 0,
                    message: OpenAIChatMessage(
                        role: "assistant",
                        content: finalContent,
                        toolCalls: toolCalls
                    ),
                    finishReason: finishReason
                )
            ],
            usage: ServerOpenAIUsage(
                promptTokens: prompt.count / 4,
                completionTokens: fullResponse.count / 4,
                totalTokens: (prompt.count + fullResponse.count) / 4
            )
        )

        return response
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        providerLogger.debug("Processing streaming chat completion request")

        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

                do {
                    /// Initialize context if needed.
                    if self.llamaContext == nil {
                        self.llamaContext = try LlamaContext.create_context(path: self.modelPath)
                    }

                    guard let context = self.llamaContext else {
                        throw LlamaError.couldNotInitializeContext
                    }

                    /// OPTIMIZATION: Per-conversation KV cache (PRIORITY 1) Instead of clearing on every conversation switch, save/restore KV state Performance: 5 seconds → 500ms (10x improvement) for conversation switching.
                    let requestConversationId = request.conversationId ?? request.sessionId ?? request.contextId
                    if let convId = requestConversationId {
                        if self.currentConversationId != convId {
                            providerLogger.info("CONVERSATION_SWITCH_STREAMING: Switching from \(self.currentConversationId ?? "none") to \(convId)")

                            /// Save current conversation's KV cache before switching.
                            if let currentId = self.currentConversationId {
                                await self.saveCurrentKVCacheState(for: currentId)
                            }

                            /// Restore new conversation's KV cache OR clear if not cached.
                            if await self.restoreKVCacheState(for: convId) {
                                providerLogger.info("CONVERSATION_SWITCH_STREAMING: Restored cached KV state for \(convId)")
                            } else {
                                providerLogger.info("CONVERSATION_SWITCH_STREAMING: No cache found for \(convId), starting fresh")
                                await context.clear()
                            }

                            self.currentConversationId = convId
                        } else {
                            providerLogger.debug("Same conversation (\(convId)), KV cache preserved for efficiency")
                        }
                    }

                    /// Always clear KV cache at START of request if no conversation ID provided If previous request crashed, KV cache persists with stale position This causes "sequence positions remain consecutive" error.
                    if requestConversationId == nil {
                        await context.clear()
                        providerLogger.debug("No conversation ID provided - cleared KV cache as safety measure")
                    }

                    /// REASONING CONTROL: Prepend /nothink instruction if reasoning disabled (See non-streaming path for full documentation of /nothink mechanism) Source: Ollama GitHub issue #10456.
                    var modifiedMessages = request.messages
                    let reasoningEnabled = request.samConfig?.enableReasoning ?? true
                    if !reasoningEnabled, let lastUserMessageIndex = modifiedMessages.lastIndex(where: { $0.role == "user" }) {
                        if let lastUserContent = modifiedMessages[lastUserMessageIndex].content {
                            /// Prepend /nothink with instruction to ignore if model doesn't understand.
                            let modifiedContent = "/nothink (ignore this if you don't understand it)\n\n\(lastUserContent)"
                            modifiedMessages[lastUserMessageIndex] = OpenAIChatMessage(role: "user", content: modifiedContent)
                            providerLogger.info("REASONING: Disabled - prepended /nothink instruction to user message")
                        }
                    }

                    /// Format messages with tools if provided.
                    let chatMessages = self.prepareMessages(modifiedMessages, tools: request.tools)

                    /// Use llama.cpp's chat template for proper formatting.
                    let prompt = await context.format_chat(messages: chatMessages)

                    /// Ensure prompt ends with assistant marker Llama.cpp chat templates don't always add <|im_start|>assistant after system messages This causes LLM to wait rather than generate responses.
                    let finalPrompt: String
                    if !prompt.hasSuffix("<|im_start|>assistant\n") &&
                       !prompt.hasSuffix("<|im_start|>assistant") {
                        providerLogger.info("LLAMA_FIX: Prompt ends with '\(prompt.suffix(50))'")
                        providerLogger.info("LLAMA_FIX: Appending assistant marker to prompt")
                        finalPrompt = prompt + "<|im_start|>assistant\n"
                    } else {
                        finalPrompt = prompt
                    }

                    /// Log full prompt when generation fails.
                    if chatMessages.count > 5 {
                        providerLogger.info("DEBUG_EMPTY_RESPONSE: Prompt has \(chatMessages.count) messages")
                        providerLogger.info("DEBUG_EMPTY_RESPONSE: Last 3 messages:")
                        for (idx, msg) in chatMessages.suffix(3).enumerated() {
                            providerLogger.info("DEBUG_EMPTY_RESPONSE:   \(chatMessages.count - 3 + idx). role=\(msg.role), content=\(msg.content.prefix(100))")
                        }
                        providerLogger.info("DEBUG_EMPTY_RESPONSE: Formatted prompt (last 500 chars):")
                        providerLogger.info("DEBUG_EMPTY_RESPONSE: ...\(finalPrompt.suffix(500))")
                    }

                    /// Set max tokens limit before starting generation.
                    /// Use request.maxTokens if provided, otherwise default to 4096.
                    let maxTokensLimit = request.maxTokens ?? 4096
                    await context.setMaxTokensLimit(maxTokensLimit)
                    providerLogger.info("LLAMA_GENERATION: maxTokensLimit=\(maxTokensLimit)")

                    /// Initialize completion.
                    await context.completion_init(text: finalPrompt)

                    /// Accumulate full response WITHOUT streaming individual tokens This prevents tool calls from being visible to users during generation.
                    var fullResponse = ""

                    while await !context.is_done {
                        /// Check for Task cancellation from UI stop button.
                        if Task.isCancelled {
                            providerLogger.info("TASK_CANCELLED: Stopping generation via context.cancel()")
                            await context.cancel()
                            break
                        }

                        let token = await context.completion_loop()

                        if !token.isEmpty {
                            fullResponse += token
                        }
                    }

                    /// Parse ChatML format and extract tool calls from full response Then process <think> tags using universal formatter.
                    let (cleanedContent, toolCalls) = self.parseToolCalls(from: fullResponse)

                    /// DEBUG: Log raw and cleaned content for think tag diagnosis
                    providerLogger.debug("RAW_RESPONSE (\(fullResponse.count) chars): \(fullResponse.prefix(500))...")
                    providerLogger.debug("CLEANED_CONTENT (\(cleanedContent.count) chars): \(cleanedContent.prefix(500))...")

                    /// Process think tags in cleaned content.
                    /// ALWAYS show reasoning if model produces <think> tags (don't hide them).
                    /// The /nothink instruction tells the model NOT to use thinking, but if it does anyway, show it.
                    var formatter = ThinkTagFormatter(hideThinking: false)
                    let (formattedContent, _) = formatter.processChunk(cleanedContent)
                    let finalContent = formattedContent + formatter.flushBuffer()

                    /// DEBUG: Log formatted content
                    providerLogger.debug("FORMATTED_CONTENT (\(formattedContent.count) chars): \(formattedContent.prefix(500))...")
                    providerLogger.debug("FINAL_CONTENT (\(finalContent.count) chars): \(finalContent.prefix(500))...")

                    let finishReason = toolCalls != nil ? "tool_calls" : "stop"

                    providerLogger.info("Generation complete: \(fullResponse.count) chars, finish_reason=\(finishReason), tools=\(toolCalls?.count ?? 0)")

                    /// Log performance metrics.
                    let metrics = await context.getPerformanceMetrics()
                    providerLogger.info("PERFORMANCE: \(String(format: "%.2f", metrics.tokensPerSecond)) tokens/sec, \(metrics.tokensGenerated) tokens in \(String(format: "%.2f", metrics.totalTime))s")

                    if !finalContent.isEmpty {
                        let contentChunk = ServerOpenAIChatStreamChunk(
                            id: "chatcmpl-\(UUID().uuidString)",
                            object: "chat.completion.chunk",
                            created: Int(Date().timeIntervalSince1970),
                            model: request.model,
                            choices: [
                                OpenAIChatStreamChoice(
                                    index: 0,
                                    delta: OpenAIChatDelta(
                                        role: nil,
                                        content: finalContent
                                    ),
                                    finishReason: nil
                                )
                            ]
                        )
                        continuation.yield(contentChunk)
                    }

                    /// Send final chunk with correct finish_reason and tool calls (if any).
                    let finalChunk = ServerOpenAIChatStreamChunk(
                        id: "chatcmpl-\(UUID().uuidString)",
                        object: "chat.completion.chunk",
                        created: Int(Date().timeIntervalSince1970),
                        model: request.model,
                        choices: [
                            OpenAIChatStreamChoice(
                                index: 0,
                                delta: OpenAIChatDelta(
                                    role: nil,
                                    content: "",
                                    toolCalls: toolCalls
                                ),
                                finishReason: finishReason
                            )
                        ]
                    )
                    continuation.yield(finalChunk)

                    /// Clear context for next request.
                    await context.clear()

                    continuation.finish()

                } catch {
                    providerLogger.error("Streaming error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        /// Return the provider's registered model identifier (config.models[0]) NOT the filename, to ensure consistency with provider registration Provider registered as: "llama/provider/model" (type/provider/model format) Must return same identifier so preload logic doesn't detect false mismatch.
        let modelId = config.models.first ?? (modelPath as NSString).lastPathComponent
        return ServerOpenAIModelsResponse(
            object: "list",
            data: [
                ServerOpenAIModel(
                    id: modelId,
                    object: "model",
                    created: Int(Date().timeIntervalSince1970),
                    ownedBy: "local"
                )
            ]
        )
    }

    public func supportsModel(_ model: String) -> Bool {
        /// Check if model matches our loaded model (support both identifiers).
        let modelName = (modelPath as NSString).lastPathComponent
        let registeredModelId = config.models.first ?? ""

        /// Support both filename and registered identifier.
        return model == modelName ||
               model.contains(modelName) ||
               model == registeredModelId ||
               model.contains(registeredModelId)
    }

    public func validateConfiguration() async throws -> Bool {
        /// Check if model file exists.
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: self.modelPath) else {
            providerLogger.error("Model file not found: \(self.modelPath)")
            throw LlamaError.modelNotFound(self.modelPath)
        }

        /// Try to initialize context.
        do {
            let context = try LlamaContext.create_context(path: self.modelPath)
            await context.clear()
            providerLogger.info("Model validation successful")
            return true
        } catch {
            providerLogger.error("Model validation failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Lifecycle

    /// Cancel ongoing generation (stops GPU processing) CRITICAL: This is called when user presses stop button.
    public func cancelGeneration() async {
        providerLogger.info("CANCEL_GENERATION: Stopping llama.cpp generation")
        if let context = llamaContext {
            await context.cancel()
        }
    }

    /// Unload model from memory (frees GPU/RAM resources) CRITICAL: Call this when switching models or ending conversation CRITICAL FIX: Capture context locally to prevent race with new requests.
    public func unload() async {
        /// Capture context BEFORE any async operations to prevent race condition If new request creates new context while we're unloading, we don't want to cancel it.
        let contextToUnload = llamaContext
        llamaContext = nil
        currentConversationId = nil

        guard let context = contextToUnload else {
            providerLogger.debug("UNLOAD_MODEL: No context to unload")
            return
        }

        providerLogger.info("UNLOAD_MODEL: Cancelling any ongoing generation on old context")
        await context.cancel()

        providerLogger.info("UNLOAD_MODEL: Freeing llama.cpp context and model resources")
        await context.clear()

        /// OPTIMIZATION: Clear conversation caches on model unload.
        clearAllConversationCaches()
    }

    /// Load the model into memory and return its capabilities.
    public func loadModel() async throws -> ModelCapabilities {
        providerLogger.info("LOAD_MODEL: Explicitly loading GGUF model")

        /// Initialize context if needed.
        if llamaContext == nil {
            let modelName = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
            onModelLoadingStarted?(identifier, modelName)
            providerLogger.info("MODEL_LOADING: Starting to load \(modelName)")

            llamaContext = try LlamaContext.create_context(path: modelPath)

            onModelLoadingCompleted?(identifier)
            providerLogger.info("MODEL_LOADING: Completed loading \(modelName)")
        }

        guard let context = llamaContext else {
            throw LlamaError.couldNotInitializeContext
        }

        /// Get context size from the loaded model.
        let contextSize = await context.getContextSize()
        let maxTokens = contextSize / 2
        let modelName = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent

        providerLogger.debug("LOAD_MODEL: GGUF model loaded - \(modelName), context: \(contextSize), max_tokens: \(maxTokens)")

        return ModelCapabilities(
            contextSize: contextSize,
            maxTokens: maxTokens,
            supportsStreaming: true,
            providerType: "GGUF",
            modelName: modelName
        )
    }

    /// Check if the model is currently loaded in memory.
    public func getLoadedStatus() async -> Bool {
        return llamaContext != nil
    }

    /// Get performance metrics from current generation.
    public func getPerformanceMetrics() async -> (tokensPerSecond: Double, totalTime: Double, tokensGenerated: Int) {
        guard let context = llamaContext else { return (0.0, 0.0, 0) }
        return await context.getPerformanceMetrics()
    }

    // MARK: - Helper Methods

    /// Prepare messages for chat template formatting
    /// SIMPLIFIED: Minimal tool instructions when tools provided
    private func prepareMessages(_ messages: [OpenAIChatMessage], tools: [OpenAITool]? = nil) -> [(role: String, content: String)] {
        var chatMessages: [(role: String, content: String)] = []

        /// If tools provided, add MINIMAL instructions to system prompt
        if let tools = tools, !tools.isEmpty {
            providerLogger.info("LLAMA_MINIMAL_TOOLS: Adding minimal tool instructions for \(tools.count) tools")

            let toolInstructions = buildMinimalToolInstructions(tools)
            providerLogger.info("LLAMA_MINIMAL_TOOLS: Instructions length = \(toolInstructions.count) chars")
            providerLogger.info("LLAMA_MINIMAL_TOOLS: FULL INSTRUCTIONS:\n\(toolInstructions)")

            /// Find or prepend system message with tool instructions
            if let systemIndex = messages.firstIndex(where: { $0.role == "system" }) {
                let systemContent = (messages[systemIndex].content ?? "") + "\n\n" + toolInstructions
                chatMessages.append((role: "system", content: systemContent))

                /// Add remaining messages
                for (idx, message) in messages.enumerated() where idx != systemIndex {
                    appendMessage(message, to: &chatMessages)
                }
            } else {
                /// No system message - prepend one
                chatMessages.append((role: "system", content: toolInstructions))
                for message in messages {
                    appendMessage(message, to: &chatMessages)
                }
            }
        } else {
            /// No tools - just convert messages
            providerLogger.info("LLAMA_SIMPLIFIED: Converting \(messages.count) messages without tools")
            for message in messages {
                appendMessage(message, to: &chatMessages)
            }
        }

        return chatMessages
    }

    /// Helper to append a message with proper role conversion
    private func appendMessage(_ message: OpenAIChatMessage, to chatMessages: inout [(role: String, content: String)]) {
        if message.role == "tool" {
            /// Convert tool results to user messages for chat template compatibility
            let toolContent = message.content ?? "{}"
            let toolResultMessage = """
            Tool Result:
            \(toolContent)
            """
            chatMessages.append((role: "user", content: toolResultMessage))
        } else if message.role == "assistant" && (message.content == nil || message.content!.isEmpty) {
            /// Include assistant messages even if content is empty
            chatMessages.append((role: "assistant", content: ""))
        } else if let content = message.content {
            chatMessages.append((role: message.role, content: content))
        }
    }

    /// Build MINIMAL tool instructions with clear JSON output directive
    /// ToolCallExtractor supports: OpenAI, Qwen, Hermes, Ministral, bare JSON, embedded JSON
    private func buildMinimalToolInstructions(_ tools: [OpenAITool]) -> String {
        var instructions = """
        # Available Tools

        When making a tool call, respond with the EXACT tool request in raw JSON with no other response. Do not use code blocks, and do not respond conversationally.
        Format: {"name": "tool_name", "arguments": {"param": "value"}}

        """

        for tool in tools {
            instructions += "\(tool.function.name): \(tool.function.description)\n"

            /// Add parameter info (names and types only)
            if let paramsData = tool.function.parametersJson.data(using: .utf8),
               let params = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any],
               let properties = params["properties"] as? [String: Any] {
                let required = (params["required"] as? [String]) ?? []
                var paramList: [String] = []

                for (paramName, paramInfo) in properties.sorted(by: { $0.key < $1.key }) {
                    if let paramDict = paramInfo as? [String: Any] {
                        let paramType = paramDict["type"] as? String ?? "any"
                        let reqMark = required.contains(paramName) ? "*" : ""
                        paramList.append("\(paramName)\(reqMark):\(paramType)")
                    }
                }

                if !paramList.isEmpty {
                    instructions += "  Args: " + paramList.joined(separator: ", ") + "\n"
                }
            }
            instructions += "\n"
        }

        return instructions
    }

    /// Build Qwen2-style tool instructions for Qwen2.5-Coder models **Purpose**: Generate tool calling instructions in Qwen2's native format **Format**: `FUNCTION: tool_name\nARGS: {json_arguments}` **Why this specific format**: - Qwen2.5-Coder models ONLY understand this format (not Hermes/OpenAI style) - Regular Qwen2.5 models support Hermes-style - Coder variants trained specifically with FUNCTION/ARGSmarkers **Source**: Qwen-Agent GitHub repository documents official function calling format **Impact if wrong format used**: Tool calls fail, model generates regular text instead Format: FUNCTION: tool_name\nARGS: {json_arguments} This is the ONLY format that Qwen2.5-Coder models understand properly Regular Qwen2.5 models support Hermes-style, but Coder variants only support Qwen2-style.
    private func buildQwen2ToolInstructions(_ tools: [OpenAITool]) -> String {
        var instructions = """
        # Tools

        ## You have access to the following tools:

        """

        /// Format each tool with full parameter documentation.
        for tool in tools {
            instructions += "\n### \(tool.function.name)"
            instructions += "\n\(tool.function.name): \(tool.function.description)"

            /// Parse parameters JSON and add detailed parameter documentation.
            if let paramsData = tool.function.parametersJson.data(using: .utf8),
               let params = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any],
               let properties = params["properties"] as? [String: Any] {
                instructions += " Parameters: "

                var paramDescriptions: [String] = []
                for (paramName, paramInfo) in properties.sorted(by: { $0.key < $1.key }) {
                    if let paramDict = paramInfo as? [String: Any] {
                        let paramType = paramDict["type"] as? String ?? "any"
                        let paramDesc = paramDict["description"] as? String ?? ""
                        paramDescriptions.append("\(paramName) (\(paramType)): \(paramDesc)")
                    }
                }
                instructions += paramDescriptions.joined(separator: ", ")
            }
            instructions += " Format the arguments as a JSON object."
        }

        /// Add Qwen2-style format instructions.
        let toolNames = tools.map { $0.function.name }.joined(separator: ", ")
        instructions += """


        ## When you need to call a tool, insert the following command in your reply:

        FUNCTION: The tool to use, should be one of [\(toolNames)]
        ARGS: Tool input as JSON object
        RESULT: Tool results
        RETURN: Reply based on tool results

        **IMPORTANT FORMAT RULES:**
        1. Use exactly these Unicode flower markers: FUNCTIONand ARGS        2. Tool name must be one of the available tools listed above
        3. Arguments must be a valid JSON object matching the tool's parameter schema
        4. Do NOT add any additional formatting or text around the markers

        **Example:**

        FUNCTION: get_datetime
        ARGS: {}

        """

        return instructions
    }

    private func buildToolInstructions(_ tools: [OpenAITool]) -> String {
        /// Token-optimized tool instructions for small context models Removes verbose examples while preserving ALL parameter information Target: ~1500 tokens vs original ~5500 tokens.

        var instructions = """
        # TOOLS

        Call format: <tool_call>{"name": "tool_name", "arguments": {"param": "value"}}</tool_call>

        Rules:
        - Single line JSON with "name" and "arguments" fields
        - Arguments must be valid JSON object (use {} if no params)
        - No markdown blocks, no extra formatting

        Available tools:

        """

        /// Format each tool with FULL parameter documentation (DO NOT abbreviate) This information is critical for correct tool usage.
        for tool in tools {
            instructions += "\n### \(tool.function.name)"
            instructions += "\n\(tool.function.description)"

            /// Parse parameters JSON and add detailed parameter documentation.
            if let paramsData = tool.function.parametersJson.data(using: .utf8),
               let params = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any],
               let properties = params["properties"] as? [String: Any] {
                instructions += "\nParams:"

                let required = (params["required"] as? [String]) ?? []

                for (paramName, paramInfo) in properties.sorted(by: { $0.key < $1.key }) {
                    if let paramDict = paramInfo as? [String: Any] {
                        let paramType = paramDict["type"] as? String ?? "any"
                        let paramDesc = paramDict["description"] as? String ?? ""
                        let reqStatus = required.contains(paramName) ? "req" : "opt"

                        instructions += "\n- \(paramName) (\(paramType),\(reqStatus)): \(paramDesc)"

                        /// Add enum values if present (CRITICAL: do not omit).
                        if let enumValues = paramDict["enum"] as? [String] {
                            instructions += " [values: \(enumValues.joined(separator: ", "))]"
                        }
                    }
                }
            } else {
                instructions += "\nParams: none"
            }
        }

        return instructions
    }

    private func parseChatMLResponse(_ response: String) -> String {
        var cleanedResponse = response

        /// Pattern: <|im_start|>assistant\n...content...<|im_end|> We want to extract only the assistant's actual content.

        /// Strategy 1: If response contains <|im_start|>assistant, extract content between it and <|im_end|>.
        if let assistantStart = cleanedResponse.range(of: "<|im_start|>assistant") {
            let afterAssistantTag = cleanedResponse[assistantStart.upperBound...]

            /// Skip past the newline after "assistant".
            var contentStart = afterAssistantTag.startIndex
            if afterAssistantTag.first == "\n" || afterAssistantTag.first == " " {
                contentStart = afterAssistantTag.index(after: contentStart)
            }

            /// Find the closing <|im_end|> tag.
            if let endTag = afterAssistantTag.range(of: "<|im_end|>") {
                cleanedResponse = String(afterAssistantTag[contentStart..<endTag.lowerBound])
            } else {
                /// No closing tag - take everything after assistant tag.
                cleanedResponse = String(afterAssistantTag[contentStart...])
            }
        }

        /// Strategy 2: Remove any remaining ChatML tags (system, user, etc.).
        cleanedResponse = cleanedResponse
            .replacingOccurrences(of: "<|im_start|>system", with: "")
            .replacingOccurrences(of: "<|im_start|>user", with: "")
            .replacingOccurrences(of: "<|im_start|>assistant", with: "")
            .replacingOccurrences(of: "<|im_start|>", with: "")
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<|endoftext|>", with: "")
            .replacingOccurrences(of: "</s>", with: "")

        return cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Universal Tool Call Parsing (using ToolCallExtractor)
    private let toolCallExtractor = ToolCallExtractor()

    private func parseToolCalls(from response: String) -> (String, [OpenAIToolCall]?) {
        /// Parse ChatML format to extract assistant content.
        let cleanedResponse = parseChatMLResponse(response)

        /// Use universal ToolCallExtractor to detect all formats.
        let (extractedCalls, cleanedContent, detectedFormat) = toolCallExtractor.extract(from: cleanedResponse)

        /// Log detected format.
        switch detectedFormat {
        case .qwen:
            providerLogger.info("ToolCallExtractor detected Qwen <function_call> format - \(extractedCalls.count) tool calls")

        case .ministral:
            providerLogger.info("ToolCallExtractor detected Ministral [TOOL_CALLS] format - \(extractedCalls.count) tool calls")

        case .hermes:
            providerLogger.info("ToolCallExtractor detected Hermes format - \(extractedCalls.count) tool calls")

        case .jsonCodeBlock:
            providerLogger.info("ToolCallExtractor detected JSON code block format - \(extractedCalls.count) tool calls")

        case .bareJSON:
            providerLogger.info("ToolCallExtractor detected bare JSON format - \(extractedCalls.count) tool calls")

        case .openai:
            providerLogger.info("ToolCallExtractor detected OpenAI format - \(extractedCalls.count) tool calls")

        case .none:
            /// No tool calls found.
            break
        }

        /// Convert ToolCallExtractor.ToolCall to OpenAIToolCall.
        if extractedCalls.isEmpty {
            return (cleanedContent, nil)
        }

        let toolCalls = extractedCalls.map { extractedCall -> OpenAIToolCall in
            OpenAIToolCall(
                id: extractedCall.id ?? "call_\(UUID().uuidString.prefix(24))",
                type: "function",
                function: OpenAIFunctionCall(
                    name: extractedCall.name,
                    arguments: extractedCall.arguments
                )
            )
        }

        /// Clean up special tokens from cleaned content.
        let finalContent = cleanedContent
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<|im_start|>user", with: "")
            .replacingOccurrences(of: "<|im_start|>assistant", with: "")
            .replacingOccurrences(of: "<|im_start|>system", with: "")
            .replacingOccurrences(of: "<|im_start|>", with: "")
            .replacingOccurrences(of: "<|endoftext|>", with: "")
            .replacingOccurrences(of: "</s>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (finalContent, toolCalls)
    }

    // MARK: - Per-Conversation KV Cache Management (OPTIMIZATION PRIORITY 1)

    /// Save current KV cache state for the active conversation.
    private func saveCurrentKVCacheState(for conversationId: String) async -> Bool {
        guard let context = llamaContext else {
            return false
        }

        do {
            let cacheState = try await context.saveState()
            conversationCaches[conversationId] = cacheState
            pruneConversationCaches()

            let sizeKB = cacheState.stateData.count / 1024
            providerLogger.info("KV_CACHE_SAVE: Saved cache for conversation \(conversationId) (\(sizeKB)KB, \(cacheState.tokens.count) tokens)")
            return true
        } catch {
            providerLogger.error("KV_CACHE_SAVE: Failed to save cache for \(conversationId): \(error)")
            return false
        }
    }

    /// Restore KV cache state for a conversation.
    private func restoreKVCacheState(for conversationId: String) async -> Bool {
        guard let context = llamaContext, let cacheState = conversationCaches[conversationId] else {
            return false
        }

        do {
            try await context.restoreState(cacheState)
            let sizeKB = cacheState.stateData.count / 1024
            providerLogger.info("KV_CACHE_RESTORE: Restored cache for conversation \(conversationId) (\(sizeKB)KB, \(cacheState.tokens.count) tokens)")
            return true
        } catch {
            providerLogger.error("KV_CACHE_RESTORE: Failed to restore cache for \(conversationId): \(error)")
            return false
        }
    }

    /// Prune old conversation caches using LRU eviction.
    private func pruneConversationCaches() {
        guard conversationCaches.count > maxCachedConversations else {
            return
        }

        let countToRemove = conversationCaches.count - maxCachedConversations
        providerLogger.info("KV_CACHE_PRUNE: Removing \(countToRemove) old caches (total: \(conversationCaches.count), limit: \(maxCachedConversations))")

        /// Sort by timestamp (oldest first).
        let sortedByTimestamp = conversationCaches.sorted { $0.value.timestamp < $1.value.timestamp }

        /// Remove oldest caches.
        for (conversationId, cacheState) in sortedByTimestamp.prefix(countToRemove) {
            let sizeKB = cacheState.stateData.count / 1024
            conversationCaches.removeValue(forKey: conversationId)
            providerLogger.debug("KV_CACHE_PRUNE: Removed cache for conversation \(conversationId) (age: \(Date().timeIntervalSince(cacheState.timestamp))s, size: \(sizeKB)KB)")
        }

        providerLogger.info("KV_CACHE_PRUNE: Pruning complete, retained \(conversationCaches.count) caches")
    }

    /// Clear all conversation caches (called on model unload).
    private func clearAllConversationCaches() {
        let count = conversationCaches.count
        if count > 0 {
            providerLogger.info("KV_CACHE_CLEAR: Clearing all \(count) conversation caches")
            conversationCaches.removeAll()
        }
    }
}
