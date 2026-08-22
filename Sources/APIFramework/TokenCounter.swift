// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import llama
import ConfigurationSystem

/// OpenAIChatMessage is defined in OpenAIModels.swift (same module).

/// Token counting utilities for context management Provides accurate token counting for local models (using llama.cpp tokenizer) and estimation for remote models.
public actor TokenCounter {
    private let logger = Logging.Logger(label: "com.sam.tokencounter")

    /// Cache for API-provided context sizes.
    private var apiContextSizes: [String: Int] = [:]

    /// Update context size from API (e.g., GitHub Copilot /models endpoint).
    public func setContextSize(modelId: String, contextSize: Int) {
        apiContextSizes[modelId] = contextSize
        logger.debug("CONTEXT_SIZE: Set '\(modelId)' to \(contextSize) tokens (from API)")
    }

    /// Update multiple context sizes from API.
    public func setContextSizes(_ sizes: [String: Int]) {
        for (modelId, size) in sizes {
            apiContextSizes[modelId] = size
        }
        logger.debug("CONTEXT_SIZE: Updated \(sizes.count) models from API")
    }

    // MARK: - Token Counting

    /// Count tokens in text using llama.cpp tokenizer (for local models) This provides exact token counts for GGUF models.
    public func countTokensLocal(text: String, model: OpaquePointer, addBos: Bool = false) -> Int {
        let vocab = llama_model_get_vocab(model)
        let utf8Count = text.utf8.count
        let n_tokens = utf8Count + (addBos ? 1 : 0) + 1
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: n_tokens)
        defer { tokens.deallocate() }

        let tokenCount = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(n_tokens), addBos, false)
        return Int(tokenCount)
    }

    /// Estimate tokens for remote models (1 token ≈ 4 characters) This is a rough approximation but works well for most models.
    public func estimateTokensRemote(text: String) -> Int {
        return text.count / 4
    }

    /// Count tokens in an OpenAIChatMessage.
    public func countTokens(message: OpenAIChatMessage, model: OpaquePointer?, isLocal: Bool) -> Int {
        var total = 0

        /// Role overhead (typically 1-2 tokens per message).
        total += 3

        /// Content tokens.
        if let content = message.content {
            if isLocal, let model = model {
                total += countTokensLocal(text: content, model: model)
            } else {
                total += estimateTokensRemote(text: content)
            }
        }

        /// Tool call tokens (if present).
        if let toolCalls = message.toolCalls {
            for toolCall in toolCalls {
                /// Tool call structure overhead + function name + arguments.
                let toolText = toolCall.function.name + toolCall.function.arguments
                if isLocal, let model = model {
                    total += countTokensLocal(text: toolText, model: model)
                } else {
                    total += estimateTokensRemote(text: toolText)
                }
                total += 10
            }
        }

        return total
    }

    /// Count total tokens in message array.
    public func countTokens(messages: [OpenAIChatMessage], model: OpaquePointer?, isLocal: Bool) -> Int {
        var total = 0
        for message in messages {
            total += countTokens(message: message, model: model, isLocal: isLocal)
        }
        return total
    }

    // MARK: - Context Management

    /// Calculate current context usage and determine if pruning is needed Returns (current tokens, should prune, context size).
    public func shouldPruneContext(
        systemPrompt: String,
        conversationMessages: [OpenAIChatMessage],
        currentInput: String,
        contextSize: Int,
        model: OpaquePointer?,
        isLocal: Bool
    ) -> (currentTokens: Int, shouldPrune: Bool, contextSize: Int) {
        /// Calculate token counts.
        var totalTokens = 0

        /// System prompt tokens.
        if isLocal, let model = model {
            totalTokens += countTokensLocal(text: systemPrompt, model: model)
        } else {
            totalTokens += estimateTokensRemote(text: systemPrompt)
        }

        /// Conversation history tokens.
        totalTokens += countTokens(messages: conversationMessages, model: model, isLocal: isLocal)

        /// Current input tokens.
        if isLocal, let model = model {
            totalTokens += countTokensLocal(text: currentInput, model: model)
        } else {
            totalTokens += estimateTokensRemote(text: currentInput)
        }

        /// Check if we should prune (70% threshold).
        let pruningThreshold = Int(Float(contextSize) * 0.7)
        let shouldPrune = totalTokens >= pruningThreshold

        if shouldPrune {
            logger.warning("CONTEXT_PRUNING: Token count \(totalTokens) exceeds 70% threshold (\(pruningThreshold)/\(contextSize))")
        } else {
            logger.debug("CONTEXT_STATUS: Token count \(totalTokens)/\(contextSize) (\(Int(Float(totalTokens)/Float(contextSize)*100))%)")
        }

        return (totalTokens, shouldPrune, contextSize)
    }

    /// Get context size for a model First checks API-provided sizes, then model config, then falls back to hardcoded defaults.
    public func getContextSize(modelName: String) -> Int {
        /// PRIORITY 1: Check API-provided context size (most accurate).
        /// Try full model name first (e.g., "github_copilot/gpt-5-mini").
        if let apiSize = apiContextSizes[modelName] {
            logger.debug("CONTEXT_SIZE: Using API-provided size for '\(modelName)': \(apiSize) tokens")
            return apiSize
        }
        
        /// Try without provider prefix (e.g., "gpt-5-mini" when cache has "gpt-5-mini").
        /// GitHub Copilot API returns model names without prefix, but we query with prefix.
        let modelWithoutProvider = modelName.components(separatedBy: "/").last ?? modelName
        if modelWithoutProvider != modelName, let apiSize = apiContextSizes[modelWithoutProvider] {
            logger.debug("CONTEXT_SIZE: Using API-provided size for '\(modelName)' (found as '\(modelWithoutProvider)'): \(apiSize) tokens")
            return apiSize
        }

        /// PRIORITY 2: Check ModelConfigurationManager (config-driven approach).
        if let contextWindow = ModelConfigurationManager.shared.getContextWindow(for: modelName) {
            logger.debug("CONTEXT_SIZE: Using model config for '\(modelName)': \(contextWindow) tokens")
            return contextWindow
        }

        /// PRIORITY 3: Fall back to hardcoded defaults (legacy pattern matching).
        let modelLower = modelName.lowercased()

        /// Local llama.cpp models: 32k standard.
        if modelLower.contains("local-llama") || modelLower.contains("gguf") {
            return 32768
        }

        /// GPT-4 Turbo: 128k context CRITICAL: Check for gpt-4.1 before general gpt-4 check.
        if modelLower.contains("gpt-4-turbo") || modelLower.contains("gpt-4-1106") || modelLower.contains("gpt-4.1") {
            return 128000
        }

        /// GPT-4: 8k context.
        if modelLower.contains("gpt-4") {
            return 8192
        }

        /// GPT-3.5 Turbo: 16k context.
        if modelLower.contains("gpt-3.5-turbo-16k") {
            return 16385
        }

        /// GPT-3.5 Turbo: 4k context.
        if modelLower.contains("gpt-3.5-turbo") {
            return 4096
        }

        /// Claude models - ACCURATE context sizes (not inflated fallbacks!) Based on published specifications.

        /// Claude 3.5 Sonnet: 90k context (NOT 200k - that causes 400 errors!).
        if modelLower.contains("claude-3.5-sonnet") || modelLower.contains("claude-3-5-sonnet") {
            logger.info("CONTEXT_SIZE: claude-3.5-sonnet = 90k tokens (hardcoded fallback)")
            return 90000
        }

        /// Claude 4 Sonnet: 216k context (per GitHub API).
        if modelLower.contains("claude-sonnet-4") && !modelLower.contains("4.5") && !modelLower.contains("4-5") {
            logger.info("CONTEXT_SIZE: claude-sonnet-4 = 216k tokens (conservative hardcoded fallback, prefer API)")
            return 216000
        }

        /// Claude 4.5 models: 144k context (GitHub API reports 144k for claude-sonnet-4.5) Conservative fallback - actual limit confirmed via API.
        if modelLower.contains("claude-4.5") || modelLower.contains("claude-4-5") || modelLower.contains("claude-sonnet-4.5") || modelLower.contains("sonnet-4.5") || modelLower.contains("haiku-4.5") {
            logger.info("CONTEXT_SIZE: claude-4.5/sonnet-4.5/haiku-4.5 = 144k tokens (hardcoded fallback, prefer API value)")
            return 144000
        }

        /// Claude Opus 4.1: 80k context (per GitHub API).
        if modelLower.contains("claude-opus-41") || modelLower.contains("opus-4.1") {
            logger.info("CONTEXT_SIZE: claude-opus-41 = 80k tokens (hardcoded fallback)")
            return 80000
        }

        /// Other Claude 3 variants: 100k fallback.
        if modelLower.contains("claude-3") {
            logger.warning("CONTEXT_SIZE: Unknown claude-3 variant '\(modelName)', using 100k fallback")
            return 100000
        }

        /// Claude 2: 100k context.
        if modelLower.contains("claude-2") {
            return 100000
        }

        /// Google Gemini models Reference: Gemini API documentation and model metadata.

        /// Gemini 2.0 Flash: 1M context.
        if modelLower.contains("gemini-2.0-flash") {
            logger.info("CONTEXT_SIZE: gemini-2.0-flash = 1M tokens")
            return 1000000
        }

        /// Gemini 1.5 Pro: 2M context (long-context variant).
        if modelLower.contains("gemini-1.5-pro") {
            logger.info("CONTEXT_SIZE: gemini-1.5-pro = 2M tokens")
            return 2000000
        }

        /// Gemini 1.5 Flash: 1M context.
        if modelLower.contains("gemini-1.5-flash") {
            logger.info("CONTEXT_SIZE: gemini-1.5-flash = 1M tokens")
            return 1000000
        }

        /// Gemini 1.0 Pro: 32k context.
        if modelLower.contains("gemini-1.0-pro") || modelLower.contains("gemini-pro") {
            logger.info("CONTEXT_SIZE: gemini-1.0-pro = 32k tokens")
            return 32768
        }

        /// Generic Gemini fallback: 32k (conservative).
        if modelLower.contains("gemini") {
            logger.warning("CONTEXT_SIZE: Unknown gemini variant '\(modelName)', using 32k fallback")
            return 32768
        }

        /// xAI Grok models (OpenAI-compatible API) Reference: xAI API documentation Note: Grok uses OpenAIProvider with baseURL set to xAI endpoint.

        /// Grok 2: 128k context.
        if modelLower.contains("grok-2") || modelLower.contains("grok2") {
            logger.info("CONTEXT_SIZE: grok-2 = 128k tokens")
            return 128000
        }

        /// Grok Beta/Vision: 128k context.
        if modelLower.contains("grok-vision") || modelLower.contains("grok-beta") {
            logger.info("CONTEXT_SIZE: grok-vision/beta = 128k tokens")
            return 128000
        }

        /// Generic Grok fallback: 128k.
        if modelLower.contains("grok") {
            logger.info("CONTEXT_SIZE: grok (generic) = 128k tokens")
            return 128000
        }

        /// Default: Conservative 8k.
        logger.warning("CONTEXT_SIZE: Unknown model '\(modelName)', using default 8192 tokens - consider fetching from API")
        return 8192
    }

    // MARK: - Token Budget Calculation

    /// Constants for token budget calculation.
    private static let BASE_TOKENS_PER_COMPLETION = 50
    private static let TOOL_OVERHEAD_PER_TOOL = 15

    /// Calculate available token budget for conversation history and user messages Accounts for model context size, system prompt, and tool definitions to determine how many tokens remain for the conversation.
    public func calculateTokenBudget(
        modelName: String,
        systemPrompt: String,
        tools: [OpenAITool]?,
        model: OpaquePointer?,
        isLocal: Bool,
        apiMaxInputTokens: Int? = nil
    ) -> Int {
        /// Get model's max prompt tokens (context window size) Prefer API-provided value, fall back to hardcoded detection.
        let modelMaxPromptTokens: Int
        if let apiMax = apiMaxInputTokens {
            modelMaxPromptTokens = apiMax
            logger.debug("Using API-provided context size: \(apiMax) tokens for model=\(modelName)")
        } else {
            modelMaxPromptTokens = getContextSize(modelName: modelName)
            logger.debug("Using hardcoded context size: \(modelMaxPromptTokens) tokens for model=\(modelName) (API value not available)")
        }

        /// Calculate base count (system prompt tokens).
        let baseCount: Int
        if isLocal, let model = model {
            baseCount = countTokensLocal(text: systemPrompt, model: model)
        } else {
            baseCount = estimateTokensRemote(text: systemPrompt)
        }

        /// Calculate tool token count.
        let toolTokenCount = calculateToolTokens(tools: tools, model: model, isLocal: isLocal)

        /// Apply formula: tokenLimit = modelMaxPromptTokens - baseCount - BaseTokensPerCompletion - toolTokenCount.
        let tokenLimit = modelMaxPromptTokens - baseCount - Self.BASE_TOKENS_PER_COMPLETION - toolTokenCount

        logger.debug("""
        TOKEN_BUDGET: model=\(modelName)
          max=\(modelMaxPromptTokens)\(apiMaxInputTokens != nil ? " (from API)" : " (hardcoded)")
          base=\(baseCount) (system prompt)
          tools=\(toolTokenCount) (from \(tools?.count ?? 0) tools)
          buffer=\(Self.BASE_TOKENS_PER_COMPLETION)
          budget=\(tokenLimit) tokens available
        """)

        return max(tokenLimit, 0)
    }

    /// Calculate tokens used by tool definitions Counts schema tokens with structural overhead per tool - Parameters: - tools: Array of OpenAI tool definitions - model: Optional llama.cpp model pointer for local models - isLocal: Whether this is a local model - Returns: Total tokens consumed by tool schemas.
    public func calculateToolTokens(
        tools: [OpenAITool]?,
        model: OpaquePointer?,
        isLocal: Bool
    ) -> Int {
        guard let tools = tools, !tools.isEmpty else { return 0 }

        var totalTokens = 0

        for tool in tools {
            /// Tool structure overhead.
            totalTokens += Self.TOOL_OVERHEAD_PER_TOOL

            /// Function name.
            if isLocal, let model = model {
                totalTokens += countTokensLocal(text: tool.function.name, model: model)
            } else {
                totalTokens += estimateTokensRemote(text: tool.function.name)
            }

            /// Function description.
            if isLocal, let model = model {
                totalTokens += countTokensLocal(text: tool.function.description, model: model)
            } else {
                totalTokens += estimateTokensRemote(text: tool.function.description)
            }

            /// Function parameters (JSON schema).
            if isLocal, let model = model {
                totalTokens += countTokensLocal(text: tool.function.parametersJson, model: model)
            } else {
                totalTokens += estimateTokensRemote(text: tool.function.parametersJson)
            }
        }

        logger.debug("TOOL_TOKENS: \(totalTokens) tokens for \(tools.count) tool definitions")
        return totalTokens
    }

    /// Calculate safety margin percentage remaining after accounting for tools and base prompt Returns percentage (0-100) of context window still available - Parameters: - modelName: Model identifier - systemPrompt: Base system prompt - tools: Tool definitions - currentTokens: Current conversation token count - model: Optional llama.cpp model pointer - isLocal: Whether local model - Returns: Percentage of budget remaining (0-100).
    public func calculateBudgetUtilization(
        modelName: String,
        systemPrompt: String,
        tools: [OpenAITool]?,
        currentTokens: Int,
        model: OpaquePointer?,
        isLocal: Bool
    ) -> Int {
        let budget = calculateTokenBudget(
            modelName: modelName,
            systemPrompt: systemPrompt,
            tools: tools,
            model: model,
            isLocal: isLocal
        )

        guard budget > 0 else { return 100 }

        let utilizationPercent = Int((Double(currentTokens) / Double(budget)) * 100)
        return min(utilizationPercent, 100)
    }

    // MARK: - Model Capabilities Resolution (ported from CLIO TokenEstimator)

    /// Get max output tokens for a model by family.
    /// Ported from SAMAPIServer.getMaxOutputTokens + CLIO Defaults.pm.
    /// Marked nonisolated: pure function, no actor-isolated state accessed.
    nonisolated public func getMaxOutputTokens(_ model: String) -> Int {
        let modelLower = model.lowercased()

        // Claude 4.5 / Opus 4.1
        if modelLower.contains("claude-4.5") || modelLower.contains("claude-4-5") ||
           modelLower.contains("claude-sonnet-4.5") || modelLower.contains("sonnet-4.5") ||
           modelLower.contains("claude-opus-41") || modelLower.contains("opus-4.1") {
            return 8192
        }
        // Claude 3.5 / Claude 4
        if modelLower.contains("claude-3.5") || modelLower.contains("claude-3-5") ||
           modelLower.contains("claude-sonnet-4") || modelLower.contains("claude-4") {
            return 8192
        }
        // Other Claude
        if modelLower.contains("claude") { return 4096 }
        // GPT-4 Turbo / GPT-4.1
        if modelLower.contains("gpt-4-turbo") || modelLower.contains("gpt-4.1") { return 4096 }
        // GPT-4o
        if modelLower.contains("gpt-4o") { return 16384 }
        // GPT-4
        if modelLower.contains("gpt-4") { return 8192 }
        // GPT-3.5
        if modelLower.contains("gpt-3.5") { return 4096 }
        // MiniMax
        if modelLower.contains("minimax-m3") { return 131072 }
        if modelLower.contains("minimax-m2") || modelLower.contains("minimax-m2.1") ||
           modelLower.contains("minimax-m2.5") || modelLower.contains("minimax-m2.7") {
            return 8192
        }
        // Gemini
        if modelLower.contains("gemini-2.5-pro") { return 8192 }
        if modelLower.contains("gemini-2.5-flash") { return 16384 }
        if modelLower.contains("gemini-1.5-pro") { return 8192 }
        if modelLower.contains("gemini") { return 8192 }
        // DeepSeek
        if modelLower.contains("deepseek") { return 32768 }
        // Grok
        if modelLower.contains("grok") { return 131072 }
        // Local llama.cpp
        if modelLower.contains("local-llama") || modelLower.contains("gguf") { return 4096 }
        // Default
        return ContextBudget.defaultMaxOutputTokens
    }

    /// Resolve model capabilities from config + API responses + defaults.
    /// Ported from CLIO's TokenEstimator.resolve_and_return_model_info.
    ///
    /// Resolution order:
    /// 1. API-provided context size (cached via setContextSize)
    /// 2. ModelConfigurationManager config-driven context window
    /// 3. TokenCounter.getContextSize hardcoded fallback
    public func resolveCapabilities(
        model: String,
        apiMaxInputTokens: Int? = nil
    ) async -> ContextCapabilities {
        let contextWindow: Int

        if let apiMax = apiMaxInputTokens {
            contextWindow = apiMax
            logger.debug("Using API-provided context size for resolveCapabilities: \(apiMax) tokens for model=\(model)")
        } else if let apiSize = apiContextSizes[model] {
            contextWindow = apiSize
        } else if let configWindow = ModelConfigurationManager.shared.getContextWindow(for: model) {
            contextWindow = configWindow
        } else {
            contextWindow = getContextSize(modelName: model)
        }

        let maxOutputTokens = getMaxOutputTokens(model)

        return ContextCapabilities(
            contextWindow: contextWindow,
            maxOutputTokens: maxOutputTokens,
            supportsTools: true
        )
    }

    /// Get the learned char/token ratio from DriftTracker.
    /// Used by call sites to pass the correct ratio to MessageValidator.
    /// Marked nonisolated because DriftTracker is thread-safe (DispatchQueue).
    nonisolated public var learnedRatio: Double {
        DriftTracker.shared.learnedRatio
    }

    /// Learn the char/token ratio from a real API response with `usage.prompt_tokens`.
    /// Weighted 80% old / 20% new, clamped to [1.5, 4.0].
    /// Also computes and stores the drift ratio.
    /// Marked nonisolated: accesses only the thread-safe DriftTracker singleton.
    nonisolated public func learnFromAPIResponse(
        totalChars: Int,
        actualPromptTokens: Int,
        estimatedPromptTokens: Int
    ) {
        DriftTracker.shared.learnFromAPIResponse(
            totalChars: totalChars,
            actualPromptTokens: actualPromptTokens,
            estimatedPromptTokens: estimatedPromptTokens
        )
        logger.debug("LEARNED_RATIO: Updated char/token ratio from API response: \(DriftTracker.shared.learnedRatio) (actual: \(actualPromptTokens), estimated: \(estimatedPromptTokens))")
    }

    /// Get the drift-aware trim threshold for this model, or nil if no usable drift data.
    /// When non-nil, the caller should pass this as `trimThreshold` in TrimConfig.
    public func getDriftAwareThreshold(model: String) async -> Int? {
        let contextWindow = apiContextSizes[model] ??
            (ModelConfigurationManager.shared.getContextWindow(for: model) ??
             getContextSize(modelName: model))
        return DriftTracker.shared.computeDriftAwareThreshold(contextWindow: contextWindow)
    }

    /// Record drift from a 400 token_limit_exceeded response.
    /// Marked nonisolated: accesses only the thread-safe DriftTracker singleton.
    nonisolated public func recordDrift(serverActualTokens: Int, estimatedTokens: Int) {
        DriftTracker.shared.recordDrift(serverActualTokens: serverActualTokens, estimatedTokens: estimatedTokens)
    }

    /// Parse a 400 token limit error message and extract server-reported token count.
    /// Marked nonisolated: pure function, no actor-isolated state accessed.
    nonisolated public func parseTokenLimitError(errorMessage: String) -> (serverActual: Int, estimated: Int)? {
        let lowerError = errorMessage.lowercased()

        let patterns = [
            "token_limit_exceeded",
            "context_length_exceeded",
            "max_tokens_exceeded",
            "prompt is too long",
            "exceeds the model's maximum",
            "maximum context length",
            "context length is"
        ]

        let isTokenLimit = patterns.contains { lowerError.contains($0) }
        guard isTokenLimit else { return nil }

        // Try to extract server-reported token count from error message.
        // Format: "prompt contains X tokens, max Y" or similar.
        let numberPattern = #"(\d+)[\s,]*tokens?"#
        if let regex = try? NSRegularExpression(pattern: numberPattern, options: .caseInsensitive) {
            let nsError = errorMessage as NSString
            let matches = regex.matches(in: errorMessage, range: NSRange(location: 0, length: nsError.length))
            for match in matches.reversed() where match.numberOfRanges >= 2 {
                let tokenStr = nsError.substring(with: match.range(at: 1))
                if let tokenCount = Int(tokenStr) {
                    // Use the last number found (usually the actual token count, not max)
                    return (serverActual: tokenCount, estimated: 0)
                }
            }
        }
        // Pattern matched but no token count found in the error message.
        // Still return non-nil so the caller knows it's a token limit error.
        return (serverActual: 0, estimated: 0)
    }
}
