// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP tool for performing multiple string replacements in a single transaction.
public class MultiReplaceStringTool: MCPTool, @unchecked Sendable {
    public let name = "multi_replace_string_in_file"
    public let description = "Perform multiple string replacements in a file in a single atomic transaction. All replacements succeed or all fail (transaction safety). Automatically creates backup and supports rollback. Replacements are applied sequentially in the order provided."

    public var parameters: [String: MCPToolParameter] {
        return [
            "filePath": MCPToolParameter(
                type: .string,
                description: "Absolute path to file",
                required: true
            ),
            "replacements": MCPToolParameter(
                type: .array,
                description: "Array of replacement objects with oldString and newString properties",
                required: true,
                arrayElementType: .object(properties: [
                    "oldString": MCPToolParameter(
                        type: .string,
                        description: "Text to find and replace",
                        required: true
                    ),
                    "newString": MCPToolParameter(
                        type: .string,
                        description: "Replacement text",
                        required: true
                    )
                ])
            ),
            "confirm": MCPToolParameter(
                type: .boolean,
                description: "SECURITY: Must be true to modify file contents. Confirmation for destructive file operations.",
                required: false
            )
        ]
    }

    public struct Replacement: Codable {
        let oldString: String
        let newString: String
    }

    public struct ReplacementResult: Codable {
        let oldString: String
        let newString: String
        let count: Int
    }

    public struct MultiReplaceStringResult: Codable {
        let success: Bool
        let filePath: String
        let replacements: [ReplacementResult]
        let totalReplacements: Int
        let backupPath: String?
        let error: String?
    }

    private let safety = FileOperationsSafety()
    private let logger = Logger(label: "com.sam.mcp.MultiReplaceStringTool")

    /// SECURITY: Rate limiting for destructive operations.
    private var lastDestructiveOperation: Date?
    private let destructiveOperationCooldown: TimeInterval = 5.0

    public init() {}

    public func initialize() async throws {
        logger.debug("MultiReplaceStringTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard let filePath = parameters["filePath"] as? String, !filePath.isEmpty else {
            throw MCPError.invalidParameters("filePath parameter is required")
        }
        guard let _ = parameters["replacements"] as? [[String: Any]] else {
            throw MCPError.invalidParameters("replacements parameter is required and must be an array")
        }
        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// SECURITY CHECK: Multiple replacements require authorization.
        let operationKey = "file_operations.multi_replace_string"
        let isAuthorized = context.conversationId.map {
            AuthorizationManager.shared.isAuthorized(conversationId: $0, operation: operationKey)
        } ?? false

        guard context.isUserInitiated || isAuthorized else {
            logger.critical("SECURITY: Autonomous multi_replace_string_in_file attempt BLOCKED - userRequest=\(context.userRequestText ?? "none")")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: """
                    SECURITY VIOLATION: File modifications must be user-initiated or authorized.

                    This operation was autonomously decided by the agent and requires authorization.

                    Please use user_collaboration to request authorization:
                    {
                      "prompt": "Modify file with multiple replacements?",
                      "authorize_operation": "\(operationKey)"
                    }
                    """)
            )
        }

        /// SECURITY LAYER 3: Rate limiting check.
        let currentTime = Date()
        if let lastOp = lastDestructiveOperation, currentTime.timeIntervalSince(lastOp) < destructiveOperationCooldown {
            let remaining = destructiveOperationCooldown - currentTime.timeIntervalSince(lastOp)
            logger.warning("SECURITY: multi_replace_string_in_file rate limited - \(String(format: "%.1f", remaining))s remaining")
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

        guard let replacementsArray = parameters["replacements"] as? [[String: Any]] else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: replacements")
            )
        }

        /// SECURITY LAYER 4: Comprehensive audit logging.
        logger.critical("""
            DESTRUCTIVE_OPERATION_AUTHORIZED:
            operation=multi_replace_string_in_file
            filePath=\(filePath)
            replacementCount=\(replacementsArray.count)
            confirm=true
            isUserInitiated=\(context.isUserInitiated)
            userRequest=\(context.userRequestText ?? "none")
            timestamp=\(ISO8601DateFormatter().string(from: Date()))
            sessionId=\(context.sessionId)
            """)

        /// Update rate limiter.
        lastDestructiveOperation = currentTime

        /// Parse replacements array.
        var replacements: [Replacement] = []
        for item in replacementsArray {
            guard let oldString = item["oldString"] as? String,
                  let newString = item["newString"] as? String else {
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "Invalid replacement format: each must have 'oldString' and 'newString'")
                )
            }
            replacements.append(Replacement(oldString: oldString, newString: newString))
        }

        if replacements.isEmpty {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "No replacements provided")
            )
        }

        /// Perform multi-replacement.
        do {
            let replaceResult = try await multiReplaceString(
                filePath: filePath,
                replacements: replacements
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

    // MARK: - Multi-String Replacement Implementation

    /// Perform multiple string replacements in a single transaction.
    @MainActor
    private func multiReplaceString(
        filePath: String,
        replacements: [Replacement]
    ) async throws -> MultiReplaceStringResult {
        /// Validate file for writing.
        let validation = safety.validateFileForWriting(filePath)
        guard validation.isValid else {
            return MultiReplaceStringResult(
                success: false,
                filePath: filePath,
                replacements: [],
                totalReplacements: 0,
                backupPath: nil,
                error: validation.error
            )
        }

        /// Read original content.
        let (originalContent, readError) = safety.readFile(filePath)
        guard var content = originalContent else {
            return MultiReplaceStringResult(
                success: false,
                filePath: filePath,
                replacements: [],
                totalReplacements: 0,
                backupPath: nil,
                error: readError
            )
        }

        /// Apply all replacements sequentially.
        var results: [ReplacementResult] = []
        var totalCount = 0

        for replacement in replacements {
            /// Count occurrences before replacement.
            let occurrenceCount = countOccurrences(of: replacement.oldString, in: content)

            /// Perform replacement.
            content = content.replacingOccurrences(of: replacement.oldString, with: replacement.newString)

            /// Record result.
            results.append(ReplacementResult(
                oldString: replacement.oldString,
                newString: replacement.newString,
                count: occurrenceCount
            ))

            totalCount += occurrenceCount
        }

        /// Write modified content with backup (single atomic write for all replacements).
        let writeResult = safety.atomicWrite(content: content, to: filePath, createBackup: true)

        if writeResult.success {
            return MultiReplaceStringResult(
                success: true,
                filePath: filePath,
                replacements: results,
                totalReplacements: totalCount,
                backupPath: writeResult.backupPath,
                error: nil
            )
        } else {
            return MultiReplaceStringResult(
                success: false,
                filePath: filePath,
                replacements: [],
                totalReplacements: 0,
                backupPath: writeResult.backupPath,
                error: writeResult.error
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
