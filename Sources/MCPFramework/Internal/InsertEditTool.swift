// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP tool for inserting or editing text at specific line numbers.
public class InsertEditTool: MCPTool, @unchecked Sendable {
    public let name = "insert_edit_into_file"
    public let description = "Insert or replace text at a specific line number in a file. Supports both inserting new lines and replacing existing lines. Uses 1-based line numbering. Automatically creates backups and supports atomic writes with rollback."

    public enum OperationType: String, Codable {
        case insert
        case replace
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "filePath": MCPToolParameter(
                type: .string,
                description: "Absolute path to file",
                required: true
            ),
            "lineNumber": MCPToolParameter(
                type: .integer,
                description: "1-based line number",
                required: true
            ),
            "newText": MCPToolParameter(
                type: .string,
                description: "Text to insert or use as replacement",
                required: true
            ),
            "operation": MCPToolParameter(
                type: .string,
                description: "Operation type: 'insert' or 'replace'",
                required: true,
                enumValues: ["insert", "replace"]
            ),
            "confirm": MCPToolParameter(
                type: .boolean,
                description: "SECURITY: Must be true to modify file contents",
                required: false
            )
        ]
    }

    public struct InsertEditResult: Codable {
        let success: Bool
        let filePath: String
        let operation: String
        let lineNumber: Int
        let linesModified: Int
        let backupPath: String?
        let error: String?
    }

    private let safety = FileOperationsSafety()
    private let logger = Logger(label: "com.sam.mcp.InsertEditTool")

    /// SECURITY: Rate limiting for destructive operations.
    private var lastDestructiveOperation: Date?
    private let destructiveOperationCooldown: TimeInterval = 5.0

    public init() {}

    public func initialize() async throws {
        logger.debug("InsertEditTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard let filePath = parameters["filePath"] as? String, !filePath.isEmpty else {
            throw MCPError.invalidParameters("filePath parameter is required")
        }
        guard let lineNumber = parameters["lineNumber"] as? Int, lineNumber >= 1 else {
            throw MCPError.invalidParameters("lineNumber parameter is required and must be >= 1")
        }
        guard let _ = parameters["newText"] as? String else {
            throw MCPError.invalidParameters("newText parameter is required")
        }
        guard let operationString = parameters["operation"] as? String,
              OperationType(rawValue: operationString.lowercased()) != nil else {
            throw MCPError.invalidParameters("operation parameter is required and must be 'insert' or 'replace'")
        }
        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// ====================================================================== SECURITY: Path Authorization Check ====================================================================== Block operations outside working directory UNLESS user authorized.
        let operationKey = "file_operations.insert_edit"
        /// Use centralized authorization guard.
        let authResult = MCPAuthorizationGuard.checkPathAuthorization(
            path: parameters["filePath"] as? String ?? "",
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
                suggestedPrompt: "Edit file [\(parameters["filePath"] as? String ?? "file")]?"
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

        /// ====================================================================== SECURITY LAYER 3: Rate Limiting ====================================================================== Prevent rapid-fire file editing.
        if let lastOperation = lastDestructiveOperation {
            let timeSinceLastOperation = Date().timeIntervalSince(lastOperation)
            if timeSinceLastOperation < destructiveOperationCooldown {
                let waitTime = destructiveOperationCooldown - timeSinceLastOperation
                logger.warning("Rate limit triggered for insert_edit_into_file (wait \(String(format: "%.1f", waitTime)) seconds)")
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "SECURITY: Destructive operations rate limited. Please wait \(String(format: "%.1f", waitTime)) seconds before retrying.")
                )
            }
        }

        /// ====================================================================== SECURITY LAYER 4: Audit Logging ====================================================================== Log all file editing operations for security audit trail.
        logger.critical("""
            DESTRUCTIVE_OPERATION_AUTHORIZED:
            operation=insert_edit_into_file
            filePath=\(parameters["filePath"] as? String ?? "unknown")
            lineNumber=\(parameters["lineNumber"] as? Int ?? 0)
            operation_type=\(parameters["operation"] as? String ?? "unknown")
            confirm=true
            isUserInitiated=\(context.isUserInitiated)
            userRequest=\(context.userRequestText ?? "none")
            timestamp=\(ISO8601DateFormatter().string(from: Date()))
            sessionId=\(context.sessionId.uuidString)
            """)

        lastDestructiveOperation = Date()

        /// Parse parameters.
        guard let filePath = parameters["filePath"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: filePath")
            )
        }

        guard let lineNumber = parameters["lineNumber"] as? Int else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: lineNumber")
            )
        }

        guard let newText = parameters["newText"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: newText")
            )
        }

        guard let operationString = parameters["operation"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: operation")
            )
        }

        /// Validate operation type.
        guard let operation = OperationType(rawValue: operationString.lowercased()) else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Invalid operation: must be 'insert' or 'replace'")
            )
        }

        /// Validate line number.
        guard lineNumber >= 1 else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Invalid line number: must be >= 1")
            )
        }

        /// Perform operation.
        do {
            let editResult = try await insertOrEdit(
                filePath: filePath,
                lineNumber: lineNumber,
                newText: newText,
                operation: operation
            )

            /// Encode to JSON.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(editResult)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            if editResult.success {
                return MCPToolResult(
                    toolName: name,
                    success: true,
                    output: MCPOutput(content: jsonString, mimeType: "application/json")
                )
            } else {
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: editResult.error ?? "Unknown error")
                )
            }
        } catch {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Edit failed: \(error.localizedDescription)")
            )
        }
    }

    // MARK: - Insert/Edit Implementation

    /// Insert or replace text at a line number.
    @MainActor
    private func insertOrEdit(
        filePath: String,
        lineNumber: Int,
        newText: String,
        operation: OperationType
    ) async throws -> InsertEditResult {
        /// Validate file for writing.
        let validation = safety.validateFileForWriting(filePath)
        guard validation.isValid else {
            return InsertEditResult(
                success: false,
                filePath: filePath,
                operation: operation.rawValue,
                lineNumber: lineNumber,
                linesModified: 0,
                backupPath: nil,
                error: validation.error
            )
        }

        /// Read original content.
        let (originalContent, readError) = safety.readFile(filePath)
        guard let content = originalContent else {
            return InsertEditResult(
                success: false,
                filePath: filePath,
                operation: operation.rawValue,
                lineNumber: lineNumber,
                linesModified: 0,
                backupPath: nil,
                error: readError
            )
        }

        /// Split into lines.
        var lines = content.components(separatedBy: .newlines)

        /// Validate line number is within bounds.
        let arrayIndex = lineNumber - 1

        switch operation {
        case .insert:
            /// Insert can be at any position from 1 to (lines.count + 1).
            guard lineNumber <= lines.count + 1 else {
                return InsertEditResult(
                    success: false,
                    filePath: filePath,
                    operation: operation.rawValue,
                    lineNumber: lineNumber,
                    linesModified: 0,
                    backupPath: nil,
                    error: "Line number \(lineNumber) out of range (file has \(lines.count) lines)"
                )
            }

            /// Insert new line at specified position.
            if arrayIndex < lines.count {
                lines.insert(newText, at: arrayIndex)
            } else {
                lines.append(newText)
            }

        case .replace:
            /// Replace requires line to exist.
            guard arrayIndex < lines.count else {
                return InsertEditResult(
                    success: false,
                    filePath: filePath,
                    operation: operation.rawValue,
                    lineNumber: lineNumber,
                    linesModified: 0,
                    backupPath: nil,
                    error: "Line number \(lineNumber) out of range (file has \(lines.count) lines)"
                )
            }

            /// Replace existing line.
            lines[arrayIndex] = newText
        }

        /// Reconstruct content.
        let modifiedContent = lines.joined(separator: "\n")

        /// Write modified content with backup.
        let writeResult = safety.atomicWrite(content: modifiedContent, to: filePath, createBackup: true)

        if writeResult.success {
            return InsertEditResult(
                success: true,
                filePath: filePath,
                operation: operation.rawValue,
                lineNumber: lineNumber,
                linesModified: 1,
                backupPath: writeResult.backupPath,
                error: nil
            )
        } else {
            return InsertEditResult(
                success: false,
                filePath: filePath,
                operation: operation.rawValue,
                lineNumber: lineNumber,
                linesModified: 0,
                backupPath: writeResult.backupPath,
                error: writeResult.error
            )
        }
    }
}
