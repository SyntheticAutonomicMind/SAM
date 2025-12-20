// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// ReadFileTool - Read file contents with optional pagination Reads the contents of a file and returns it as a string.
public class ReadFileTool: MCPTool, @unchecked Sendable {
    public let name = "read_file"
    public let description = """
    Read the contents of a file. Line numbers are 1-indexed. This tool will truncate its output at 2000 lines \
    and may be called repeatedly with offset and limit parameters to read larger files in chunks.
    """

    private let fileOperationsSafety = FileOperationsSafety()

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
            let content = try readFile(at: resolvedPath, offset: offset, limit: limit)

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

    private func readFile(at filePath: String, offset: Int?, limit: Int) throws -> String {
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

        /// TOKEN-AWARE LIMITING: Prevent exceeding provider context window limits Most providers have 64K-128K token limits.
        var content = requestedLines.joined(separator: "\n")
        let maxTokens = 10_000
        let estimatedTokens = TokenEstimator.estimateTokens(content)
        var tokenLimited = false

        if estimatedTokens > maxTokens {
            /// Content exceeds token limit - truncate.
            content = TokenEstimator.truncate(content, toTokenLimit: maxTokens)
            truncated = true
            tokenLimited = true
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
