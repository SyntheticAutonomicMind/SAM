// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Consolidated Build and Version Control Operations MCP Tool Combines create_and_run_task, run_task, get_task_output, git_commit, and get_changed_files.
public class BuildVersionControlTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "build_and_version_control"
    public let description = """
    Build tasks and version control operations.

    OPERATIONS (pass via 'operation' parameter):
    • create_and_run_task - Create and execute SAM task
    • run_task - Run existing SAM task by label
    • get_task_output - Get task execution output
    • git_commit - Commit changes to repository
    • get_changed_files - Get changed files in repo

    WHEN TO USE:
    - Building/compiling projects
    - Running automated tasks
    - Git commits and tracking changes

    WHEN NOT TO USE:
    - Simple shell commands (use terminal_operations)
    - Non-git version control
    - File operations unrelated to git

    KEY PARAMETERS:
    • operation: REQUIRED - operation type
    • task: Task config (create_and_run_task)
    • label: Task label (run_task)
    • message: Commit message (git_commit)

    EXAMPLES:
    SUCCESS: {"operation": "create_and_run_task", "task": {...}, "workspaceFolder": "/project"}
    SUCCESS: {"operation": "git_commit", "message": "Add feature X"}
    SUCCESS: {"operation": "get_changed_files"}
    """

    public var supportedOperations: [String] {
        return [
            "create_and_run_task",
            "run_task",
            "get_task_output",
            "git_commit",
            "get_changed_files"
        ]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: "Build/VCS operation to perform",
                required: true,
                enumValues: ["create_and_run_task", "run_task", "get_task_output", "git_commit", "get_changed_files"]
            ),
            "task": MCPToolParameter(
                type: .object(properties: [:]),
                description: "Task definition (for create_task)",
                required: false
            ),
            "workspaceFolder": MCPToolParameter(
                type: .string,
                description: "Workspace folder path",
                required: false
            ),
            "label": MCPToolParameter(
                type: .string,
                description: "Task label (for run_task)",
                required: false
            ),
            "id": MCPToolParameter(
                type: .string,
                description: "Task ID (for get_task_output)",
                required: false
            ),
            "message": MCPToolParameter(
                type: .string,
                description: "Commit message (for git_commit)",
                required: false
            ),
            "files": MCPToolParameter(
                type: .array,
                description: "Files to commit (for git_commit)",
                required: false,
                arrayElementType: .string
            ),
            "repositoryPath": MCPToolParameter(
                type: .string,
                description: "Git repository path (for get_changes)",
                required: false
            ),
            "sourceControlState": MCPToolParameter(
                type: .array,
                description: "Git state filter (for get_changes)",
                required: false,
                arrayElementType: .string
            )
        ]
    }

    private let logger = Logging.Logger(label: "com.sam.mcp.BuildVersionControl")

    public init() {
        logger.debug("BuildVersionControlTool initialized")

        /// Register with ToolDisplayInfoRegistry for proper progress indicators.
        ToolDisplayInfoRegistry.shared.register("build_and_version_control", provider: BuildVersionControlTool.self)
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

        switch operation {
        case "create_and_run_task":
            var taskParameters = parameters
            /// Default workspaceFolder to working directory if not provided
            if taskParameters["workspaceFolder"] == nil {
                if let workingDir = context.workingDirectory {
                    taskParameters["workspaceFolder"] = workingDir
                    logger.debug("create_and_run_task: Using working directory as default workspaceFolder: \(workingDir)")
                }
            }
            let tool = CreateAndRunTaskTool()
            return await tool.execute(parameters: taskParameters, context: context)

        case "run_task":
            let tool = RunTaskTool()
            return await tool.execute(parameters: parameters, context: context)

        case "get_task_output":
            let tool = GetTaskOutputTool()
            return await tool.execute(parameters: parameters, context: context)

        case "git_commit":
            /// Add confirm=true when authorized or user-initiated.
            var commitParameters = parameters
            let operationKey = "build_and_version_control.git_commit"
            let isAuthorized = context.conversationId.map {
                AuthorizationManager.shared.isAuthorized(conversationId: $0, operation: operationKey)
            } ?? false

            if isAuthorized || context.isUserInitiated {
                commitParameters["confirm"] = true
                logger.debug("Adding confirm=true to git_commit (authorized=\(isAuthorized), userInitiated=\(context.isUserInitiated))")
            }

            let tool = GitCommitTool()
            return await tool.execute(parameters: commitParameters, context: context)

        case "get_changed_files":
            var changedFilesParameters = parameters
            /// Default repositoryPath to working directory if not provided
            if changedFilesParameters["repositoryPath"] == nil {
                if let workingDir = context.workingDirectory {
                    changedFilesParameters["repositoryPath"] = workingDir
                    logger.debug("get_changed_files: Using working directory as default repositoryPath: \(workingDir)")
                }
            }
            let tool = GetChangedFilesTool()
            return await tool.execute(parameters: changedFilesParameters, context: context)

        default:
            return operationError(operation, message: "Unknown operation")
        }
    }

    // MARK: - Parameter Validation

    private func validateParameters(operation: String, parameters: [String: Any]) -> MCPToolResult? {
        switch operation {
        case "create_and_run_task":
            guard parameters["task"] != nil else {
                return operationError(operation, message: """
                    Missing required parameter 'task'.

                    Usage: {"operation": "create_and_run_task", "task": {...}, "workspaceFolder": "..."}
                    """)
            }
            /// workspaceFolder is optional - defaults to working directory if not provided

        case "run_task":
            guard parameters["label"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'label'.

                    Usage: {"operation": "run_task", "label": "task name"}
                    """)
            }

        case "git_commit":
            guard parameters["message"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'message'.

                    Usage: {"operation": "git_commit", "message": "commit message"}
                    Example: {"operation": "git_commit", "message": "feat: Add validation"}
                    """)
            }

        default:
            break
        }

        return nil
    }
}

// MARK: - Protocol Conformance

extension BuildVersionControlTool: ToolDisplayInfoProvider {
    public static func extractDisplayInfo(from arguments: [String: Any]) -> String? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        switch operation.lowercased().replacingOccurrences(of: "_", with: "") {
        case "runtests":
            if let files = arguments["files"] as? [String], !files.isEmpty {
                if files.count == 1 {
                    let filename = (files[0] as NSString).lastPathComponent
                    return "Running tests: \(filename)"
                } else {
                    return "Running tests: \(files.count) files"
                }
            }
            return "Running tests"

        case "createtask", "createandruntask":
            if let label = arguments["label"] as? String {
                return "Creating task: \(label)"
            }
            return "Creating task"

        case "runtask":
            if let taskName = arguments["taskName"] as? String {
                return "Running task: \(taskName)"
            }
            return "Running task"

        case "gettaskoutput":
            if let taskName = arguments["taskName"] as? String {
                return "Getting task output: \(taskName)"
            }
            return "Getting task output"

        case "gitcommit":
            if let message = arguments["message"] as? String {
                let preview = message.count > 60 ? String(message.prefix(57)) + "..." : message
                return "Committing: \(preview)"
            }
            return "Committing changes"

        case "getchanges", "getchangedfiles":
            return "Getting changed files"

        default:
            return nil
        }
    }

    public static func extractToolDetails(from arguments: [String: Any]) -> [String]? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        var details: [String] = []
        let normalizedOp = operation.lowercased().replacingOccurrences(of: "_", with: "")

        switch normalizedOp {
        case "runtests":
            if let files = arguments["files"] as? [String] {
                if files.isEmpty {
                    details.append("Running all tests in workspace")
                } else {
                    details.append("Files: \(files.count)")
                    /// Show first 2 files.
                    for file in files.prefix(2) {
                        let filename = (file as NSString).lastPathComponent
                        details.append("• \(filename)")
                    }
                    if files.count > 2 {
                        details.append("• ... and \(files.count - 2) more")
                    }
                }
            }
            if let mode = arguments["mode"] as? String {
                details.append("Mode: \(mode)")
            }
            return details.isEmpty ? nil : details

        case "createtask", "createandruntask":
            if let label = arguments["label"] as? String {
                details.append("Label: \(label)")
            }
            if let command = arguments["command"] as? String {
                let preview = command.count > 50 ? String(command.prefix(47)) + "..." : command
                details.append("Command: \(preview)")
            }
            if let group = arguments["group"] as? String {
                details.append("Group: \(group)")
            }
            return details.isEmpty ? nil : details

        case "runtask":
            if let taskName = arguments["taskName"] as? String {
                details.append("Task: \(taskName)")
            }
            if let workspaceFolder = arguments["workspaceFolder"] as? String {
                let folderName = (workspaceFolder as NSString).lastPathComponent
                details.append("Workspace: \(folderName)")
            }
            return details.isEmpty ? nil : details

        case "gettaskoutput":
            if let taskName = arguments["taskName"] as? String {
                details.append("Task: \(taskName)")
            }
            details.append("Retrieving task execution output")
            return details

        case "gitcommit":
            if let message = arguments["message"] as? String {
                let preview = message.count > 70 ? String(message.prefix(67)) + "..." : message
                details.append("Message: \(preview)")
            }
            if let filePaths = arguments["filePaths"] as? [String] {
                details.append("Files: \(filePaths.count)")
            } else {
                details.append("Files: All staged changes")
            }
            return details.isEmpty ? nil : details

        case "getchanges", "getchangedfiles":
            if let states = arguments["sourceControlState"] as? [String] {
                details.append("State filter: \(states.joined(separator: ", "))")
            } else {
                details.append("Getting all changes (staged, unstaged, conflicts)")
            }
            if let repoPath = arguments["repositoryPath"] as? String {
                let repoName = (repoPath as NSString).lastPathComponent
                details.append("Repository: \(repoName)")
            }
            return details.isEmpty ? nil : details

        default:
            return nil
        }
    }
}
