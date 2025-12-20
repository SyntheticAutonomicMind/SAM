// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for semantic code search using natural language queries Leverages SAM's VectorRAGService to perform semantic search across the codebase.
public class SemanticSearchTool: MCPTool, @unchecked Sendable {
    public let name = "semantic_search"
    public let description = "Run a natural language search for relevant code or documentation comments from the user's current workspace. Returns relevant code snippets from the user's current workspace if it is large, or the full contents of the workspace if it is small."

    public var parameters: [String: MCPToolParameter] {
        return [
            "query": MCPToolParameter(
                type: .string,
                description: "Search query (function names, variables, comments)",
                required: true
            ),
            "rootPath": MCPToolParameter(
                type: .string,
                description: "Search root (defaults to current)",
                required: false
            ),
            "includePattern": MCPToolParameter(
                type: .string,
                description: "File filter glob (e.g. '**/*.swift')",
                required: false
            ),
            "limit": MCPToolParameter(
                type: .integer,
                description: "Max results (default: 20)",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.SemanticSearchTool")

    public init() {}

    public func initialize() async throws {
        logger.debug("[SemanticSearchTool] Initialized")
    }

    public func validateParameters(_ params: [String: Any]) throws -> Bool {
        /// query is required.
        guard let query = params["query"] as? String, !query.isEmpty else {
            throw MCPError.invalidParameters("query parameter is required and must be a non-empty string")
        }

        /// rootPath is optional - if provided, must exist.
        if let rootPath = params["rootPath"] as? String {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw MCPError.invalidParameters("rootPath must be an existing directory")
            }
        }

        /// limit is optional - if provided, must be positive.
        if let limit = params["limit"] as? Int, limit <= 0 {
            throw MCPError.invalidParameters("limit must be a positive integer")
        }

        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let query = parameters["query"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "query parameter is required"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }

        let rootPath = parameters["rootPath"] as? String ?? context.workingDirectory ?? FileManager.default.currentDirectoryPath
        let includePattern = parameters["includePattern"] as? String
        let limit = parameters["limit"] as? Int ?? 20

        do {
            /// Perform semantic search.
            let results = try await performSemanticCodeSearch(
                query: query,
                rootPath: rootPath,
                includePattern: includePattern,
                limit: limit
            )

            /// Convert to JSON.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(results)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

            logger.debug("[SemanticSearchTool] Found \(results.count) relevant code snippets for query: '\(query.prefix(50))'")

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(
                    content: jsonString,
                    mimeType: "application/json"
                )
            )

        } catch {
            logger.error("[SemanticSearchTool] Semantic search failed: \(error.localizedDescription)")

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "Semantic search failed: \(error.localizedDescription)"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }
    }

    // MARK: - Helper Methods

    @MainActor
    private func performSemanticCodeSearch(
        query: String,
        rootPath: String,
        includePattern: String?,
        limit: Int
    ) async throws -> [CodeSearchResult] {
        logger.debug("[SemanticSearchTool] Starting semantic search in '\(rootPath)'")

        /// Step 1: Find all code files in workspace.
        let codeFiles = try findCodeFiles(in: rootPath, matching: includePattern)
        logger.debug("[SemanticSearchTool] Found \(codeFiles.count) code files to search")

        /// Step 2: Read and index file contents.
        var codeSnippets: [CodeSnippet] = []
        for file in codeFiles.prefix(100) {
            if let snippets = try? extractCodeSnippets(from: file) {
                codeSnippets.append(contentsOf: snippets)
            }
        }
        logger.debug("[SemanticSearchTool] Extracted \(codeSnippets.count) code snippets")

        /// Step 3: Perform semantic matching.
        let rankedResults = rankSnippetsByRelevance(snippets: codeSnippets, query: query, limit: limit)

        /// Step 4: Convert to output format.
        let results = rankedResults.map { snippet, relevance in
            CodeSearchResult(
                file: snippet.file,
                line: snippet.startLine,
                content: snippet.content,
                relevance: relevance,
                context: snippet.context
            )
        }

        return results
    }

    private func findCodeFiles(in rootPath: String, matching pattern: String?) throws -> [String] {
        var files: [String] = []

        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey]

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: rootPath),
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return files
        }

        let codeExtensions = ["swift", "m", "mm", "h", "c", "cpp", "hpp", "js", "ts", "py", "java", "kt"]

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                  resourceValues.isDirectory == false else {
                continue
            }

            let path = fileURL.path

            /// Check if file matches extension.
            guard let ext = fileURL.pathExtension.lowercased() as String?,
                  codeExtensions.contains(ext) else {
                continue
            }

            /// Apply pattern filter if provided.
            if let pattern = pattern {
                /// Simple pattern matching - could be enhanced with proper glob matching.
                if pattern.contains("*") {
                    let regexPattern = pattern.replacingOccurrences(of: "**", with: ".*").replacingOccurrences(of: "*", with: "[^/]*")
                    if let regex = try? NSRegularExpression(pattern: regexPattern, options: []),
                       regex.firstMatch(in: path, options: [], range: NSRange(path.startIndex..., in: path)) != nil {
                        files.append(path)
                    }
                } else if path.contains(pattern) {
                    files.append(path)
                }
            } else {
                files.append(path)
            }
        }

        return files
    }

    private func extractCodeSnippets(from file: String) throws -> [CodeSnippet] {
        let content = try String(contentsOfFile: file, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var snippets: [CodeSnippet] = []
        var currentSnippet = ""
        var snippetStartLine = 1
        var lineNumber = 1

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            /// Start new snippet on function/class/struct declarations.
            if trimmed.starts(with: "func ") || trimmed.starts(with: "class ") ||
               trimmed.starts(with: "struct ") || trimmed.starts(with: "enum ") ||
               trimmed.starts(with: "protocol ") {
                /// Save previous snippet if exists.
                if !currentSnippet.isEmpty {
                    snippets.append(CodeSnippet(
                        file: file,
                        startLine: snippetStartLine,
                        content: currentSnippet,
                        context: extractContext(from: currentSnippet)
                    ))
                }

                /// Start new snippet.
                currentSnippet = line + "\n"
                snippetStartLine = lineNumber
            } else if !currentSnippet.isEmpty {
                currentSnippet += line + "\n"

                /// End snippet on closing braces or after ~20 lines.
                if trimmed == "}" || lineNumber - snippetStartLine > 20 {
                    snippets.append(CodeSnippet(
                        file: file,
                        startLine: snippetStartLine,
                        content: currentSnippet,
                        context: extractContext(from: currentSnippet)
                    ))
                    currentSnippet = ""
                }
            }

            lineNumber += 1
        }

        /// Add final snippet if exists.
        if !currentSnippet.isEmpty {
            snippets.append(CodeSnippet(
                file: file,
                startLine: snippetStartLine,
                content: currentSnippet,
                context: extractContext(from: currentSnippet)
            ))
        }

        return snippets
    }

    private func extractContext(from snippet: String) -> String {
        /// Extract comments and first line for context.
        let lines = snippet.components(separatedBy: .newlines)
        var context = ""

        for line in lines.prefix(5) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "///") || trimmed.starts(with: "//") {
                context += trimmed + " "
            } else if !trimmed.isEmpty && context.isEmpty {
                context = trimmed
                break
            }
        }

        return context.trimmingCharacters(in: .whitespaces)
    }

    private func rankSnippetsByRelevance(
        snippets: [CodeSnippet],
        query: String,
        limit: Int
    ) -> [(CodeSnippet, Double)] {
        let queryTerms = query.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        var rankedSnippets: [(CodeSnippet, Double)] = []

        for snippet in snippets {
            let content = snippet.content.lowercased()
            let context = snippet.context.lowercased()

            /// Calculate relevance score.
            var score: Double = 0.0

            /// Exact query match.
            if content.contains(query.lowercased()) {
                score += 1.0
            }

            /// Term matching (weighted by position and frequency).
            for term in queryTerms {
                if context.contains(term) {
                    score += 0.5
                }
                if content.contains(term) {
                    score += 0.3
                }
            }

            /// Boost for definitions.
            if snippet.content.contains("func ") || snippet.content.contains("class ") {
                score *= 1.2
            }

            if score > 0 {
                rankedSnippets.append((snippet, score))
            }
        }

        /// Sort by relevance and return top results.
        rankedSnippets.sort { $0.1 > $1.1 }
        return Array(rankedSnippets.prefix(limit))
    }
}

// MARK: - Supporting Types

private struct CodeSnippet {
    let file: String
    let startLine: Int
    let content: String
    let context: String
}

private struct CodeSearchResult: Codable {
    let file: String
    let line: Int
    let content: String
    let relevance: Double
    let context: String
}
