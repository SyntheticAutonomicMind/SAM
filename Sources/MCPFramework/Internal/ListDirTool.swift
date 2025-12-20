// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP tool for listing directory contents with metadata.
public class ListDirTool: MCPTool, @unchecked Sendable {
    public let name = "list_dir"
    public let description = "List contents of a directory with metadata (name, size, type, modification date). Only lists immediate children - does not recurse into subdirectories. Supports pagination for large directories (default limit: 100 files). Returns totalCount and hasMore to indicate if additional pages exist."

    public var parameters: [String: MCPToolParameter] {
        return [
            "path": MCPToolParameter(
                type: .string,
                description: "Absolute path to directory",
                required: true
            ),
            "limit": MCPToolParameter(
                type: .integer,
                description: "Maximum number of entries to return (default: 100). Use with offset for pagination.",
                required: false
            ),
            "offset": MCPToolParameter(
                type: .integer,
                description: "Number of entries to skip (default: 0). Use with limit for pagination.",
                required: false
            )
        ]
    }

    public struct DirectoryEntry: Codable {
        let name: String
        let isDirectory: Bool
        let size: Int64?
        let modifiedDate: String
        let permissions: String
    }

    public struct ListDirResult: Codable {
        let message: String
        let path: String
        let entries: [DirectoryEntry]
        let count: Int
        let totalCount: Int
        let hasMore: Bool
        let offset: Int
        let limit: Int
    }

    private let fileManager = FileManager.default
    private let safety = FileOperationsSafety()
    private let logger = Logger(label: "com.sam.mcp.ListDirTool")

    public init() {}

    public func initialize() async throws {
        logger.debug("ListDirTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard let path = parameters["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParameters("path parameter is required and must not be empty")
        }
        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// Parse parameters.
        guard let path = parameters["path"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: path")
            )
        }

        /// Parse pagination parameters.
        let limit = (parameters["limit"] as? Int) ?? 100
        let offset = (parameters["offset"] as? Int) ?? 0

        /// Validate pagination parameters.
        guard limit > 0 && limit <= 1000 else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "limit must be between 1 and 1000")
            )
        }

        guard offset >= 0 else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "offset must be non-negative")
            )
        }

        /// Resolve path against workingDirectory if relative
        let resolvedPath: String
        if path.hasPrefix("/") || path.hasPrefix("~") {
            resolvedPath = (path as NSString).expandingTildeInPath
        } else if let workingDir = context.workingDirectory {
            resolvedPath = (workingDir as NSString).appendingPathComponent(path)
        } else {
            resolvedPath = (fileManager.currentDirectoryPath as NSString).appendingPathComponent(path)
        }

        /// Validate directory.
        let validation = safety.validateDirectory(resolvedPath)
        guard validation.isValid else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: validation.error ?? "Invalid directory")
            )
        }

        /// List directory contents.
        do {
            let listResult = try await listDirectory(resolvedPath, limit: limit, offset: offset)

            /// Build result with pagination metadata and clear success message.
            let dirName = (resolvedPath as NSString).lastPathComponent
            let successMessage = listResult.entries.isEmpty ?
                "Directory '\(dirName)' is empty (0 files/folders)" :
                "Directory '\(dirName)' listed successfully (\(listResult.totalCount) files/folders total)"

            let result = ListDirResult(
                message: successMessage,
                path: resolvedPath,
                entries: listResult.entries,
                count: listResult.entries.count,
                totalCount: listResult.totalCount,
                hasMore: listResult.hasMore,
                offset: offset,
                limit: limit
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
                output: MCPOutput(content: "List failed: \(error.localizedDescription)")
            )
        }
    }

    // MARK: - Directory Listing Implementation

    private struct ListResult {
        let entries: [DirectoryEntry]
        let totalCount: Int
        let hasMore: Bool
    }

    /// List contents of a directory with pagination.
    @MainActor
    private func listDirectory(_ path: String, limit: Int, offset: Int) async throws -> ListResult {
        let dirURL = URL(fileURLWithPath: path)
        var allEntries: [DirectoryEntry] = []

        /// Get directory contents.
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .fileSizeKey,
                    .contentModificationDateKey
                ],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw NSError(domain: "ListDirTool", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to read directory contents: \(error.localizedDescription)"
            ])
        }

        /// Process each entry.
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let resourceValues = try url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .fileSizeKey,
                    .contentModificationDateKey
                ])

                let isDirectory = resourceValues.isDirectory ?? false
                let size = isDirectory ? nil : resourceValues.fileSize.map { Int64($0) }
                let modifiedDate = resourceValues.contentModificationDate ?? Date()

                /// Get permissions using FileManager attributes.
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0

                let entry = DirectoryEntry(
                    name: url.lastPathComponent,
                    isDirectory: isDirectory,
                    size: size,
                    modifiedDate: formatDate(modifiedDate),
                    permissions: formatPermissions(permissions)
                )

                allEntries.append(entry)
            } catch {
                /// Skip entries we can't read metadata for.
                continue
            }
        }

        /// Apply pagination.
        let totalCount = allEntries.count
        let endIndex = min(offset + limit, totalCount)
        let paginatedEntries = offset < totalCount ? Array(allEntries[offset..<endIndex]) : []
        let hasMore = endIndex < totalCount

        return ListResult(entries: paginatedEntries, totalCount: totalCount, hasMore: hasMore)
    }

    // MARK: - Helper Methods

    /// Format date as ISO 8601 string.
    private func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Format POSIX permissions as Unix-style string (e.g., "rwxr-xr-x").
    private func formatPermissions(_ permissions: Int) -> String {
        let owner = formatPermissionTriple((permissions >> 6) & 0x7)
        let group = formatPermissionTriple((permissions >> 3) & 0x7)
        let other = formatPermissionTriple(permissions & 0x7)
        return owner + group + other
    }

    /// Format a permission triple (3 bits) as "rwx" string.
    private func formatPermissionTriple(_ triple: Int) -> String {
        let read = (triple & 0x4) != 0 ? "r" : "-"
        let write = (triple & 0x2) != 0 ? "w" : "-"
        let execute = (triple & 0x1) != 0 ? "x" : "-"
        return read + write + execute
    }
}
