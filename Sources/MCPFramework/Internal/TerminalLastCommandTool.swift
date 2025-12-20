// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for retrieving the last command executed in the terminal Tracks the most recently executed command via run_in_terminal, along with its timestamp and exit code.
public class TerminalLastCommandTool: MCPTool, @unchecked Sendable {
    public let name = "terminal_last_command"
    public let description = "Get the last command run in the active terminal."

    public var parameters: [String: MCPToolParameter] {
        return [:]
    }

    /// Static state to track last command across tool instances.
    nonisolated(unsafe) static var lastCommand: String?
    nonisolated(unsafe) static var lastTimestamp: Date?
    nonisolated(unsafe) static var lastExitCode: Int32?
    static private let lock = NSLock()

    public init() {}

    public func initialize() async throws {
        /// No initialization required.
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        let command = Self.lastCommand
        let timestamp = Self.lastTimestamp
        let exitCode = Self.lastExitCode

        guard let cmd = command, let ts = timestamp else {
            let result = makeResult(
                command: nil,
                timestamp: nil,
                exitCode: nil,
                message: "No commands have been executed yet"
            )
            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: result, mimeType: "application/json")
            )
        }

        let result = makeResult(
            command: cmd,
            timestamp: ts,
            exitCode: exitCode,
            message: nil
        )

        return MCPToolResult(
            toolName: name,
            success: true,
            output: MCPOutput(content: result, mimeType: "application/json")
        )
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        /// No parameters to validate.
        return true
    }

    /// Update the last command record - called by RunInTerminalTool.
    public static func updateLastCommand(_ command: String, exitCode: Int32?) {

        lastCommand = command
        lastTimestamp = Date()
        lastExitCode = exitCode
    }

    private func makeResult(command: String?, timestamp: Date?, exitCode: Int32?, message: String?) -> String {
        var result: [String: Any] = [:]

        if let cmd = command {
            result["command"] = cmd
        }
        if let ts = timestamp {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            result["timestamp"] = formatter.string(from: ts)
        }
        if let code = exitCode {
            result["exitCode"] = code
        }
        if let msg = message {
            result["message"] = msg
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "{\"error\": \"Failed to encode result\"}"
        }

        return jsonString
    }
}
