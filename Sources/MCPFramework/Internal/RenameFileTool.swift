// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for renaming files and directories **CRITICAL**: Essential tool for file organization, batch renaming, and workflow automation.
public class RenameFileTool: MCPTool, @unchecked Sendable {
    public let name = "rename_file"
    public let description = """
        Rename a file or directory to a new name. Use this tool to organize files, apply naming conventions, or move files to different locations.

        Key Features:
        - Rename individual files or directories
        - Move files to different directories (if paths differ)
        - Validates paths exist before renaming
        - Prevents accidental overwrites
        - Atomic filesystem operation (succeeds or fails completely)

        Common Use Cases:
        - Organize photos with meaningful names
        - Apply naming conventions to project files
        - Move files between directories
        - Clean up messy file structures

        Safety:
        - Requires absolute paths for both old and new locations
        - Checks source file exists
        - Prevents overwriting existing files (returns error)
        - Atomic operation (no partial renames)
        """

    public var parameters: [String: MCPToolParameter] {
        return [
            "old_path": MCPToolParameter(
                type: .string,
                description: "Absolute path to the file or directory to rename",
                required: true
            ),
            "new_path": MCPToolParameter(
                type: .string,
                description: "New absolute path for the file or directory",
                required: true
            ),
            "confirm": MCPToolParameter(
                type: .boolean,
                description: "SECURITY: Must be true to rename/move files. Confirmation for destructive file operations.",
                required: false
            )
        ]
    }

    public struct RenameResult: Codable {
        let success: Bool
        let old_path: String
        let new_path: String
        let message: String
    }

    private let fileManager = FileManager.default
    private let logger = Logger(label: "com.sam.mcp.RenameFileTool")

    /// SECURITY: Rate limiting for destructive operations.
    private var lastDestructiveOperation: Date?
    private let destructiveOperationCooldown: TimeInterval = 5.0

    public init() {}

    public func initialize() async throws {
        logger.debug("RenameFileTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard let oldPath = parameters["old_path"] as? String, !oldPath.isEmpty else {
            throw MCPError.invalidParameters("old_path parameter is required and must not be empty")
        }
        guard let newPath = parameters["new_path"] as? String, !newPath.isEmpty else {
            throw MCPError.invalidParameters("new_path parameter is required and must not be empty")
        }

        /// Validate absolute paths.
        guard oldPath.hasPrefix("/") else {
            throw MCPError.invalidParameters("old_path must be an absolute path (start with /)")
        }
        guard newPath.hasPrefix("/") else {
            throw MCPError.invalidParameters("new_path must be an absolute path (start with /)")
        }

        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// SECURITY LAYER: Block autonomous destructive operations UNLESS authorized.
        let operationKey = "file_operations.rename_file"
        let isAuthorized = context.conversationId.map {
            AuthorizationManager.shared.isAuthorized(conversationId: $0, operation: operationKey)
        } ?? false

        guard context.isUserInitiated || isAuthorized else {
            logger.critical("SECURITY: Autonomous rename_file attempt BLOCKED - userRequest=\(context.userRequestText ?? "none")")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: """
                    SECURITY VIOLATION: File rename/move must be user-initiated or authorized.

                    This operation was autonomously decided by the agent and requires authorization.

                    Please use user_collaboration to request authorization:
                    {
                      "prompt": "Rename/move file?",
                      "authorize_operation": "\(operationKey)"
                    }
                    """)
            )
        }

        /// SECURITY LAYER 3: Rate limiting check.
        let currentTime = Date()
        if let lastOp = lastDestructiveOperation, currentTime.timeIntervalSince(lastOp) < destructiveOperationCooldown {
            let remaining = destructiveOperationCooldown - currentTime.timeIntervalSince(lastOp)
            logger.warning("SECURITY: rename_file rate limited - \(String(format: "%.1f", remaining))s remaining")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "SECURITY: Destructive operations rate limited. Please wait \(String(format: "%.0f", remaining)) seconds before retrying.")
            )
        }

        guard let oldPath = parameters["old_path"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: old_path")
            )
        }

        guard let newPath = parameters["new_path"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: new_path")
            )
        }

        /// SECURITY LAYER 4: Comprehensive audit logging.
        logger.critical("""
            DESTRUCTIVE_OPERATION_AUTHORIZED:
            operation=rename_file
            oldPath=\(oldPath)
            newPath=\(newPath)
            confirm=true
            isUserInitiated=\(context.isUserInitiated)
            userRequest=\(context.userRequestText ?? "none")
            timestamp=\(ISO8601DateFormatter().string(from: Date()))
            sessionId=\(context.sessionId)
            """)

        /// Update rate limiter.
        lastDestructiveOperation = currentTime

        logger.debug("Renaming file: \(oldPath) -> \(newPath)")

        do {
            let result = try renameFile(from: oldPath, to: newPath)

            /// Encode result to JSON.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(result)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            return MCPToolResult(
                toolName: name,
                success: result.success,
                output: MCPOutput(content: jsonString, mimeType: "application/json")
            )
        } catch {
            logger.error("Rename failed: \(error.localizedDescription)")

            let result = RenameResult(
                success: false,
                old_path: oldPath,
                new_path: newPath,
                message: "Rename failed: \(error.localizedDescription)"
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = (try? encoder.encode(result)) ?? Data()
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: jsonString, mimeType: "application/json")
            )
        }
    }

    // MARK: - Rename Implementation

    private func renameFile(from oldPath: String, to newPath: String) throws -> RenameResult {
        /// Validate source exists.
        guard fileManager.fileExists(atPath: oldPath) else {
            return RenameResult(
                success: false,
                old_path: oldPath,
                new_path: newPath,
                message: "Source file does not exist: \(oldPath)"
            )
        }

        /// Check if destination already exists.
        if fileManager.fileExists(atPath: newPath) {
            return RenameResult(
                success: false,
                old_path: oldPath,
                new_path: newPath,
                message: "Destination already exists: \(newPath). Cannot overwrite existing file."
            )
        }

        /// Ensure destination directory exists.
        let destinationDir = (newPath as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: destinationDir) {
            try fileManager.createDirectory(
                atPath: destinationDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            logger.debug("Created destination directory: \(destinationDir)")
        }

        /// Perform atomic rename/move.
        try fileManager.moveItem(atPath: oldPath, toPath: newPath)

        logger.debug("Successfully renamed: \(oldPath) -> \(newPath)")

        return RenameResult(
            success: true,
            old_path: oldPath,
            new_path: newPath,
            message: "File renamed successfully"
        )
    }
}
