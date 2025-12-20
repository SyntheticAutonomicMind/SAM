// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Storage service for large tool results that exceed provider payload limits **Problem**: GitHub Copilot and other providers return 400 errors when tool results exceed token limits.
public class ToolResultStorage: @unchecked Sendable {
    private let logger = Logger(label: "com.sam.toolresultstorage")
    private let conversationsBaseDir: URL
    private let fileManager = FileManager.default

    /// Threshold for persisting tool results (8K tokens) Results larger than this will be stored to disk instead of sent inline Conservative limit to avoid GitHub Copilot 400 errors.
    public static let persistenceThreshold = 8_000

    /// Preview size sent to provider (1K tokens) Safe limit that fits within context even with multiple tool calls.
    public static let previewTokenLimit = 1_000

    public init(conversationsBaseDir: URL? = nil) {
        /// Default to SAM's conversation storage directory.
        if let baseDir = conversationsBaseDir {
            self.conversationsBaseDir = baseDir
        } else {
            /// ~/Library/Application Support/com.syntheticautonomicmind.sam/conversations.
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.conversationsBaseDir = appSupport
                .appendingPathComponent("com.syntheticautonomicmind.sam")
                .appendingPathComponent("conversations")
        }

        logger.debug("ToolResultStorage initialized with base directory: \(self.conversationsBaseDir.path(percentEncoded: false))")
    }

    /// Persist a tool result to disk - Parameters: - content: The tool result content (UTF-8 text) - toolCallId: Unique identifier for this tool call - conversationId: Conversation owning this result - Returns: Metadata about the persisted result - Throws: `ToolResultStorageError` if persistence fails.
    public func persistResult(
        content: String,
        toolCallId: String,
        conversationId: UUID
    ) throws -> PersistedResultMetadata {
        /// Build path: conversations/<conversationId>/tool_results/<toolCallId>.txt.
        let conversationDir = conversationsBaseDir.appendingPathComponent(conversationId.uuidString)
        let toolResultsDir = conversationDir.appendingPathComponent("tool_results")
        let resultFile = toolResultsDir.appendingPathComponent("\(toolCallId).txt")

        logger.debug("Persisting tool result: \(toolCallId) to \(resultFile.path(percentEncoded: false))")

        /// Create tool_results directory if needed.
        do {
            try fileManager.createDirectory(at: toolResultsDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create tool_results directory: \(error)")
            throw ToolResultStorageError.directoryCreationFailed(error)
        }

        /// Write content to file.
        do {
            try content.write(to: resultFile, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write tool result file: \(error)")
            throw ToolResultStorageError.writeFailed(error)
        }

        /// Calculate metadata.
        let totalLength = content.count
        let created = Date()

        logger.info("Persisted tool result: \(toolCallId), size: \(totalLength) chars")

        return PersistedResultMetadata(
            toolCallId: toolCallId,
            conversationId: conversationId,
            filePath: resultFile.path(percentEncoded: false),
            totalLength: totalLength,
            created: created
        )
    }

    /// Retrieve a chunk of a persisted tool result - Parameters: - toolCallId: Tool call identifier - conversationId: Conversation owning the result (for security validation) - offset: Character offset to start reading from (0-based) - length: Number of characters to read - Returns: Retrieved chunk with metadata - Throws: `ToolResultStorageError` if retrieval fails.
    public func retrieveChunk(
        toolCallId: String,
        conversationId: UUID,
        offset: Int = 0,
        length: Int = 8192
    ) throws -> RetrievedChunk {
        /// Build path.
        let conversationDir = conversationsBaseDir.appendingPathComponent(conversationId.uuidString)
        let toolResultsDir = conversationDir.appendingPathComponent("tool_results")
        let resultFile = toolResultsDir.appendingPathComponent("\(toolCallId).txt")

        logger.debug("Retrieving tool result chunk: \(toolCallId), offset: \(offset), length: \(length)")

        /// Security check: Verify file exists in conversation's directory.
        guard fileManager.fileExists(atPath: resultFile.path(percentEncoded: false)) else {
            logger.warning("Tool result not found: \(toolCallId) in conversation \(conversationId)")
            throw ToolResultStorageError.resultNotFound(toolCallId: toolCallId)
        }

        /// Read file content.
        let fullContent: String
        do {
            fullContent = try String(contentsOf: resultFile, encoding: .utf8)
        } catch {
            logger.error("Failed to read tool result file: \(error)")
            throw ToolResultStorageError.readFailed(error)
        }

        let totalLength = fullContent.count

        /// Validate offset.
        guard offset >= 0 && offset < totalLength else {
            throw ToolResultStorageError.invalidOffset(offset: offset, totalLength: totalLength)
        }

        /// Calculate chunk bounds.
        let startIndex = fullContent.index(fullContent.startIndex, offsetBy: offset)
        let endOffset = min(offset + length, totalLength)
        let endIndex = fullContent.index(fullContent.startIndex, offsetBy: endOffset)

        let chunk = String(fullContent[startIndex..<endIndex])
        let actualLength = chunk.count

        logger.debug("Retrieved chunk: offset=\(offset), requested=\(length), actual=\(actualLength), total=\(totalLength)")

        return RetrievedChunk(
            toolCallId: toolCallId,
            offset: offset,
            length: actualLength,
            totalLength: totalLength,
            content: chunk,
            hasMore: endOffset < totalLength
        )
    }

    /// Check if a tool result exists for the given conversation - Parameters: - toolCallId: Tool call identifier - conversationId: Conversation owning the result - Returns: True if result exists.
    public func resultExists(toolCallId: String, conversationId: UUID) -> Bool {
        let conversationDir = conversationsBaseDir.appendingPathComponent(conversationId.uuidString)
        let toolResultsDir = conversationDir.appendingPathComponent("tool_results")
        let resultFile = toolResultsDir.appendingPathComponent("\(toolCallId).txt")
        return fileManager.fileExists(atPath: resultFile.path(percentEncoded: false))
    }

    /// Delete a specific tool result - Parameters: - toolCallId: Tool call identifier - conversationId: Conversation owning the result - Throws: `ToolResultStorageError` if deletion fails.
    public func deleteResult(toolCallId: String, conversationId: UUID) throws {
        let conversationDir = conversationsBaseDir.appendingPathComponent(conversationId.uuidString)
        let toolResultsDir = conversationDir.appendingPathComponent("tool_results")
        let resultFile = toolResultsDir.appendingPathComponent("\(toolCallId).txt")

        guard fileManager.fileExists(atPath: resultFile.path(percentEncoded: false)) else {
            /// Already deleted - not an error.
            return
        }

        do {
            try fileManager.removeItem(at: resultFile)
            logger.debug("Deleted tool result: \(toolCallId)")
        } catch {
            logger.error("Failed to delete tool result: \(error)")
            throw ToolResultStorageError.deleteFailed(error)
        }
    }

    /// Delete all tool results for a conversation This is called when a conversation is deleted - Parameter conversationId: Conversation to clean up - Throws: `ToolResultStorageError` if cleanup fails.
    public func deleteAllResults(conversationId: UUID) throws {
        let conversationDir = conversationsBaseDir.appendingPathComponent(conversationId.uuidString)
        let toolResultsDir = conversationDir.appendingPathComponent("tool_results")

        guard fileManager.fileExists(atPath: toolResultsDir.path(percentEncoded: false)) else {
            /// No tool results - not an error.
            return
        }

        do {
            try fileManager.removeItem(at: toolResultsDir)
            logger.debug("Deleted all tool results for conversation: \(conversationId)")
        } catch {
            logger.error("Failed to delete tool results directory: \(error)")
            throw ToolResultStorageError.deleteFailed(error)
        }
    }

    /// List all tool result IDs for a conversation - Parameter conversationId: Conversation to query - Returns: Array of tool call IDs with persisted results.
    public func listResults(conversationId: UUID) -> [String] {
        let conversationDir = conversationsBaseDir.appendingPathComponent(conversationId.uuidString)
        let toolResultsDir = conversationDir.appendingPathComponent("tool_results")

        guard let files = try? fileManager.contentsOfDirectory(atPath: toolResultsDir.path(percentEncoded: false)) else {
            return []
        }

        /// Extract toolCallId from filename (remove .txt extension).
        return files
            .filter { $0.hasSuffix(".txt") }
            .map { String($0.dropLast(4)) }
    }

    // MARK: - Unified Tool Result Processing

    /// Maximum size for inline tool results (8KB)
    /// Results larger than this are persisted and replaced with markers
    public static let maxInlineSize = 8192

    /// Process tool result: return inline content or persist and return marker
    /// This is the unified method that replaces the memory-only ToolResultCache
    /// - Parameters:
    ///   - toolCallId: Unique identifier for this tool call
    ///   - content: The tool result content
    ///   - conversationId: Conversation owning this result (required for persistence)
    /// - Returns: Either the original content (if small) or a marker with preview (if large)
    public func processToolResult(
        toolCallId: String,
        content: String,
        conversationId: UUID
    ) -> String {
        let contentSize = content.utf8.count

        if contentSize <= Self.maxInlineSize {
            /// Small enough to send inline
            logger.debug("Tool result inline: toolCallId=\(toolCallId), size=\(contentSize) bytes")
            return content
        }

        /// Persist the full content to disk
        do {
            let metadata = try persistResult(
                content: content,
                toolCallId: toolCallId,
                conversationId: conversationId
            )

            /// Generate preview chunk
            let previewChunk = String(content.prefix(Self.maxInlineSize))

            let marker = """
            [TOOL_RESULT_PREVIEW: First \(Self.maxInlineSize) bytes shown]

            \(previewChunk)

            [TOOL_RESULT_STORED: toolCallId=\(toolCallId), totalLength=\(contentSize), remaining=\(contentSize - Self.maxInlineSize) bytes]

            To read the full result, use:
            read_tool_result(toolCallId: "\(toolCallId)", offset: 0, length: 8192)
            """

            logger.info("Tool result chunked: toolCallId=\(toolCallId), totalSize=\(contentSize) bytes, preview=\(Self.maxInlineSize) bytes, path=\(metadata.filePath)")

            return marker

        } catch {
            /// Fallback: If persistence fails, truncate and log warning
            logger.error("Failed to persist tool result, falling back to truncation: \(error)")
            let truncated = String(content.prefix(Self.maxInlineSize))
            return """
            [WARNING: Tool result too large (\(contentSize) bytes) and persistence failed]

            \(truncated)

            [TRUNCATED: Remaining \(contentSize - Self.maxInlineSize) bytes not shown]
            """
        }
    }
}

// MARK: - Data Structures

/// Metadata about a persisted tool result.
public struct PersistedResultMetadata {
    public let toolCallId: String
    public let conversationId: UUID
    public let filePath: String
    public let totalLength: Int
    public let created: Date

    /// Generate a preview (first 1KB) for inline display.
    public func generatePreview(from content: String) -> String {
        let previewLength = min(1024, content.count)
        let preview = content.prefix(previewLength)
        return String(preview)
    }
}

/// Retrieved chunk of a tool result.
public struct RetrievedChunk {
    public let toolCallId: String
    public let offset: Int
    public let length: Int
    public let totalLength: Int
    public let content: String
    public let hasMore: Bool

    /// Calculate next offset for pagination.
    public var nextOffset: Int? {
        return hasMore ? offset + length : nil
    }
}

// MARK: - Errors

/// Errors that can occur during tool result storage operations.
public enum ToolResultStorageError: Error, LocalizedError {
    case directoryCreationFailed(Error)
    case writeFailed(Error)
    case readFailed(Error)
    case deleteFailed(Error)
    case resultNotFound(toolCallId: String)
    case invalidOffset(offset: Int, totalLength: Int)

    public var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let error):
            return "Failed to create tool results directory: \(error.localizedDescription)"
        case .writeFailed(let error):
            return "Failed to write tool result: \(error.localizedDescription)"
        case .readFailed(let error):
            return "Failed to read tool result: \(error.localizedDescription)"
        case .deleteFailed(let error):
            return "Failed to delete tool result: \(error.localizedDescription)"
        case .resultNotFound(let toolCallId):
            return "Tool result not found: \(toolCallId)"
        case .invalidOffset(let offset, let totalLength):
            return "Invalid offset \(offset) for tool result (total length: \(totalLength))"
        }
    }
}
