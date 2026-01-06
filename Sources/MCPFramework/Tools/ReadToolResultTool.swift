// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConfigurationSystem
import Logging

/// MCP tool for reading persisted tool results in chunks **Purpose**: Large tool results (>16KB) are automatically persisted to disk to avoid provider 400 errors.
public class ReadToolResultTool: MCPTool, @unchecked Sendable {
    public let name = "read_tool_result"
    public let description = """
    Read a persisted tool result in chunks. Use when a tool returns a reference to stored content instead of inline data.

    **When to Use**:
    - Tool response contains `[TOOL_RESULT_STORED]` marker
    - Tool response includes `toolCallId` and `totalLength` metadata
    - You need to access large web scraping/research results (>16KB)

    **How to Use Efficiently**:
    - ALWAYS check if the first chunk contains a complete answer or summary
    - If first chunk fully answers the user's question, respond immediately - DO NOT read more chunks
    - Only continue reading additional chunks if:
      * The summary/answer is incomplete or missing key details
      * User explicitly requested the full/raw output
      * You need specific information not in the first chunk
    - Most research results include complete summaries in first chunk - check before continuing

    **Chunked Retrieval**:
    - Default chunk size: 8192 characters (8KB)
    - Maximum chunk size: 32768 characters (32KB)
    - Use `offset` + `length` for pagination
    - Check `hasMore` in response to continue reading

    **Example Workflow**:
    1. web_operations returns: "Preview: ... [TOOL_RESULT_STORED: toolCallId=abc123, totalLength=150000]"
    2. Read first chunk: read_tool_result(toolCallId: "abc123", offset: 0, length: 8192)
    3. Read next chunk: read_tool_result(toolCallId: "abc123", offset: 8192, length: 8192)
    4. Continue until hasMore=false

    **Parameters**:
    - toolCallId (required): Tool call ID from the stored result message
    - offset (optional): Character offset to start reading from (default: 0)
    - length (optional): Number of characters to read (default: 8192, max: 32768)

    **Security**: You can only access results from your own conversation. Cross-conversation access is denied.
    """

    public var parameters: [String: MCPToolParameter] {
        return [
            "toolCallId": MCPToolParameter(
                type: .string,
                description: "Tool call ID from the stored result message",
                required: true
            ),
            "offset": MCPToolParameter(
                type: .integer,
                description: "Character offset to start reading from (0-based, default: 0)",
                required: false
            ),
            "length": MCPToolParameter(
                type: .integer,
                description: "Number of characters to read (default: 8192, max: 32768)",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.ReadToolResult")
    private let storage: ToolResultStorage

    public init(storage: ToolResultStorage? = nil) {
        self.storage = storage ?? ToolResultStorage()
        logger.debug("ReadToolResultTool initialized")
    }

    public func initialize() async throws {
        logger.debug("ReadToolResultTool ready")
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        logger.debug("ReadToolResultTool executing")

        /// Extract parameters.
        guard let toolCallId = parameters["toolCallId"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    ERROR: Missing required parameter 'toolCallId'

                    Usage:
                    {
                        "toolCallId": "call_abc123",
                        "offset": 0,
                        "length": 8192
                    }
                    """,
                    mimeType: "text/plain"
                )
            )
        }

        let offset = parameters["offset"] as? Int ?? 0
        let requestedLength = parameters["length"] as? Int ?? 8192

        /// Enforce maximum chunk size.
        let maxChunkSize = 32_768
        let length = min(requestedLength, maxChunkSize)

        if requestedLength > maxChunkSize {
            logger.warning("Requested length \(requestedLength) exceeds max \(maxChunkSize), capped to \(maxChunkSize)")
        }

        /// Get conversation ID from context.
        guard let conversationId = context.conversationId else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: "ERROR: No conversation ID in context. Cannot retrieve tool result.",
                    mimeType: "text/plain"
                )
            )
        }

        /// Retrieve chunk.
        do {
            let chunk = try storage.retrieveChunk(
                toolCallId: toolCallId,
                conversationId: conversationId,
                offset: offset,
                length: length
            )

            logger.debug("Retrieved chunk: offset=\(chunk.offset), length=\(chunk.length), hasMore=\(chunk.hasMore)")

            /// Format response.
            var responseLines: [String] = []
            responseLines.append("[TOOL_RESULT_CHUNK]")
            responseLines.append("Tool Call ID: \(chunk.toolCallId)")
            responseLines.append("Offset: \(chunk.offset)")
            responseLines.append("Length: \(chunk.length)")
            responseLines.append("Total Length: \(chunk.totalLength)")
            responseLines.append("Has More: \(chunk.hasMore)")
            if let nextOffset = chunk.nextOffset {
                responseLines.append("Next Offset: \(nextOffset)")
            }
            responseLines.append("")
            responseLines.append("--- Content ---")
            responseLines.append(chunk.content)
            responseLines.append("--- End Content ---")

            if chunk.hasMore {
                responseLines.append("")
                responseLines.append("To read next chunk:")
                responseLines.append("read_tool_result(toolCallId: \"\(chunk.toolCallId)\", offset: \(chunk.nextOffset!), length: \(length))")
            } else {
                responseLines.append("")
                responseLines.append("SUCCESS: All content retrieved (no more chunks)")
            }

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(
                    content: responseLines.joined(separator: "\n"),
                    mimeType: "text/plain"
                ),
                metadata: MCPResultMetadata(
                    additionalContext: [
                        "toolCallId": toolCallId,
                        "offset": String(chunk.offset),
                        "length": String(chunk.length),
                        "totalLength": String(chunk.totalLength),
                        "hasMore": String(chunk.hasMore)
                    ]
                )
            )

        } catch ToolResultStorageError.resultNotFound(let toolCallId) {
            logger.warning("Tool result not found: \(toolCallId)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    ERROR: Tool result not found: \(toolCallId)

                    This result may have been:
                    - Already deleted
                    - Never persisted (small enough to send inline)
                    - From a different conversation (cross-conversation access denied)

                    Check that the toolCallId is correct and the result was actually persisted.
                    """,
                    mimeType: "text/plain"
                )
            )

        } catch ToolResultStorageError.invalidOffset(let offset, let totalLength) {
            logger.warning("Invalid offset: \(offset) for result with length \(totalLength)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    ERROR: Invalid offset \(offset)

                    The tool result has \(totalLength) characters total.
                    Valid offset range: 0 to \(totalLength - 1)

                    Start reading from offset 0:
                    read_tool_result(toolCallId: "\(toolCallId)", offset: 0, length: \(length))
                    """,
                    mimeType: "text/plain"
                )
            )

        } catch {
            logger.error("Failed to retrieve tool result: \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: "ERROR: Failed to retrieve tool result: \(error.localizedDescription)",
                    mimeType: "text/plain"
                )
            )
        }
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard let toolCallId = parameters["toolCallId"] as? String, !toolCallId.isEmpty else {
            throw MCPError.invalidParameters("toolCallId is required and must be a non-empty string")
        }

        if let offset = parameters["offset"] as? Int, offset < 0 {
            throw MCPError.invalidParameters("offset must be >= 0")
        }

        if let length = parameters["length"] as? Int, length <= 0 {
            throw MCPError.invalidParameters("length must be > 0")
        }

        return true
    }
}
