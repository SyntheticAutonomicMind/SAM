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

    private let llamaEngine: LlamaEngine
    private let modelPath: String

    /// Track conversation ID to detect conversation switches When conversation changes, KV cache must be cleared to prevent context leak.
    private var currentConversationId: String?

    /// OPTIMIZATION: Per-conversation KV cache storage (PRIORITY 1) Similar to MLX's implementation, cache KV state for up to 5 conversations This prevents expensive KV cache rebuild when switching between conversations Performance: 5 seconds -> 500ms conversation switch time (10x improvement).
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
        self.llamaEngine = LlamaEngine(modelPath: modelPath)
        providerLogger.info("LlamaProvider initialized for model: \(modelPath)")
    }

    // MARK: - Protocol Conformance

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        providerLogger.debug("Processing chat completion request")

        let context = try await ensureContext()
        let requestConversationId = request.conversationId ?? request.sessionId ?? request.contextId
        try await configureContextForRequest(context, conversationId: requestConversationId)

        let modifiedRequest = LocalProviderCore.injectNothinkIfNeeded(request)
        let processedMessages = LocalProviderCore.processMessages(modifiedRequest.messages)

        let prompt = try await llamaEngine.buildPrompt(
            messages: processedMessages,
            tools: modifiedRequest.tools,
            reasoningEnabled: modifiedRequest.samConfig?.enableReasoning ?? true
        )

        let samplerConfig = buildSamplerConfig(from: request)
        let maxTokensLimit = request.maxTokens ?? 4096
        let stopSequences = ["<|im_end|>", "<|endoftext|>", "</s>"]

        let events = llamaEngine.generateStream(
            prompt: prompt,
            maxTokens: maxTokensLimit,
            samplerConfig: samplerConfig,
            stopSequences: stopSequences
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

        var formatter = ThinkTagFormatter(hideThinking: false)
        let (formatted, _) = formatter.processChunk(cleanedContent)
        let finalContent = formatted + formatter.flushBuffer()

        await context.clear()

        return LocalProviderCore.buildChatResponse(
            model: request.model,
            content: finalContent,
            toolCalls: toolCalls,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            finishReason: finishReason
        )
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
                    let context = try await self.ensureContext()
                    let requestConversationId = request.conversationId ?? request.sessionId ?? request.contextId
                    try await self.configureContextForRequest(context, conversationId: requestConversationId)

                    let modifiedRequest = LocalProviderCore.injectNothinkIfNeeded(request)
                    let processedMessages = LocalProviderCore.processMessages(modifiedRequest.messages)

                    let prompt = try await self.llamaEngine.buildPrompt(
                        messages: processedMessages,
                        tools: modifiedRequest.tools,
                        reasoningEnabled: modifiedRequest.samConfig?.enableReasoning ?? true
                    )

                    let samplerConfig = self.buildSamplerConfig(from: request)
                    let maxTokensLimit = request.maxTokens ?? 4096
                    let stopSequences = ["<|im_end|>", "<|endoftext|>", "</s>"]

                    let events = self.llamaEngine.generateStream(
                        prompt: prompt,
                        maxTokens: maxTokensLimit,
                        samplerConfig: samplerConfig,
                        stopSequences: stopSequences
                    )

                    var accumulated = ""
                    var toolCalls: [OpenAIToolCall]?
                    var finishReason: LocalProviderEvent.FinishReason = .stop

                    for try await event in events {
                        if Task.isCancelled {
                            await context.cancel()
                            break
                        }
                        switch event {
                        case .textDelta(let text):
                            accumulated += text
                        case .usage:
                            break  // Suppress per-token usage in streaming mode.
                        case .finished(let reason):
                            finishReason = reason
                        }
                    }

                    let (cleanedContent, extractedToolCalls) = LocalProviderCore.parseToolCalls(from: accumulated)
                    toolCalls = extractedToolCalls

                    var formatter = ThinkTagFormatter(hideThinking: false)
                    let (formatted, _) = formatter.processChunk(cleanedContent)
                    let finalContent = formatted + formatter.flushBuffer()

                    if !finalContent.isEmpty {
                        let contentChunk = LocalProviderCore.buildStreamChunk(
                            model: request.model,
                            content: finalContent,
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

                    if await !context.hasRecurrentState {
                        await context.resetGeneration()
                    } else {
                        await context.clear()
                    }

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
        await llamaEngine.cancel()
    }

    /// Unload model from memory (frees GPU/RAM resources) CRITICAL: Call this when switching models or ending conversation CRITICAL FIX: Capture context locally to prevent race with new requests.
    public func unload() async {
        providerLogger.info("UNLOAD_MODEL: Freeing llama.cpp context and model resources")
        await llamaEngine.unload()
        currentConversationId = nil
        clearAllConversationCaches()
    }

    /// Load the model into memory and return its capabilities.
    public func loadModel() async throws -> ModelCapabilities {
        providerLogger.info("LOAD_MODEL: Explicitly loading GGUF model")

        let context = try await ensureContext()

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
        return await llamaEngine.isLoaded()
    }

    /// Get performance metrics from current generation.
    public func getPerformanceMetrics() async -> (tokensPerSecond: Double, totalTime: Double, tokensGenerated: Int) {
        guard let context = await llamaEngine.currentContext() else { return (0.0, 0.0, 0) }
        return await context.getPerformanceMetrics()
    }

    // MARK: - Context Management

    /// Initialize the underlying context if not already loaded. Notifies the
    /// EndpointManager of model loading start/complete when used for the first load.
    private func ensureContext() async throws -> LlamaContext {
        if let existing = await llamaEngine.currentContext() {
            return existing
        }

        let modelName = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        onModelLoadingStarted?(identifier, modelName)
        providerLogger.info("MODEL_LOADING: Starting to load \(modelName)")

        let context = try await llamaEngine.loadContext()

        onModelLoadingCompleted?(identifier)
        providerLogger.info("MODEL_LOADING: Completed loading \(modelName)")
        return context
    }

    /// Apply per-conversation KV cache state for the request.
    /// Falls back to a clear() when no conversation ID is provided so a
    /// crashed previous request doesn't leave stale state.
    private func configureContextForRequest(_ context: LlamaContext, conversationId: String?) async throws {
        if let convId = conversationId {
            if currentConversationId != convId {
                providerLogger.info("CONVERSATION_SWITCH: Switching from \(currentConversationId ?? "none") to \(convId)")

                if let currentId = currentConversationId {
                    await saveCurrentKVCacheState(for: currentId)
                }

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
        } else {
            await context.clear()
            providerLogger.debug("No conversation ID provided - cleared KV cache as safety measure")
        }
    }

    /// Build a sampler config from a request, falling back to defaults.
    private func buildSamplerConfig(from request: OpenAIChatRequest) -> LlamaContext.SamplerConfig {
        var config = LlamaContext.SamplerConfig()
        if let temperature = request.temperature {
            config.temperature = Float(temperature)
        }
        if let topP = request.topP {
            config.topP = Float(topP)
        }
        if let repetitionPenalty = request.repetitionPenalty {
            config.repetitionPenalty = Float(repetitionPenalty)
        }
        return config
    }

    // MARK: - Per-Conversation KV Cache Management (OPTIMIZATION PRIORITY 1)

    /// Save current KV cache state for the active conversation.
    private func saveCurrentKVCacheState(for conversationId: String) async -> Bool {
        guard let context = await llamaEngine.currentContext() else {
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
        guard let context = await llamaEngine.currentContext(), let cacheState = conversationCaches[conversationId] else {
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

    private func pruneConversationCaches() {
        if conversationCaches.count > maxCachedConversations {
            let sorted = conversationCaches.sorted { $0.value.timestamp < $1.value.timestamp }
            let toRemove = sorted.prefix(conversationCaches.count - maxCachedConversations)
            for (key, _) in toRemove {
                conversationCaches.removeValue(forKey: key)
                providerLogger.info("KV_CACHE_PRUNE: Removed cache for \(key)")
            }
        }
    }

    private func clearAllConversationCaches() {
        let count = conversationCaches.count
        conversationCaches.removeAll()
        providerLogger.info("KV_CACHE_CLEAR: Cleared \(count) cached conversation states")
    }
}

/// Adapter that conforms a `LlamaContext` to the engine protocol.
///
/// The engine owns the model lifecycle (load, unload, cancel) and translates
/// between the llama.cpp token-by-token model and the event-based protocol
/// the providers consume. Per-conversation KV cache management stays in the
/// provider; the engine is conversation-agnostic.
actor LlamaEngine {
    private let modelPath: String
    private var context: LlamaContext?

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    func currentContext() -> LlamaContext? {
        return context
    }

    func isLoaded() -> Bool {
        return context != nil
    }

    func loadContext() throws -> LlamaContext {
        if let context = context {
            return context
        }
        let new = try LlamaContext.create_context(path: modelPath)
        context = new
        return new
    }

    func cancel() {
        guard let context = context else { return }
        Task {
            await context.cancel()
        }
    }

    func unload() {
        let old = context
        context = nil
        Task {
            await old?.destroy()
        }
    }

    /// Build a prompt string from messages, applying the chat template and
    /// appending tool instructions when tools are provided.
    func buildPrompt(
        messages: [OpenAIChatMessage],
        tools: [OpenAITool]?,
        reasoningEnabled: Bool
    ) async throws -> String {
        guard let context = context else {
            throw LlamaError.couldNotInitializeContext
        }

        var chatMessages: [(role: String, content: String)] = []

        if let tools = tools, !tools.isEmpty {
            let toolInstructions = LocalProviderCore.buildToolInstructions(tools)
            providerLogger.info("LLAMA_TOOLS: Adding tool instructions for \(tools.count) tools (\(toolInstructions.count) chars)")

            if let systemIndex = messages.firstIndex(where: { $0.role == "system" }) {
                let merged = (messages[systemIndex].content ?? "") + "\n\n" + toolInstructions
                chatMessages.append((role: "system", content: merged))
                for (idx, message) in messages.enumerated() where idx != systemIndex {
                    appendMessage(message, to: &chatMessages)
                }
            } else {
                chatMessages.append((role: "system", content: toolInstructions))
                for message in messages {
                    appendMessage(message, to: &chatMessages)
                }
            }
        } else {
            for message in messages {
                appendMessage(message, to: &chatMessages)
            }
        }

        let prompt = await context.format_chat(messages: chatMessages)

        /// Ensure the prompt ends with the assistant marker so the model knows to start.
        if !prompt.hasSuffix("<|im_start|>assistant\n") &&
           !prompt.hasSuffix("<|im_start|>assistant") {
            providerLogger.info("LLAMA_FIX: Appending assistant marker to prompt")
            return prompt + "<|im_start|>assistant\n"
        }
        return prompt
    }

    /// Convert a single message into a chat-template tuple, with the same
    /// special-case handling the original LlamaProvider applied (tool->user,
    /// empty assistant content preserved, no nil content).
    private func appendMessage(_ message: OpenAIChatMessage, to chatMessages: inout [(role: String, content: String)]) {
        if message.role == "tool" {
            let toolContent = message.content ?? "{}"
            chatMessages.append((role: "user", content: "Tool Result:\n\(toolContent)"))
        } else if message.role == "assistant" && (message.content == nil || message.content!.isEmpty) {
            chatMessages.append((role: "assistant", content: ""))
        } else if let content = message.content {
            chatMessages.append((role: message.role, content: content))
        }
    }

    /// Stream a completion, yielding engine-agnostic events.
    ///
    /// Wraps the llama.cpp token-by-token generation loop. Honors temperature,
    /// top-p, and repetition penalty from `samplerConfig`, and the user-supplied
    /// stop sequences. Always streams the full response - the provider decides
    /// whether to emit incremental chunks or buffer the full output.
    ///
    /// Nonisolated because the returned stream does the actor hop internally -
    /// this lets callers `for try await` the result from any isolation domain
    /// without an extra `await` on the call site.
    nonisolated func generateStream(
        prompt: String,
        maxTokens: Int,
        samplerConfig: LlamaContext.SamplerConfig,
        stopSequences: [String]?
    ) -> AsyncThrowingStream<LocalProviderEvent, Error> {
        let engine = self
        return AsyncThrowingStream { continuation in
            Task {
                guard let context = await engine.currentContext() else {
                    continuation.finish(throwing: LlamaError.couldNotInitializeContext)
                    return
                }

                do {
                    await context.setSampling(samplerConfig)
                    await context.setStopSequences(stopSequences)
                    await context.setMaxTokensLimit(maxTokens)
                    await context.completion_init(text: prompt)

                    var completionChars = 0
                    var generatedTokens = 0

                    while await !context.is_done {
                        if Task.isCancelled {
                            await context.cancel()
                            continuation.yield(.finished(reason: .cancelled))
                            break
                        }

                        let token = await context.completion_loop()
                        if !token.isEmpty {
                            completionChars += token.count
                            generatedTokens += 1
                            continuation.yield(.textDelta(token))
                        }
                    }

                    let promptTokensEstimate = prompt.count / 4
                    let completionTokensEstimate = completionChars / 4
                    continuation.yield(.usage(
                        promptTokens: promptTokensEstimate,
                        completionTokens: completionTokensEstimate
                    ))

                    let reason: LocalProviderEvent.FinishReason
                    if generatedTokens >= maxTokens {
                        reason = .length
                    } else {
                        reason = .stop
                    }

                    continuation.yield(.finished(reason: reason))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
