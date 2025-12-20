// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP tool for searching files by glob pattern.
public class FileSearchTool: MCPTool, @unchecked Sendable {
    public let name = "file_search"
    public let description = "Search for files matching a glob pattern. Supports patterns like '**/// .swift' (all Swift files), 'Sources/**' (all files under Sources), or '.test*.swift' (test files one level deep). Searches from specified root path or current directory."

    public var parameters: [String: MCPToolParameter] {
        return [
            "query": MCPToolParameter(
                type: .string,
                description: "Glob pattern like '**/*.swift' or 'Sources/**'",
                required: true
            ),
            "rootPath": MCPToolParameter(
                type: .string,
                description: "Root directory to search from (defaults to current directory)",
                required: false
            ),
            "limit": MCPToolParameter(
                type: .integer,
                description: "Maximum number of results to return per request (default: 100, max: 1000)",
                required: false
            ),
            "offset": MCPToolParameter(
                type: .integer,
                description: "Number of results to skip for pagination (default: 0)",
                required: false
            )
        ]
    }

    public struct FileSearchResult: Codable {
        let files: [String]
        let count: Int
        let totalCount: Int
        let offset: Int
        let hasMore: Bool
    }

    private let fileManager = FileManager.default
    private let logger = Logger(label: "com.sam.mcp.FileSearchTool")

    public init() {}

    public func initialize() async throws {
        logger.debug("FileSearchTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard let query = parameters["query"] as? String, !query.isEmpty else {
            throw MCPError.invalidParameters("query parameter is required and must not be empty")
        }
        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// Parse parameters.
        guard let query = parameters["query"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: query")
            )
        }

        let rootPath = parameters["rootPath"] as? String ?? context.workingDirectory ?? FileManager.default.currentDirectoryPath

        /// Pagination parameters.
        let requestedLimit = parameters["limit"] as? Int ?? 100
        let limit = min(requestedLimit, 1000)
        let offset = parameters["offset"] as? Int ?? 0

        /// Perform search.
        do {
            let searchResult = try await searchFiles(
                pattern: query,
                rootPath: rootPath,
                limit: limit,
                offset: offset
            )

            /// Build result with pagination metadata.
            let result = FileSearchResult(
                files: searchResult.files,
                count: searchResult.files.count,
                totalCount: searchResult.totalCount,
                offset: offset,
                hasMore: searchResult.hasMore
            )

            /// Encode to JSON.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(result)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: jsonString, mimeType: "application/json")
            )
        } catch {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Search failed: \(error.localizedDescription)")
            )
        }
    }

    // MARK: - File Search Implementation

    private struct SearchResult {
        let files: [String]
        let totalCount: Int
        let hasMore: Bool
    }

    /// Search for files matching glob pattern.
    @MainActor
    private func searchFiles(
        pattern: String,
        rootPath: String,
        limit: Int,
        offset: Int
    ) async throws -> SearchResult {
        var allFiles: [String] = []

        /// Parse glob pattern.
        let globMatcher = GlobMatcher(pattern: pattern)

        /// Enumerate all files recursively using synchronous API in Task.
        let rootURL = URL(fileURLWithPath: rootPath)

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw NSError(domain: "FileSearchTool", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create directory enumerator"
            ])
        }

        /// Convert enumerator to array synchronously to avoid async iteration issues.
        let allURLs = enumerator.allObjects.compactMap { $0 as? URL }

        for fileURL in allURLs {
            /// Get relative path from root.
            let relativePath = fileURL.path.replacingOccurrences(of: rootPath + "/", with: "")

            /// Check if matches pattern.
            if globMatcher.matches(relativePath) {
                allFiles.append(relativePath)
            }
        }

        /// Apply pagination.
        let totalCount = allFiles.count
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + limit, totalCount)
        let paginatedFiles = Array(allFiles[startIndex..<endIndex])
        let hasMore = endIndex < totalCount

        return SearchResult(
            files: paginatedFiles,
            totalCount: totalCount,
            hasMore: hasMore
        )
    }
}

// MARK: - Glob Pattern Matcher

/// Simple glob pattern matcher supporting *, **, ?, and character classes.
private struct GlobMatcher {
    let pattern: String
    let isRecursive: Bool
    let regex: NSRegularExpression?

    init(pattern: String) {
        self.pattern = pattern
        self.isRecursive = pattern.contains("**")

        /// Convert glob pattern to regex.
        var regexPattern = "^"
        var i = pattern.startIndex

        while i < pattern.endIndex {
            let char = pattern[i]

            if char == "*" {
                /// Check for **.
                let nextIndex = pattern.index(after: i)
                if nextIndex < pattern.endIndex && pattern[nextIndex] == "*" {
                    /// ** matches any number of directories.
                    regexPattern += ".*"
                    i = pattern.index(after: nextIndex)

                    /// Skip trailing /.
                    if i < pattern.endIndex && pattern[i] == "/" {
                        i = pattern.index(after: i)
                    }
                    continue
                } else {
                    /// * matches anything except /.
                    regexPattern += "[^/]*"
                }
            } else if char == "?" {
                /// ?.
                regexPattern += "[^/]"
            } else if char == "[" {
                /// Character class - pass through.
                regexPattern += "["
            } else if char == "]" {
                regexPattern += "]"
            } else if "\\^$.|+(){}".contains(char) {
                /// Escape regex special characters.
                regexPattern += "\\\(char)"
            } else {
                regexPattern.append(char)
            }

            i = pattern.index(after: i)
        }

        regexPattern += "$"

        /// Compile regex.
        self.regex = try? NSRegularExpression(pattern: regexPattern, options: [])
    }

    /// Check if a path matches the glob pattern.
    func matches(_ path: String) -> Bool {
        guard let regex = regex else {
            /// Fallback to simple comparison if regex compilation failed.
            return path == pattern
        }

        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }
}
