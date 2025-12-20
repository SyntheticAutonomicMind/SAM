// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for creating SAM tasks.json and executing tasks Creates or updates SAM conversation-scoped tasks.json file with task definitions and optionally executes the created task immediately.
public class CreateAndRunTaskTool: MCPTool, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.tools.create_and_run_task")

    /// SECURITY: Rate limiting for destructive operations.
    private var lastDestructiveOperation: Date?
    private let destructiveOperationCooldown: TimeInterval = 5.0

    public let name = "create_and_run_task"
    public let description = "Creates and runs a build, run, or custom task for the workspace by generating or adding to a tasks.json file based on the project structure (such as package.json or README.md). If the user asks to build, run, launch and they have no tasks.json file, use this tool. If they ask to create or add a task, use this tool."

    public var parameters: [String: MCPToolParameter] {
        return [
            "task": MCPToolParameter(
                type: .object(properties: [
                    "label": MCPToolParameter(type: .string, description: "Task label", required: true),
                    "type": MCPToolParameter(type: .string, description: "Task type (only 'shell' supported)", required: true),
                    "command": MCPToolParameter(type: .string, description: "Shell command to execute", required: true),
                    "args": MCPToolParameter(type: .array, description: "Command arguments", required: false, arrayElementType: .string),
                    "group": MCPToolParameter(type: .string, description: "Task group", required: false),
                    "isBackground": MCPToolParameter(type: .boolean, description: "Run in background (true for servers/watch tasks)", required: false),
                    "problemMatcher": MCPToolParameter(type: .array, description: "Error matcher ($tsc, $eslint-stylish, $gcc, etc.)", required: false, arrayElementType: .string)
                ]),
                description: "Task configuration object",
                required: true
            ),
            "workspaceFolder": MCPToolParameter(
                type: .string,
                description: "Workspace folder absolute path",
                required: true
            ),
            "confirm": MCPToolParameter(
                type: .boolean,
                description: "SECURITY: Must be true to create tasks.json",
                required: false
            )
        ]
    }

    public init() {}

    public func initialize() async throws {
        /// No initialization required.
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// ====================================================================== SECURITY: Authorization Check ====================================================================== Block autonomous task creation UNLESS authorized.
        let operationKey = "build_and_version_control.create_and_run_task"
        let isAuthorized = context.conversationId.map {
            AuthorizationManager.shared.isAuthorized(conversationId: $0, operation: operationKey)
        } ?? false

        if !context.isUserInitiated && !isAuthorized {
            logger.critical("""
                DESTRUCTIVE_OPERATION_BLOCKED:
                operation=create_and_run_task
                workspaceFolder=\(parameters["workspaceFolder"] as? String ?? "unknown")
                isUserInitiated=false
                isAuthorized=false
                reason=Autonomous task creation blocked - requires authorization
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
                      "prompt": "Create and run task?",
                      "authorize_operation": "\(operationKey)"
                    }
                    """)
            )
        }

        /// ====================================================================== SECURITY LAYER 3: Rate Limiting ====================================================================== Prevent rapid-fire task creation.
        if let lastOperation = lastDestructiveOperation {
            let timeSinceLastOperation = Date().timeIntervalSince(lastOperation)
            if timeSinceLastOperation < destructiveOperationCooldown {
                let waitTime = destructiveOperationCooldown - timeSinceLastOperation
                logger.warning("Rate limit triggered for create_and_run_task (wait \(String(format: "%.1f", waitTime)) seconds)")
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "SECURITY: Destructive operations rate limited. Please wait \(String(format: "%.1f", waitTime)) seconds before retrying.")
                )
            }
        }

        /// ====================================================================== SECURITY LAYER 4: Audit Logging ====================================================================== Log task creation for security audit trail.
        let taskDict = parameters["task"] as? [String: Any]
        let taskLabel = taskDict?["label"] as? String ?? "unknown"
        logger.critical("""
            DESTRUCTIVE_OPERATION_AUTHORIZED:
            operation=create_and_run_task
            taskLabel=\(taskLabel)
            workspaceFolder=\(parameters["workspaceFolder"] as? String ?? "unknown")
            confirm=true
            isUserInitiated=\(context.isUserInitiated)
            userRequest=\(context.userRequestText ?? "none")
            timestamp=\(ISO8601DateFormatter().string(from: Date()))
            sessionId=\(context.sessionId.uuidString)
            """)

        lastDestructiveOperation = Date()

        guard let taskDict = parameters["task"] as? [String: Any],
              let workspaceFolder = parameters["workspaceFolder"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameters: task and workspaceFolder")
            )
        }

        guard let label = taskDict["label"] as? String,
              let type = taskDict["type"] as? String,
              let command = taskDict["command"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Task must have label, type, and command")
            )
        }

        /// Get SAM conversation-scoped configuration path.
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

        /// Build task object.
        var task: [String: Any] = [
            "label": label,
            "type": type,
            "command": command
        ]

        if let args = taskDict["args"] as? [String] {
            task["args"] = args
        }
        if let group = taskDict["group"] as? String {
            task["group"] = group
        }
        if let isBackground = taskDict["isBackground"] as? Bool {
            task["isBackground"] = isBackground
        }
        if let problemMatcher = taskDict["problemMatcher"] as? [String] {
            task["problemMatcher"] = problemMatcher
        }

        /// Read existing tasks.json or create new.
        var tasksConfig: [String: Any] = [
            "version": "2.0.0",
            "tasks": []
        ]

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: tasksFileURL.path) {
            if let data = try? Data(contentsOf: tasksFileURL),
               let existingConfig = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                tasksConfig = existingConfig
            }
        }

        /// Add or update task.
        var tasks = tasksConfig["tasks"] as? [[String: Any]] ?? []
        if let existingIndex = tasks.firstIndex(where: { ($0["label"] as? String) == label }) {
            tasks[existingIndex] = task
        } else {
            tasks.append(task)
        }
        tasksConfig["tasks"] = tasks

        /// Write tasks.json.
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: tasksConfig, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: tasksFileURL)
        } catch {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to write tasks.json: \(error.localizedDescription)")
            )
        }

        let result: [String: Any] = [
            "success": true,
            "samConfigPath": tasksFileURL.path,
            "taskLabel": label,
            "message": "Task '\(label)' created successfully in SAM conversation configuration. Use run_in_terminal to execute the task command: \(command)"
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
        guard let task = parameters["task"] as? [String: Any],
              parameters["workspaceFolder"] is String else {
            return false
        }

        return task["label"] != nil && task["type"] != nil && task["command"] != nil
    }
}
