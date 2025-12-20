// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for getting the current selection in the active terminal **Note**: In headless/server mode, this functionality is not applicable.
public class TerminalSelectionTool: MCPTool, @unchecked Sendable {
    public let name = "terminal_selection"
    public let description = "Get the current selection in the active terminal."

    public var parameters: [String: MCPToolParameter] {
        return [:]
    }

    public init() {}

    public func initialize() async throws {
        /// No initialization required.
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// In server/headless mode, terminal selection is not applicable This would require integration with Terminal.app or GUI terminal emulator.
        let result: [String: Any] = [
            "selection": "",
            "message": "Terminal selection not available in server mode. This feature requires GUI terminal emulator integration."
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "{\"error\": \"Failed to encode result\"}")
            )
        }

        return MCPToolResult(
            toolName: name,
            success: true,
            output: MCPOutput(content: jsonString, mimeType: "application/json")
        )
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        /// No parameters to validate.
        return true
    }
}
