// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// WorkflowRound.swift SAM Tracks tool calls and results per iteration for workflow observability.

import Foundation

/// Represents structured thinking/reasoning captured from LLM during workflow Provides transparency and debugging capabilities for multi-step tool execution.
public struct ThinkingStep: Codable {
    /// The reasoning text from the LLM.
    public let text: String

    /// When this thinking occurred.
    public let timestamp: Date

    /// Token count if available.
    public let tokens: Int?

    /// Additional metadata (model, provider, etc.).
    public let metadata: [String: String]

    public init(
        text: String,
        timestamp: Date = Date(),
        tokens: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.text = text
        self.timestamp = timestamp
        self.tokens = tokens
        self.metadata = metadata
    }
}

/// Represents a single iteration/round in an autonomous workflow Tracks tool calls, results, and metadata for each iteration.
public struct WorkflowRound: Codable {
    /// Iteration number (0-based, matches billing iterationNumber).
    public let iterationNumber: Int

    /// Tool calls made in this round.
    public let toolCalls: [ToolCallInfo]

    /// Results from tool executions (keyed by tool call ID).
    public let toolResults: [String: String]

    /// DEPRECATED: Legacy string-based thinking steps (use structuredThinking instead) Chain-of-thought steps if captured (from think tool).
    public let thinkingSteps: [String]?

    /// Structured thinking/reasoning captured from LLM (Phase 1 enhancement) Contains timestamp, tokens, metadata for transparency and debugging.
    public let structuredThinking: [ThinkingStep]?

    /// LLM response text for this round (assistant message content).
    public let llmResponseText: String?

    /// Response type (success, error, etc.).
    public let responseStatus: String

    /// Additional metadata for this round.
    public let metadata: [String: String]

    /// Timestamp when round started.
    public let timestamp: Date

    /// Duration of this round in seconds.
    public let duration: TimeInterval?

    /// Tracks if this round is a continuation after an error (for context filtering).
    public let isContinuation: Bool?

    public init(
        iterationNumber: Int,
        toolCalls: [ToolCallInfo] = [],
        toolResults: [String: String] = [:],
        thinkingSteps: [String]? = nil,
        structuredThinking: [ThinkingStep]? = nil,
        llmResponseText: String? = nil,
        responseStatus: String = "success",
        metadata: [String: String] = [:],
        timestamp: Date = Date(),
        duration: TimeInterval? = nil,
        isContinuation: Bool? = nil
    ) {
        self.iterationNumber = iterationNumber
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.thinkingSteps = thinkingSteps
        self.structuredThinking = structuredThinking
        self.llmResponseText = llmResponseText
        self.responseStatus = responseStatus
        self.metadata = metadata
        self.timestamp = timestamp
        self.duration = duration
        self.isContinuation = isContinuation
    }
}

/// Information about a tool call within a workflow round.
public struct ToolCallInfo: Codable {
    /// Unique tool call ID.
    public let id: String

    /// Tool name (e.g., "file_operations", "terminal_operations").
    public let name: String

    /// Tool arguments (JSON string).
    public let arguments: String

    /// Success status.
    public let success: Bool

    /// Error message if failed.
    public let error: String?

    public init(
        id: String,
        name: String,
        arguments: String,
        success: Bool = true,
        error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.success = success
        self.error = error
    }
}
