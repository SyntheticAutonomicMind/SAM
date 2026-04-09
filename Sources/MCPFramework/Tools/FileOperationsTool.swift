// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Unified File Operations MCP Tool Consolidates file_read_operations, file_search_operations, and file_write_operations into a single tool.
public class FileOperationsTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "file_operations"
    public let description = """
    File operations: read, search, write, and manage workspace files.

    AUTHORIZATION:
    • Inside working directory: AUTO-APPROVED
    • Outside working directory: Requires user_collaboration
    • Relative paths: Auto-resolve to working directory

    === READ (4 ops) ===
    • read_file - Read file with optional line range (filePath, offset, limit)
    • list_dir - List directory contents (path)
    • get_file_info - Get file metadata, size, type (filePath)
    • get_errors - Get compilation/lint errors (filePaths)

    === SEARCH (4 ops) ===
    • file_search - Find files by glob pattern (query, e.g., '**/*.swift')
    • grep_search - Text search with regex (query, isRegexp, includePattern)
    • semantic_search - AI-powered code search (query)
    • list_usages - Find all references to symbol (symbolName)

    === WRITE (6 ops, auto-approved inside working dir) ===
    • create_file - Create new file (filePath, content)
    • replace_string - Replace text in file (filePath, oldString, newString)
    • multi_replace_string - Multiple replacements (filePath, replacements)
    • insert_edit - Insert/replace at line number (filePath, lineNumber, newText)
    • rename_file - Rename or move file (oldPath, newPath)
    • delete_file - Delete file (filePath)

    WHEN TO USE:
    - Reading/editing code files
    - Searching codebase for patterns
    - Creating/modifying workspace files
    - Getting file metadata and document info

    WHEN NOT TO USE:
    - Web content (use web_operations)

    EXAMPLES:
    SUCCESS: {"operation": "read_file", "filePath": "/path/to/file.swift"}
    SUCCESS: {"operation": "grep_search", "query": "func.*test", "isRegexp": true, "includePattern": "**/*.swift"}
    SUCCESS: {"operation": "create_file", "filePath": "test.txt", "content": "Hello"}
    SUCCESS: {"operation": "get_file_info", "filePath": "document.pdf"}
    """

    public var supportedOperations: [String] {
        return [
            /// Read operations (4)
            "read_file", "list_dir", "get_file_info", "get_errors", "read_tool_result",
            /// Search operations (4)
            "file_search", "grep_search", "semantic_search", "list_usages",
            /// Write operations (6)
            "create_file", "replace_string", "multi_replace_string",
            "insert_edit", "rename_file", "delete_file"
        ]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: "File operation to perform (read/search/write category)",
                required: true,
                enumValues: [
                    "read_file", "list_dir", "get_file_info", "get_errors", "read_tool_result",
                    "file_search", "grep_search", "semantic_search", "list_usages",
                    "create_file", "replace_string", "multi_replace_string",
                    "insert_edit", "rename_file", "delete_file"
                ]
            ),
            /// Common parameters
            "filePath": MCPToolParameter(
                type: .string,
                description: "File path for read/write operations",
                required: false
            ),
            "filePaths": MCPToolParameter(
                type: .array,
                description: "Multiple file paths (for get_errors, list_usages)",
                required: false,
                arrayElementType: .string
            ),
            "path": MCPToolParameter(
                type: .string,
                description: "Directory path (for list_dir)",
                required: false
            ),
            /// Read parameters
            "offset": MCPToolParameter(
                type: .integer,
                description: "Line offset to start reading from (for read_file)",
                required: false
            ),
            "limit": MCPToolParameter(
                type: .integer,
                description: "Maximum lines to read (for read_file)",
                required: false
            ),
            /// Search parameters
            "query": MCPToolParameter(
                type: .string,
                description: "Search query or glob pattern (for search operations)",
                required: false
            ),
            "isRegexp": MCPToolParameter(
                type: .boolean,
                description: "Whether query is regex (for grep_search)",
                required: false
            ),
            "includePattern": MCPToolParameter(
                type: .string,
                description: "File pattern to include in search",
                required: false
            ),
            "symbolName": MCPToolParameter(
                type: .string,
                description: "Symbol name to find usages (for list_usages)",
                required: false
            ),
            "maxResults": MCPToolParameter(
                type: .integer,
                description: "Maximum results to return (for search operations)",
                required: false
            ),
            /// Write parameters
            "content": MCPToolParameter(
                type: .string,
                description: "File content (for create_file)",
                required: false
            ),
            "oldString": MCPToolParameter(
                type: .string,
                description: "String to replace (for replace_string)",
                required: false
            ),
            "newString": MCPToolParameter(
                type: .string,
                description: "Replacement string (for replace_string)",
                required: false
            ),
            "replacements": MCPToolParameter(
                type: .array,
                description: "Array of {oldString, newString} replacements (for multi_replace_string)",
                required: false,
                arrayElementType: .object(properties: [:])
            ),
            "lineNumber": MCPToolParameter(
                type: .integer,
                description: "Line number for insert/replace (1-based, for insert_edit)",
                required: false
            ),
            "newText": MCPToolParameter(
                type: .string,
                description: "Text to insert or replace (for insert_edit)",
                required: false
            ),
            "insertOperation": MCPToolParameter(
                type: .string,
                description: "Insert operation type: 'insert' or 'replace' (for insert_edit)",
                required: false,
                enumValues: ["insert", "replace"]
            ),
            "newPath": MCPToolParameter(
                type: .string,
                description: "New file path (for rename_file)",
                required: false
            ),
            "oldPath": MCPToolParameter(
                type: .string,
                description: "Original file path (for rename_file)",
                required: false
            )
        ]
    }

    private let logger = Logging.Logger(label: "com.sam.mcp.FileOperations")

    public init() {
        logger.debug("FileOperationsTool initialized - unified file operations (15 operations total)")

        /// Register with ToolDisplayInfoRegistry for proper progress indicators.
        ToolDisplayInfoRegistry.shared.register("file_operations", provider: FileOperationsTool.self)
    }

    /// Resolve file path against working directory if it's relative - Parameters: - path: The file path (may be absolute or relative) - context: Execution context containing working directory - Returns: Absolute file path.
    private func resolvePath(_ path: String, context: MCPExecutionContext) -> String {
        /// If path is absolute, return as-is.
        if path.hasPrefix("/") || path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }

        /// If path is relative and working directory exists, resolve against it.
        if let workingDir = context.workingDirectory {
            let resolvedPath = (workingDir as NSString).appendingPathComponent(path)
            logger.debug("Resolved relative path '\(path)' to '\(resolvedPath)' using working directory '\(workingDir)'")
            return resolvedPath
        }

        /// Fallback: resolve against current directory.
        let currentDir = FileManager.default.currentDirectoryPath
        return (currentDir as NSString).appendingPathComponent(path)
    }

    @MainActor
    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        /// Validate parameters before routing.
        if let validationError = validateParameters(operation: operation, parameters: parameters) {
            return validationError
        }

        /// AUTHORIZATION CHECK using centralized guard.
        /// Check authorization for ALL operations that access file paths.
        /// Read operations outside the working directory are just as dangerous
        /// as write operations - they allow agents to traverse the file system
        /// and read arbitrary files (SSH keys, credentials, source code, etc.).
        let pathFreeOperations = ["read_tool_result"]
        var isAuthorized = false

        if !pathFreeOperations.contains(operation) {
            let operationKey = "file_operations.\(operation)"

            /// Extract the primary file path for authorization check.
            /// Cover ALL path parameter names used across MCP tools.
            let primaryPath: String? = {
                if let filePath = parameters["filePath"] as? String {
                    return filePath
                }
                if let path = parameters["path"] as? String {
                    return path
                }
                if let oldPath = parameters["oldPath"] as? String {
                    return oldPath
                }
                if let rootPath = parameters["rootPath"] as? String {
                    return rootPath
                }
                if let filePath = parameters["file_path"] as? String {
                    return filePath
                }
                if let directory = parameters["directory"] as? String {
                    return directory
                }
                if let workspacePath = parameters["workspace_path"] as? String {
                    return workspacePath
                }
                /// Check array-style paths (filePaths) - authorize the first one
                /// as a representative check (all should be in the same scope).
                if let filePaths = parameters["filePaths"] as? [String],
                   let first = filePaths.first {
                    return first
                }
                return nil
            }()

            if let path = primaryPath {
                /// Use centralized authorization guard.
                let authResult = MCPAuthorizationGuard.checkPathAuthorization(
                    path: path,
                    workingDirectory: context.workingDirectory,
                    conversationId: context.conversationId,
                    operation: operationKey,
                    isUserInitiated: context.isUserInitiated
                )

                switch authResult {
                case .allowed(let reason):
                    logger.debug("Operation authorized", metadata: [
                        "operation": .string(operation),
                        "path": .string(path),
                        "reason": .string(reason)
                    ])
                    isAuthorized = true

                case .denied(let reason):
                    return operationError(operation, message: "Operation denied: \(reason)")

                case .requiresAuthorization(let reason):
                    let authError = MCPAuthorizationGuard.authorizationError(
                        operation: operationKey,
                        reason: reason,
                        suggestedPrompt: "May I \(operation) on \(path)?"
                    )
                    if let errorMsg = authError["error"] as? String {
                        return operationError(operation, message: errorMsg)
                    }
                    return operationError(operation, message: "Authorization required for path: \(path)")
                }
            }
        }

        /// Route to appropriate internal tool based on operation.
        /// Resolve file paths against working directory for relative paths.
        var resolvedParams = parameters

        /// Resolve common path parameters.
        if let filePath = parameters["filePath"] as? String {
            resolvedParams["filePath"] = resolvePath(filePath, context: context)
        }
        if let path = parameters["path"] as? String {
            resolvedParams["path"] = resolvePath(path, context: context)
        }
        if let oldPath = parameters["oldPath"] as? String {
            resolvedParams["oldPath"] = resolvePath(oldPath, context: context)
        }
        if let newPath = parameters["newPath"] as? String {
            resolvedParams["newPath"] = resolvePath(newPath, context: context)
        }
        if let rootPath = parameters["rootPath"] as? String {
            resolvedParams["rootPath"] = resolvePath(rootPath, context: context)
        }
        if let filePath = parameters["file_path"] as? String {
            resolvedParams["file_path"] = resolvePath(filePath, context: context)
        }
        if let workspacePath = parameters["workspace_path"] as? String {
            resolvedParams["workspace_path"] = resolvePath(workspacePath, context: context)
        }
        if let filePaths = parameters["filePaths"] as? [String] {
            resolvedParams["filePaths"] = filePaths.map { resolvePath($0, context: context) }
        }

        switch operation {
        /// READ OPERATIONS (4).
        case "read_file":
            let tool = ReadFileTool()
            return await tool.execute(parameters: resolvedParams, context: context)

        case "list_dir":
            /// If no path provided, default to working directory or current directory
            if resolvedParams["path"] == nil {
                if let workingDir = context.workingDirectory {
                    resolvedParams["path"] = workingDir
                    logger.debug("list_dir: Using working directory as default path: \(workingDir)")
                } else {
                    resolvedParams["path"] = FileManager.default.currentDirectoryPath
                    logger.debug("list_dir: Using current directory as default path")
                }
            }
            let tool = ListDirTool()
            return await tool.execute(parameters: resolvedParams, context: context)

        case "get_errors":
            let tool = GetErrorsTool()
            return await tool.execute(parameters: resolvedParams, context: context)

        case "get_file_info":
            let tool = GetDocInfoTool()
            return await tool.execute(parameters: resolvedParams, context: context)

        case "read_tool_result":
            /// Delegate to ReadToolResultTool for chunked reading of large tool outputs
            let tool = ReadToolResultTool()
            return await tool.execute(parameters: parameters, context: context)

        /// SEARCH OPERATIONS (4)
        case "file_search":
            let tool = FileSearchTool()
            return await tool.execute(parameters: resolvedParams, context: context)

        case "grep_search":
            let tool = GrepSearchTool()
            return await tool.execute(parameters: resolvedParams, context: context)

        case "semantic_search":
            let tool = SemanticSearchTool()
            return await tool.execute(parameters: resolvedParams, context: context)

        case "list_usages":
            let tool = ListCodeUsagesTool()
            return await tool.execute(parameters: resolvedParams, context: context)

        /// WRITE OPERATIONS (6) - All include confirm=true when authorized.
        case "create_file":
            var createParams = resolvedParams

            /// Use stored authorization result (already consumed above).
            if isAuthorized || context.isUserInitiated {
                createParams["confirm"] = true
                logger.debug("Adding confirm=true to create_file (authorized=\(isAuthorized), userInitiated=\(context.isUserInitiated))")
            }

            let tool = CreateFileTool()
            return await tool.execute(parameters: createParams, context: context)

        case "replace_string":
            var replaceParams = resolvedParams

            /// Use stored authorization result (already consumed above).
            if isAuthorized || context.isUserInitiated {
                replaceParams["confirm"] = true
                logger.debug("Adding confirm=true to replace_string (authorized=\(isAuthorized), userInitiated=\(context.isUserInitiated))")
            }

            let tool = ReplaceStringTool()
            return await tool.execute(parameters: replaceParams, context: context)

        case "multi_replace_string":
            var multiReplaceParams = resolvedParams

            /// Use stored authorization result (already consumed above).
            if isAuthorized || context.isUserInitiated {
                multiReplaceParams["confirm"] = true
                logger.debug("Adding confirm=true to multi_replace_string (authorized=\(isAuthorized), userInitiated=\(context.isUserInitiated))")
            }

            let tool = MultiReplaceStringTool()
            return await tool.execute(parameters: multiReplaceParams, context: context)

        case "insert_edit":
            /// Transform parameters: insertOperation → operation for InsertEditTool.
            var insertParams = resolvedParams
            if let insertOperation = resolvedParams["insertOperation"] as? String {
                insertParams["operation"] = insertOperation
                insertParams.removeValue(forKey: "insertOperation")
            }

            /// Use stored authorization result (already consumed above).
            if isAuthorized || context.isUserInitiated {
                insertParams["confirm"] = true
                logger.debug("Adding confirm=true to insert_edit (authorized=\(isAuthorized), userInitiated=\(context.isUserInitiated))")
            }

            let tool = InsertEditTool()
            return await tool.execute(parameters: insertParams, context: context)

        case "rename_file":
            /// Transform parameters: oldPath → old_path, newPath → new_path Already resolved in resolvedParams.
            var renameParams = resolvedParams
            if let oldPath = resolvedParams["oldPath"] as? String {
                renameParams["old_path"] = oldPath
                renameParams.removeValue(forKey: "oldPath")
            }
            if let newPath = resolvedParams["newPath"] as? String {
                renameParams["new_path"] = newPath
                renameParams.removeValue(forKey: "newPath")
            }

            /// Use stored authorization result (already consumed above).
            if isAuthorized || context.isUserInitiated {
                renameParams["confirm"] = true
                logger.debug("Adding confirm=true to rename_file (authorized=\(isAuthorized), userInitiated=\(context.isUserInitiated))")
            }

            let tool = RenameFileTool()
            return await tool.execute(parameters: renameParams, context: context)

        case "delete_file":
            var deleteParams = resolvedParams

            /// Use stored authorization result (already consumed above).
            if isAuthorized || context.isUserInitiated {
                deleteParams["confirm"] = true
                logger.debug("Adding confirm=true to delete_file (authorized=\(isAuthorized), userInitiated=\(context.isUserInitiated))")
            }

            let tool = DeleteFileTool()
            return await tool.execute(parameters: deleteParams, context: context)

        default:
            return operationError(operation, message: "Unknown file operation")
        }
    }

    public func progressMessage(for operation: String, parameters: [String: Any]) -> String {
        /// Provide granular progress messages based on operation category.
        switch operation {
        /// Read operations.
        case "read_file":
            if let filePath = parameters["filePath"] as? String {
                let fileName = (filePath as NSString).lastPathComponent
                return "Reading file: \(fileName)"
            }
            return "Reading file"

        case "list_dir":
            if let path = parameters["path"] as? String {
                let dirName = (path as NSString).lastPathComponent
                return "Listing directory: \(dirName)"
            }
            return "Listing directory"

        case "get_errors":
            if let filePaths = parameters["filePaths"] as? [String], !filePaths.isEmpty {
                return "Checking errors in \(filePaths.count) file(s)"
            }
            return "Checking workspace errors"

        case "get_file_info":
            if let filePath = parameters["filePath"] as? String {
                let fileName = (filePath as NSString).lastPathComponent
                return "Getting info: \(fileName)"
            }
            return "Getting file info"

        /// Search operations.
        case "file_search":
            if let query = parameters["query"] as? String {
                return "Searching files: \(query)"
            }
            return "Searching files"

        case "grep_search":
            if let query = parameters["query"] as? String {
                let isRegexp = parameters["isRegexp"] as? Bool ?? false
                return isRegexp ? "Searching code (regex): \(query)" : "Searching code: \(query)"
            }
            return "Searching code"

        case "semantic_search":
            if let query = parameters["query"] as? String {
                return "Semantic search: \(query)"
            }
            return "Semantic search"

        case "list_usages":
            if let symbolName = parameters["symbolName"] as? String {
                return "Finding usages of: \(symbolName)"
            }
            return "Finding symbol usages"

        /// Write operations.
        case "create_file":
            if let filePath = parameters["filePath"] as? String {
                let fileName = (filePath as NSString).lastPathComponent
                return "Creating file: \(fileName)"
            }
            return "Creating file"

        case "replace_string":
            if let filePath = parameters["filePath"] as? String {
                let fileName = (filePath as NSString).lastPathComponent
                return "Replacing text in: \(fileName)"
            }
            return "Replacing text"

        case "multi_replace_string":
            if let filePath = parameters["filePath"] as? String {
                let fileName = (filePath as NSString).lastPathComponent
                let count = (parameters["replacements"] as? [[String: Any]])?.count ?? 0
                return "Applying \(count) replacements to: \(fileName)"
            }
            return "Applying multiple replacements"

        case "insert_edit":
            if let filePath = parameters["filePath"] as? String {
                let fileName = (filePath as NSString).lastPathComponent
                let insertOp = parameters["insertOperation"] as? String ?? "edit"
                return "\(insertOp.capitalized) text in: \(fileName)"
            }
            return "Editing file"

        case "rename_file":
            if let oldPath = parameters["oldPath"] as? String {
                let oldName = (oldPath as NSString).lastPathComponent
                return "Renaming file: \(oldName)"
            }
            return "Renaming file"

        case "delete_file":
            if let filePath = parameters["filePath"] as? String {
                let fileName = (filePath as NSString).lastPathComponent
                return "Deleting file: \(fileName)"
            }
            return "Deleting file"

        default:
            return "File operation: \(operation)"
        }
    }

    public func validateParameters(operation: String, parameters: [String: Any]) -> MCPToolResult? {
        /// Operation-specific validation.
        switch operation {
        /// Read operations.
        case "read_file":
            guard parameters["filePath"] is String else {
                return operationError(operation, message: "Missing required parameter: filePath")
            }

        case "list_dir":
            /// path is optional - if not provided, defaults to working directory
            break

        case "get_errors":
            /// filePaths is optional (all files if not specified)
            break

        case "get_file_info":
            guard parameters["filePath"] is String else {
                return operationError(operation, message: "Missing required parameter: filePath")
            }

        /// Search operations.
        case "file_search", "grep_search", "semantic_search":
            guard parameters["query"] is String else {
                return operationError(operation, message: "Missing required parameter: query")
            }
            if operation == "grep_search" {
                guard parameters["isRegexp"] is Bool else {
                    return operationError(operation, message: "Missing required parameter: isRegexp")
                }
            }

        case "list_usages":
            guard parameters["symbolName"] is String else {
                return operationError(operation, message: "Missing required parameter: symbolName")
            }

            break

        /// Write operations.
        case "create_file":
            guard parameters["filePath"] is String else {
                return operationError(operation, message: "Missing required parameter: filePath")
            }
            guard parameters["content"] is String else {
                return operationError(operation, message: "Missing required parameter: content")
            }

        case "replace_string":
            guard parameters["filePath"] is String else {
                return operationError(operation, message: "Missing required parameter: filePath")
            }
            guard parameters["oldString"] is String else {
                return operationError(operation, message: "Missing required parameter: oldString")
            }
            guard parameters["newString"] is String else {
                return operationError(operation, message: "Missing required parameter: newString")
            }

        case "multi_replace_string":
            guard parameters["filePath"] is String else {
                return operationError(operation, message: "Missing required parameter: filePath")
            }
            guard parameters["replacements"] is [[String: Any]] else {
                return operationError(operation, message: "Missing required parameter: replacements (array)")
            }

        case "insert_edit":
            guard parameters["filePath"] is String else {
                return operationError(operation, message: "Missing required parameter: filePath")
            }
            guard parameters["lineNumber"] is Int else {
                return operationError(operation, message: "Missing required parameter: lineNumber")
            }
            guard parameters["newText"] is String else {
                return operationError(operation, message: "Missing required parameter: newText")
            }
            guard let op = parameters["insertOperation"] as? String, ["insert", "replace"].contains(op) else {
                return operationError(operation, message: "Missing or invalid parameter: insertOperation (must be 'insert' or 'replace')")
            }

        case "rename_file":
            guard parameters["oldPath"] is String else {
                return operationError(operation, message: "Missing required parameter: oldPath")
            }
            guard parameters["newPath"] is String else {
                return operationError(operation, message: "Missing required parameter: newPath")
            }

        case "delete_file":
            guard parameters["filePath"] is String else {
                return operationError(operation, message: "Missing required parameter: filePath")
            }

        default:
            return operationError(operation, message: "Unknown operation")
        }

        return nil
    }
}

// MARK: - Protocol Conformance

extension FileOperationsTool: ToolDisplayInfoProvider {
    public static func extractDisplayInfo(from arguments: [String: Any]) -> String? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        switch operation {
        /// Read operations.
        case "read_file":
            if let filePath = arguments["filePath"] as? String {
                let filename = (filePath as NSString).lastPathComponent
                return "Reading: \(filename)"
            }
            return "Reading file"

        case "list_dir":
            if let path = arguments["path"] as? String {
                let dirname = (path as NSString).lastPathComponent
                return "Listing: \(dirname)"
            }
            return "Listing directory"

        case "get_errors":
            return "Checking errors"

        case "get_file_info":
            if let filePath = arguments["filePath"] as? String {
                let filename = (filePath as NSString).lastPathComponent
                return "Info: \(filename)"
            }
            return "Getting file info"

        /// Search operations.
        case "file_search":
            if let query = arguments["query"] as? String {
                return "Finding files: \(query)"
            }
            return "Finding files"

        case "grep_search":
            if let query = arguments["query"] as? String {
                return "Searching: \(query)"
            }
            return "Searching code"

        case "semantic_search":
            if let query = arguments["query"] as? String {
                return "Semantic search: \(query)"
            }
            return "Semantic search"

        case "list_usages":
            if let symbolName = arguments["symbolName"] as? String {
                return "Finding usages: \(symbolName)"
            }
            return "Finding usages"

        /// Write operations.
        case "create_file":
            if let filePath = arguments["filePath"] as? String {
                let filename = (filePath as NSString).lastPathComponent
                return "Creating: \(filename)"
            }
            return "Creating file"

        case "replace_string":
            if let filePath = arguments["filePath"] as? String {
                let filename = (filePath as NSString).lastPathComponent
                return "Editing: \(filename)"
            }
            return "Editing file"

        case "multi_replace_string":
            if let filePath = arguments["filePath"] as? String {
                let filename = (filePath as NSString).lastPathComponent
                return "Multi-edit: \(filename)"
            }
            return "Multi-editing file"

        case "insert_edit":
            if let filePath = arguments["filePath"] as? String {
                let filename = (filePath as NSString).lastPathComponent
                return "Inserting in: \(filename)"
            }
            return "Inserting in file"

        case "rename_file":
            if let oldPath = arguments["oldPath"] as? String {
                let oldName = (oldPath as NSString).lastPathComponent
                return "Renaming: \(oldName)"
            }
            return "Renaming file"

        case "delete_file":
            if let filePath = arguments["filePath"] as? String {
                let filename = (filePath as NSString).lastPathComponent
                return "Deleting: \(filename)"
            }
            return "Deleting file"

        default:
            return nil
        }
    }

    public static func extractToolDetails(from arguments: [String: Any]) -> [String]? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        var details: [String] = []

        switch operation {
        /// Read operations.
        case "read_file":
            if let filePath = arguments["filePath"] as? String {
                details.append("File: \((filePath as NSString).lastPathComponent)")
                if let offset = arguments["offset"] as? Int {
                    details.append("Starting at line: \(offset)")
                }
                if let limit = arguments["limit"] as? Int {
                    details.append("Reading: \(limit) lines")
                }
            }
            return details.isEmpty ? nil : details

        case "list_dir":
            if let path = arguments["path"] as? String {
                details.append("Directory: \((path as NSString).lastPathComponent)")
            }
            return details.isEmpty ? nil : details

        case "get_errors":
            if let filePaths = arguments["filePaths"] as? [String] {
                details.append("Files: \(filePaths.count)")
            } else {
                details.append("Checking all files")
            }
            return details

        case "get_file_info":
            if let filePath = arguments["filePath"] as? String {
                details.append("File: \((filePath as NSString).lastPathComponent)")
            }
            return details.isEmpty ? nil : details

        /// Search operations.
        case "file_search":
            if let query = arguments["query"] as? String {
                details.append("Pattern: \(query)")
            }
            if let maxResults = arguments["maxResults"] as? Int {
                details.append("Max results: \(maxResults)")
            }
            return details.isEmpty ? nil : details

        case "grep_search":
            if let query = arguments["query"] as? String {
                let preview = query.count > 50 ? String(query.prefix(47)) + "..." : query
                details.append("Pattern: \(preview)")
            }
            if let includePattern = arguments["includePattern"] as? String {
                details.append("In: \(includePattern)")
            }
            if let isRegexp = arguments["isRegexp"] as? Bool, isRegexp {
                details.append("Mode: Regular expression")
            }
            return details.isEmpty ? nil : details

        case "semantic_search":
            if let query = arguments["query"] as? String {
                let preview = query.count > 60 ? String(query.prefix(57)) + "..." : query
                details.append("Query: \(preview)")
            }
            return details.isEmpty ? nil : details

        case "list_usages":
            if let symbolName = arguments["symbolName"] as? String {
                details.append("Symbol: \(symbolName)")
            }
            if let filePaths = arguments["filePaths"] as? [String] {
                details.append("Files: \(filePaths.count) specified")
            }
            return details.isEmpty ? nil : details

        /// Write operations.
        case "create_file":
            if let filePath = arguments["filePath"] as? String {
                details.append("File: \((filePath as NSString).lastPathComponent)")
            }
            if let content = arguments["content"] as? String {
                let lines = content.components(separatedBy: .newlines).count
                details.append("Size: \(lines) lines")
            }
            return details.isEmpty ? nil : details

        case "replace_string":
            if let filePath = arguments["filePath"] as? String {
                details.append("File: \((filePath as NSString).lastPathComponent)")
            }
            if let oldString = arguments["oldString"] as? String {
                let lines = oldString.components(separatedBy: .newlines).count
                details.append("Replacing: \(lines) line(s)")
            }
            return details.isEmpty ? nil : details

        case "multi_replace_string":
            if let filePath = arguments["filePath"] as? String {
                details.append("File: \((filePath as NSString).lastPathComponent)")
            }
            if let replacements = arguments["replacements"] as? [[String: Any]] {
                details.append("Changes: \(replacements.count) replacements")
            }
            return details.isEmpty ? nil : details

        case "insert_edit":
            if let filePath = arguments["filePath"] as? String {
                details.append("File: \((filePath as NSString).lastPathComponent)")
            }
            if let lineNumber = arguments["lineNumber"] as? Int {
                details.append("At line: \(lineNumber)")
            }
            return details.isEmpty ? nil : details

        case "rename_file":
            if let oldPath = arguments["oldPath"] as? String,
               let newPath = arguments["newPath"] as? String {
                details.append("From: \((oldPath as NSString).lastPathComponent)")
                details.append("To: \((newPath as NSString).lastPathComponent)")
            }
            return details.isEmpty ? nil : details

        case "delete_file":
            if let filePath = arguments["filePath"] as? String {
                details.append("File: \((filePath as NSString).lastPathComponent)")
            }
            return details.isEmpty ? nil : details

        default:
            return nil
        }
    }
}
