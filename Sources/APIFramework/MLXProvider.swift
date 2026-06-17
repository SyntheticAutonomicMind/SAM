// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// MLXProvider.swift SAM Created by AI Assistant on 2025.

import Foundation
import SwiftUI
import ConfigurationSystem
import Logging
import MLX
import Tokenizers
import MLXLLM
import MLXLMCommon
import MLXIntegration

private let providerLogger = Logging.Logger(label: "com.sam.mlx.MLXProvider")

/// Errors specific to the MLX provider.
public enum MLXError: LocalizedError {
    case invalidModelStructure(String)
    case modelNotLoaded
    case chatTemplateFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidModelStructure(let msg): return "Invalid MLX model structure: \(msg)"
        case .modelNotLoaded: return "MLX model is not loaded"
        case .chatTemplateFailed(let msg): return "MLX chat template failed: \(msg)"
        }
    }
}

/// Local AI provider using Apple's MLX framework for on-device inference with Apple Silicon optimization.
@MainActor
public class MLXProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration

    private let mlxEngine: MLXEngine
    private let modelPath: String

    /// Track conversation ID to detect conversation switches.
    private var currentConversationId: String?

    /// KV CACHE: Per-conversation prompt caching Each conversation maintains its own KV cache that: 1.
    private var conversationCaches: [String: [KVCache]] = [:]
    private var conversationAccessTimes: [String: Date] = [:]
    private let maxCachedConversations = 10

    /// Track ongoing generation task for cancellation.
    private var activeGenerationTask: Task<Void, Never>?

    /// Model loading notifications (optional callback to EndpointManager).
    private var onModelLoadingStarted: ((String, String) -> Void)?
    private var onModelLoadingCompleted: ((String) -> Void)?

    public init(config: ProviderConfiguration, modelPath: String, onModelLoadingStarted: ((String, String) -> Void)? = nil, onModelLoadingCompleted: ((String) -> Void)? = nil) {
        self.identifier = config.providerId
        self.config = config
        self.modelPath = modelPath
        self.onModelLoadingStarted = onModelLoadingStarted
        self.onModelLoadingCompleted = onModelLoadingCompleted
        self.mlxEngine = MLXEngine(modelPath: modelPath)
        providerLogger.info("MLXProvider initialized for model: \(modelPath)")
    }

    // MARK: - Protocol Conformance

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        providerLogger.info("Processing MLX chat completion with model: \(request.model)")

        let requestConversationId = request.conversationId ?? request.sessionId ?? request.contextId
        let (model, tokenizer) = try await mlxEngine.loadModelIfNeeded(
            identifier: identifier,
            onModelLoadingStarted: onModelLoadingStarted,
            onModelLoadingCompleted: onModelLoadingCompleted
        )

        let modifiedRequest = LocalProviderCore.injectNothinkIfNeeded(request)
        let processedMessages = LocalProviderCore.processMessages(modifiedRequest.messages)

        let (systemPrompt, nonSystemMessages) = LocalProviderCore.extractSystemPrompt(from: processedMessages)
        let tools = LocalProviderCore.convertToolsToMLXSpec(modifiedRequest.tools)

        let prompt = try await mlxEngine.buildPrompt(
            model: model,
            tokenizer: tokenizer,
            messages: nonSystemMessages,
            systemPrompt: systemPrompt,
            tools: modifiedRequest.tools,
            toolsEnabled: request.samConfig?.mcpToolsEnabled ?? true
        )

        let temperature = Float(request.temperature ?? 0.8)
        let topP = Float(request.topP ?? 0.95)
        let maxTokens = request.maxTokens ?? 2048

        let events = mlxEngine.generateStream(
            model: model,
            tokenizer: tokenizer,
            messages: prompt.messages,
            tools: tools,
            cache: conversationCaches[requestConversationId ?? ""],
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP
        )

        var accumulated = ""
        var toolCalls: [OpenAIToolCall]?
        var promptTokens = 0
        var completionTokens = 0
        var finishReason: LocalProviderEvent.FinishReason = .stop

        for try await event in events {
            switch event {
            case .textDelta(let text):
                accumulated += text
            case .usage(let p, let c):
                promptTokens = p
                completionTokens = c
            case .finished(let reason):
                finishReason = reason
            }
        }

        let (cleanedContent, extractedToolCalls) = LocalProviderCore.parseToolCalls(from: accumulated)
        toolCalls = extractedToolCalls

        return LocalProviderCore.buildChatResponse(
            model: request.model,
            content: cleanedContent,
            toolCalls: toolCalls,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            finishReason: finishReason
        )
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        providerLogger.debug("Processing streaming MLX chat completion")

        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

                let streamTask = Task { [weak self] in
                    guard let self = self else { return }

                    do {
                        let requestConversationId = request.conversationId ?? request.sessionId ?? request.contextId
                        let (model, tokenizer) = try await self.mlxEngine.loadModelIfNeeded(
                            identifier: self.identifier,
                            onModelLoadingStarted: self.onModelLoadingStarted,
                            onModelLoadingCompleted: self.onModelLoadingCompleted
                        )

                        let modifiedRequest = LocalProviderCore.injectNothinkIfNeeded(request)
                        let processedMessages = LocalProviderCore.processMessages(modifiedRequest.messages)

                        let (systemPrompt, nonSystemMessages) = LocalProviderCore.extractSystemPrompt(from: processedMessages)
                        let tools = LocalProviderCore.convertToolsToMLXSpec(modifiedRequest.tools)

                        let prompt = try await self.mlxEngine.buildPrompt(
                            model: model,
                            tokenizer: tokenizer,
                            messages: nonSystemMessages,
                            systemPrompt: systemPrompt,
                            tools: modifiedRequest.tools,
                            toolsEnabled: request.samConfig?.mcpToolsEnabled ?? true
                        )

                        let temperature = Float(request.temperature ?? 0.8)
                        let topP = Float(request.topP ?? 0.95)
                        let maxTokens = request.maxTokens ?? 2048

                        let events = self.mlxEngine.generateStream(
                            model: model,
                            tokenizer: tokenizer,
                            messages: prompt.messages,
                            tools: tools,
                            cache: self.conversationCaches[requestConversationId ?? ""],
                            maxTokens: maxTokens,
                            temperature: temperature,
                            topP: topP
                        )

                        var accumulated = ""
                        var toolCalls: [OpenAIToolCall]?
                        var finishReason: LocalProviderEvent.FinishReason = .stop

                        for try await event in events {
                            if Task.isCancelled {
                                break
                            }
                            switch event {
                            case .textDelta(let text):
                                accumulated += text
                            case .usage:
                                break
                            case .finished(let reason):
                                finishReason = reason
                            }
                        }

                        let (cleanedContent, extractedToolCalls) = LocalProviderCore.parseToolCalls(from: accumulated)
                        toolCalls = extractedToolCalls

                        if !cleanedContent.isEmpty {
                            let contentChunk = LocalProviderCore.buildStreamChunk(
                                model: request.model,
                                content: cleanedContent,
                                toolCalls: nil,
                                finishReason: nil
                            )
                            continuation.yield(contentChunk)
                        }

                        let finalChunk = LocalProviderCore.buildStreamChunk(
                            model: request.model,
                            content: nil,
                            toolCalls: toolCalls,
                            finishReason: toolCalls != nil ? .toolCalls : finishReason
                        )
                        continuation.yield(finalChunk)

                        continuation.finish()
                    } catch {
                        providerLogger.error("MLX streaming error: \(error.localizedDescription)")
                        continuation.finish(throwing: error)
                    }
                }

                self.activeGenerationTask = streamTask
            }
        }
    }

    public func supportsModel(_ model: String) -> Bool {
        let modelName = (modelPath as NSString).lastPathComponent
        let registeredModelId = config.models.first ?? ""
        return model == modelName || model.contains(modelName) || model == registeredModelId || model.contains(registeredModelId)
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
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

    public func validateConfiguration() async throws -> Bool {
        let configPath = URL(fileURLWithPath: modelPath).appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw MLXError.invalidModelStructure("Missing config.json at \(configPath.path)")
        }
        return true
    }

    // MARK: - Lifecycle

    public func cancelGeneration() async {
        providerLogger.info("CANCEL_GENERATION: Stopping MLX generation")
        if let task = activeGenerationTask {
            task.cancel()
            activeGenerationTask = nil
        }
    }

    public func unload() async {
        let taskToCancel = activeGenerationTask
        activeGenerationTask = nil
        currentConversationId = nil
        clearAllConversationCaches()
        if let task = taskToCancel {
            task.cancel()
        }
        await mlxEngine.unload()
        MLX.Memory.clearCache()
        let remaining = MLX.Memory.activeMemory
        providerLogger.info("MLX_MEMORY: After unload - active memory: \(remaining / 1024 / 1024)MB")
    }

    public func loadModel() async throws -> ModelCapabilities {
        providerLogger.info("LOAD_MODEL: Explicitly loading MLX model")
        let (model, _) = try await mlxEngine.loadModelIfNeeded(
            identifier: identifier,
            onModelLoadingStarted: onModelLoadingStarted,
            onModelLoadingCompleted: onModelLoadingCompleted
        )

        let configPath = URL(fileURLWithPath: modelPath).appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw MLXError.invalidModelStructure("Missing config.json")
        }
        let configData = try Data(contentsOf: configPath)
        guard let configJson = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw MLXError.invalidModelStructure("Invalid config.json format")
        }
        let contextSize = configJson["max_position_embeddings"] as? Int ?? 32768
        let maxTokens = contextSize / 2
        let modelName = URL(fileURLWithPath: modelPath).lastPathComponent
        return ModelCapabilities(
            contextSize: contextSize,
            maxTokens: maxTokens,
            supportsStreaming: true,
            providerType: "MLX",
            modelName: modelName
        )
    }

    public func getLoadedStatus() async -> Bool {
        return await mlxEngine.isLoaded()
    }

    // MARK: - Cache management

    private func clearAllConversationCaches() {
        let count = conversationCaches.count
        conversationCaches.removeAll()
        conversationAccessTimes.removeAll()
        providerLogger.info("KV_CACHE_CLEAR: Cleared \(count) cached conversation states")
    }
}

/// Adapter that conforms an MLX model + tokenizer to the engine protocol.
///
/// The engine owns model loading/unloading and the prompt building for Apple's
/// chat-template pipeline. Per-conversation KV cache management stays in the
/// provider; the engine is conversation-agnostic. Marked @MainActor because
/// MLX's ModelContext/Tokenizer types are MainActor-isolated.
@MainActor
public final class MLXEngine {
    private let modelPath: String
    private nonisolated(unsafe) var cachedModel: (model: any LanguageModel, tokenizer: Tokenizer)?
    private nonisolated(unsafe) var cachedModelPath: String?

    public init(modelPath: String) {
        self.modelPath = modelPath
    }

    public func isLoaded() -> Bool {
        return cachedModel != nil
    }

    /// Load the model+tokenizer, using the cache when path matches.
    /// The callbacks fire only on the first load (cache miss).
    public func loadModelIfNeeded(
        identifier: String,
        onModelLoadingStarted: ((String, String) -> Void)?,
        onModelLoadingCompleted: ((String) -> Void)?
    ) async throws -> (model: any LanguageModel, tokenizer: Tokenizer) {
        if let cached = cachedModel, cachedModelPath == modelPath {
            return cached
        }

        let modelName = URL(fileURLWithPath: modelPath).lastPathComponent
        onModelLoadingStarted?(identifier, modelName)
        providerLogger.info("MODEL_LOADING: Starting to load \(modelName)")

        let modelURL = URL(fileURLWithPath: modelPath)
        let (baseModel, tokenizer) = try await AppleMLXAdapter().loadModel(from: modelURL)

        cachedModel = (baseModel, tokenizer)
        cachedModelPath = modelPath

        onModelLoadingCompleted?(identifier)
        providerLogger.info("MODEL_LOADING: Completed loading \(modelName)")
        return (baseModel, tokenizer)
    }

    /// Release the cached model and clear adapter caches.
    public func unload() {
        cachedModel = nil
        cachedModelPath = nil
    }

    /// Build the chat-template messages list and the rendered prompt.
    ///
    /// Returns the full messages list (including system prompt and tool
    /// guidance) and a short summary of the rendered prompt. The provider
    /// passes the messages list to MLXLMCommon.generate; the summary is for
    /// logging only.
    public func buildPrompt(
        model: any LanguageModel,
        tokenizer: Tokenizer,
        messages: [OpenAIChatMessage],
        systemPrompt: String,
        tools: [OpenAITool]?,
        toolsEnabled: Bool
    ) async throws -> (messages: [Message], prompt: String) {
        var chatMessages: [Message] = []

        let effectiveSystemPrompt: String
        if !systemPrompt.isEmpty {
            effectiveSystemPrompt = systemPrompt
        } else if let tools = tools, !tools.isEmpty, toolsEnabled {
            effectiveSystemPrompt = SystemPromptManager.shared.generateSystemPrompt(toolsEnabled: true)
        } else {
            effectiveSystemPrompt = SystemPromptManager.shared.generateSystemPrompt(toolsEnabled: false)
        }

        if !effectiveSystemPrompt.isEmpty {
            var systemMessage: Message = [:]
            systemMessage["role"] = "system"
            systemMessage["content"] = effectiveSystemPrompt
            chatMessages.append(systemMessage)
        }

        if let tools = tools, !tools.isEmpty {
            let toolGuidance = LocalProviderCore.buildToolInstructions(tools)
            if !toolGuidance.isEmpty {
                let existing = chatMessages.firstIndex(where: { ($0["role"] as? String) == "system" })
                if let idx = existing {
                    let prev = (chatMessages[idx]["content"] as? String) ?? ""
                    chatMessages[idx]["content"] = prev + "\n\n" + toolGuidance
                } else {
                    var sysMsg: Message = [:]
                    sysMsg["role"] = "system"
                    sysMsg["content"] = toolGuidance
                    chatMessages.insert(sysMsg, at: 0)
                }
            }
        }

        for msg in messages {
            var mlxMessage: Message = [:]
            mlxMessage["role"] = msg.role
            mlxMessage["content"] = msg.content
            if let toolCallId = msg.toolCallId {
                mlxMessage["tool_call_id"] = toolCallId
            }
            if let toolCalls = msg.toolCalls {
                mlxMessage["tool_calls"] = toolCalls.map { toolCall in
                    return [
                        "id": toolCall.id,
                        "type": toolCall.type,
                        "function": [
                            "name": toolCall.function.name,
                            "arguments": toolCall.function.arguments
                        ]
                    ] as [String: any Sendable]
                }
            }
            chatMessages.append(mlxMessage)
        }

        let prompt = try tokenizer.applyChatTemplate(
            messages: chatMessages,
            chatTemplate: nil,
            addGenerationPrompt: true,
            truncation: false,
            maxLength: nil,
            tools: nil,
            additionalContext: ["add_generation_prompt": true]
        )

        return (chatMessages, "\(prompt.count) tokens")
    }

    /// Stream a completion, yielding engine-agnostic events.
    ///
    /// Bridges Apple's MLXLMCommon.generate AsyncSequence to the
    /// `LocalProviderEvent` protocol. The AppleMLXAdapter already handles
    /// the thinking-tag state machine; this method's only job is to convert
    /// the per-token chunks into events.
    public func generateStream(
        model: any LanguageModel,
        tokenizer: Tokenizer,
        messages: [Message],
        tools: [ToolSpec]?,
        cache: [KVCache]?,
        maxTokens: Int,
        temperature: Float,
        topP: Float
    ) -> AsyncThrowingStream<LocalProviderEvent, Error> {
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let inputTokens = try tokenizer.applyChatTemplate(
                        messages: messages,
                        chatTemplate: nil,
                        addGenerationPrompt: true,
                        truncation: false,
                        maxLength: nil,
                        tools: nil,
                        additionalContext: ["add_generation_prompt": true]
                    )

                    let input = LMInput(tokens: MLXArray(inputTokens))
                    let modelConfig = ModelConfiguration(id: "mlx-local")
                    let context = ModelContext(
                        configuration: modelConfig,
                        model: model,
                        processor: StandInUserInputProcessor(),
                        tokenizer: tokenizer
                    )

                    let parameters = GenerateParameters(
                        maxTokens: maxTokens,
                        temperature: temperature,
                        topP: topP
                    )

                    var completionChars = 0
                    for await item in try MLXLMCommon.generate(
                        input: input,
                        cache: cache,
                        parameters: parameters,
                        context: context
                    ) {
                        if Task.isCancelled {
                            continuation.yield(.finished(reason: .cancelled))
                            break
                        }
                        if let chunk = item.chunk {
                            completionChars += chunk.count
                            continuation.yield(.textDelta(String(chunk)))
                        }
                    }

                    let promptTokensEstimate = messages.reduce(0) { $0 + ((($1["content"] as? String) ?? "").count / 4) }
                    let completionTokensEstimate = completionChars / 4
                    continuation.yield(.usage(
                        promptTokens: promptTokensEstimate,
                        completionTokens: completionTokensEstimate
                    ))
                    continuation.yield(.finished(reason: .stop))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
