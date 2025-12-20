// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Search indexed files in the working directory Provides fast file search using the Working Directory Indexer.
public class SearchIndexTool: MCPTool, @unchecked Sendable {
    public let name = "search_index"
    public let description = """
Search files using the working directory index for fast lookups.

WHEN TO USE:
- Finding files by name/path substring
- Finding files by extension
- Getting file statistics
- Listing all files quickly

WHEN NOT TO USE:
- Pattern matching (use file_search with glob patterns)
- Text content search (use grep_search)
- Code search (use semantic_search)

EXAMPLES:
{"query": "Orchestrator"} - Find files with "Orchestrator" in name/path
{"extension": "swift"} - Find all Swift files
{"operation": "stats"} - Get index statistics
"""

    public var parameters: [String: MCPToolParameter] {
        return [
            "query": MCPToolParameter(
                type: .string,
                description: "Search query (filename or path substring)",
                required: false
            ),
            "extension": MCPToolParameter(
                type: .string,
                description: "File extension filter (e.g., 'swift', 'md')",
                required: false
            ),
            "operation": MCPToolParameter(
                type: .string,
                description: "Special operation: 'stats' for statistics, 'refresh' to rebuild index",
                required: false,
                enumValues: ["stats", "refresh"]
            )
        ]
    }

    private let logger = Logger(label: "com.sam.search-index-tool")

    /// Static indexer instance per working directory.
    nonisolated(unsafe) private static var indexers: [String: WorkingDirectoryIndexer] = [:]
    private static let indexerLock = NSLock()

    public init() {
        /// Register with ToolDisplayInfoRegistry for proper progress indicators.
        ToolDisplayInfoRegistry.shared.register("search_index", provider: SearchIndexTool.self)
    }

    /// Get or create indexer for working directory.
    private func getIndexer(workingDirectory: String?) -> WorkingDirectoryIndexer? {
        guard let workingDir = workingDirectory else {
            logger.warning("No working directory provided for search_index")
            return nil
        }

        Self.indexerLock.lock()
        defer { Self.indexerLock.unlock() }

        if let existingIndexer = Self.indexers[workingDir] {
            return existingIndexer
        }

        /// Create new indexer.
        let url = URL(fileURLWithPath: workingDir)
        let indexer = WorkingDirectoryIndexer(workingDirectory: url)
        Self.indexers[workingDir] = indexer

        logger.info("Created new file indexer for \(workingDir)")
        return indexer
    }

    public func execute(
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        guard let indexer = getIndexer(workingDirectory: context.workingDirectory) else {
            return operationError(
                "search_index",
                message: "No working directory available for indexing"
            )
        }

        /// Always refresh index before search to pick up new files This ensures files added since last search are immediately available.
        indexer.refresh()

        /// Handle special operations.
        if let operation = parameters["operation"] as? String {
            switch operation {
            case "stats":
                return handleStats(indexer: indexer)
            case "refresh":
                return handleRefresh(indexer: indexer)
            default:
                return operationError(
                    "search_index",
                    message: "Unknown operation: \(operation)"
                )
            }
        }

        /// Handle search operations.
        if let query = parameters["query"] as? String {
            return handleNameSearch(indexer: indexer, query: query)
        }

        if let extension_ = parameters["extension"] as? String {
            return handleExtensionSearch(indexer: indexer, extension: extension_)
        }

        /// No parameters - return all files.
        return handleListAll(indexer: indexer)
    }

    private func handleNameSearch(indexer: WorkingDirectoryIndexer, query: String) -> MCPToolResult {
        let results = indexer.searchByName(query: query)

        var output = "Found \(results.count) file(s) matching '\(query)':\n\n"

        for entry in results.prefix(100) {
            let sizeStr = formatFileSize(entry.size)
            let typeStr = entry.isDirectory ? "[DIR]" : ""
            output += "\(typeStr)\(entry.relativePath) (\(sizeStr))\n"
        }

        if results.count > 100 {
            output += "\n... and \(results.count - 100) more files\n"
        }

        if results.isEmpty {
            output = "No files found matching '\(query)'"
        }

        return MCPToolResult(
            success: true,
            output: MCPOutput(content: output),
            toolName: name
        )
    }

    private func handleExtensionSearch(indexer: WorkingDirectoryIndexer, extension ext: String) -> MCPToolResult {
        let results = indexer.searchByExtension(ext)

        var output = "Found \(results.count) .\(ext) file(s):\n\n"

        for entry in results.prefix(100) {
            let sizeStr = formatFileSize(entry.size)
            output += "\(entry.relativePath) (\(sizeStr))\n"
        }

        if results.count > 100 {
            output += "\n... and \(results.count - 100) more files\n"
        }

        if results.isEmpty {
            output = "No .\(ext) files found"
        }

        return MCPToolResult(
            success: true,
            output: MCPOutput(content: output),
            toolName: name
        )
    }

    private func handleStats(indexer: WorkingDirectoryIndexer) -> MCPToolResult {
        let stats = indexer.getStatistics()

        var output = "File Index Statistics:\n\n"
        output += "Working Directory: \(stats["workingDirectory"] as? String ?? "unknown")\n"
        output += "Total Files: \(stats["totalFiles"] as? Int ?? 0)\n"
        output += "Total Directories: \(stats["totalDirectories"] as? Int ?? 0)\n"
        output += "Total Size: \(formatFileSize(Int64(stats["totalSize"] as? Int ?? 0)))\n\n"

        if let extensionCounts = stats["extensionCounts"] as? [String: Int] {
            output += "Files by Extension:\n"
            let sortedExtensions = extensionCounts.sorted { $0.value > $1.value }
            for (ext, count) in sortedExtensions.prefix(20) {
                output += "  .\(ext): \(count) files\n"
            }

            if extensionCounts.count > 20 {
                output += "  ... and \(extensionCounts.count - 20) more extensions\n"
            }
        }

        return MCPToolResult(
            success: true,
            output: MCPOutput(content: output),
            toolName: name
        )
    }

    private func handleRefresh(indexer: WorkingDirectoryIndexer) -> MCPToolResult {
        indexer.refresh()
        let count = indexer.getFileCount()
        return MCPToolResult(
            success: true,
            output: MCPOutput(content: "Index refreshed. \(count) files indexed."),
            toolName: name
        )
    }

    private func handleListAll(indexer: WorkingDirectoryIndexer) -> MCPToolResult {
        let files = indexer.getAllFiles()

        var output = "Indexed \(files.count) files:\n\n"

        for entry in files.prefix(100) {
            let sizeStr = formatFileSize(entry.size)
            let typeStr = entry.isDirectory ? "[DIR]" : ""
            output += "\(typeStr)\(entry.relativePath) (\(sizeStr))\n"
        }

        if files.count > 100 {
            output += "\n... and \(files.count - 100) more files\n"
        }

        return MCPToolResult(
            success: true,
            output: MCPOutput(content: output),
            toolName: name
        )
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func operationError(_ operation: String, message: String) -> MCPToolResult {
        logger.error("Operation failed: \(message)", metadata: [
            "operation": .string(operation)
        ])
        return MCPToolResult(
            success: false,
            output: MCPOutput(content: "ERROR: \(message)"),
            toolName: name
        )
    }
}

// MARK: - ToolDisplayInfoProvider

extension SearchIndexTool: ToolDisplayInfoProvider {
    public static func extractDisplayInfo(from arguments: [String: Any]) -> String? {
        if let query = arguments["query"] as? String {
            return "Searching index: '\(query)'"
        }
        if let ext = arguments["extension"] as? String {
            return "Finding .\(ext) files"
        }
        if let op = arguments["operation"] as? String {
            switch op {
            case "stats":
                return "Getting index statistics"
            case "refresh":
                return "Refreshing file index"
            default:
                return "Searching files"
            }
        }
        return "Searching files"
    }

    public static func extractToolDetails(from arguments: [String: Any]) -> [String]? {
        var details: [String] = []

        if let query = arguments["query"] as? String {
            details.append("Query: \(query)")
        }
        if let ext = arguments["extension"] as? String {
            details.append("Extension: .\(ext)")
        }
        if let op = arguments["operation"] as? String {
            details.append("Operation: \(op)")
        }

        return details.isEmpty ? nil : details
    }
}
