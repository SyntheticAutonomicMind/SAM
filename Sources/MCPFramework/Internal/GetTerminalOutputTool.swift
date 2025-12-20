// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for retrieving output from background terminal processes **CRITICAL**: Enables checking status and output of background processes started with run_in_terminal.
public class GetTerminalOutputTool: MCPTool, @unchecked Sendable {
    public let name = "get_terminal_output"
    public let description = "Get the output of a terminal command previously started with run_in_terminal"

    public var parameters: [String: MCPToolParameter] {
        return [
            "id": MCPToolParameter(
                type: .string,
                description: "The ID of the terminal to check.",
                required: true
            )
        ]
    }

    public struct TerminalOutputResult: Codable {
        let terminalId: String
        let output: String
        let isRunning: Bool
        let exitCode: Int32?
        let truncated: Bool
    }

    private let logger = Logger(label: "com.sam.mcp.GetTerminalOutputTool")
    private static let outputSizeLimit = 60 * 1024

    public init() {}

    public func initialize() async throws {
        logger.debug("GetTerminalOutputTool initialized")
    }

    public func validateParameters(_ params: [String: Any]) throws -> Bool {
        guard let id = params["id"] as? String, !id.isEmpty else {
            throw MCPError.invalidParameters("id parameter is required and must be a non-empty string")
        }
        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let terminalId = parameters["id"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: id")
            )
        }

        logger.debug("Checking output for terminal: \(terminalId)")

        /// Get output from RunInTerminalTool.
        let (output, isRunning, exitCode) = RunInTerminalTool.getProcessOutput(terminalId: terminalId)

        /// Truncate if necessary.
        let (truncatedOutput, wasTruncated) = truncateOutput(output)

        let result = TerminalOutputResult(
            terminalId: terminalId,
            output: truncatedOutput,
            isRunning: isRunning,
            exitCode: exitCode,
            truncated: wasTruncated
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let jsonData = try? encoder.encode(result),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            logger.debug("Retrieved output for terminal \(terminalId) (running: \(isRunning))")
            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: jsonString, mimeType: "application/json")
            )
        }

        return MCPToolResult(
            toolName: name,
            success: false,
            output: MCPOutput(content: "Failed to encode terminal output result")
        )
    }

    private func truncateOutput(_ output: String) -> (String, Bool) {
        let data = output.data(using: .utf8) ?? Data()
        if data.count > Self.outputSizeLimit {
            let truncatedData = data.prefix(Self.outputSizeLimit)
            let truncatedString = String(data: truncatedData, encoding: .utf8) ?? output
            let warning = "\n\n[OUTPUT TRUNCATED - exceeded 60KB limit]"
            return (truncatedString + warning, true)
        }
        return (output, false)
    }
}
