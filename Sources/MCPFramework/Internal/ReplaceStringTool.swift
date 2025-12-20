// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP tool for replacing text in files with safety features.
public class ReplaceStringTool: MCPTool, @unchecked Sendable {
    public let name = "replace_string_in_file"
    public let description = "Replace all occurrences of an exact string in a file. The search is whitespace-sensitive and case-sensitive. Automatically creates backups and supports atomic writes with rollback on failure. Optionally validates expected number of replacements."

    public var parameters: [String: MCPToolParameter] {
        return [
            "filePath": MCPToolParameter(
                type: .string,
                description: "Absolute path to file",
                required: true
            ),
            "oldString": MCPToolParameter(
                type: .string,
                description: "Exact text to replace",
                required: true
            ),
            "newString": MCPToolParameter(
                type: .string,
                description: "Replacement text",
                required: true
            ),
            "expectedReplacements": MCPToolParameter(
                type: .integer,
                description: "Optional: expected replacement count for validation",
                required: false
            ),
            "confirm": MCPToolParameter(
                type: .boolean,
                description: "SECURITY: Must be true to modify file contents. Confirmation for destructive file operations.",
                required: false
            )
        ]
    }

    public struct ReplaceStringResult: Codable {
        let success: Bool
        let filePath: String
        let replacementCount: Int
        let backupPath: String?
        let error: String?
        let validated: Bool
    }

    private let safety = FileOperationsSafety()
    private let logger = Logger(label: "com.sam.mcp.ReplaceStringTool")

    /// SECURITY: Rate limiting for destructive operations.
    private var lastDestructiveOperation: Date?
    private let destructiveOperationCooldown: TimeInterval = 5.0

    public init() {}

    public func initialize() async throws {
        logger.debug("ReplaceStringTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard let filePath = parameters["filePath"] as? String, !filePath.isEmpty else {
            throw MCPError.invalidParameters("filePath parameter is required")
        }
        guard let oldString = parameters["oldString"] as? String, !oldString.isEmpty else {
            throw MCPError.invalidParameters("oldString parameter is required")
        }
        guard parameters["newString"] is String else {
            throw MCPError.invalidParameters("newString parameter is required")
        }
        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// SECURITY CHECK: File modification requires authorization Block autonomous file replacement UNLESS user authorized via user_collaboration.
        let operationKey = "file_operations.replace_string"
        let isAuthorized = context.conversationId.map {
            AuthorizationManager.shared.isAuthorized(conversationId: $0, operation: operationKey)
        } ?? false

        guard context.isUserInitiated || isAuthorized else {
            logger.critical("SECURITY: Autonomous replace_string_in_file attempt BLOCKED - userRequest=\(context.userRequestText ?? "none")")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: """
                    SECURITY VIOLATION: File modifications must be user-initiated or authorized.

                    This operation was autonomously decided by the agent and requires authorization.

                    Please use user_collaboration to request authorization:
                    {
                      "prompt": "Modify file?",
                      "authorize_operation": "\(operationKey)"
                    }
                    """)
            )
        }

        /// SECURITY LAYER 3: Rate limiting check.
        let currentTime = Date()
        if let lastOp = lastDestructiveOperation, currentTime.timeIntervalSince(lastOp) < destructiveOperationCooldown {
            let remaining = destructiveOperationCooldown - currentTime.timeIntervalSince(lastOp)
            logger.warning("SECURITY: replace_string_in_file rate limited - \(String(format: "%.1f", remaining))s remaining")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "SECURITY: Destructive operations rate limited. Please wait \(String(format: "%.0f", remaining)) seconds before retrying.")
            )
        }

        /// Parse parameters.
        guard let filePath = parameters["filePath"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: filePath")
            )
        }

        guard let oldString = parameters["oldString"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: oldString")
            )
        }

        guard let newString = parameters["newString"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: newString")
            )
        }

        let expectedReplacements = parameters["expectedReplacements"] as? Int

        /// SECURITY LAYER 4: Comprehensive audit logging.
        logger.critical("""
            DESTRUCTIVE_OPERATION_AUTHORIZED:
            operation=replace_string_in_file
            filePath=\(filePath)
            confirm=true
            isUserInitiated=\(context.isUserInitiated)
            userRequest=\(context.userRequestText ?? "none")
            timestamp=\(ISO8601DateFormatter().string(from: Date()))
            sessionId=\(context.sessionId)
            """)

        /// Update rate limiter.
        lastDestructiveOperation = currentTime

        /// Perform replacement.
        do {
            let replaceResult = try await replaceString(
                filePath: filePath,
                oldString: oldString,
                newString: newString,
                expectedReplacements: expectedReplacements
            )

            /// Encode to JSON.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(replaceResult)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            if replaceResult.success {
                return MCPToolResult(
                    toolName: name,
                    success: true,
                    output: MCPOutput(content: jsonString, mimeType: "application/json")
                )
            } else {
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: replaceResult.error ?? "Unknown error")
                )
            }
        } catch {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Replace failed: \(error.localizedDescription)")
            )
        }
    }

    // MARK: - String Replacement Implementation

    /// Replace all occurrences of a string in a file.
    @MainActor
    private func replaceString(
        filePath: String,
        oldString: String,
        newString: String,
        expectedReplacements: Int?
    ) async throws -> ReplaceStringResult {
        /// Validate file for writing.
        let validation = safety.validateFileForWriting(filePath)
        guard validation.isValid else {
            return ReplaceStringResult(
                success: false,
                filePath: filePath,
                replacementCount: 0,
                backupPath: nil,
                error: validation.error,
                validated: false
            )
        }

        /// Read original content.
        let (originalContent, readError) = safety.readFile(filePath)
        guard let content = originalContent else {
            return ReplaceStringResult(
                success: false,
                filePath: filePath,
                replacementCount: 0,
                backupPath: nil,
                error: readError,
                validated: false
            )
        }

        /// Count occurrences before replacement.
        let occurrenceCount = countOccurrences(of: oldString, in: content)

        /// Validate expected count if provided.
        if let expected = expectedReplacements, expected != occurrenceCount {
            return ReplaceStringResult(
                success: false,
                filePath: filePath,
                replacementCount: 0,
                backupPath: nil,
                error: "Expected \(expected) replacements but found \(occurrenceCount) occurrences",
                validated: false
            )
        }

        /// Perform replacement.
        let modifiedContent = content.replacingOccurrences(of: oldString, with: newString)

        /// Write modified content with backup.
        let writeResult = safety.atomicWrite(content: modifiedContent, to: filePath, createBackup: true)

        if writeResult.success {
            return ReplaceStringResult(
                success: true,
                filePath: filePath,
                replacementCount: occurrenceCount,
                backupPath: writeResult.backupPath,
                error: nil,
                validated: expectedReplacements != nil
            )
        } else {
            return ReplaceStringResult(
                success: false,
                filePath: filePath,
                replacementCount: 0,
                backupPath: writeResult.backupPath,
                error: writeResult.error,
                validated: false
            )
        }
    }

    /// Count occurrences of a string in content.
    private func countOccurrences(of searchString: String, in content: String) -> Int {
        var count = 0
        var searchRange = content.startIndex..<content.endIndex

        while let range = content.range(of: searchString, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<content.endIndex
        }

        return count
    }
}
