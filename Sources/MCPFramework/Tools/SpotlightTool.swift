// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for Spotlight search via mdfind.
/// Provides file search, content search, and metadata queries using macOS Spotlight.
public class SpotlightTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "spotlight_search"

    public let description = """
    Search the user's files using macOS Spotlight (mdfind).

    OPERATIONS:
    • search - Search files by name or content (query, optional: directory, max_results, file_type)
    • search_content - Search inside file contents (query, optional: directory, max_results)
    • search_metadata - Search by metadata attributes (attribute, value, optional: directory, max_results)
    • file_info - Get Spotlight metadata for a specific file (path)
    • recent_files - Find recently modified files (optional: directory, hours, max_results, file_type)

    Common file_type values: document, image, audio, video, pdf, presentation, spreadsheet, source_code
    Metadata attributes: kMDItemContentType, kMDItemAuthors, kMDItemCreator, kMDItemKind, etc.
    """

    public var supportedOperations: [String] {
        return ["search", "search_content", "search_metadata", "file_info", "recent_files"]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: "Spotlight operation to perform",
                required: true,
                enumValues: supportedOperations
            ),
            "query": MCPToolParameter(
                type: .string,
                description: "Search query string",
                required: false
            ),
            "directory": MCPToolParameter(
                type: .string,
                description: "Directory to search in (defaults to user's home)",
                required: false
            ),
            "max_results": MCPToolParameter(
                type: .integer,
                description: "Maximum results to return (default: 25)",
                required: false
            ),
            "file_type": MCPToolParameter(
                type: .string,
                description: "Filter by file type: document, image, audio, video, pdf, presentation, spreadsheet, source_code",
                required: false
            ),
            "attribute": MCPToolParameter(
                type: .string,
                description: "Metadata attribute name for search_metadata (e.g., kMDItemContentType)",
                required: false
            ),
            "value": MCPToolParameter(
                type: .string,
                description: "Metadata attribute value to match",
                required: false
            ),
            "path": MCPToolParameter(
                type: .string,
                description: "File path for file_info operation",
                required: false
            ),
            "hours": MCPToolParameter(
                type: .integer,
                description: "Hours back to search for recent_files (default: 24)",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.spotlight")

    @MainActor
    public func initialize() async throws {
        logger.debug("SpotlightTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard parameters["operation"] is String else {
            throw MCPError.invalidParameters("Missing 'operation' parameter")
        }
        return true
    }

    @MainActor
    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        switch operation {
        case "search":
            return await searchFiles(parameters: parameters)
        case "search_content":
            return await searchContent(parameters: parameters)
        case "search_metadata":
            return await searchMetadata(parameters: parameters)
        case "file_info":
            return await fileInfo(parameters: parameters)
        case "recent_files":
            return await recentFiles(parameters: parameters)
        default:
            return operationError(operation, message: "Unknown operation")
        }
    }

    // MARK: - mdfind Execution

    private func runMdfind(args: [String], maxResults: Int) async -> (output: String, exitCode: Int32) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output, process.terminationStatus)
        } catch {
            logger.error("mdfind execution failed: \(error)")
            return ("", 1)
        }
    }

    private func formatResults(_ output: String, maxResults: Int) -> (paths: [String], formatted: String) {
        let paths = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        let limited = Array(paths.prefix(maxResults))

        if limited.isEmpty {
            return ([], "No results found.")
        }

        var formatted = ""
        let fm = FileManager.default

        for path in limited {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            var details = "- **\(name)**\n  Path: \(path)\n"

            if let attrs = try? fm.attributesOfItem(atPath: path) {
                if let size = attrs[.size] as? Int64 {
                    details += "  Size: \(formatSize(size))\n"
                }
                if let modified = attrs[.modificationDate] as? Date {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    details += "  Modified: \(formatter.string(from: modified))\n"
                }
            }
            formatted += details + "\n"
        }

        if paths.count > maxResults {
            formatted += "... and \(paths.count - maxResults) more results. Narrow your search or increase max_results."
        }

        return (limited, formatted)
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    // MARK: - File Type Mapping

    private func contentTypeQuery(for fileType: String) -> String? {
        switch fileType.lowercased() {
        case "document", "doc":
            return "kMDItemContentTypeTree == 'public.text' || kMDItemContentTypeTree == 'public.composite-content'"
        case "image", "img":
            return "kMDItemContentTypeTree == 'public.image'"
        case "audio", "music":
            return "kMDItemContentTypeTree == 'public.audio'"
        case "video", "movie":
            return "kMDItemContentTypeTree == 'public.movie'"
        case "pdf":
            return "kMDItemContentType == 'com.adobe.pdf'"
        case "presentation", "slides":
            return "kMDItemContentTypeTree == 'public.presentation'"
        case "spreadsheet":
            return "kMDItemContentTypeTree == 'public.spreadsheet'"
        case "source_code", "code":
            return "kMDItemContentTypeTree == 'public.source-code'"
        default:
            return nil
        }
    }

    // MARK: - Operations

    @MainActor
    private func searchFiles(parameters: [String: Any]) async -> MCPToolResult {
        guard let query = parameters["query"] as? String, !query.isEmpty else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: query"))
        }

        let maxResults = parameters["max_results"] as? Int ?? 25
        let directory = parameters["directory"] as? String
        let fileType = parameters["file_type"] as? String

        var args: [String] = []

        // Build query with optional file type filter
        if let fileType = fileType, let typeQuery = contentTypeQuery(for: fileType) {
            args.append("-interpret")
            args.append("(\(typeQuery)) && (kMDItemFSName == '*\(query)*'cd || kMDItemDisplayName == '*\(query)*'cd)")
        } else {
            args.append("-name")
            args.append(query)
        }

        if let dir = directory {
            args.append("-onlyin")
            args.append(dir)
        }

        let (output, exitCode) = await runMdfind(args: args, maxResults: maxResults)

        if exitCode != 0 {
            return MCPToolResult(success: false, output: MCPOutput(content: "Spotlight search failed."))
        }

        let (_, formatted) = formatResults(output, maxResults: maxResults)
        let totalCount = output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        let header = "Spotlight search for '\(query)' (\(min(totalCount, maxResults)) of \(totalCount) results):\n\n"

        return MCPToolResult(success: true, output: MCPOutput(content: header + formatted))
    }

    @MainActor
    private func searchContent(parameters: [String: Any]) async -> MCPToolResult {
        guard let query = parameters["query"] as? String, !query.isEmpty else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: query"))
        }

        let maxResults = parameters["max_results"] as? Int ?? 25
        let directory = parameters["directory"] as? String

        var args: [String] = []
        // Content search uses mdfind without -name flag
        args.append(query)

        if let dir = directory {
            args.append("-onlyin")
            args.append(dir)
        }

        let (output, exitCode) = await runMdfind(args: args, maxResults: maxResults)

        if exitCode != 0 {
            return MCPToolResult(success: false, output: MCPOutput(content: "Content search failed."))
        }

        let (_, formatted) = formatResults(output, maxResults: maxResults)
        let totalCount = output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        let header = "Files containing '\(query)' (\(min(totalCount, maxResults)) of \(totalCount) results):\n\n"

        return MCPToolResult(success: true, output: MCPOutput(content: header + formatted))
    }

    @MainActor
    private func searchMetadata(parameters: [String: Any]) async -> MCPToolResult {
        guard let attribute = parameters["attribute"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: attribute"))
        }
        guard let value = parameters["value"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: value"))
        }

        let maxResults = parameters["max_results"] as? Int ?? 25
        let directory = parameters["directory"] as? String

        var args = ["\(attribute) == '\(value)'"]

        if let dir = directory {
            args.append("-onlyin")
            args.append(dir)
        }

        let (output, exitCode) = await runMdfind(args: args, maxResults: maxResults)

        if exitCode != 0 {
            return MCPToolResult(success: false, output: MCPOutput(content: "Metadata search failed."))
        }

        let (_, formatted) = formatResults(output, maxResults: maxResults)
        let totalCount = output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        let header = "Files where \(attribute) == '\(value)' (\(min(totalCount, maxResults)) of \(totalCount) results):\n\n"

        return MCPToolResult(success: true, output: MCPOutput(content: header + formatted))
    }

    @MainActor
    private func fileInfo(parameters: [String: Any]) async -> MCPToolResult {
        guard let path = parameters["path"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: path"))
        }

        let expandedPath = NSString(string: path).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "File not found: \(path)"))
        }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = [expandedPath]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                return MCPToolResult(success: false, output: MCPOutput(content: "Failed to get metadata for: \(path)"))
            }

            return MCPToolResult(success: true, output: MCPOutput(content: "Metadata for \(path):\n\n\(output)"))
        } catch {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to run mdls: \(error.localizedDescription)"))
        }
    }

    @MainActor
    private func recentFiles(parameters: [String: Any]) async -> MCPToolResult {
        let hours = parameters["hours"] as? Int ?? 24
        let maxResults = parameters["max_results"] as? Int ?? 25
        let directory = parameters["directory"] as? String
        let fileType = parameters["file_type"] as? String

        var query = "kMDItemFSContentChangeDate >= $time.now(-\(hours * 3600))"

        if let fileType = fileType, let typeQuery = contentTypeQuery(for: fileType) {
            query += " && (\(typeQuery))"
        }

        var args = [query]

        if let dir = directory {
            args.append("-onlyin")
            args.append(dir)
        }

        let (output, exitCode) = await runMdfind(args: args, maxResults: maxResults)

        if exitCode != 0 {
            return MCPToolResult(success: false, output: MCPOutput(content: "Recent files search failed."))
        }

        let (_, formatted) = formatResults(output, maxResults: maxResults)
        let totalCount = output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        let typeStr = fileType.map { " (\($0))" } ?? ""
        let header = "Files modified in the last \(hours) hours\(typeStr) (\(min(totalCount, maxResults)) of \(totalCount) results):\n\n"

        return MCPToolResult(success: true, output: MCPOutput(content: header + formatted))
    }
}
