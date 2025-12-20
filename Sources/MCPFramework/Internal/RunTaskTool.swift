// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for executing tasks from tasks.json Reads tasks.json and executes the specified task by running its command.
public class RunTaskTool: MCPTool, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.tools.run_task")

    /// SECURITY: Rate limiting for task execution.
    private var lastDestructiveOperation: Date?
    private let destructiveOperationCooldown: TimeInterval = 5.0

    public let name = "run_task"
    public let description = "Execute an existing task from tasks.json by label. Note: This is a simplified implementation - use run_in_terminal for direct command execution."

    public var parameters: [String: MCPToolParameter] {
        return [
            "task_label": MCPToolParameter(
                type: .string,
                description: "Label of the task to execute",
                required: true
            ),
            "workspaceFolder": MCPToolParameter(
                type: .string,
                description: "Workspace folder path (optional, defaults to current directory)",
                required: false
            ),
            "confirm": MCPToolParameter(
                type: .boolean,
                description: "SECURITY: Must be true to execute tasks (commands run via run_in_terminal which has its own guard rails)",
                required: false
            )
        ]
    }

    public init() {}

    public func initialize() async throws {}

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// ====================================================================== SECURITY: Authorization Check ====================================================================== Block autonomous task execution UNLESS authorized.
        let operationKey = "build_and_version_control.run_task"
        let isAuthorized = context.conversationId.map {
            AuthorizationManager.shared.isAuthorized(conversationId: $0, operation: operationKey)
        } ?? false

        if !context.isUserInitiated && !isAuthorized {
            logger.critical("""
                DESTRUCTIVE_OPERATION_BLOCKED:
                operation=run_task
                taskLabel=\(parameters["task_label"] as? String ?? "unknown")
                isUserInitiated=false
                isAuthorized=false
                reason=Autonomous task execution blocked - requires authorization
                timestamp=\(ISO8601DateFormatter().string(from: Date()))
                sessionId=\(context.sessionId.uuidString)
                """)

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: """
                    SECURITY VIOLATION: Destructive operations must be user-initiated or authorized.

                    This operation was autonomously decided by the agent and requires authorization.

                    Please use user_collaboration to request authorization:
                    {
                      "prompt": "Run task?",
                      "authorize_operation": "\(operationKey)"
                    }
                    """)
            )
        }

        /// ====================================================================== SECURITY LAYER 3: Rate Limiting ====================================================================== Prevent rapid-fire task execution.
        if let lastOperation = lastDestructiveOperation {
            let timeSinceLastOperation = Date().timeIntervalSince(lastOperation)
            if timeSinceLastOperation < destructiveOperationCooldown {
                let waitTime = destructiveOperationCooldown - timeSinceLastOperation
                logger.warning("Rate limit triggered for run_task (wait \(String(format: "%.1f", waitTime)) seconds)")
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "SECURITY: Destructive operations rate limited. Please wait \(String(format: "%.1f", waitTime)) seconds before retrying.")
                )
            }
        }

        /// ====================================================================== SECURITY LAYER 4: Audit Logging ====================================================================== Log task execution for security audit trail.
        logger.critical("""
            DESTRUCTIVE_OPERATION_AUTHORIZED:
            operation=run_task
            taskLabel=\(parameters["task_label"] as? String ?? "unknown")
            confirm=true
            isUserInitiated=\(context.isUserInitiated)
            userRequest=\(context.userRequestText ?? "none")
            timestamp=\(ISO8601DateFormatter().string(from: Date()))
            sessionId=\(context.sessionId.uuidString)
            """)

        lastDestructiveOperation = Date()

        guard let taskLabel = parameters["task_label"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: task_label")
            )
        }

        /// Get SAM conversation-scoped tasks.json path.
        guard let conversationId = context.conversationId else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "No active conversation. Tasks are conversation-scoped in SAM.")
            )
        }

        let tasksFileURL: URL
        do {
            tasksFileURL = try SAMConfigurationPaths.tasksFilePath(conversationId: conversationId.uuidString)
        } catch {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to get SAM configuration path: \(error.localizedDescription)")
            )
        }

        guard FileManager.default.fileExists(atPath: tasksFileURL.path) else {
            let msg = "No tasks.json found in SAM conversation configuration. Use create_and_run_task to create tasks first."
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: msg)
            )
        }

        guard let data = try? Data(contentsOf: tasksFileURL),
              let tasksConfig = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = tasksConfig["tasks"] as? [[String: Any]] else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to parse tasks.json")
            )
        }

        guard let task = tasks.first(where: { ($0["label"] as? String) == taskLabel }) else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Task '\(taskLabel)' not found in tasks.json")
            )
        }

        guard let command = task["command"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Task '\(taskLabel)' has no command defined")
            )
        }

        let result: [String: Any] = [
            "success": true,
            "message": "Task found. Use run_in_terminal to execute: \(command)",
            "taskLabel": taskLabel,
            "command": command,
            "note": "Simplified implementation - task variable substitution and problem matchers not yet implemented"
        ]

        guard let resultData = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
              let resultString = String(data: resultData, encoding: .utf8) else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to encode result")
            )
        }

        return MCPToolResult(
            toolName: name,
            success: true,
            output: MCPOutput(content: resultString, mimeType: "application/json")
        )
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        return parameters["task_label"] is String
    }
}
