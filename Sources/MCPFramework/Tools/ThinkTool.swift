// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

/// MCP tool for agent reasoning and problem-solving transparency Implements the thinking pattern from VS Code Copilot to allow agents to "think out loud" before generating final responses.
public final class ThinkTool: MCPTool {

    // MARK: - Protocol Conformance

    public let name = "think"
    public let description = """
    Planning and analysis for complex reasoning.

    CRITICAL: Think once, then execute. DO NOT get stuck in thinking loops.
    - First, use this tool to outline your thoughts and approach
    - THEN, take action: execute another tool, generate a final response, or perform a concrete step based on your plan
    - DO NOT call think multiple times in a row without taking action
    - "Taking action" means executing a tool, generating a user-facing response, or performing a specific step derived from your plan.

    USE FOR:
    - Planning before complex multi-tool workflows
    - Clarifying approach when uncertain
    - Breaking down large or ambiguous requests
    - Analyzing errors or unexpected results

    DO NOT USE FOR:
    - Simple, single-step tasks
    - Repeated planning without taking action
    - Todo list management (use memory_operations instead)
    """

    public var parameters: [String: MCPToolParameter] {
        return [
            "thoughts": MCPToolParameter(
                type: .string,
                description: "Your thoughts, analysis, planning, or reasoning process.",
                required: true
            ),
            "requested_tools": MCPToolParameter(
                type: .array,
                description: "Optional: List of tool names to request for subsequent iterations. Examples: web_operations, file_operations, document_operations, build_and_version_control, memory_operations. Next iteration will have requested tools available.",
                required: false,
                arrayElementType: .string
            )
        ]
    }

    // MARK: - Helper Methods

    private let logger = Logging.Logger(label: "com.sam.mcp.ThinkTool")

    // MARK: - Lifecycle

    public func initialize() async throws {
        logger.debug("ThinkTool initialized")
        /// No async setup required for this tool.
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        /// Validate thoughts parameter exists and is non-empty.
        guard let thoughts = parameters["thoughts"] as? String, !thoughts.isEmpty else {
            throw MCPError.invalidParameters("thoughts parameter is required and must not be empty")
        }

        return true
    }

    // MARK: - Tool Execution

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        logger.debug("ThinkTool executing")

        /// Validate required parameters.
        guard let thoughts = parameters["thoughts"] as? String, !thoughts.isEmpty else {
            logger.error("Missing or empty thoughts parameter")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "ERROR: 'thoughts' parameter is required and must not be empty")
            )
        }

        /// Log the thinking for transparency.
        let conversationId = context.conversationId?.uuidString ?? "unknown"
        logger.debug("Agent thinking (conversation: \(conversationId)): \(thoughts.prefix(200))\(thoughts.count > 200 ? "..." : "")")

        /// Log requested_tools if present (for small context models).
        var requestedTools: [String]?
        if let tools = parameters["requested_tools"] as? [String], !tools.isEmpty {
            requestedTools = tools
            logger.info("TOOL_REQUEST: Model requested tools: \(tools.joined(separator: ", "))")
        }

        return handleTraditionalThinking(thoughts: thoughts, requestedTools: requestedTools)
    }

    // MARK: - Mode Handlers

    /// Traditional planning and analysis.
    private func handleTraditionalThinking(thoughts: String, requestedTools: [String]?) -> MCPToolResult {
        logger.debug("ThinkTool: Traditional planning mode")

        var output = thoughts

        /// If tools were requested, include that info in the output AgentOrchestrator/SharedConversationService will parse this for next iteration.
        if let tools = requestedTools, !tools.isEmpty {
            output += "\n\nTOOL_REQUEST: \(tools.joined(separator: ", "))"
        }

        /// Generate progress event so UI creates a thinking card WITHOUT text-based SUCCESS: pattern.
        /// MODERN APPROACH: Use ONLY ToolDisplayData (JSON) for UI rendering.
        let progressEvent = MCPProgressEvent(
            eventType: .userMessage,
            toolName: name,
            display: ToolDisplayData(
                action: "thinking",
                actionDisplayName: "Thinking",
                summary: String(thoughts.prefix(100)),
                details: [thoughts],
                status: .success,
                icon: "brain.head.profile"
            ),
            status: "success",
            message: nil,  /// NO text message - use ToolDisplayData only
            timestamp: Date()
        )

        logger.info("THINK_TOOL_PROGRESS_EVENT_CREATED: eventType=userMessage, using ToolDisplayData (modern JSON approach)")

        /// Return the thoughts as the tool result This will be displayed to the user as part of the streaming response.
        return MCPToolResult(
            toolName: name,
            success: true,
            output: MCPOutput(content: output),
            progressEvents: [progressEvent]
        )
    }

    // MARK: - Cleanup

    public func cleanup() async {
        logger.debug("ThinkTool cleanup completed")
    }
}
