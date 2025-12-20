// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for retrieving aggregated search results from recent file and text searches Provides a unified view of recent search operations, for recent search operations.
public class GetSearchViewResultsTool: MCPTool, @unchecked Sendable {
    public let name = "get_search_view_results"
    public let description = "The results from the search view. Aggregates and returns recent file_search and grep_search results in a unified format."

    public var parameters: [String: MCPToolParameter] {
        return [:]
    }

    private let logger = Logger(label: "com.sam.mcp.GetSearchViewResultsTool")

    /// Shared search results cache (in-memory for now).
    nonisolated(unsafe) private static var searchResultsCache: SearchResultsCache = SearchResultsCache()

    public init() {}

    public func initialize() async throws {
        logger.debug("[GetSearchViewResultsTool] Initialized")
    }

    public func validateParameters(_ params: [String: Any]) throws -> Bool {
        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        do {
            /// Get aggregated search results.
            let results = Self.searchResultsCache.getAggregatedResults()

            /// Convert to JSON.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(results)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            logger.debug("[GetSearchViewResultsTool] Retrieved \(results.totalMatches) matches from \(results.totalFiles) files")

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(
                    content: jsonString,
                    mimeType: "application/json"
                )
            )

        } catch {
            logger.error("[GetSearchViewResultsTool] Failed to retrieve results: \(error.localizedDescription)")

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "Failed to retrieve search results: \(error.localizedDescription)"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }
    }

    // MARK: - Public Cache Access

    /// Add a file search result to the cache (called by FileSearchTool).
    public static func cacheFileSearchResult(query: String, files: [String]) {
        searchResultsCache.addFileSearch(query: query, files: files)
    }

    /// Add a grep search result to the cache (called by GrepSearchTool).
    public static func cacheGrepSearchResult(query: String, matches: [(file: String, line: Int, content: String)]) {
        searchResultsCache.addGrepSearch(query: query, matches: matches)
    }
}

// MARK: - Supporting Types

private class SearchResultsCache {
    private var fileSearches: [FileSearchEntry] = []
    private var grepSearches: [GrepSearchEntry] = []
    private let maxCacheSize = 10

    func addFileSearch(query: String, files: [String]) {
        let entry = FileSearchEntry(
            query: query,
            files: files,
            timestamp: Date()
        )

        fileSearches.insert(entry, at: 0)
        if fileSearches.count > maxCacheSize {
            fileSearches.removeLast()
        }
    }

    func addGrepSearch(query: String, matches: [(file: String, line: Int, content: String)]) {
        let entry = GrepSearchEntry(
            query: query,
            matches: matches,
            timestamp: Date()
        )

        grepSearches.insert(entry, at: 0)
        if grepSearches.count > maxCacheSize {
            grepSearches.removeLast()
        }
    }

    func getAggregatedResults() -> AggregatedSearchResults {
        var totalMatches = 0
        var uniqueFiles = Set<String>()
        var searches: [SearchOperation] = []

        /// Process file searches.
        for entry in fileSearches.prefix(5) {
            totalMatches += entry.files.count
            uniqueFiles.formUnion(entry.files)

            searches.append(SearchOperation(
                type: "file_search",
                query: entry.query,
                fileCount: entry.files.count,
                matchCount: entry.files.count,
                timestamp: entry.timestamp,
                files: entry.files.map { SearchFile(path: $0, matches: []) }
            ))
        }

        /// Process grep searches.
        for entry in grepSearches.prefix(5) {
            let fileMatches = Dictionary(grouping: entry.matches, by: { $0.file })
            totalMatches += entry.matches.count
            uniqueFiles.formUnion(fileMatches.keys)

            let searchFiles = fileMatches.map { file, matches in
                SearchFile(
                    path: file,
                    matches: matches.map { SearchMatch(line: $0.line, content: $0.content) }
                )
            }

            searches.append(SearchOperation(
                type: "grep_search",
                query: entry.query,
                fileCount: fileMatches.count,
                matchCount: entry.matches.count,
                timestamp: entry.timestamp,
                files: searchFiles
            ))
        }

        return AggregatedSearchResults(
            totalMatches: totalMatches,
            totalFiles: uniqueFiles.count,
            searches: searches,
            timestamp: Date()
        )
    }

    private struct FileSearchEntry {
        let query: String
        let files: [String]
        let timestamp: Date
    }

    private struct GrepSearchEntry {
        let query: String
        let matches: [(file: String, line: Int, content: String)]
        let timestamp: Date
    }
}

private struct AggregatedSearchResults: Codable {
    let totalMatches: Int
    let totalFiles: Int
    let searches: [SearchOperation]
    let timestamp: Date
}

private struct SearchOperation: Codable {
    let type: String
    let query: String
    let fileCount: Int
    let matchCount: Int
    let timestamp: Date
    let files: [SearchFile]
}

private struct SearchFile: Codable {
    let path: String
    let matches: [SearchMatch]
}

private struct SearchMatch: Codable {
    let line: Int
    let content: String
}
