// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Storage service for large tool results that exceed provider payload limits
///
/// **Problem**: GitHub Copilot and other providers return 400 errors when tool results
/// exceed token limits. Large results are persisted to disk and a preview is sent inline.
///
/// **Chunk sizing**: Scales dynamically based on the model's context window.
/// Larger context models can handle bigger chunks, reducing round-trips.
///   32k context  -> ~8KB chunks
///   128k context -> ~32KB chunks
///   200k context -> ~32KB chunks (ceiling)
///
/// **Line wrapping**: Lines exceeding 1000 characters are wrapped before persisting
/// to prevent AI models from generating malformed JSON when encountering ultra-long lines.
///
/// **Fuzzy ID matching**: When a toolCallId isn't found exactly, suggests similar IDs
/// using Levenshtein distance to help the AI model recover from minor ID typos.
public class ToolResultStorage: @unchecked Sendable {
    private let logger = Logger(label: "com.sam.toolresultstorage")
    private let conversationsBaseDir: URL
    private let fileManager = FileManager.default

    /// Threshold for persisting tool results (8K tokens)
    /// Results larger than this will be stored to disk instead of sent inline
    /// Conservative limit to avoid GitHub Copilot 400 errors.
    public static let persistenceThreshold = 8_000

    /// Preview size sent to provider (1K tokens)
    /// Safe limit that fits within context even with multiple tool calls.
    public static let previewTokenLimit = 1_000

    /// Hard ceiling for chunk size (32KB)
    /// No single chunk should exceed this regardless of context window.
    public static let maxChunkSize = 32_768

    /// Minimum chunk size (8KB)
    /// Even small context models get at least this much per chunk.
    public static let minChunkSize = 8_192

    /// Maximum line length before wrapping (1000 chars)
    /// Lines longer than this are wrapped to prevent AI model confusion.
    public static let maxLineLength = 1000

    /// Default context window when model info is unavailable
    public static let defaultContextWindow = 32_000

    public init(conversationsBaseDir: URL? = nil) {
        if let baseDir = conversationsBaseDir {
            self.conversationsBaseDir = baseDir
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.conversationsBaseDir = appSupport
                .appendingPathComponent("com.syntheticautonomicmind.sam")
                .appendingPathComponent("conversations")
        }

        logger.debug("ToolResultStorage initialized with base directory: \(self.conversationsBaseDir.path(percentEncoded: false))")
    }

    // MARK: - Dynamic Chunk Sizing

    /// Calculate the default chunk size based on the model's context window.
    ///
    /// Heuristic: ~4 chars per token, use ~2% of context for a single chunk.
    /// This keeps chunks well within budget while scaling with capability.
    ///   32k ctx  -> ~2500 tokens -> ~10k bytes -> clamp to 8192
    ///   128k ctx -> ~10k tokens  -> ~40k bytes -> clamp to 32768
    ///   200k ctx -> ~16k tokens  -> ~64k bytes -> clamp to 32768
    ///
    /// - Parameter contextWindow: Model's context window in tokens
    /// - Returns: Chunk size in bytes (between minChunkSize and maxChunkSize)
    public static func defaultChunkSize(contextWindow: Int = defaultContextWindow) -> Int {
        let size = Int(Double(contextWindow) * 4.0 * 0.02)
        return max(minChunkSize, min(size, maxChunkSize))
    }

    /// Calculate chunk size from a model name by looking up its context window.
    ///
    /// - Parameter modelName: Full model name (e.g., "gpt-4o", "claude-3-5-sonnet")
    /// - Returns: Chunk size in bytes
    public static func chunkSizeForModel(_ modelName: String) -> Int {
        let contextWindow = ModelConfigurationManager.shared.getContextWindow(for: modelName)
            ?? defaultContextWindow
        return defaultChunkSize(contextWindow: contextWindow)
    }

    // MARK: - Line Wrapping

    /// Wrap lines that exceed maxLineLength to prevent AI model confusion.
    /// Ultra-long lines (e.g., minified JSON, base64 data) cause AI models to
    /// generate malformed output when they try to reproduce or reference them.
    ///
    /// - Parameter content: The content to wrap
    /// - Returns: Content with long lines wrapped at maxLineLength
    public static func wrapLongLines(_ content: String) -> String {
        var result = String()
        result.reserveCapacity(content.count)

        var currentLineStart = content.startIndex
        while currentLineStart < content.endIndex {
            // Find end of current line
            let lineEnd = content[currentLineStart...].firstIndex(where: { $0 == "\n" }) ?? content.endIndex
            let line = String(content[currentLineStart..<lineEnd])

            if line.count <= maxLineLength {
                result.append(line)
            } else {
                // Wrap the long line in chunks
                var offset = line.startIndex
                while offset < line.endIndex {
                    let end = line.index(offset, offsetBy: maxLineLength, limitedBy: line.endIndex) ?? line.endIndex
                    result.append(String(line[offset..<end]))
                    if end < line.endIndex {
                        result.append("\n")
                    }
                    offset = end
                }
            }

            // Add the newline if the original line had one
            if lineEnd < content.endIndex {
                result.append("\n")
            }
            currentLineStart = (lineEnd < content.endIndex) ? content.index(after: lineEnd) : lineEnd
        }

        return result
    }

    // MARK: - Fuzzy ID Matching

    /// Find tool result IDs that are similar to the requested ID.
    /// Uses Levenshtein distance to suggest alternatives when an exact match fails.
    ///
    /// - Parameters:
    ///   - toolCallId: The requested tool call ID
    ///   - conversationId: Conversation to search within
    ///   - maxDistance: Maximum edit distance to consider (default: 3)
    /// - Returns: Array of (toolCallId, distance) pairs sorted by similarity
    public func findSimilarResults(
        toolCallId: String,
        conversationId: UUID,
        maxDistance: Int = 3
    ) -> [(id: String, distance: Int)] {
        let availableIds = listResults(conversationId: conversationId)

        return availableIds
            .compactMap { id -> (String, Int)? in
                let distance = Self.levenshtein(id, toolCallId)
                return distance <= maxDistance ? (id, distance) : nil
            }
            .sorted { $0.1 < $1.1 }
    }

    /// Calculate Levenshtein edit distance between two strings.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let aCount = aChars.count
        let bCount = bChars.count

        if aCount == 0 { return bCount }
        if bCount == 0 { return aCount }

        // Use single-row optimization for memory efficiency
        var row = Array(0...bCount)

        for i in 1...aCount {
            var prev = row[0]
            row[0] = i

            for j in 1...bCount {
                let temp = row[j]
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                row[j] = min(
                    row[j] + 1,      // deletion
                    row[j - 1] + 1,  // insertion
                    prev + cost      // substitution
                )
                prev = temp
            }
        }

        return row[bCount]
    }

    // MARK: - Persistence

    /// Persist a tool result to disk.
    /// Content is line-wrapped before storage to prevent AI model confusion.
    ///
    /// - Parameters:
    ///   - content: The tool result content (UTF-8 text)
    ///   - toolCallId: Unique identifier for this tool call
    ///   - conversationId: Conversation owning this result
    /// - Returns: Metadata about the persisted result
    /// - Throws: `ToolResultStorageError` if persistence fails
    public func persistResult(
        content: String,
        toolCallId: String,
        conversationId: UUID
    ) throws -> PersistedResultMetadata {
        let conversationDir = conversationsBaseDir.appendingPathComponent(conversationId.uuidString)
        let toolResultsDir = conversationDir.appendingPathComponent("tool_results")
        let resultFile = toolResultsDir.appendingPathComponent("\(toolCallId).txt")

        logger.debug("Persisting tool result: \(toolCallId) to \(resultFile.path(percentEncoded: false))")

        // Create tool_results directory if needed
        do {
            try fileManager.createDirectory(at: toolResultsDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create tool_results directory: \(error)")
            throw ToolResultStorageError.directoryCreationFailed(error)
        }

        // Wrap long lines before persisting
        let wrappedContent = Self.wrapLongLines(content)

        // Write content to file
        do {
            try wrappedContent.write(to: resultFile, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write tool result file: \(error)")
            throw ToolResultStorageError.writeFailed(error)
        }

        let totalLength = wrappedContent.count
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

    // MARK: - Retrieval

    /// Retrieve a chunk of a persisted tool result.
    ///
    /// - Parameters:
    ///   - toolCallId: Tool call identifier
    ///   - conversationId: Conversation owning the result (for security validation)
    ///   - offset: Character offset to start reading from (0-based)
    ///   - length: Number of characters to read
    /// - Returns: Retrieved chunk with metadata
    /// - Throws: `ToolResultStorageError` if retrieval fails
    public func retrieveChunk(
        toolCallId: String,
        conversationId: UUID,
        offset: Int = 0,
        length: Int = 8192
    ) throws -> RetrievedChunk {
        let conversationDir = conversationsBaseDir.appendingPathComponent(conversationId.uuidString)
        let toolResultsDir = conversationDir.appendingPathComponent("tool_results")
        let resultFile = toolResultsDir.appendingPathComponent("\(toolCallId).txt")

        logger.debug("Retrieving tool result chunk: \(toolCallId), offset: \(offset), length: \(length)")

        // Security check: Verify file exists in conversation's directory
        guard fileManager.fileExists(atPath: resultFile.path(percentEncoded: false)) else {
            logger.warning("Tool result not found: \(toolCallId) in conversation \(conversationId)")

            // Try fuzzy matching to suggest alternatives
            let similar = findSimilarResults(toolCallId: toolCallId, conversationId: conversationId)
            if !similar.isEmpty {
                let suggestions = similar.prefix(3).map { $0.id }.joined(separator: ", ")
                throw ToolResultStorageError.resultNotFoundWithSuggestions(
                    toolCallId: toolCallId,
                    suggestions: suggestions
                )
            }

            throw ToolResultStorageError.resultNotFound(toolCallId: toolCallId)
        }

        // Read file content
        let fullContent: String
        do {
            fullContent = try String(contentsOf: resultFile, encoding: .utf8)
        } catch {
            logger.error("Failed to read tool result file: \(error)")
            throw ToolResultStorageError.readFailed(error)
        }

        let totalLength = fullContent.count

        // Validate offset
        guard offset >= 0 && offset < totalLength else {
            throw ToolResultStorageError.invalidOffset(offset: offset, totalLength: totalLength)
        }

        // Calculate chunk bounds
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

    /// Check if a tool result exists for the given conversation.
    public func resultExists(toolCallId: String, conversationId: UUID) -> Bool {
        let conversationDir = conversationsBaseDir.appendingPathComponent(conversationId.uuidString)
        let toolResultsDir = conversationDir.appendingPathComponent("tool_results")
        let resultFile = toolResultsDir.appendingPathComponent("\(toolCallId).txt")
        return fileManager.fileExists(atPath: resultFile.path(percentEncoded: false))
    }

    /// Delete a specific tool result.
    public func deleteResult(toolCallId: String, conversationId: UUID) throws {
        let conversationDir = conversationsBaseDir.appendingPathComponent(conversationId.uuidString)
        let toolResultsDir = conversationDir.appendingPathComponent("tool_results")
        let resultFile = toolResultsDir.appendingPathComponent("\(toolCallId).txt")

        guard fileManager.fileExists(atPath: resultFile.path(percentEncoded: false)) else {
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

    /// Delete all tool results for a conversation.
    public func deleteAllResults(conversationId: UUID) throws {
        let conversationDir = conversationsBaseDir.appendingPathComponent(conversationId.uuidString)
        let toolResultsDir = conversationDir.appendingPathComponent("tool_results")

        guard fileManager.fileExists(atPath: toolResultsDir.path(percentEncoded: false)) else {
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

    /// List all tool result IDs for a conversation.
    public func listResults(conversationId: UUID) -> [String] {
        let conversationDir = conversationsBaseDir.appendingPathComponent(conversationId.uuidString)
        let toolResultsDir = conversationDir.appendingPathComponent("tool_results")

        guard let files = try? fileManager.contentsOfDirectory(atPath: toolResultsDir.path(percentEncoded: false)) else {
            return []
        }

        return files
            .filter { $0.hasSuffix(".txt") }
            .map { String($0.dropLast(4)) }
    }

    // MARK: - Unified Tool Result Processing

    /// Maximum size for inline tool results (8KB)
    /// Results larger than this are persisted and replaced with markers
    public static let maxInlineSize = 8192

    /// Process tool result: return inline content or persist and return marker.
    /// This is the unified method that replaces the memory-only ToolResultCache.
    ///
    /// - Parameters:
    ///   - toolCallId: Unique identifier for this tool call
    ///   - content: The tool result content
    ///   - conversationId: Conversation owning this result (required for persistence)
    ///   - modelName: Optional model name for dynamic chunk sizing
    /// - Returns: Either the original content (if small) or a marker with preview (if large)
    public func processToolResult(
        toolCallId: String,
        content: String,
        conversationId: UUID,
        modelName: String? = nil
    ) -> String {
        let contentSize = content.utf8.count

        if contentSize <= Self.maxInlineSize {
            logger.debug("Tool result inline: toolCallId=\(toolCallId), size=\(contentSize) bytes")
            return content
        }

        // Persist the full content to disk
        do {
            let metadata = try persistResult(
                content: content,
                toolCallId: toolCallId,
                conversationId: conversationId
            )

            // Calculate dynamic chunk size based on model
            let chunkSize: Int
            if let modelName = modelName {
                chunkSize = Self.chunkSizeForModel(modelName)
            } else {
                chunkSize = Self.minChunkSize
            }

            // Generate preview chunk
            let previewChunk = String(content.prefix(Self.maxInlineSize))

            let marker = """
            [TOOL_RESULT_PREVIEW: First \(Self.maxInlineSize) bytes shown]

            \(previewChunk)

            [TOOL_RESULT_STORED: toolCallId=\(toolCallId), totalLength=\(contentSize), remaining=\(contentSize - Self.maxInlineSize) bytes]

            To read the full result, use:
            file_operations(operation: "read_tool_result", toolCallId: "\(toolCallId)", offset: 0, length: \(chunkSize))
            """

            logger.info("Tool result chunked: toolCallId=\(toolCallId), totalSize=\(contentSize) bytes, preview=\(Self.maxInlineSize) bytes, chunkSize=\(chunkSize), path=\(metadata.filePath)")

            return marker

        } catch {
            // Fallback: If persistence fails, truncate and log warning
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
    case resultNotFoundWithSuggestions(toolCallId: String, suggestions: String)
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
        case .resultNotFoundWithSuggestions(let toolCallId, let suggestions):
            return "Tool result not found: \(toolCallId)\n\nDid you mean one of these?\n\(suggestions)"
        case .invalidOffset(let offset, let totalLength):
            return "Invalid offset \(offset) for tool result (total length: \(totalLength))"
        }
    }
}