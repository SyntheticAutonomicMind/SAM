// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Centralized authorization guard for MCP tool operations AUTHORIZATION POLICY: - Operations INSIDE working directory: ALLOWED (unrestricted access to safe workspace) - Operations OUTSIDE working directory: REQUIRE user authorization This provides a secure sandbox model where agents have full control within their designated workspace but must ask permission for operations outside that scope.
public struct MCPAuthorizationGuard {
    private static let logger = Logger(label: "com.sam.mcp.AuthorizationGuard")

    /// Resolve a path (relative or absolute) against the working directory
    /// This is the CANONICAL path resolution function - all MCP tools should use this.
    /// - Parameters:
    ///   - path: The path to resolve (relative or absolute)
    ///   - workingDirectory: The working directory to use as base for relative paths
    /// - Returns: Fully resolved absolute path
    public static func resolvePath(_ path: String, workingDirectory: String?) -> String {
        /// Expand tilde first.
        let expandedPath = NSString(string: path).expandingTildeInPath

        /// Check if path is absolute (starts with /).
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardized.path
        }

        /// Path is relative - resolve against working directory if available.
        if let workingDir = workingDirectory {
            let expandedWorkingDir = NSString(string: workingDir).expandingTildeInPath
            let resolvedPath = URL(fileURLWithPath: expandedWorkingDir)
                .appendingPathComponent(expandedPath)
                .standardized
                .path

            logger.debug("Resolved relative path against working directory", metadata: [
                "relativePath": .string(path),
                "workingDirectory": .string(expandedWorkingDir),
                "resolvedPath": .string(resolvedPath)
            ])

            return resolvedPath
        }

        /// No working directory - resolve against current directory (fallback).
        return URL(fileURLWithPath: expandedPath).standardized.path
    }

    /// Check if a file path operation requires user authorization - Parameters: - path: The file path to check (will be expanded and normalized) - workingDirectory: The conversation's working directory (safe workspace) - conversationId: The conversation context - operation: The operation key (e.g., "file_operations.create_file") - isUserInitiated: If true, bypass authorization (user directly initiated) - Returns: Authorization result (allowed, denied, or requires authorization).
    public static func checkPathAuthorization(
        path: String,
        workingDirectory: String?,
        conversationId: UUID?,
        operation: String,
        isUserInitiated: Bool
    ) -> AuthorizationResult {
        /// User-initiated operations always allowed.
        if isUserInitiated {
            logger.debug("Operation allowed - user initiated", metadata: [
                "operation": .string(operation),
                "path": .string(path)
            ])
            return .allowed(reason: "User-initiated operation")
        }

        /// Resolve path against working directory (handles relative paths properly).
        let normalizedPath = resolvePath(path, workingDirectory: workingDirectory)

        /// If no working directory configured, require authorization.
        guard let workingDirStr = workingDirectory else {
            logger.debug("Authorization required - no working directory configured", metadata: [
                "operation": .string(operation),
                "path": .string(normalizedPath)
            ])
            return .requiresAuthorization(reason: "No working directory configured for this conversation")
        }

        /// Expand and normalize working directory path.
        let expandedWorkingDir = NSString(string: workingDirStr).expandingTildeInPath
        let workingDirPath = URL(fileURLWithPath: expandedWorkingDir).standardized.path

        /// Proper subdirectory containment check BUG: hasPrefix() alone is insufficient - "/workspace/conv-123" would match "/workspace/conv-123-other" SOLUTION: Check for exact match OR prefix with trailing slash to ensure directory boundary.
        let isInsideWorkingDirectory = (normalizedPath == workingDirPath) ||
                                        normalizedPath.hasPrefix(workingDirPath + "/")

        logger.debug("Authorization check for path", metadata: [
            "operation": .string(operation),
            "path": .string(path),
            "normalizedPath": .string(normalizedPath),
            "workingDirectory": .string(workingDirPath),
            "isInside": .stringConvertible(isInsideWorkingDirectory)
        ])

        if isInsideWorkingDirectory {
            /// Path is inside working directory - ALLOW unrestricted access (including all subdirectories).
            logger.debug("Operation allowed - inside working directory", metadata: [
                "operation": .string(operation),
                "path": .string(normalizedPath),
                "workingDirectory": .string(workingDirPath)
            ])
            return .allowed(reason: "Path is inside working directory")
        }

        /// Path is outside working directory - check if authorized.
        guard let convId = conversationId else {
            logger.warning("Authorization denied - no conversation context", metadata: [
                "operation": .string(operation),
                "path": .string(normalizedPath)
            ])
            return .denied(reason: "No conversation context available")
        }

        /// Check if operation is already authorized via AuthorizationManager.
        if AuthorizationManager.shared.isAuthorized(conversationId: convId, operation: operation) {
            logger.debug("Operation allowed - previously authorized", metadata: [
                "conversationId": .string(convId.uuidString),
                "operation": .string(operation),
                "path": .string(normalizedPath)
            ])
            return .allowed(reason: "User previously authorized this operation")
        }

        /// Require authorization for operations outside working directory.
        logger.debug("Authorization required - outside working directory", metadata: [
            "operation": .string(operation),
            "path": .string(normalizedPath),
            "workingDirectory": .string(workingDirPath)
        ])
        return .requiresAuthorization(
            reason: "Path '\(normalizedPath)' is outside working directory '\(workingDirPath)'"
        )
    }

    /// Check if a command execution requires user authorization - Parameters: - command: The command to execute - workingDirectory: The conversation's working directory (safe workspace) - conversationId: The conversation context - operation: The operation key (e.g., "terminal_operations.run_command") - isUserInitiated: If true, bypass authorization (user directly initiated) - Returns: Authorization result (allowed, denied, or requires authorization).
    public static func checkCommandAuthorization(
        command: String,
        workingDirectory: String?,
        conversationId: UUID?,
        operation: String,
        isUserInitiated: Bool
    ) -> AuthorizationResult {
        /// User-initiated operations always allowed.
        if isUserInitiated {
            logger.debug("Command allowed - user initiated", metadata: [
                "operation": .string(operation),
                "command": .string(command)
            ])
            return .allowed(reason: "User-initiated operation")
        }

        /// If no working directory configured, require authorization.
        guard let workingDirStr = workingDirectory else {
            logger.debug("Authorization required - no working directory configured", metadata: [
                "operation": .string(operation),
                "command": .string(command)
            ])
            return .requiresAuthorization(reason: "No working directory configured for this conversation")
        }

        /// Commands executed within working directory are ALLOWED (they still run in sandbox environment with proper working directory).
        logger.debug("Command allowed - will execute in working directory", metadata: [
            "operation": .string(operation),
            "command": .string(command),
            "workingDirectory": .string(workingDirStr)
        ])

        /// Check if operation is already authorized via AuthorizationManager.
        if let convId = conversationId,
           AuthorizationManager.shared.isAuthorized(conversationId: convId, operation: operation) {
            logger.debug("Command allowed - previously authorized", metadata: [
                "conversationId": .string(convId.uuidString),
                "operation": .string(operation)
            ])
            return .allowed(reason: "User previously authorized this operation")
        }

        /// For now, allow all commands within working directory context Future enhancement: could parse command and check if it references paths outside working directory.
        return .allowed(reason: "Command will execute in working directory sandbox")
    }

    /// Generate user-friendly authorization error message.
    public static func authorizationError(
        operation: String,
        reason: String,
        suggestedPrompt: String? = nil
    ) -> [String: Any] {
        var message = """
            Operation '\(operation)' requires user authorization.
            Reason: \(reason)

            """

        if let prompt = suggestedPrompt {
            message += """
                Please use user_collaboration tool to ask permission:
                {
                  "prompt": "\(prompt)",
                  "authorize_operation": "\(operation)"
                }
                """
        } else {
            message += """
                Please use user_collaboration tool to ask permission:
                {
                  "prompt": "May I perform \(operation)?",
                  "authorize_operation": "\(operation)"
                }
                """
        }

        return [
            "success": false,
            "error": message
        ]
    }
}

/// Result of authorization check.
public enum AuthorizationResult {
    case allowed(reason: String)
    case denied(reason: String)
    case requiresAuthorization(reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var reason: String {
        switch self {
        case .allowed(let reason): return reason
        case .denied(let reason): return reason
        case .requiresAuthorization(let reason): return reason
        }
    }
}
