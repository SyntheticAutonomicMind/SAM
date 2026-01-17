// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// MLXProvider.swift SAM Created by AI Assistant on 2025.

import Foundation
import SwiftUI
import ConfigurationSystem
import Logging
import MLX
import Tokenizers
import Training

/// Import MLX components.
import MLXLLM
import MLXLMCommon
import MLXIntegration

private let providerLogger = Logging.Logger(label: "com.sam.mlx.MLXProvider")

/// Local AI provider using Apple's MLX framework for on-device inference with Apple Silicon optimization.
@MainActor
public class MLXProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration

    private let modelPath: String
    private let appleMLXAdapter = AppleMLXAdapter()
    private let modelCache = MLXModelCache()
    private let toolCallExtractor = ToolCallExtractor()
    
    /// Optional LoRA adapter ID for fine-tuned models
    private let loraAdapterId: String?
    
    /// Cached LoRA adapter (loaded on demand)
    private var cachedAdapter: LoRAAdapter?

    /// Track conversation ID to detect conversation switches.
    private var currentConversationId: String?

    /// Cached model and tokenizer for faster inference.
    private var cachedModel: (model: any LanguageModel, tokenizer: Tokenizer)?
    private var cachedModelPath: String?

    /// KV CACHE: Per-conversation prompt caching Each conversation maintains its own KV cache that: 1.
    private var conversationCaches: [String: [KVCache]] = [:]
    private var conversationAccessTimes: [String: Date] = [:]
    private let maxCachedConversations = 10

    /// Track ongoing generation task for cancellation.
    private var activeGenerationTask: Task<Void, Never>?

    /// Model loading notifications (optional callback to EndpointManager).
    private var onModelLoadingStarted: ((String, String) -> Void)?
    private var onModelLoadingCompleted: ((String) -> Void)?

    public init(config: ProviderConfiguration, modelPath: String, loraAdapterId: String? = nil, onModelLoadingStarted: ((String, String) -> Void)? = nil, onModelLoadingCompleted: ((String) -> Void)? = nil) {
        self.identifier = config.providerId
        self.config = config
        self.modelPath = modelPath
        self.loraAdapterId = loraAdapterId
        self.onModelLoadingStarted = onModelLoadingStarted
        self.onModelLoadingCompleted = onModelLoadingCompleted
        providerLogger.info("MLXProvider initialized for model: \(modelPath)", metadata: loraAdapterId != nil ? ["loraAdapter": "\(loraAdapterId!)"] : [:])

        self.appleMLXAdapter.enablePerformanceMonitoring = false

        /// Initialize cache.
        let cache = self.modelCache
        Task {
            try? await cache.initialize()
        }
    }

    // MARK: - Protocol Conformance

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        providerLogger.info("Processing MLX chat completion with model: \(request.model)")

        /// REASONING CONTROL: Prepend /nothink instruction if reasoning disabled **What is reasoning**: Some models (DeepSeek-R1, QwQ) generate internal <think> tags showing step-by-step reasoning before final answer.
        var modifiedRequest = request
        let reasoningEnabled = request.samConfig?.enableReasoning ?? true
        if !reasoningEnabled, let lastUserMessageIndex = modifiedRequest.messages.lastIndex(where: { $0.role == "user" }) {
            if let lastUserContent = modifiedRequest.messages[lastUserMessageIndex].content {
                /// Prepend /nothink with instruction to ignore if model doesn't understand.
                let modifiedContent = "/nothink (ignore this if you don't understand it)\n\n\(lastUserContent)"
                var modifiedMessages = modifiedRequest.messages
                modifiedMessages[lastUserMessageIndex] = OpenAIChatMessage(role: "user", content: modifiedContent)
                modifiedRequest = OpenAIChatRequest(
                    model: request.model,
                    messages: modifiedMessages,
                    temperature: request.temperature,
                    topP: request.topP,
                    repetitionPenalty: request.repetitionPenalty,
                    maxTokens: request.maxTokens,
                    stream: request.stream,
                    tools: request.tools,
                    samConfig: request.samConfig,
                    contextId: request.contextId,
                    enableMemory: request.enableMemory,
                    sessionId: request.sessionId,
                    conversationId: request.conversationId,
                    statefulMarker: request.statefulMarker
                )
                providerLogger.info("REASONING: Disabled - prepended /nothink instruction to user message")
            }
        }

        let requestToProcess = modifiedRequest

        /// Log all messages to see what we're receiving.
        providerLogger.info("MLX_DEBUG: Received \(requestToProcess.messages.count) messages:")
        for (index, msg) in requestToProcess.messages.enumerated() {
            providerLogger.info("MLX_DEBUG: Message \(index): role=\(msg.role), content=\(msg.content?.prefix(100) ?? "nil")")
        }

        /// PRIORITY 3 OPTIMIZATION: Single-pass message processing (4x faster) Instead of 4 separate iterations: system extraction, tool conversion, role merging, final building We now do all operations in ONE pass with inline merging.
        providerLogger.debug("MLX_OPTIMIZATION: Processing \(requestToProcess.messages.count) messages in single pass")

        /// Get system prompt with tool guidance
        let toolsEnabled = request.samConfig?.mcpToolsEnabled ?? true
        var systemPrompt = SystemPromptManager.shared.generateSystemPrompt(toolsEnabled: toolsEnabled)

        /// Add tool guidance dynamically if tools present
        if let requestTools = request.tools, !requestTools.isEmpty {
            var toolsList = "\n\n## Available Tools\n"
            for tool in requestTools {
                toolsList += "\(tool.function.name): \(tool.function.description)\n"

                if let paramsData = tool.function.parametersJson.data(using: .utf8),
                   let params = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any],
                   let props = params["properties"] as? [String: [String: Any]] {
                    let required = (params["required"] as? [String]) ?? []
                    var paramList: [String] = []

                    for (paramName, paramDetails) in props.sorted(by: { $0.key < $1.key }) {
                        let isRequired = required.contains(paramName)
                        let paramType = paramDetails["type"] as? String ?? "any"
                        let reqMark = isRequired ? "*" : ""
                        paramList.append("\(paramName)\(reqMark):\(paramType)")
                    }

                    if !paramList.isEmpty {
                        toolsList += "  Args: " + paramList.joined(separator: ", ") + "\n"
                    }
                }
                toolsList += "\n"
            }
            systemPrompt += toolsList
        }

        providerLogger.info("MLX_NON_STREAMING_PROMPT: Using SystemPromptManager, tools=\(request.tools?.count ?? 0), length=\(systemPrompt.count)")

        /// Process messages in single pass (replaces 4 separate iterations)
        var processedWithoutSystem = processMessagesOptimized(requestToProcess.messages)

        /// Remove system message from processed (we'll add our own)
        processedWithoutSystem.removeAll { $0.role == "system" }

        /// Build final message list with our system prompt first
        var alternatingMessages = [OpenAIChatMessage]()
        alternatingMessages.append(OpenAIChatMessage(role: "system", content: systemPrompt))
        alternatingMessages.append(contentsOf: processedWithoutSystem)

        providerLogger.info("MLX_DEBUG: After system merge + alternation fix: \(alternatingMessages.count) messages (was \(request.messages.count))")

        /// Convert OpenAI messages to Tokenizers.Message format CRITICAL: Must preserve tool_call_id for Mistral/Mistral models.
        let messages: [Message] = alternatingMessages.map { msg in
            var message: Message = [:]
            message["role"] = msg.role
            message["content"] = msg.content

            /// Preserve tool_call_id for tool result messages.
            if let toolCallId = msg.toolCallId {
                message["tool_call_id"] = toolCallId
            }

            /// Preserve tool_calls for assistant messages with tool calls.
            if let toolCalls = msg.toolCalls {
                message["tool_calls"] = toolCalls.map { toolCall in
                    return [
                        "id": toolCall.id,
                        "type": toolCall.type,
                        "function": [
                            "name": toolCall.function.name,
                            "arguments": toolCall.function.arguments
                        ]
                    ] as [String: Any]
                }
            }

            return message
        }

        /// Convert tools if present.
        let tools: [ToolSpec]? = request.tools?.map { tool in
            /// ToolSpec is a typealias for [String: Any] in Tokenizers.
            var toolSpec: ToolSpec = [:]
            toolSpec["type"] = "function"

            /// Parse parametersJson back to dictionary.
            var parameters: [String: Any] = [:]
            if let data = tool.function.parametersJson.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parameters = parsed
            }

            toolSpec["function"] = [
                "name": tool.function.name,
                "description": tool.function.description,
                "parameters": parameters
            ]
            return toolSpec
        }

        /// Load model if not cached.
        let (model, tokenizer) = try await loadModelIfNeeded()

        /// Generate response.
        let responseText = try await appleMLXAdapter.generate(
            model: model,
            tokenizer: tokenizer,
            messages: messages,
            tools: tools,
            maxTokens: request.maxTokens ?? 2048,
            temperature: Float(request.temperature ?? 0.8)
        )

        providerLogger.info("Generated response: \(responseText.prefix(100))...")

        /// Use universal tool call extractor to detect if response contains tool calls Supports 6 formats: OpenAI, Ministral, Qwen, Hermes, JSON blocks, bare JSON.
        let (toolCalls, cleanedContent, detectedFormat) = toolCallExtractor.extract(from: responseText)
        let finishReason = toolCalls.isEmpty ? "stop" : "tool_calls"

        let finalContent = cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines)

        if !toolCalls.isEmpty {
            providerLogger.info("MLX_TOOLS: Detected \(toolCalls.count) tool calls (format: \(detectedFormat)), setting finish_reason=tool_calls, cleaned content")
        }

        /// Convert ToolCallExtractor.ToolCall to OpenAIToolCall format.
        let openAIToolCalls: [OpenAIToolCall]? = toolCalls.isEmpty ? nil : toolCalls.map { tc in
            OpenAIToolCall(
                id: tc.id ?? "call_\(UUID().uuidString)",
                type: "function",
                function: OpenAIFunctionCall(name: tc.name, arguments: tc.arguments)
            )
        }

        /// Build OpenAI-compatible response.
        let completion = ServerOpenAIChatResponse(
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
                        toolCalls: openAIToolCalls
                    ),
                    finishReason: finishReason
                )
            ],
            usage: ServerOpenAIUsage(
                promptTokens: estimateTokenCount(request.messages),
                completionTokens: estimateTokenCount([OpenAIChatMessage(role: "assistant", content: responseText)]),
                totalTokens: 0
            )
        )

        return completion
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        return AsyncThrowingStream { continuation in
            /// Store task for cancellation, cleared on completion.
            let generationTask = Task { @MainActor in
                defer {
                    /// Clear task reference when done.
                    self.activeGenerationTask = nil
                }

                do {
                    providerLogger.info("Processing streaming MLX chat completion with model: \(request.model)")

                    /// REASONING CONTROL: Prepend /nothink instruction if reasoning disabled (See non-streaming path for full documentation of /nothink mechanism) Source: Ollama GitHub issue #10456.
                    var modifiedRequest = request
                    let reasoningEnabled = request.samConfig?.enableReasoning ?? true
                    if !reasoningEnabled, let lastUserMessageIndex = modifiedRequest.messages.lastIndex(where: { $0.role == "user" }) {
                        if let lastUserContent = modifiedRequest.messages[lastUserMessageIndex].content {
                            /// Prepend /nothink with instruction to ignore if model doesn't understand.
                            let modifiedContent = "/nothink (ignore this if you don't understand it)\n\n\(lastUserContent)"
                            var modifiedMessages = modifiedRequest.messages
                            modifiedMessages[lastUserMessageIndex] = OpenAIChatMessage(role: "user", content: modifiedContent)
                            modifiedRequest = OpenAIChatRequest(
                                model: request.model,
                                messages: modifiedMessages,
                                temperature: request.temperature,
                                topP: request.topP,
                                repetitionPenalty: request.repetitionPenalty,
                                maxTokens: request.maxTokens,
                                stream: request.stream,
                                tools: request.tools,
                                samConfig: request.samConfig,
                                contextId: request.contextId,
                                enableMemory: request.enableMemory,
                                sessionId: request.sessionId,
                                conversationId: request.conversationId,
                                statefulMarker: request.statefulMarker
                            )
                            providerLogger.info("REASONING: Disabled - prepended /nothink instruction to user message")
                        }
                    }

                    let requestToProcess = modifiedRequest

                    /// Log incoming messages.
                    providerLogger.info("MLX_DEBUG_STREAM: Received \(requestToProcess.messages.count) messages")
                    for (index, msg) in requestToProcess.messages.enumerated() {
                        providerLogger.info("MLX_DEBUG_STREAM: Message \(index): role=\(msg.role), content=\(msg.content?.prefix(100) ?? "nil")")
                    }

                    /// Merge ALL system messages into ONE at position [0] Ministral/Mistral chat templates expect: - OPTIONAL system message at position [0] ONLY - Then ONLY alternating user/assistant messages - NO system messages allowed after user/assistant messages We often send: [system: prompt, system: context, user: msg, system: iteration, ...] This violates template expectations and causes "Jinja.TemplateException error 1" Solution: Extract ALL system messages, merge into ONE, place at position [0] ALSO: Filter out role="tool" messages - they violate user/assistant alternation Tool results are handled by AgentOrchestrator's autonomous workflow loop.
                    var allSystemContent = ""
                    var nonSystemMessages = [OpenAIChatMessage]()

                    for msg in requestToProcess.messages {
                        if msg.role == "system" {
                            /// Accumulate ALL system message content.
                            if let content = msg.content {
                                if !allSystemContent.isEmpty {
                                    allSystemContent += "\n\n"
                                }
                                allSystemContent += content
                            }
                        } else if msg.role == "tool" {
                            /// Convert tool results to user message format for MLX strict alternation MLX models require user/assistant/user/assistant pattern, cannot handle role=tool Solution: Inject tool result as a user message with clear labeling.
                            providerLogger.debug("MLX_TOOLS: Converting tool message to user message format for strict alternation")

                            /// Extract tool result content.
                            let toolContent = msg.content ?? "{}"

                            /// Format as user message with tool result label.
                            let toolResultMessage = """
                            Tool Result:
                            \(toolContent)
                            """

                            nonSystemMessages.append(OpenAIChatMessage(role: "user", content: toolResultMessage))
                        } else {
                            /// Preserve all non-system, non-tool messages in order.
                            nonSystemMessages.append(msg)
                        }
                    }

                    /// Build final message list: merged system message FIRST, then all others.
                    var processedMessages = [OpenAIChatMessage]()

                    /// Use SystemPromptManager to get real SAM prompt with all guard rails Pass toolsEnabled from samConfig to filter tool-specific guidance when tools are disabled.
                    let toolsEnabled = request.samConfig?.mcpToolsEnabled ?? true
                    var systemPrompt = SystemPromptManager.shared.generateSystemPrompt(toolsEnabled: toolsEnabled)

                    /// Add tool guidance dynamically if tools present - minimal format, let model use native format.
                    if let requestTools = request.tools, !requestTools.isEmpty {
                        var toolsList = "\n\n## Available Tools\n"
                        for tool in requestTools {
                            toolsList += "\(tool.function.name): \(tool.function.description)\n"

                            /// Parse parametersJson to get parameter names and types only.
                            if let paramsData = tool.function.parametersJson.data(using: .utf8),
                               let params = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any],
                               let props = params["properties"] as? [String: [String: Any]] {
                                let required = (params["required"] as? [String]) ?? []
                                var paramList: [String] = []

                                for (paramName, paramDetails) in props.sorted(by: { $0.key < $1.key }) {
                                    let isRequired = required.contains(paramName)
                                    let paramType = paramDetails["type"] as? String ?? "any"
                                    let reqMark = isRequired ? "*" : ""
                                    paramList.append("\(paramName)\(reqMark):\(paramType)")
                                }

                                if !paramList.isEmpty {
                                    toolsList += "  Args: " + paramList.joined(separator: ", ") + "\n"
                                }
                            }
                            toolsList += "\n"
                        }
                        systemPrompt += toolsList
                    }

                    providerLogger.info("MLX_STREAMING_PROMPT: Using SystemPromptManager, tools=\(request.tools?.count ?? 0), length=\(systemPrompt.count)")
                    processedMessages.append(OpenAIChatMessage(role: "system", content: systemPrompt))
                    processedMessages.append(contentsOf: nonSystemMessages)

                    /// Enforce strict user/assistant alternation Consecutive same-role messages (user→user or assistant→assistant) violate Ministral template This happens with: duplicate responses, multiple user messages, tool filtering gaps Solution: Merge consecutive same-role messages into one.
                    var alternatingMessages = [OpenAIChatMessage]()
                    var lastRole: String?
                    var accumulatedContent = ""
                    var accumulatedToolCalls: [OpenAIToolCall] = []

                    for msg in processedMessages {
                        if msg.role == lastRole {
                            /// Same role as previous - accumulate content.
                            if let content = msg.content, !content.isEmpty {
                                if !accumulatedContent.isEmpty {
                                    accumulatedContent += "\n\n"
                                }
                                accumulatedContent += content
                            }
                            /// Accumulate tool calls if present.
                            if let toolCalls = msg.toolCalls {
                                accumulatedToolCalls.append(contentsOf: toolCalls)
                            }
                        } else {
                            /// Different role - flush accumulated message if any.
                            if let role = lastRole {
                                let flushedMessage = OpenAIChatMessage(
                                    role: role,
                                    content: accumulatedContent.isEmpty ? "" : accumulatedContent,
                                    toolCalls: accumulatedToolCalls.isEmpty ? nil : accumulatedToolCalls
                                )
                                alternatingMessages.append(flushedMessage)
                            }
                            /// Start new accumulation.
                            lastRole = msg.role
                            accumulatedContent = msg.content ?? ""
                            accumulatedToolCalls = msg.toolCalls ?? []
                        }
                    }

                    /// Flush final accumulated message.
                    if let role = lastRole {
                        let flushedMessage = OpenAIChatMessage(
                            role: role,
                            content: accumulatedContent.isEmpty ? "" : accumulatedContent,
                            toolCalls: accumulatedToolCalls.isEmpty ? nil : accumulatedToolCalls
                        )
                        alternatingMessages.append(flushedMessage)
                    }

                    providerLogger.info("MLX_DEBUG: After system merge + alternation fix: \(alternatingMessages.count) messages (was \(request.messages.count))")
                    for (index, msg) in alternatingMessages.enumerated() {
                        providerLogger.info("MLX_DEBUG: Final message \(index): role=\(msg.role), content=\(msg.content?.prefix(100) ?? "nil")")
                    }

                    /// Convert OpenAI messages to Tokenizers.Message format CRITICAL: Must preserve tool_call_id for Mistral/Mistral models.
                    let messages: [Message] = alternatingMessages.map { msg in
                        var message: Message = [:]
                        message["role"] = msg.role
                        message["content"] = msg.content

                        /// Preserve tool_call_id for tool result messages.
                        if let toolCallId = msg.toolCallId {
                            message["tool_call_id"] = toolCallId
                        }

                        /// Preserve tool_calls for assistant messages with tool calls.
                        if let toolCalls = msg.toolCalls {
                            message["tool_calls"] = toolCalls.map { toolCall in
                                return [
                                    "id": toolCall.id,
                                    "type": toolCall.type,
                                    "function": [
                                        "name": toolCall.function.name,
                                        "arguments": toolCall.function.arguments
                                    ]
                                ] as [String: Any]
                            }
                        }

                        return message
                    }

                    /// Convert tools if present.
                    let tools: [ToolSpec]? = request.tools?.map { tool in
                        var toolSpec: ToolSpec = [:]
                        toolSpec["type"] = "function"

                        /// Parse parametersJson back to dictionary.
                        var parameters: [String: Any] = [:]
                        if let data = tool.function.parametersJson.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            parameters = parsed
                        }

                        toolSpec["function"] = [
                            "name": tool.function.name,
                            "description": tool.function.description,
                            "parameters": parameters
                        ]
                        return toolSpec
                    }

                    /// Load model if not cached.
                    let (model, tokenizer) = try await self.loadModelIfNeeded()

                    /// Get MLX configuration from provider config, or auto-detect optimal profile.
                    let mlxConfig: MLXConfiguration
                    if let configuredMLXConfig = self.config.mlxConfig {
                        mlxConfig = configuredMLXConfig
                        providerLogger.info("PERFORMANCE: Using configured MLX profile")
                    } else {
                        /// Check global preferences first (UI settings), then auto-detect as fallback.
                        let preset = UserDefaults.standard.string(forKey: "localModels.mlxPreset") ?? "auto"

                        if preset == "auto" || preset.isEmpty {
                            /// Auto-detect optimal profile based on system RAM.
                            let capabilities = SystemCapabilities()
                            mlxConfig = capabilities.ramProfile.mlxConfiguration
                            providerLogger.info("PERFORMANCE: Auto-detected \(capabilities.ramProfile.rawValue) for \(capabilities.physicalMemoryGB)GB RAM")
                        } else {
                            /// Use global preferences.
                            mlxConfig = getGlobalMLXConfiguration()
                            providerLogger.info("PERFORMANCE: Using user-configured MLX preset: \(preset)")
                        }
                    }

                    /// PER-CONVERSATION KV CACHE Strategy: Each conversation gets its own persistent cache - System prompt (6000+ tokens with tools) cached automatically on first turn - Conversation history accumulated incrementally - Isolated per conversation for privacy Performance: - Turn 1: Full computation (~20-30s for cold start) - Turn 2+: Only new tokens computed (~5-10s, system prompt cached!) - Benefit: 6000+ token system prompt processed once, reused forever in conversation.

                    let conversationId = request.conversationId ?? "default"
                    providerLogger.info("KV_CACHE_DEBUG: request.conversationId=\(request.conversationId ?? "nil"), using=\(conversationId)")
                    var cache: [KVCache]?

                    if conversationCaches[conversationId] == nil {
                        providerLogger.info("KV_CACHE: Creating new cache for conversation \(conversationId)")

                        /// Create new cache for this conversation.
                        let parameters = GenerateParameters(
                            maxKVSize: mlxConfig.maxKVSize,
                            kvBits: mlxConfig.kvBits,
                            kvGroupSize: mlxConfig.kvGroupSize
                        )
                        cache = model.newCache(parameters: parameters)
                        conversationCaches[conversationId] = cache

                        /// MEMORY LEAK FIX: Track access time and prune if needed.
                        conversationAccessTimes[conversationId] = Date()
                        pruneConversationCaches()
                    } else {
                        cache = conversationCaches[conversationId]
                        let cacheOffset = cache?.first?.offset ?? 0
                        providerLogger.info("KV_CACHE: Reusing cache for conversation \(conversationId) (\(cacheOffset) tokens cached)")

                        /// MEMORY LEAK FIX: Update access time for LRU.
                        conversationAccessTimes[conversationId] = Date()
                    }

                    /// Use request parameters if provided, otherwise fall back to config defaults.
                    let effectiveTopP = request.topP ?? mlxConfig.topP
                    let effectiveRepetitionPenalty = request.repetitionPenalty ?? mlxConfig.repetitionPenalty

                    providerLogger.info("MLX_PARAMS: topP=\(effectiveTopP), repetitionPenalty=\(effectiveRepetitionPenalty?.description ?? "nil"), temperature=\(request.temperature ?? 0.8)")

                    /// Generate streaming response with KV CACHE MLX automatically reuses cached KV for matching tokens.
                    /// REASONING CONTROL: ALWAYS show <think> tags if model produces them (hideThinking: false).
                    /// The /nothink instruction tells the model NOT to use thinking, but if it does anyway, show it.
                    let hideThinking = false

                    let stream = self.appleMLXAdapter.generateStream(
                        model: model,
                        tokenizer: tokenizer,
                        messages: messages,
                        tools: tools,
                        cache: cache,
                        maxTokens: requestToProcess.maxTokens ?? 2048,
                        temperature: Float(requestToProcess.temperature ?? 0.8),
                        topP: Float(effectiveTopP),
                        repetitionPenalty: effectiveRepetitionPenalty.map { Float($0) },
                        repetitionContextSize: mlxConfig.repetitionContextSize,
                        kvBits: mlxConfig.kvBits,
                        kvGroupSize: mlxConfig.kvGroupSize,
                        quantizedKVStart: mlxConfig.quantizedKVStart,
                        maxKVSize: mlxConfig.maxKVSize,
                        modelId: requestToProcess.model,
                        hideThinking: hideThinking
                    )

                    /// Accumulate full response for tool call detection at end.
                    var fullResponse = ""

                    /// Track if we're inside a tool call block (to filter from streaming).
                    var insideToolCall = false
                    var toolCallBuffer = ""

                    /// Universal think tag formatter for streaming content (backup layer).
                    /// AppleMLXAdapter handles think tags in the stream, this is a backup.
                    /// ALWAYS show reasoning (hideThinking: false).
                    var thinkFormatter = ThinkTagFormatter(hideThinking: false)

                    /// Forward chunks as SSE format - STREAM IMMEDIATELY (but filter tool calls).
                    for try await chunk in stream {
                        /// Check if task was cancelled (model switch or user stop).
                        if Task.isCancelled {
                            providerLogger.info("MLX generation cancelled")
                            continuation.finish()
                            return
                        }

                        if chunk.isComplete {
                            /// Detect tool calls in accumulated response MLX models output tools in various formats: 1.
                            let (toolCalls, _, detectedFormat) = toolCallExtractor.extract(from: fullResponse)
                            let finishReason = toolCalls.isEmpty ? "stop" : "tool_calls"

                            if !toolCalls.isEmpty {
                                providerLogger.info("MLX_TOOLS: Detected \(toolCalls.count) tool calls (format: \(detectedFormat)) in streaming response, setting finish_reason=tool_calls")

                                /// Chunks already sent during streaming Tool call detection happens at end, doesn't affect streaming If needed, could send cleaned content here, but for now we accept that tool call markers may appear in UI (user sees full model output).
                            }

                            /// Send final chunk with finish_reason and tool calls CRITICAL FIX: Include toolCalls in delta when finish_reason=tool_calls Without this, orchestrator receives finish_reason but no actual tool calls Convert ToolCallExtractor.ToolCall to OpenAIToolCall format.
                            let openAIToolCalls: [OpenAIToolCall]? = toolCalls.isEmpty ? nil : toolCalls.map { tc in
                                OpenAIToolCall(
                                    id: tc.id ?? "call_\(UUID().uuidString)",
                                    type: "function",
                                    function: OpenAIFunctionCall(name: tc.name, arguments: tc.arguments)
                                )
                            }

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
                                            toolCalls: openAIToolCalls
                                        ),
                                        finishReason: finishReason
                                    )
                                ]
                            )
                            continuation.yield(finalChunk)
                            continuation.finish()
                        } else {
                            /// Accumulate response text for tool call detection at end.
                            fullResponse += chunk.text

                            /// PROCESS CHUNK THROUGH THINK TAG FORMATTER Handles <think></think> tags with stateful buffering across chunks.
                            let (processedContent, _) = thinkFormatter.processChunk(chunk.text)

                            /// FILTER TOOL CALL MARKERS while streaming for clean UI Tool calls detected at end, but markers filtered during streaming Patterns: <function_call>, <tool_call>, [TOOL_CALLS], <function>.
                            var filteredText = processedContent
                            var skipChunk = false

                            /// Actually remove tool call markers from content before streaming Previous code just set skipChunk flag but didn't filter the text itself This caused tags to appear in UI even when skipping was intended.

                            /// Check for opening tags (tool calls).
                            if processedContent.contains("<function_call>") || processedContent.contains("<tool_call>") ||
                               processedContent.contains("[TOOL_CALLS]") || processedContent.contains("<function>") {
                                insideToolCall = true
                                toolCallBuffer += processedContent
                                skipChunk = true
                                /// Remove ALL tool call markers (both opening and closing).
                                filteredText = processedContent
                                    .replacingOccurrences(of: "<function_call>", with: "")
                                    .replacingOccurrences(of: "</function_call>", with: "")
                                    .replacingOccurrences(of: "<tool_call>", with: "")
                                    .replacingOccurrences(of: "</tool_call>", with: "")
                                    .replacingOccurrences(of: "[TOOL_CALLS]", with: "")
                                    .replacingOccurrences(of: "<function>", with: "")
                                    .replacingOccurrences(of: "</function>", with: "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)

                                /// Check if closing tag is also in this chunk.
                                if processedContent.contains("</function_call>") || processedContent.contains("</tool_call>") ||
                                   processedContent.contains("</function>") {
                                    insideToolCall = false
                                    toolCallBuffer = ""
                                }
                            } else if insideToolCall {
                                /// Inside tool call block - buffer it and remove from stream.
                                toolCallBuffer += processedContent
                                skipChunk = true

                                /// Remove any partial closing tags or content.
                                filteredText = ""

                                /// Check for closing tags.
                                if processedContent.contains("</function_call>") || processedContent.contains("</tool_call>") ||
                                   processedContent.contains("]") || processedContent.contains("</function>") {
                                    insideToolCall = false
                                    providerLogger.debug("MLX_STREAMING: Filtered tool block from UI: \(toolCallBuffer.prefix(50))...")
                                    toolCallBuffer = ""
                                }
                            }

                            /// Only stream if not inside tool call block AND filtered text has content CRITICAL: Also check that filteredText is not empty or just whitespace.
                            if !skipChunk && !filteredText.isEmpty {
                                /// STREAM IMMEDIATELY for responsive UI (18 TPS shown correctly).
                                let streamChunk = ServerOpenAIChatStreamChunk(
                                    id: "chatcmpl-\(UUID().uuidString)",
                                    object: "chat.completion.chunk",
                                    created: Int(Date().timeIntervalSince1970),
                                    model: request.model,
                                    choices: [
                                        OpenAIChatStreamChoice(
                                            index: 0,
                                            delta: OpenAIChatDelta(
                                                role: fullResponse == chunk.text ? "assistant" : nil,
                                                content: filteredText
                                            ),
                                            finishReason: nil
                                        )
                                    ]
                                )
                                continuation.yield(streamChunk)
                            }
                        }
                    }

                    /// Flush any buffered think content when stream ends.
                    let flushedContent = thinkFormatter.flushBuffer()
                    if !flushedContent.isEmpty {
                        let flushChunk = ServerOpenAIChatStreamChunk(
                            id: "chatcmpl-\(UUID().uuidString)",
                            object: "chat.completion.chunk",
                            created: Int(Date().timeIntervalSince1970),
                            model: request.model,
                            choices: [
                                OpenAIChatStreamChoice(
                                    index: 0,
                                    delta: OpenAIChatDelta(
                                        role: nil,
                                        content: flushedContent
                                    ),
                                    finishReason: nil
                                )
                            ]
                        )
                        continuation.yield(flushChunk)
                    }

                    providerLogger.info("Completed streaming response: \(fullResponse.count) chars")

                    /// Extract tool calls from full response after streaming completes This handles Qwen/Mistral/Hermes tool calling formats that use XML/JSON in response text.
                    let (toolCalls, cleanedContent, detectedFormat) = toolCallExtractor.extract(from: fullResponse)

                    if !toolCalls.isEmpty {
                        providerLogger.info("MLX_STREAMING: Extracted \(toolCalls.count) tool calls (format: \(detectedFormat))")

                        /// Send tool calls in final chunk.
                        let openAIToolCalls = toolCalls.map { tc in
                            OpenAIToolCall(
                                id: tc.id ?? "call_\(UUID().uuidString.prefix(24))",
                                type: "function",
                                function: OpenAIFunctionCall(
                                    name: tc.name,
                                    arguments: tc.arguments
                                )
                            )
                        }

                        let toolCallChunk = ServerOpenAIChatStreamChunk(
                            id: "chatcmpl-\(UUID().uuidString)",
                            object: "chat.completion.chunk",
                            created: Int(Date().timeIntervalSince1970),
                            model: request.model,
                            choices: [
                                OpenAIChatStreamChoice(
                                    index: 0,
                                    delta: OpenAIChatDelta(
                                        role: nil,
                                        content: nil,
                                        toolCalls: openAIToolCalls
                                    ),
                                    finishReason: "tool_calls"
                                )
                            ]
                        )
                        continuation.yield(toolCallChunk)
                    } else {
                        /// No tool calls - normal completion.
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
                                        content: nil
                                    ),
                                    finishReason: "stop"
                                )
                            ]
                        )
                        continuation.yield(finalChunk)
                    }

                } catch {
                    providerLogger.error("MLX streaming inference failed: \(error)")
                    continuation.finish(throwing: error)
                }
            }

            /// Store task reference for cancellation (must be after Task creation).
            self.activeGenerationTask = generationTask
        }
    }

    public func supportsModel(_ model: String) -> Bool {
        return config.models.contains(model)
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        let models = config.models.map { modelId in
            ServerOpenAIModel(
                id: modelId,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: "local-mlx"
            )
        }
        return ServerOpenAIModelsResponse(object: "list", data: models)
    }

    public func validateConfiguration() async throws -> Bool {
        /// Verify model path exists.
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw MLXError.modelNotFound(modelPath)
        }

        /// Verify model has required files.
        let configPath = URL(fileURLWithPath: modelPath).appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw MLXError.invalidModelStructure("Missing config.json")
        }

        providerLogger.info("MLX model configuration validated: \(modelPath)")
        return true
    }

    // MARK: - Lifecycle

    /// Cancel ongoing generation (stops GPU processing).
    public func cancelGeneration() async {
        providerLogger.info("CANCEL_GENERATION: Stopping MLX generation")
        if let task = activeGenerationTask {
            task.cancel()
            activeGenerationTask = nil
            providerLogger.info("CANCEL_GENERATION: MLX generation task cancelled")
        }
    }

    /// Unload the model to free memory CRITICAL FIX: Capture task/model locally to prevent race with new requests.
    public func unload() async {
        /// Capture task and model BEFORE any async operations.
        let taskToCancel = activeGenerationTask
        let modelToUnload = cachedModel
        _ = cachedModelPath

        /// Clear provider state immediately.
        activeGenerationTask = nil
        currentConversationId = nil
        cachedModel = nil
        cachedModelPath = nil

        /// Cancel old task if it exists (won't affect new requests).
        if let task = taskToCancel {
            providerLogger.info("UNLOAD_MODEL: Cancelling ongoing generation on old model")
            task.cancel()
        }

        if modelToUnload != nil {
            providerLogger.info("Unloading MLX model: \(identifier)")
        } else {
            providerLogger.debug("UNLOAD_MODEL: No model to unload")
        }

        /// Clear adapter cache.
        appleMLXAdapter.clearCache()

        /// MEMORY LEAK FIX: Clear conversation caches on model unload.
        clearAllConversationCaches()
    }

    /// Load the model into memory and return its capabilities.
    public func loadModel() async throws -> ModelCapabilities {
        providerLogger.info("LOAD_MODEL: Explicitly loading MLX model")

        /// Trigger model loading.
        let (model, _) = try await loadModelIfNeeded()

        /// Read config.json to get context size and other parameters.
        let configPath = URL(fileURLWithPath: modelPath).appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw MLXError.invalidModelStructure("Missing config.json")
        }

        let configData = try Data(contentsOf: configPath)
        guard let configJson = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw MLXError.invalidModelStructure("Invalid config.json format")
        }

        /// Extract model parameters.
        let contextSize = configJson["max_position_embeddings"] as? Int ?? 32768
        let maxTokens = contextSize / 2
        let modelName = URL(fileURLWithPath: modelPath).lastPathComponent

        providerLogger.debug("LOAD_MODEL: MLX model loaded - \(modelName), context: \(contextSize), max_tokens: \(maxTokens)")

        return ModelCapabilities(
            contextSize: contextSize,
            maxTokens: maxTokens,
            supportsStreaming: true,
            providerType: "MLX",
            modelName: modelName
        )
    }

    /// Check if the model is currently loaded in memory.
    public func getLoadedStatus() async -> Bool {
        return cachedModel != nil
    }

    /// Clear old conversation caches using LRU eviction Called automatically when cache size exceeds maxCachedConversations.
    private func pruneConversationCaches() {
        guard conversationCaches.count > maxCachedConversations else {
            return
        }

        let countToRemove = conversationCaches.count - maxCachedConversations
        providerLogger.info("KV_CACHE_PRUNE: Removing \(countToRemove) old caches (total: \(conversationCaches.count), limit: \(maxCachedConversations))")

        /// Sort by access time (oldest first).
        let sortedByAccess = conversationAccessTimes.sorted { $0.value < $1.value }

        /// Remove oldest caches.
        for (conversationId, accessTime) in sortedByAccess.prefix(countToRemove) {
            conversationCaches.removeValue(forKey: conversationId)
            conversationAccessTimes.removeValue(forKey: conversationId)

            let cacheOffset = conversationCaches[conversationId]?.first?.offset ?? 0
            providerLogger.debug("KV_CACHE_PRUNE: Removed cache for conversation \(conversationId) (last access: \(accessTime), size: \(cacheOffset) tokens)")
        }

        providerLogger.info("KV_CACHE_PRUNE: Pruning complete, retained \(conversationCaches.count) caches")
    }

    /// Clear all conversation caches (called on model unload).
    private func clearAllConversationCaches() {
        let count = conversationCaches.count
        if count > 0 {
            providerLogger.info("KV_CACHE_CLEAR: Clearing all \(count) conversation caches")
            conversationCaches.removeAll()
            conversationAccessTimes.removeAll()
        }
    }

    // MARK: - Helper Methods

    /// Builds principle-based tool usage guidance for MLX models Aligns with system prompt's "Direct Response Guidance" (order=2).
    private func buildMLXToolGuidance(_ tools: [OpenAITool]) -> String {
        var guidance = """
        # TOOL USAGE GUIDANCE

        You have access to tools. Use tools when they would improve your response or help accomplish the user's goal.

        **When to use tools:**
        - User requests information you don't have (use memory_operations, web_operations, etc.)
        - User asks you to perform an action (use appropriate tool)
        - Tools would provide more accurate/current information than your training

        **When NOT to use tools:**
        - Simple greetings or casual conversation
        - Questions you can answer directly from your knowledge (jokes, explanations, coding help)
        - Situations where tools don't add value

        **Tool Call Format:**
        When you decide to use a tool, output it in this format:

        <function_call>
        {"name": "tool_name", "arguments": {...}}
        </function_call>

        **CRITICAL RULES:**
        - When using tools, execute immediately (don't describe plans)
        - Output ONLY the <function_call> block (no preamble)
        - After receiving tool results, incorporate them into your response
        - Use judgment - tools extend capability, don't complicate simple interactions

        **Example (tool appropriate):**
        User: "What did we discuss about Python?"
        Assistant: <function_call>
        {"name": "memory_operations", "arguments": {"operation": "search", "query": "Python discussions", "similarity_threshold": 0.5}}
        </function_call>

        **Example (tool NOT appropriate):**
        User: "Tell me a joke"
        Assistant: Why did the programmer quit his job? Because he didn't get arrays! (No tool needed - this is general knowledge)

        AVAILABLE TOOLS:
        """

        /// Add brief tool list (names and descriptions only, not full schemas).
        for tool in tools {
            guidance += "\n- \(tool.function.name): \(tool.function.description)"
        }

        return guidance
    }

    private func loadModelIfNeeded() async throws -> (model: any LanguageModel, tokenizer: Tokenizer) {
        /// Return cached model if available.
        if let cached = cachedModel, cachedModelPath == modelPath {
            let modelTypeName = String(describing: type(of: cached.model))
            providerLogger.info("🔍 CACHE HIT: Using cached MLX model", metadata: [
                "modelType": "\(modelTypeName)",
                "hasLoRA": "\(loraAdapterId != nil)",
                "adapterId": "\(loraAdapterId ?? "none")"
            ])
            
            // DIAGNOSTIC: Check if model has LoRA layers
            if let loraModel = cached.model as? LoRAModel {
                let layerSample = loraModel.loraLayers.prefix(1)
                for layer in layerSample {
                    for (key, module) in layer.namedModules() {
                        let moduleType = String(describing: type(of: module))
                        providerLogger.debug("🔍 CACHE: Sample layer module", metadata: [
                            "key": "\(key)",
                            "type": "\(moduleType)"
                        ])
                    }
                }
            }
            
            return cached
        }
        
        providerLogger.info("🔍 CACHE MISS: Need to load model", metadata: [
            "cachedModelPath": "\(cachedModelPath ?? "none")",
            "requestedPath": "\(modelPath)",
            "pathsMatch": "\(cachedModelPath == modelPath)"
        ])

        /// Notify model loading started.
        let modelName = URL(fileURLWithPath: modelPath).lastPathComponent
        onModelLoadingStarted?(identifier, modelName)
        providerLogger.info("MODEL_LOADING: Starting to load \(modelName)")

        providerLogger.info("Loading MLX model from: \(modelPath)")
        let modelURL = URL(fileURLWithPath: modelPath)

        // INVESTIGATION: Read and log the actual model config
        let configPath = modelURL.appendingPathComponent("config.json")
        if let configData = try? Data(contentsOf: configPath),
           let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            providerLogger.debug("🔍 Model config at path \(modelPath)", metadata: [
                "hidden_size": "\(config["hidden_size"] as? Int ?? -1)",
                "num_attention_heads": "\(config["num_attention_heads"] as? Int ?? -1)",
                "num_key_value_heads": "\(config["num_key_value_heads"] as? Int ?? -1)",
                "intermediate_size": "\(config["intermediate_size"] as? Int ?? -1)",
                "model_type": "\(config["model_type"] as? String ?? "unknown")"
            ])
        } else {
            providerLogger.warning("⚠️ Could not read config.json at \(configPath.path)")
        }

        let (baseModel, tokenizer) = try await appleMLXAdapter.loadModel(from: modelURL)
        
        // INVESTIGATION: Log the loaded model type
        let modelTypeName = String(describing: type(of: baseModel))
        providerLogger.debug("🔍 Loaded base model type: \(modelTypeName)")
        
        /// Apply LoRA adapter if specified
        var finalModel: any LanguageModel = baseModel
        
        if let adapterId = loraAdapterId {
            // Load adapter if not already cached
            if cachedAdapter == nil {
                providerLogger.info("Loading LoRA adapter: \(adapterId)")
                cachedAdapter = try await AdapterManager.shared.loadAdapter(id: adapterId)
                providerLogger.info("LoRA adapter loaded successfully", metadata: [
                    "layers": "\(cachedAdapter?.layers.count ?? 0)",
                    "parameters": "\(cachedAdapter?.parameterCount() ?? 0)"
                ])
            }
            
            // CRITICAL: Always apply LoRA weights, even if adapter was cached
            // The base model is reloaded fresh each time, so LoRA must be reapplied
            do {
                finalModel = try applyLoRAWeights(to: baseModel)
            } catch {
                providerLogger.error("Failed to apply LoRA adapter: \(error)")
                throw error
            }
        }

        /// Cache final model (with LoRA applied if applicable) for next request.
        cachedModel = (finalModel, tokenizer)
        cachedModelPath = modelPath

        /// Notify model loading completed.
        onModelLoadingCompleted?(identifier)
        providerLogger.info("MODEL_LOADING: Completed loading \(modelName)")
        providerLogger.debug("MLX model loaded and cached successfully")
        return (finalModel, tokenizer)
    }

    private func estimateTokenCount(_ messages: [OpenAIChatMessage]) -> Int {
        return messages.reduce(0) { total, msg in
            let content = msg.content ?? ""
            return total + (content.count / 4)
        }
    }

    // MARK: - PRIORITY 3 OPTIMIZATION: Single-Pass Message Processing

    /// Process messages in a single pass instead of 4 separate iterations Merges: system extraction, tool conversion, role merging.
    private func processMessagesOptimized(_ messages: [OpenAIChatMessage]) -> [OpenAIChatMessage] {
        var systemContent = ""
        var processed: [OpenAIChatMessage] = []
        var lastRole: String?

        // SINGLE PASS: Extract system, convert tools, merge consecutive roles
        for msg in messages {
            if msg.role == "system" {
                // Accumulate system content
                if let content = msg.content {
                    if !systemContent.isEmpty {
                        systemContent += "\n\n"
                    }
                    systemContent += content
                }
            } else if msg.role == "tool" {
                // Convert tool results to user message format
                let toolContent = msg.content ?? "{}"
                let toolMessage = OpenAIChatMessage(
                    role: "user",
                    content: "Tool Result:\n\(toolContent)"
                )
                appendWithMerge(&processed, toolMessage, &lastRole)
            } else {
                // Regular user/assistant messages
                appendWithMerge(&processed, msg, &lastRole)
            }
        }

        // Prepend merged system message if any
        if !systemContent.isEmpty {
            processed.insert(OpenAIChatMessage(role: "system", content: systemContent), at: 0)
        }

        return processed
    }

    /// Append message with automatic merging of consecutive same-role messages.
    private func appendWithMerge(
        _ array: inout [OpenAIChatMessage],
        _ message: OpenAIChatMessage,
        _ lastRole: inout String?
    ) {
        if lastRole == message.role, let last = array.last {
            // Merge with previous message
            var mergedContent = last.content ?? ""
            if !mergedContent.isEmpty, let newContent = message.content, !newContent.isEmpty {
                mergedContent += "\n\n"
            }
            mergedContent += message.content ?? ""

            // Merge tool calls if present
            var mergedToolCalls = last.toolCalls ?? []
            if let newToolCalls = message.toolCalls {
                mergedToolCalls.append(contentsOf: newToolCalls)
            }

            array[array.count - 1] = OpenAIChatMessage(
                role: message.role,
                content: mergedContent,
                toolCalls: mergedToolCalls.isEmpty ? nil : mergedToolCalls
            )
        } else {
            // Append as new message
            array.append(message)
            lastRole = message.role
        }
    }
    
    // MARK: - LoRA Weight Application
    
    /// Apply LoRA adapter weights to the base model
    private func applyLoRAWeights(to model: any LanguageModel) throws -> any LanguageModel {
        guard let adapter = cachedAdapter else {
            return model
        }
        
        providerLogger.info("Applying LoRA weights using MLX LoRAContainer", metadata: [
            "adapterId": "\(adapter.id)",
            "layers": "\(adapter.layers.count)",
            "rank": "\(adapter.rank)"
        ])
        
        // Get adapter directory path
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let adapterDir = appSupport
            .appendingPathComponent("SAM")
            .appendingPathComponent("adapters")
            .appendingPathComponent(adapter.id)
        
        do {
            // Load LoRA container from adapter directory
            let container = try LoRAContainer.from(directory: adapterDir)
            
            providerLogger.debug("LoRA config loaded", metadata: [
                "numLayers": "\(container.configuration.numLayers)",
                "rank": "\(container.configuration.loraParameters.rank)",
                "scale": "\(container.configuration.loraParameters.scale)",
                "keys": "\(container.configuration.loraParameters.keys?.joined(separator: ", ") ?? "nil")"
            ])
            
            // INVESTIGATION: Log base model details before applying LoRA
            let baseModelType = String(describing: type(of: model))
            providerLogger.debug("🔍 About to apply LoRA to model type: \(baseModelType)")
            
            // DIAGNOSTIC: Check model layers BEFORE LoRA
            if let loraModel = model as? LoRAModel {
                let layerSample = loraModel.loraLayers.prefix(1)
                for layer in layerSample {
                    for (key, module) in layer.namedModules() {
                        let moduleType = String(describing: type(of: module))
                        providerLogger.debug("🔍 BEFORE LoRA: Layer module", metadata: [
                            "key": "\(key)",
                            "type": "\(moduleType)"
                        ])
                    }
                }
            }
            
            // Apply adapter to model
            // This modifies the model in-place by replacing Linear layers with LoRALinear layers
            try container.load(into: model)
            
            // INVESTIGATION: Log model details after applying LoRA
            providerLogger.debug("🔍 LoRA applied, model type after: \(String(describing: type(of: model)))")
            
            // DIAGNOSTIC: Check model layers AFTER LoRA - should see LoRALinear now
            if let loraModel = model as? LoRAModel {
                let layerSample = loraModel.loraLayers.prefix(1)
                var loraLayerCount = 0
                var linearLayerCount = 0
                
                for layer in layerSample {
                    for (key, module) in layer.namedModules() {
                        let moduleType = String(describing: type(of: module))
                        providerLogger.debug("🔍 AFTER LoRA: Layer module", metadata: [
                            "key": "\(key)",
                            "type": "\(moduleType)"
                        ])
                        
                        if moduleType.contains("LoRA") {
                            loraLayerCount += 1
                        } else if moduleType.contains("Linear") {
                            linearLayerCount += 1
                        }
                    }
                }
                
                providerLogger.info("🔍 Layer inspection complete", metadata: [
                    "loraLayers": "\(loraLayerCount)",
                    "linearLayers": "\(linearLayerCount)",
                    "expected": "LoRALinear if working correctly"
                ])
            }
            
            providerLogger.info("LoRA weights applied successfully", metadata: [
                "adapterId": "\(adapter.id)"
            ])
            
            return model
        } catch {
            providerLogger.error("Failed to apply LoRA weights", metadata: [
                "adapterId": "\(adapter.id)",
                "error": "\(error.localizedDescription)"
            ])
            throw error
        }
    }
}

// MARK: - Errors

enum MLXError: Error, LocalizedError {
    case notImplemented
    case modelNotLoaded
    case modelNotFound(String)
    case invalidModelStructure(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "MLX provider not fully implemented - work in progress"

        case .modelNotLoaded:
            return "MLX model not loaded"

        case .modelNotFound(let path):
            return "MLX model not found at path: \(path)"

        case .invalidModelStructure(let reason):
            return "Invalid MLX model structure: \(reason)"

        case .generationFailed(let message):
            return "MLX generation failed: \(message)"
        }
    }
}
