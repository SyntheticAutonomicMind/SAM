// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for getting output from task execution **Note**: This is a stub implementation for future task system integration.
public class GetTaskOutputTool: MCPTool, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.tools.get_task_output")

    public let name = "get_task_output"
    public let description = "Get the output of a task execution. Note: Use get_terminal_output instead - tasks in SAM are executed via run_in_terminal."

    public var parameters: [String: MCPToolParameter] {
        return [
            "task_id": MCPToolParameter(
                type: .string,
                description: "Task ID or label",
                required: true
            )
        ]
    }

    public init() {}

    public func initialize() async throws {}

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        let result: [String: Any] = [
            "message": "Task output retrieval not implemented. Use get_terminal_output with the terminal ID returned from run_in_terminal.",
            "note": "SAM executes tasks via run_in_terminal, which returns a terminalId. Pass that terminalId to get_terminal_output to retrieve execution output."
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
        return true
    }
}
