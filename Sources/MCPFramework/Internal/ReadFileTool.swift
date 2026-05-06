// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

/// ReadFileTool - Read file contents with optional pagination Reads the contents of a file and returns it as a string.
/// Supports binary file detection with helpful error messages and ToolResultStorage for large files.
public class ReadFileTool: MCPTool, @unchecked Sendable {
    public let name = "read_file"
    public let description = """
    Read the contents of a file. Line numbers are 1-indexed. This tool will truncate its output at 2000 lines \
    and may be called repeatedly with offset and limit parameters to read larger files in chunks.
    
    For very large files, results are automatically persisted to disk and can be read with read_tool_result.
    Binary files (images, compiled binaries, etc.) are detected and a helpful error is returned.
    """

    private let fileOperationsSafety = FileOperationsSafety()
    private let logger = Logger(label: "com.sam.mcp.ReadFileTool")
    private let storage = ToolResultStorage()

    /// Maximum tokens for inline results (50K tokens = ~200K chars).
    /// Results exceeding this are persisted to disk via ToolResultStorage.
    private static let inlineTokenLimit = 50_000

    /// Binary file extensions that cannot be read as text.
    private static let binaryExtensions: Set<String> = [
        "pdf", "docx", "xlsx", "pptx", "doc", "xls", "ppt",
        "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg", "iso",
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "ico", "webp",
        "mp3", "mp4", "avi", "mov", "wmv", "flv", "mkv", "wav", "aac", "flac",
        "o", "so", "dylib", "dll", "exe", "bin", "dat",
        "sqlite", "db", "woff", "woff2", "ttf", "otf", "eot",
        "class", "jar", "war", "pyc"
    ]

    public var parameters: [String: MCPToolParameter] {
        return [
            "filePath": MCPToolParameter(
                type: .string,
                description: "File absolute path",
                required: true
            ),
            "offset": MCPToolParameter(
                type: .integer,
                description: "Start line (1-based, for large files)",
                required: false
            ),
            "limit": MCPToolParameter(
                type: .integer,
                description: "Max lines (use with offset)",
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

        /// Validate offset if provided.
        if let offset = params["offset"] as? Int {
            guard offset >= 1 else {
                throw MCPError.invalidParameters("offset must be >= 1 (line numbers are 1-based)")
            }
        }

        /// Validate limit if provided.
        if let limit = params["limit"] as? Int {
            guard limit > 0 else {
                throw MCPError.invalidParameters("limit must be > 0")
            }
        }
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
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

        let offset = parameters["offset"] as? Int
        let limit = parameters["limit"] as? Int ?? 2000

        /// Resolve path against workingDirectory if relative
        let resolvedPath: String
        if filePath.hasPrefix("/") || filePath.hasPrefix("~") {
            resolvedPath = (filePath as NSString).expandingTildeInPath
        } else if let workingDir = context.workingDirectory {
            resolvedPath = (workingDir as NSString).appendingPathComponent(filePath)
        } else {
            resolvedPath = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(filePath)
        }

        do {
            /// Check for binary file before attempting to read.
            if let binaryError = checkForBinaryFile(at: resolvedPath) {
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(
                        content: """
                        {
                            "error": true,
                            "message": "\(binaryError)",
                            "isBinary": true
                        }
                        """,
                        mimeType: "application/json"
                    )
                )
            }

            /// Validate file can be read.
            let validation = fileOperationsSafety.validateFileForReading(resolvedPath)
            guard validation.isValid else {
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(
                        content: """
                        {
                            "error": true,
                            "message": "\(validation.error ?? "File validation failed")"
                        }
                        """,
                        mimeType: "application/json"
                    )
                )
            }

            /// Read file contents.
            let content = try readFile(at: resolvedPath, offset: offset, limit: limit, context: context)

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: content, mimeType: "application/json")
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
                        "message": "Failed to read file: \(error.localizedDescription)"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }
    }

    // MARK: - Binary File Detection

    /// Check if a file appears to be binary and return an error message if so.
    private func checkForBinaryFile(at path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        /// Check by file extension first (fast path).
        if Self.binaryExtensions.contains(ext) {
            return binaryFileMessage(path: path, ext: ext)
        }

        /// Content sniffing: check first 8KB for null bytes.
        /// This catches binary files with unknown extensions.
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           data.count > 0 {
            let sniffSize = min(data.count, 8192)
            let sniffData = data.prefix(sniffSize)

            /// If we find null bytes, it's likely binary.
            if sniffData.contains(0x00) {
                /// But allow UTF-16/UTF-32 encoded text files (they have null bytes).
                /// Check for BOM first.
                let sniffPrefix = Data(sniffData.prefix(4))
                if sniffPrefix == Data([0xFF, 0xFE]) || sniffPrefix == Data([0xFE, 0xFF]) {
                    return nil  /// UTF-16 BOM - treat as text
                }
                if sniffPrefix == Data([0x00, 0x00, 0xFE, 0xFF]) || sniffPrefix == Data([0xEF, 0xBB, 0xBF]) {
                    return nil  /// UTF-32 BOM or UTF-8 BOM - treat as text
                }

                /// Null byte found without text BOM - likely binary
                return binaryFileMessage(path: path, ext: ext.isEmpty ? "unknown" : ext)
            }
        }

        return nil
    }

    /// Generate a helpful error message for binary files with alternatives.
    private func binaryFileMessage(path: String, ext: String) -> String {
        let fileName = (path as NSString).lastPathComponent
        var message = "Cannot read binary file: \(fileName) (.\(ext) format)"
        message += "\\n\\nAlternatives:"

        switch ext {
        case "pdf", "docx", "xlsx", "pptx", "doc", "xls", "ppt":
            message += "\\n- Use document_import tool to import and extract text from this file"
            message += "\\n- Use get_file_info to view file metadata"
        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp":
            message += "\\n- Use document_import tool to perform OCR on this image"
            message += "\\n- Use get_file_info to view image metadata"
        case "zip", "tar", "gz", "7z", "rar", "dmg":
            message += "\\n- Use terminal_operations to list archive contents"
            message += "\\n- Use get_file_info to view archive metadata"
        default:
            message += "\\n- Use get_file_info to view file metadata"
        }

        return message
    }

    private func readFile(at filePath: String, offset: Int?, limit: Int, context: MCPExecutionContext) throws -> String {
        /// Read file contents.
        let url = URL(fileURLWithPath: filePath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw MCPError.executionFailed("Unable to read file contents. File may be binary or use unsupported encoding.")
        }

        /// Split into lines.
        let lines = contents.components(separatedBy: .newlines)
        let totalLines = lines.count

        /// Calculate slice range.
        let startIndex: Int
        let endIndex: Int

        if let offset = offset {
            /// 1-based to 0-based index.
            startIndex = max(0, offset - 1)
            endIndex = min(totalLines, startIndex + limit)
        } else {
            /// No offset - read from beginning.
            startIndex = 0
            endIndex = min(totalLines, limit)
        }

        /// Extract requested lines.
        let requestedLines = Array(lines[startIndex..<endIndex])
        let returnedLines = requestedLines.count
        var truncated = endIndex < totalLines

        /// TOKEN-AWARE LIMITING: Use ToolResultStorage for large files.
        var content = requestedLines.joined(separator: "\n")
        let estimatedTokens = TokenEstimator.estimateTokens(content)
        var tokenLimited = false

        if estimatedTokens > Self.inlineTokenLimit {
            /// Content exceeds inline limit - persist to disk and return instructions.
            if let conversationId = context.conversationId,
               let toolCallId = context.toolCallId {
                do {
                    let metadata = try storage.persistResult(
                        content: content,
                        toolCallId: toolCallId,
                        conversationId: conversationId
                    )

                    logger.info("Large file persisted to disk: \(estimatedTokens) tokens -> \(metadata.filePath)")

                    /// Return preview with read_tool_result instructions.
                    let preview = TokenEstimator.truncate(content, toTokenLimit: ToolResultStorage.previewTokenLimit)
                    let previewTokens = TokenEstimator.estimateTokens(preview)

                    var result: [String: Any] = [
                        "filePath": filePath,
                        "content": preview,
                        "totalLines": totalLines,
                        "returnedLines": returnedLines,
                        "truncated": true,
                        "estimatedTokens": estimatedTokens,
                        "tokenLimited": true,
                        "previewTokens": previewTokens,
                        "totalTokens": estimatedTokens,
                        "storageToolCallId": toolCallId,
                        "storagePath": metadata.filePath,
                        "readMore": "Use read_tool_result(toolCallId: \"\(toolCallId)\", offset: 0, length: 8192) to read the full content"
                    ]

                    if let offset = offset {
                        result["offset"] = offset
                    }
                    result["limit"] = limit

                    let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                        throw MCPError.executionFailed("Failed to encode result as JSON")
                    }
                    return jsonString
                } catch {
                    logger.error("Failed to persist large file result: \(error), truncating instead")
                    content = TokenEstimator.truncate(content, toTokenLimit: Self.inlineTokenLimit)
                    truncated = true
                    tokenLimited = true
                }
            } else {
                /// Fallback: truncate if we can't persist (missing context).
                content = TokenEstimator.truncate(content, toTokenLimit: Self.inlineTokenLimit)
                truncated = true
                tokenLimited = true
            }
        }

        /// Build result JSON.
        var result: [String: Any] = [
            "filePath": filePath,
            "content": content,
            "totalLines": totalLines,
            "returnedLines": returnedLines,
            "truncated": truncated,
            "estimatedTokens": TokenEstimator.estimateTokens(content),
            "tokenLimited": tokenLimited
        ]

        if let offset = offset {
            result["offset"] = offset
        }

        if offset != nil || truncated {
            result["limit"] = limit
        }

        /// Convert to JSON string.
        let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw MCPError.executionFailed("Failed to encode result as JSON")
        }

        return jsonString
    }
}