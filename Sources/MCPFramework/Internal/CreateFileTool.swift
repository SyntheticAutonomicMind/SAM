// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

private let logger = Logger(label: "com.sam.mcp.createfile")

/// CreateFileTool - Create new files with safety checks Creates a new file with the specified content.
public class CreateFileTool: MCPTool, @unchecked Sendable {
    public let name = "create_file"
    public let description = """
    This is a tool for creating a new file in the workspace. The file will be created with the specified content. \
    The directory will be created if it does not already exist. Never use this tool to edit a file that already exists \
    unless the overwrite parameter is explicitly set to true.
    """

    private let fileOperationsSafety = FileOperationsSafety()

    /// SECURITY: Rate limiting for destructive operations.
    private var lastDestructiveOperation: Date?
    private let destructiveOperationCooldown: TimeInterval = 5.0

    public var parameters: [String: MCPToolParameter] {
        return [
            "filePath": MCPToolParameter(
                type: .string,
                description: "The absolute path to the file to create.",
                required: true
            ),
            "content": MCPToolParameter(
                type: .string,
                description: "The content to write to the file.",
                required: true
            ),
            "overwrite": MCPToolParameter(
                type: .boolean,
                description: "Optional: Whether to allow overwriting an existing file (default: false). If false and file exists, operation will fail with an error.",
                required: false
            )
        ]
    }

    public init() {}

    public func initialize() async throws {
        /// No initialization needed.
    }

    public func validateParameters(_ params: [String: Any]) throws {
        guard let filePath = params["filePath"] as? String, !filePath.isEmpty else {
            throw MCPError.invalidParameters("filePath parameter is required and must be a non-empty string")
        }

        guard params["content"] is String else {
            throw MCPError.invalidParameters("content parameter is required and must be a string")
        }

        /// Validate overwrite if provided.
        if let overwrite = params["overwrite"], !(overwrite is Bool) {
            throw MCPError.invalidParameters("overwrite parameter must be a boolean")
        }
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// ====================================================================== SECURITY: Path Authorization Check ====================================================================== Block operations outside working directory UNLESS user authorized.
        let operationKey = "file_operations.create_file"
        let authResult = MCPAuthorizationGuard.checkPathAuthorization(
            path: parameters["filePath"] as? String ?? "",
            workingDirectory: context.workingDirectory,
            conversationId: context.conversationId,
            operation: operationKey,
            isUserInitiated: context.isUserInitiated
        )

        switch authResult {
        case .allowed:
            /// Path is inside working directory or user authorized - continue with operation.
            break

        case .denied(let reason):
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Operation denied: \(reason)")
            )

        case .requiresAuthorization(let reason):
            let authError = MCPAuthorizationGuard.authorizationError(
                operation: operationKey,
                reason: reason,
                suggestedPrompt: "Create file [\(parameters["filePath"] as? String ?? "path")]?"
            )
            if let errorMsg = authError["error"] as? String {
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: errorMsg)
                )
            }
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Authorization required for path")
            )
        }

        /// ====================================================================== SECURITY LAYER 3: Rate Limiting ====================================================================== Prevent rapid-fire file creation.
        if let lastOperation = lastDestructiveOperation {
            let timeSinceLastOperation = Date().timeIntervalSince(lastOperation)
            if timeSinceLastOperation < destructiveOperationCooldown {
                let waitTime = destructiveOperationCooldown - timeSinceLastOperation
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "SECURITY: Destructive operations rate limited. Please wait \(String(format: "%.1f", waitTime)) seconds before retrying.")
                )
            }
        }

        /// ====================================================================== SECURITY LAYER 4: Audit Logging ====================================================================== Log file creation for security audit trail.
        let overwrite = parameters["overwrite"] as? Bool ?? false
        logger.info("""
            DESTRUCTIVE_OPERATION_AUTHORIZED:
            operation=create_file
            filePath=\(parameters["filePath"] as? String ?? "unknown")
            overwrite=\(overwrite)
            confirm=true
            isUserInitiated=\(context.isUserInitiated)
            timestamp=\(ISO8601DateFormatter().string(from: Date()))
            sessionId=\(context.sessionId.uuidString)
            """)

        lastDestructiveOperation = Date()

        /// Extract parameters.
        guard let filePath = parameters["filePath"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "filePath parameter is required"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }

        guard let content = parameters["content"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "content parameter is required"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }

        do {
            /// Create file.
            let result = try createFile(at: filePath, content: content, overwrite: overwrite)

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: result, mimeType: "application/json")
            )

        } catch let error as MCPError {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "\(error.localizedDescription)"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        } catch {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "Failed to create file: \(error.localizedDescription)"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }
    }

    private func createFile(at filePath: String, content: String, overwrite: Bool) throws -> String {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: filePath)

        /// Check if file exists.
        let fileExists = fileManager.fileExists(atPath: filePath)

        if fileExists && !overwrite {
            throw MCPError.executionFailed("File already exists at '\(filePath)'. Set overwrite=true to replace it.")
        }

        /// Get parent directory.
        let parentDirectory = url.deletingLastPathComponent().path

        /// Create parent directories if needed.
        if !fileManager.fileExists(atPath: parentDirectory) {
            do {
                try fileManager.createDirectory(
                    atPath: parentDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                throw MCPError.executionFailed("Failed to create parent directory: \(error.localizedDescription)")
            }
        }

        /// Validate we can write to parent directory.
        if !fileManager.isWritableFile(atPath: parentDirectory) {
            throw MCPError.executionFailed("Parent directory is not writable: \(parentDirectory)")
        }

        /// Write file using atomic write for safety.
        do {
            if fileExists {
                /// File exists and overwrite=true - use atomic write with backup.
                let writeResult = fileOperationsSafety.atomicWrite(
                    content: content,
                    to: filePath,
                    createBackup: true
                )
                if !writeResult.success {
                    throw MCPError.executionFailed("Failed to write file: \(writeResult.error ?? "Unknown error")")
                }
            } else {
                /// New file - write directly.
                try content.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch let mcpError as MCPError {
            throw mcpError
        } catch {
            throw MCPError.executionFailed("Failed to write file: \(error.localizedDescription)")
        }

        /// Build result JSON with clear success message.
        /// CRITICAL: Include filename prominently so LLM knows exactly what was created
        /// and doesn't try to create the same file again
        let filename = url.lastPathComponent
        let successMessage = fileExists ?
            "CREATED: \(filename) (overwritten at \(filePath))" :
            "CREATED: \(filename) at \(filePath)"

        let result: [String: Any] = [
            "success": true,
            "message": successMessage,
            "filename": filename,
            "filePath": filePath,
            "created": !fileExists,
            "overwritten": fileExists
        ]

        /// Convert to JSON string.
        let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw MCPError.executionFailed("Failed to encode result as JSON")
        }

        return jsonString
    }
}
