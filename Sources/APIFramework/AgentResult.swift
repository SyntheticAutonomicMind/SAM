// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// Result container for autonomous agent workflow execution.
public struct AgentResult {
    /// The final LLM response after workflow completion.
    public let finalResponse: String

    /// Number of iterations executed in the autonomous loop.
    public let iterations: Int

    /// Complete workflow history with per-iteration metadata (PRIMARY SOURCE - Phase 2).
    public let workflowRounds: [WorkflowRound]

    /// History of all tool executions during the workflow (DEPRECATED - computed from workflowRounds).
    public var toolExecutions: [ToolExecution] {
        /// Extract tool executions from workflowRounds for backward compatibility.
        return workflowRounds.flatMap { round -> [ToolExecution] in
            round.toolCalls.map { toolCall in
                ToolExecution(
                    toolCallId: toolCall.id,
                    toolName: toolCall.name,
                    arguments: [:],
                    result: round.toolResults[toolCall.id] ?? "",
                    timestamp: round.timestamp,
                    iteration: round.iterationNumber
                )
            }
        }
    }

    /// LLM responses at each iteration (DEPRECATED - computed from workflowRounds).
    public var iterationResponses: [IterationResponse] {
        /// Extract iteration responses from workflowRounds for backward compatibility.
        return workflowRounds.map { round in
            IterationResponse(
                iteration: round.iterationNumber,
                content: round.llmResponseText ?? "",
                requestedTools: round.toolCalls.map { $0.name },
                timestamp: round.timestamp
            )
        }
    }

    /// Metadata about the workflow execution.
    public let metadata: WorkflowMetadata

    /// Whether the workflow completed successfully.
    public var isSuccess: Bool {
        return metadata.completionReason == .workflowComplete
    }

    public init(
        finalResponse: String,
        iterations: Int,
        workflowRounds: [WorkflowRound],
        metadata: WorkflowMetadata
    ) {
        self.finalResponse = finalResponse
        self.iterations = iterations
        self.workflowRounds = workflowRounds
        self.metadata = metadata
    }
}

/// LLM response at a specific iteration (for transparency).
public struct IterationResponse {
    /// Iteration number.
    public let iteration: Int

    /// LLM's response content at this iteration.
    public let content: String

    /// Whether LLM requested tools at this iteration.
    public let requestedTools: [String]

    /// Timestamp of this iteration.
    public let timestamp: Date

    public init(
        iteration: Int,
        content: String,
        requestedTools: [String],
        timestamp: Date = Date()
    ) {
        self.iteration = iteration
        self.content = content
        self.requestedTools = requestedTools
        self.timestamp = timestamp
    }
}

/// Information about a single tool execution.
public struct ToolExecution: @unchecked Sendable {
    /// OpenAI tool call ID (for linking with API messages).
    public let toolCallId: String

    /// Tool name (e.g., "think", "web_search", "document_import").
    public let toolName: String

    /// Arguments passed to the tool.
    public let arguments: [String: Any]

    /// Result returned by the tool.
    public let result: String

    /// Success status from MCPToolResult.
    public let success: Bool

    /// Timestamp when tool was executed.
    public let timestamp: Date

    /// Iteration number when this tool was called.
    public let iteration: Int

    public init(
        toolCallId: String,
        toolName: String,
        arguments: [String: Any],
        result: String,
        success: Bool = true,
        timestamp: Date = Date(),
        iteration: Int
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.success = success
        self.timestamp = timestamp
        self.iteration = iteration
    }
}

/// Metadata about the workflow execution.
public struct WorkflowMetadata {
    /// Reason the workflow completed.
    public let completionReason: CompletionReason

    /// Total time taken for the workflow.
    public let totalDuration: TimeInterval

    /// Number of tokens used across all iterations.
    public let tokensUsed: Int?

    /// Whether any errors occurred during execution.
    public let hadErrors: Bool

    /// Errors encountered (if any).
    public let errors: [Error]

    public init(
        completionReason: CompletionReason,
        totalDuration: TimeInterval,
        tokensUsed: Int? = nil,
        hadErrors: Bool = false,
        errors: [Error] = []
    ) {
        self.completionReason = completionReason
        self.totalDuration = totalDuration
        self.tokensUsed = tokensUsed
        self.hadErrors = hadErrors
        self.errors = errors
    }
}

/// Reasons for workflow completion.
public enum CompletionReason: String, Codable {
    /// Workflow completed naturally (finish_reason != "tool_calls").
    case workflowComplete = "workflow_complete"

    /// Hit maximum iteration limit.
    case maxIterationsReached = "max_iterations_reached"

    /// User or system cancelled the workflow.
    case cancelled = "cancelled"

    /// Error occurred that prevented continuation.
    case error = "error"

    /// Tool execution failed.
    case toolExecutionFailed = "tool_execution_failed"
}
