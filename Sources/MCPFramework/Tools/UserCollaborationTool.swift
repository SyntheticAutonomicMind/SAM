// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP tool for requesting user input mid-stream during task execution This tool enables SAM to ask the user for clarification, confirmation, or additional information without breaking the conversation flow.
public class UserCollaborationTool: MCPTool, @unchecked Sendable {
    public let name = "user_collaboration"
    public let description = """
        Ask user for input, clarification, or decisions during task execution.

        CRITICAL - Ask Questions Here, Not in Chat:
        - If you have a question, call this tool - don't respond to user with questions
        - Don't say "Do you want me to...?" or "Should I...?" in chat
        - Use this tool to ask, wait for response, then continue working

        WORKFLOW:
        1. Output your question with full context to the user
        2. Call this tool to pause and wait for user response
        3. Continue with user's input in same execution

        WHEN TO USE:
        - Ambiguous requests needing clarification
        - Multiple valid approaches - user should choose
        - Confirmation before destructive operations
        - Information only user knows (API keys, credentials, paths, configuration)

        WHEN NOT TO USE:
        - Questions answerable with tools (use memory_operations, file_operations instead)
        - Optional confirmations (just proceed unless destructive)
        - Information already in context

        EXAMPLES:
        SUCCESS: "Found 500 files. Rename all?" (destructive confirmation)
        SUCCESS: "Use approach A (fast) or B (thorough)?" (user preference)
        SUCCESS: "What's your API key?" (user-only information)
        "Should I search the codebase?" (just do it)
        "Is this okay?" (unnecessary confirmation)

        Tool blocks execution indefinitely until user responds (no timeout).
        User is in full control - workflow waits as long as needed.
        """

    public var parameters: [String: MCPToolParameter] {
        return [
            "prompt": MCPToolParameter(
                type: .string,
                description: "The question or request to show to the user. Be specific and clear about what you need.",
                required: true
            ),
            "context": MCPToolParameter(
                type: .string,
                description: "Optional context to help the user understand why you're asking. Will be shown above the prompt.",
                required: false
            ),
            "authorize_operation": MCPToolParameter(
                type: .string,
                description: "Optional: The tool operation to authorize if user approves. Format: 'tool_name.operation' (e.g., 'terminal_operations.create_directory'). If user responds with approval, this operation will be temporarily authorized.",
                required: false
            )
        ]
    }

    // MARK: - Execution Control Properties

    /// User collaboration MUST block workflow - we wait indefinitely for user response.
    public var requiresBlocking: Bool { true }

    /// User collaboration must execute serially (one at a time).
    public var requiresSerial: Bool { true }

    private let logger = Logger(label: "com.sam.mcp.UserCollaborationTool")

    /// Shared state for pending user responses Key: toolCallId (UUID string), Value: PendingResponse.
    nonisolated(unsafe) private static var pendingResponses: [String: PendingResponse] = [:]
    private static let responseLock = NSLock()

    public init() {}

    public func initialize() async throws {
        logger.debug("UserCollaborationTool initialized - enabling mid-stream user collaboration")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard let prompt = parameters["prompt"] as? String, !prompt.isEmpty else {
            throw MCPError.invalidParameters("prompt parameter is required and must not be empty")
        }

        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// AUTO-APPROVE CHECK: If auto-approve is enabled for this conversation, bypass user collaboration.
        if let conversationId = context.conversationId,
           AuthorizationManager.shared.isAutoApproveEnabled(conversationId: conversationId) {
            /// If authorize_operation was specified, grant it immediately.
            if let operation = parameters["authorize_operation"] as? String {
                /// Get expiry duration from user preferences (default: 5 minutes).
                let expiryDuration = DurationParser.getAuthorizationExpiryDuration()

                AuthorizationManager.shared.grantAuthorization(
                    conversationId: conversationId,
                    operation: operation,
                    expirySeconds: expiryDuration,
                    oneTimeUse: false
                )

                logger.debug("Auto-approve: Authorization granted without user prompt", metadata: [
                    "operation": .string(operation),
                    "conversationId": .string(conversationId.uuidString)
                ])
            }

            /// Return immediate approval without blocking.
            let prompt = parameters["prompt"] as? String ?? "Operation requested"
            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: "Auto-approved: \(prompt)")
            )
        }

        /// EXTERNAL API CALL DETECTION: If this is an external API call (GitHub Copilot agent, etc.), return immediately without blocking.
        if context.isExternalAPICall {
            guard let prompt = parameters["prompt"] as? String else {
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "Missing required parameter: prompt")
                )
            }

            let userContext = parameters["context"] as? String

            logger.debug("External API call detected - returning collaboration request immediately without blocking", metadata: [
                "prompt": .string(prompt),
                "context": .string(userContext ?? "none")
            ])

            /// Return special message indicating user input is needed External caller can handle this their own way (e.g., via their own UI).
            var message = "USER_INPUT_REQUIRED: \(prompt)"
            if let ctx = userContext {
                message += "\n\nContext: \(ctx)"
            }

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: message)
            )
        }

        /// INTERNAL SAM USE (NORMAL COLLABORATION PROTOCOL): Parse parameters.
        guard let prompt = parameters["prompt"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: prompt")
            )
        }

        let userContext = parameters["context"] as? String
        let authorizeOperation = parameters["authorize_operation"] as? String

        /// Use tool call ID from LLM (e.g., GitHub Copilot's "call_XYZ..." format) This ensures user responses submitted with LLM's ID can be matched to this request Fallback to UUID only if toolCallId not provided (backward compatibility).
        let toolCallId = context.toolCallId ?? UUID().uuidString

        logger.debug("User collaboration requested", metadata: [
            "toolCallId": .string(toolCallId),
            "prompt": .string(prompt),
            "waitMode": .string("indefinite"),
            "authorizeOperation": .string(authorizeOperation ?? "none"),
            "source": .string(context.toolCallId != nil ? "LLM" : "generated")
        ])

        /// Create pending response entry.
        let pending = PendingResponse(
            toolCallId: toolCallId,
            prompt: prompt,
            context: userContext,
            conversationId: context.conversationId,
            requestedAt: Date()
        )

        Self.pendingResponses[toolCallId] = pending

        /// Send SSE event to notify UI NOTE: This will be handled by the streaming handler in APIHandler The event format: { type: "user_input_required", toolCallId, prompt, context?.
        await notifyUIForInput(toolCallId: toolCallId, prompt: prompt, context: userContext, conversationId: context.conversationId)

        /// Block execution indefinitely until user responds (NO TIMEOUT).
        logger.debug("BLOCKING: Waiting indefinitely for user input (no timeout) - workflow STOPPED", metadata: [
            "toolCallId": .string(toolCallId)
        ])

        let result = await waitForUserResponse(
            toolCallId: toolCallId,
            authorizeOperation: authorizeOperation,
            conversationId: context.conversationId
        )

        /// Clean up pending response.
        Self.pendingResponses.removeValue(forKey: toolCallId)

        return result
    }

    // MARK: - Async Blocking Mechanism

    /// Wait for user response indefinitely (no timeout) Workflow is BLOCKED until user responds - user is in full control.
    @MainActor
    private func waitForUserResponse(toolCallId: String, authorizeOperation: String?, conversationId: UUID?) async -> MCPToolResult {
        let startTime = Date()
        var pollCount = 0

        /// INDEFINITE WAIT: Poll for response every 100ms until user responds No timeout - user has full control, workflow waits as long as needed.
        while true {
            pollCount += 1
            
            /// Log every 10 polls (every second) to track that we're still waiting
            if pollCount % 10 == 0 {
                let elapsed = Date().timeIntervalSince(startTime)
                logger.debug("COLLAB_DEBUG: Still waiting for user response", metadata: [
                    "toolCallId": .string(toolCallId),
                    "pollCount": .stringConvertible(pollCount),
                    "elapsedSeconds": .stringConvertible(elapsed),
                    "hasPending": .stringConvertible(Self.pendingResponses[toolCallId] != nil),
                    "hasResponse": .stringConvertible(Self.pendingResponses[toolCallId]?.userResponse != nil)
                ])
            }
            
            /// Check if response received.
            if let pending = Self.pendingResponses[toolCallId], let response = pending.userResponse {

                let waitTime = Date().timeIntervalSince(startTime)
                logger.info("USER_RESPONDED: User response received after \(String(format: "%.2f", waitTime))s", metadata: [
                    "toolCallId": .string(toolCallId),
                    "waitTimeSeconds": .stringConvertible(waitTime),
                    "pollCount": .stringConvertible(pollCount)
                ])

                /// AUTHORIZATION HANDLING: If authorize_operation was specified, check if user approved.
                if let operation = authorizeOperation, let convId = conversationId {
                    if AuthorizationManager.isApprovalResponse(response) {
                        /// User approved!.
                        let expiryDuration = DurationParser.getAuthorizationExpiryDuration()

                        AuthorizationManager.shared.grantAuthorization(
                            conversationId: convId,
                            operation: operation,
                            expirySeconds: expiryDuration,
                            oneTimeUse: false
                        )
                        logger.debug("Authorization granted based on user approval", metadata: [
                            "operation": .string(operation),
                            "expirySeconds": .stringConvertible(expiryDuration),
                            "conversationId": .string(convId.uuidString)
                        ])
                    } else if AuthorizationManager.isRejectionResponse(response) {
                        logger.debug("Authorization denied based on user rejection", metadata: [
                            "operation": .string(operation),
                            "conversationId": .string(convId.uuidString)
                        ])
                    }
                }

                return MCPToolResult(
                    toolName: name,
                    success: true,
                    output: MCPOutput(
                        content: """
                        User response: \(response)

                        ACTION REQUIRED: Process the user's response and continue with your workflow.
                        Do NOT end the conversation - use the response to make decisions and proceed with the task.
                        """,
                        mimeType: "text/plain",
                        additionalData: [
                            "toolCallId": toolCallId,
                            "waitTimeSeconds": waitTime,
                            "userResponse": response
                        ]
                    )
                )
            }

            /// Sleep for 100ms before checking again.
            try? await Task.sleep(nanoseconds: 100_000_000)

            /// Loop continues indefinitely until user responds No timeout - user is in full control of when to respond.
        }
    }

    /// Notify UI that user input is required (will be sent as SSE event).
    @MainActor
    private func notifyUIForInput(toolCallId: String, prompt: String, context: String?, conversationId: UUID?) async {
        /// Post notification via global event system AgentOrchestrator/StreamingHandler will observe and emit SSE event.
        ToolNotificationCenter.shared.postUserInputRequired(
            toolCallId: toolCallId,
            prompt: prompt,
            context: context,
            conversationId: conversationId
        )

        logger.debug("UI notification posted for tool call", metadata: [
            "toolCallId": .string(toolCallId),
            "prompt": .string(prompt)
        ])
    }

    // MARK: - Public Interface for Response Handling

    /// Submit user response for a pending tool call (called from API endpoint).
    public static func submitUserResponse(toolCallId: String, userInput: String) -> Bool {
        let logger = Logger(label: "com.sam.mcp.UserCollaborationTool.submitResponse")
        logger.info("COLLAB_DEBUG: submitUserResponse called", metadata: [
            "toolCallId": .string(toolCallId),
            "userInputLength": .stringConvertible(userInput.count),
            "pendingCount": .stringConvertible(pendingResponses.count),
            "hasPending": .stringConvertible(pendingResponses[toolCallId] != nil)
        ])

        guard var pending = pendingResponses[toolCallId] else {
            logger.error("COLLAB_DEBUG: No pending response found for toolCallId", metadata: [
                "toolCallId": .string(toolCallId),
                "availableToolCallIds": .string(Array(pendingResponses.keys).joined(separator: ", "))
            ])
            return false
        }

        logger.debug("COLLAB_DEBUG: Updating pending response", metadata: [
            "toolCallId": .string(toolCallId),
            "waitTimeSeconds": .stringConvertible(Date().timeIntervalSince(pending.requestedAt))
        ])

        pending.userResponse = userInput
        pending.respondedAt = Date()
        pendingResponses[toolCallId] = pending

        logger.debug("COLLAB_DEBUG: Pending response updated, posting notification")

        /// Notify that user response was received so AgentOrchestrator can emit it as streaming chunk
        ToolNotificationCenter.shared.postUserResponseReceived(
            toolCallId: toolCallId,
            userInput: userInput,
            conversationId: pending.conversationId
        )

        logger.info("COLLAB_DEBUG: Notification posted successfully", metadata: [
            "toolCallId": .string(toolCallId)
        ])

        return true
    }

    /// Get pending response info (for debugging/monitoring).
    public static func getPendingResponse(toolCallId: String) -> PendingResponse? {
        return pendingResponses[toolCallId]
    }

    /// Get all pending responses (for debugging/monitoring).
    public static func getAllPendingResponses() -> [PendingResponse] {
        return Array(pendingResponses.values)
    }
}

// MARK: - Supporting Types

/// Tracks a pending user collaboration request.
public struct PendingResponse {
    let toolCallId: String
    let prompt: String
    let context: String?
    let conversationId: UUID?
    let requestedAt: Date
    var userResponse: String?
    var respondedAt: Date?

    public var isWaiting: Bool {
        return userResponse == nil
    }

    public var waitTime: TimeInterval? {
        guard let responded = respondedAt else { return nil }
        return responded.timeIntervalSince(requestedAt)
    }
}
