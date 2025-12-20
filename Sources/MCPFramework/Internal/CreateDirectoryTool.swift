// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for creating directories Creates a directory structure, recursively creating parent directories as needed (like mkdir -p).
public class CreateDirectoryTool: MCPTool, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.tools.create_directory")

    /// SECURITY: Rate limiting for destructive operations.
    private var lastDestructiveOperation: Date?
    private let destructiveOperationCooldown: TimeInterval = 5.0

    public let name = "create_directory"
    public let description = "Create a new directory structure in the workspace. Will recursively create all directories in the path, like mkdir -p. You do not need to use this tool before using create_file, that tool will automatically create the needed directories."

    public var parameters: [String: MCPToolParameter] {
        return [
            "dirPath": MCPToolParameter(
                type: .string,
                description: "The absolute path to the directory to create.",
                required: true
            )
        ]
    }

    public init() {}

    public func initialize() async throws {}

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// ====================================================================== SECURITY: Path Authorization Check ====================================================================== Block operations outside working directory UNLESS user authorized.
        let operationKey = "terminal_operations.create_directory"
        /// Use centralized authorization guard.
        let authResult = MCPAuthorizationGuard.checkPathAuthorization(
            path: parameters["dirPath"] as? String ?? "",
            workingDirectory: context.workingDirectory,
            conversationId: context.conversationId,
            operation: operationKey,
            isUserInitiated: context.isUserInitiated
        )

        switch authResult {
        case .allowed:
            /// Path is inside working directory or user authorized - continue.
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
                suggestedPrompt: "Create directory [\(parameters["dirPath"] as? String ?? "path")]?"
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

        /// ====================================================================== SECURITY LAYER 3: Rate Limiting ====================================================================== Prevent rapid-fire directory creation.
        if let lastOperation = lastDestructiveOperation {
            let timeSinceLastOperation = Date().timeIntervalSince(lastOperation)
            if timeSinceLastOperation < destructiveOperationCooldown {
                let waitTime = destructiveOperationCooldown - timeSinceLastOperation
                logger.warning("Rate limit triggered for create_directory (wait \(String(format: "%.1f", waitTime)) seconds)")
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "SECURITY: Destructive operations rate limited. Please wait \(String(format: "%.1f", waitTime)) seconds before retrying.")
                )
            }
        }

        /// ====================================================================== SECURITY LAYER 4: Audit Logging ====================================================================== Log directory creation for security audit trail.
        logger.critical("""
            DESTRUCTIVE_OPERATION_AUTHORIZED:
            operation=create_directory
            dirPath=\(parameters["dirPath"] as? String ?? "unknown")
            confirm=true
            isUserInitiated=\(context.isUserInitiated)
            userRequest=\(context.userRequestText ?? "none")
            timestamp=\(ISO8601DateFormatter().string(from: Date()))
            sessionId=\(context.sessionId.uuidString)
            """)

        lastDestructiveOperation = Date()

        /// Extract directory path.
        guard let dirPath = parameters["dirPath"] as? String, !dirPath.isEmpty else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: dirPath")
            )
        }

        /// Resolve path (relative paths resolve to working directory, absolute paths remain unchanged).
        let resolvedPath: String
        if dirPath.hasPrefix("/") || dirPath.hasPrefix("~") {
            /// Absolute path - expand tilde if present.
            resolvedPath = (dirPath as NSString).expandingTildeInPath
        } else {
            /// Relative path - resolve to working directory.
            if let workingDir = context.workingDirectory {
                resolvedPath = (workingDir as NSString).appendingPathComponent(dirPath)
            } else {
                /// No working directory - use current directory.
                resolvedPath = FileManager.default.currentDirectoryPath + "/" + dirPath
            }
        }

        /// Check if directory already exists.
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory)

        if exists && isDirectory.boolValue {
            /// Directory already exists.
            logger.debug("Directory already exists: \(resolvedPath)")

            let result: [String: Any] = [
                "success": true,
                "path": resolvedPath,
                "created": false,
                "message": "Directory already exists"
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "Failed to encode result")
                )
            }

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: jsonString, mimeType: "application/json")
            )
        } else if exists && !isDirectory.boolValue {
            /// Path exists but is a file, not a directory.
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Path exists but is a file, not a directory: \(resolvedPath)")
            )
        }

        /// Create directory with intermediate directories.
        do {
            try fileManager.createDirectory(
                atPath: resolvedPath,
                withIntermediateDirectories: true,
                attributes: nil
            )

            logger.debug("Successfully created directory: \(resolvedPath)")

            let result: [String: Any] = [
                "success": true,
                "path": resolvedPath,
                "created": true,
                "message": "Directory created successfully"
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "Failed to encode result")
                )
            }

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: jsonString, mimeType: "application/json")
            )
        } catch {
            logger.error("Failed to create directory: \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to create directory: \(error.localizedDescription)")
            )
        }
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard let dirPath = parameters["dirPath"] as? String, !dirPath.isEmpty else {
            return false
        }
        return true
    }
}
