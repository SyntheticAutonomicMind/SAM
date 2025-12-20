// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Internal Delete File Tool Handles file deletion with safety checks and authorization requirements.
public class DeleteFileTool: MCPTool, @unchecked Sendable {
    public let name = "delete_file"
    public let description = "Delete a file from the workspace"

    public var parameters: [String: MCPToolParameter] {
        return [
            "filePath": MCPToolParameter(
                type: .string,
                description: "Path to file to delete",
                required: true
            ),
            "confirm": MCPToolParameter(
                type: .boolean,
                description: "Confirmation flag (automatically set by authorization system)",
                required: false
            )
        ]
    }

    private let logger = Logging.Logger(label: "com.sam.mcp.DeleteFile")

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let filePath = parameters["filePath"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: filePath")
            )
        }

        /// Check confirmation flag (set by authorization system).
        let confirmed = parameters["confirm"] as? Bool ?? false
        guard confirmed else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: """
                    File deletion requires user authorization.

                    This operation will permanently delete: \(filePath)

                    Please use user_collaboration tool to request permission.
                    """)
            )
        }

        /// Expand tilde in path.
        let expandedPath = (filePath as NSString).expandingTildeInPath

        /// Safety checks.
        let fileManager = FileManager.default
        let fileURL = URL(fileURLWithPath: expandedPath)

        /// Check if file exists.
        guard fileManager.fileExists(atPath: expandedPath) else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "File does not exist: \(expandedPath)")
            )
        }

        /// Check if path is a directory.
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Path is a directory, not a file: \(expandedPath). Use appropriate directory deletion method.")
            )
        }

        /// Perform deletion.
        do {
            try fileManager.removeItem(at: fileURL)
            logger.debug("Successfully deleted file: \(expandedPath)")

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: "Successfully deleted file: \(filePath)")
            )
        } catch {
            logger.error("Failed to delete file \(expandedPath): \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to delete file: \(error.localizedDescription)")
            )
        }
    }
}
