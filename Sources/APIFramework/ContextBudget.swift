// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

// MARK: - ContextCapabilities

/// Model capabilities resolved from model config + API responses.
/// Used by `TokenCounter.resolveCapabilities` and `MessageValidator`.
///
/// Ported from CLIO's Defaults.pm / TokenEstimator.pm capability model.
public struct ContextCapabilities: Sendable {
    /// The model's true context window (tokens).
    public let contextWindow: Int

    /// The model's actual max output tokens. Falls back to
    /// `ContextBudget.defaultMaxOutputTokens` when the model reports
    /// no output cap (e.g. local llama.cpp).
    public let maxOutputTokens: Int

    /// Whether the model supports function/tool calling.
    public let supportsTools: Bool

    public init(contextWindow: Int, maxOutputTokens: Int? = nil, supportsTools: Bool = true) {
        self.contextWindow = max(contextWindow, 1000)
        self.maxOutputTokens = max(maxOutputTokens ?? ContextBudget.defaultMaxOutputTokens, 512)
        self.supportsTools = supportsTools
    }

    /// Compute the prompt budget: the maximum tokens the conversation
    /// (messages + tool definitions) may consume before trimming.
    ///
    /// ```
    /// budget = context_window - output_reserve - estimation_buffer
    /// ```
    ///
    /// When `hasTools` is true AND the model supports tools, the output
    /// reserve is capped at `ContextBudget.defaultToolOutputReserve` (8192)
    /// -- an agentic tool-calling turn produces a short response (tool_call
    /// JSON + brief text, well under 8K tokens). Reserving the model's full
    /// `maxOutputTokens` (often 32K+) wastes prompt budget on every tool call.
    ///
    /// The estimation buffer covers token-estimation error (char/token
    /// heuristic), per-message overhead (role framing, separators), and
    /// provider-specific formatting tokens (JSON structure of tool_calls,
    /// response priming).
    public func computePromptBudget(hasTools: Bool = false) -> Int {
        let outputReserve: Int
        if hasTools && supportsTools {
            outputReserve = min(maxOutputTokens, ContextBudget.defaultToolOutputReserve)
        } else {
            outputReserve = maxOutputTokens
        }

        let estBuffer = ContextBudget.outputEstimationBuffer(contextWindow: contextWindow)
        var budget = contextWindow - outputReserve - estBuffer
        if budget < 1000 { budget = 1000 }
        return budget
    }
}

// MARK: - TrimConfig

/// Configuration for `MessageValidator.validateAndTruncate`.
///
/// Ported from CLIO's `validate_and_truncate` %args hash. Carries the
/// resolved model capabilities, tool definitions, learned char/token ratio,
/// and optional drift-aware trim threshold from the caller so MessageValidator
/// can compute the correct budget walk ceiling.
public struct TrimConfig: Sendable {
    /// Resolved model capabilities (context window, max output tokens, tools support).
    public let caps: ContextCapabilities

    /// Tools array (for the tool-calling output-reserve optimization).
    public let tools: [OpenAITool]?

    /// Pre-computed token count for tool definitions sent in this request.
    public let toolTokens: Int

    /// Learned characters-per-token ratio (from API feedback).
    /// Clamped to [1.5, 4.0] by MessageValidator.
    public let tokenRatio: Double

    /// Optional caller override for the trim threshold in tokens.
    /// When non-nil, replaces `computePromptBudget()` as the walk ceiling
    /// (e.g. drift-aware threshold from the last API response).
    /// When nil, MessageValidator computes the budget from `caps`.
    public let trimThreshold: Int?

    /// Whether the request includes tool definitions (for budget computation).
    public var hasTools: Bool { (tools?.isEmpty == false) }

    public init(
        caps: ContextCapabilities,
        tools: [OpenAITool]? = nil,
        toolTokens: Int = 0,
        tokenRatio: Double = ContextBudget.defaultCharsPerToken,
        trimThreshold: Int? = nil
    ) {
        self.caps = caps
        self.tools = tools
        self.toolTokens = toolTokens
        self.tokenRatio = max(ContextBudget.minLearnedRatio,
                              min(tokenRatio, ContextBudget.maxLearnedRatio))
        self.trimThreshold = trimThreshold
    }

    /// The effective budget that MessageValidator uses as the walk ceiling.
    /// If `trimThreshold` is provided, use it (drift-aware); otherwise compute.
    public var effectiveBudget: Int {
        if let t = trimThreshold, t > 0 {
            return max(t, 1000)
        }
        var budget = caps.computePromptBudget(hasTools: hasTools) - toolTokens
        if budget < 1000 { budget = 1000 }
        return budget
    }

    /// Compute the prompt budget from model capabilities (mirrors CLIO's
    /// compute_prompt_budget). Used by callers that want the budget without
    /// creating a full TrimConfig.
    public static func computePromptBudget(caps: ContextCapabilities, hasTools: Bool) -> Int {
        caps.computePromptBudget(hasTools: hasTools)
    }
}

// MARK: - DriftTracker

/// Thread-safe storage for learned token ratio and drift ratio.
/// Ported from CLIO's TokenEstimator.pm package state + Session::State drift save.
///
/// The learned ratio smooths char/token estimation (80% old / 20% new,
/// clamped [1.5, 4.0]) from API `usage.prompt_tokens` feedback.
/// The drift ratio = actual_tokens / estimated_tokens, updated from
/// server-reported token counts on 400 errors and on successful responses.
/// The drift-aware threshold tightens the proactive trim so it lands at
/// 90% *actual* tokens instead of 90% *estimated*.
public final class DriftTracker: @unchecked Sendable {
    public static let shared = DriftTracker()
    private let queue = DispatchQueue(label: "com.sam.DriftTracker")
    private var _learnedRatio: Double = ContextBudget.defaultCharsPerToken
    private var _driftRatio: Double?
    private var _driftLastUpdated: Date?
    private var _driftActualTokens: Int?
    private var _driftEstimatedTokens: Int?

    public var learnedRatio: Double {
        get { queue.sync { _learnedRatio } }
    }

    public var driftRatio: Double? {
        get { queue.sync { _driftRatio } }
    }

    public var driftLastUpdated: Date? {
        get { queue.sync { _driftLastUpdated } }
    }

    /// Learn the char/token ratio from a real API response.
    /// Called by the workflow loop after receiving `usage.prompt_tokens`.
    /// Weighted 80% old / 20% new, clamped to [1.5, 4.0].
    /// Also computes and stores the drift ratio.
    public func learnFromAPIResponse(
        totalChars: Int,
        actualPromptTokens: Int,
        estimatedPromptTokens: Int
    ) {
        guard totalChars > 0, actualPromptTokens > 0 else { return }

        queue.sync {
            let actualRatio = Double(totalChars) / Double(actualPromptTokens)
            let newRatio = (_learnedRatio * 0.8) + (actualRatio * 0.2)
            _learnedRatio = max(ContextBudget.minLearnedRatio,
                                min(newRatio, ContextBudget.maxLearnedRatio))

            // Drift = actual / estimated (how much the heuristic under/over-counts).
            let drift = Double(actualPromptTokens) / Double(max(estimatedPromptTokens, 1))
            _driftRatio = max(ContextBudget.minDriftRatio,
                              min(drift, ContextBudget.maxDriftRatio))
            _driftLastUpdated = Date()
            _driftActualTokens = actualPromptTokens
            _driftEstimatedTokens = estimatedPromptTokens
        }
    }

    /// Record a drift measurement from a 400 token_limit_exceeded response.
    /// `serverActualTokens` comes from the server's error object
    /// (n_prompt_tokens / prompt_tokens / etc).
    public func recordDrift(serverActualTokens: Int, estimatedTokens: Int) {
        guard serverActualTokens > 0, estimatedTokens > 0 else { return }
        queue.sync {
            let drift = Double(serverActualTokens) / Double(estimatedTokens)
            _driftRatio = max(ContextBudget.minDriftRatio,
                              min(drift, ContextBudget.maxDriftRatio))
            _driftLastUpdated = Date()
            _driftActualTokens = serverActualTokens
            _driftEstimatedTokens = estimatedTokens
        }
    }

    /// Compute the drift-aware trim threshold:
    /// `int(ctxWindow * 0.90 / max(1.0, drift))` but only tighten (never exceed raw 90%).
    /// Returns nil when there's no usable drift data.
    public func computeDriftAwareThreshold(contextWindow: Int) -> Int? {
        return queue.sync {
            guard let drift = _driftRatio,
                  let lastUpdated = _driftLastUpdated,
                  drift >= ContextBudget.driftAwareThreshold else {
                return nil
            }
            let age = Date().timeIntervalSince(lastUpdated)
            guard age < ContextBudget.driftMaxAgeSeconds else { return nil }

            let rawThreshold = Int(Double(contextWindow) * ContextBudget.proactiveTrimPct)
            if drift > 1.0 {
                // When actual tokens exceed estimates (drift > 1.0), we undercounted
                // tokens. Tighten the threshold: trim at 0.9 * ctx / drift so actual
                // usage stays at ~90% of the context window. Use min to pick the
                // more conservative (lower = more trimming) value.
                return min(rawThreshold, Int(Double(rawThreshold) / drift))
            }
            return rawThreshold
        }
    }

    public func reset() {
        queue.sync {
            _driftRatio = nil
            _driftLastUpdated = nil
            _driftActualTokens = nil
            _driftEstimatedTokens = nil
        }
    }
}

// MARK: - Context Budget Constants (ported from CLIO Defaults.pm + TokenEstimator.pm)

/// Centralized constants for context budget management.
/// Ported from CLIO::Core::Defaults and CLIO::Memory::TokenEstimator.
public enum ContextBudget {
    // MARK: Context window fallbacks

    /// Cloud models - used when model capabilities are unavailable from the API.
    public static let defaultContextWindow: Int = 128_000

    /// Local inference models - smaller because the model's max context
    /// is bounded by host RAM.
    public static let defaultLocalContextWindow: Int = 65_536

    // MARK: Output token fallbacks

    /// Output reserve fallback when no output limit is known.
    public static let defaultMaxOutputTokens: Int = 16_384

    // MARK: Output reservation

    /// Output reserve when tools are active. Tool-calling agent responses
    /// are short (tool_call JSON + brief text, well under 8K).
    public static let defaultToolOutputReserve: Int = 8_192

    // MARK: Estimation buffer (subtracted from budget)

    /// Constant part of the estimation buffer.
    public static let outputEstimationBufferConstant: Int = 8_192

    /// Proportional part (5% of context window).
    public static let outputEstimationBufferPct: Double = 0.05

    /// Cap on the proportional buffer.
    public static let outputEstimationBufferMax: Int = 51_200

    /// Compute the total estimation buffer: constant + min(context * pct, cap).
    public static func outputEstimationBuffer(contextWindow: Int) -> Int {
        let proportional = Int(Double(contextWindow) * outputEstimationBufferPct)
        let clamped = min(proportional, outputEstimationBufferMax)
        return outputEstimationBufferConstant + clamped
    }

    // MARK: Trimming floors

    /// Minimum tokens to keep after trimming (absolute floor).
    public static let defaultPostTrimFloor: Int = 24_000

    // MARK: CSSS slot bounds

    /// Minimum CSSS slot size. The first trim creates a naturally small
    /// summary; without this floor, CSSS locks to that tiny size and
    /// starves all subsequent summaries.
    public static let minCSSSlotTokens: Int = 8_000

    /// Maximum CSSS slot size. Prevents unbounded growth.
    public static let maxCSSSlotTokens: Int = 12_000

    // MARK: Per-message overhead

    /// Per-message token overhead (role + delimiters).
    public static let tokensPerMessage: Int = 4

    /// Tool message extra overhead (name + tool_call_id fields).
    public static let toolMessageOverhead: Int = 8

    /// Tool call JSON structure overhead.
    public static let toolCallOverhead: Int = 10

    // MARK: Default char/token ratio

    /// Default characters per token (conservative for English text).
    public static let defaultCharsPerToken: Double = 4.0

    /// Learned ratio clamp bounds.
    public static let minLearnedRatio: Double = 1.5
    public static let maxLearnedRatio: Double = 4.0

    // MARK: Drift-aware threshold

    /// Proactive trim threshold as a fraction of context window.
    public static let proactiveTrimPct: Double = 0.90

    /// Drift ratio threshold above which we tighten the trim threshold.
    public static let driftAwareThreshold: Double = 1.2

    /// Maximum age (seconds) of a saved drift ratio before it's considered stale.
    public static let driftMaxAgeSeconds: TimeInterval = 3600

    /// Drift ratio clamp bounds.
    public static let minDriftRatio: Double = 1.0
    public static let maxDriftRatio: Double = 4.0

    // MARK: Reactive trim tiers (on 400 token_limit_exceeded)

    /// Tier 1: precise cut (90% of context window).
    public static let reactiveTier1Pct: Double = 0.90

    /// Tier 2: moderate cut (75% of context window).
    public static let reactiveTier2Pct: Double = 0.75

    // MARK: Model family max output tokens defaults

    /// Per-model-family max output token defaults.
    /// Used when the model config doesn't specify max_output_tokens.
    /// Ported from SAMAPIServer.getMaxOutputTokens.
    public static func defaultMaxOutputTokens(for model: String) -> Int? {
        let modelLower = model.lowercased()

        // Claude models
        if modelLower.contains("claude-3.5") || modelLower.contains("claude-3-5") ||
           (modelLower.contains("claude-sonnet-4") && !modelLower.contains("4.5")) {
            return 8192
        }
        if modelLower.contains("claude-4.5") || modelLower.contains("claude-sonnet-4.5") ||
           modelLower.contains("claude-opus-41") || modelLower.contains("opus-4.1") {
            return 8192
        }
        if modelLower.contains("claude") {
            return 4096
        }

        // GPT-4 family
        if modelLower.contains("gpt-4-turbo") || modelLower.contains("gpt-4.1") {
            return 4096
        }
        if modelLower.contains("gpt-4o") {
            return 16384
        }
        if modelLower.contains("gpt-4") {
            return 8192
        }
        if modelLower.contains("gpt-3.5") {
            return 4096
        }

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

        // Local llama.cpp models
        if modelLower.contains("local-llama") || modelLower.contains("gguf") {
            return 4096
        }

        return nil
    }
}
