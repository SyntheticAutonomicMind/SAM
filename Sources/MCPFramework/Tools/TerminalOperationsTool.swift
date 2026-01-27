// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Consolidated Terminal Operations MCP Tool Combines run_in_terminal, get_terminal_output, terminal_last_command, terminal_selection, create_directory, and terminal_session management.
public class TerminalOperationsTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "terminal_operations"
    public let description = """
    Execute terminal commands and manage persistent PTY sessions.

    OPERATIONS:
    • run_command - Execute shell command (command, explanation, isBackground)
    • get_terminal_output/buffer - Get output from background process (id)
    • get_last_command/get_terminal_selection - Get command/selection
    • create_directory - Create directory recursively (dirPath)
    • create_session - Start PTY session (working_directory)
    • send_input - Send to session (session_id, input). Shell: end with \\r\\n
    • get_output/get_history - Read session output (session_id)
    • close_session - Close session (session_id)

    IMPORTANT:
    • isBackground=true ONLY for long-running servers. Default false.
    • send_input: Shell commands need \\r\\n, keystrokes don't

    SSH/REMOTE ACCESS:
    • Verify location: 'echo $HOSTNAME' before SSH
    • If already on target system, don't SSH again
    • Connect first, verify connection, then work
    """

    public var supportedOperations: [String] {
        return [
            "run_command",
            "get_terminal_output",
            "get_terminal_buffer",
            "get_last_command",
            "get_terminal_selection",
            "create_directory",
            /// Merged from terminal_session:.
            "create_session",
            "send_input",
            "get_output",
            "get_history",
            "close_session"
        ]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: "Terminal operation to perform",
                required: true,
                enumValues: [
                    "run_command", "get_terminal_output", "get_terminal_buffer", "get_last_command",
                    "get_terminal_selection", "create_directory", "create_session", "send_input",
                    "get_output", "get_history", "close_session"
                ]
            ),
            "command": MCPToolParameter(
                type: .string,
                description: "Shell command to execute (for run_command)",
                required: false
            ),
            "explanation": MCPToolParameter(
                type: .string,
                description: "Command explanation (for run_command)",
                required: false
            ),
            "isBackground": MCPToolParameter(
                type: .boolean,
                description: """
                    CRITICAL: Run as background process. Use ONLY for:
                    SUCCESS: Long-running servers (web servers, dev servers)
                    SUCCESS: Watch mode processes (file watchers, auto-rebuild)

                    NEVER use for workflow execution commands:
                    ssh commands (must wait for response)
                    file operations (must confirm completion)
                    installation commands (must verify success)
                    ANY command where you need the output

                    Default: false (RECOMMENDED for 99% of commands)
                    """,
                required: false
            ),
            "id": MCPToolParameter(
                type: .string,
                description: "Terminal ID (for get_terminal_output)",
                required: false
            ),
            "dirPath": MCPToolParameter(
                type: .string,
                description: "Directory path (for create_directory)",
                required: false
            ),
            "session_id": MCPToolParameter(
                type: .string,
                description: "PTY session ID (for send_input, get_output, get_history, close_session)",
                required: false
            ),
            "conversation_id": MCPToolParameter(
                type: .string,
                description: "Conversation ID to use as session ID (for create_session)",
                required: false
            ),
            "input": MCPToolParameter(
                type: .string,
                description: "Command/input to send (for send_input)",
                required: false
            ),
            "working_directory": MCPToolParameter(
                type: .string,
                description: "Initial working directory (for create_session)",
                required: false
            ),
            "from_index": MCPToolParameter(
                type: .integer,
                description: "Start reading from this index (for get_output)",
                required: false
            )
        ]
    }

    private let logger = Logging.Logger(label: "com.sam.mcp.TerminalOperations")

    public init() {
        logger.debug("TerminalOperationsTool initialized")

        /// Register with ToolDisplayInfoRegistry for proper progress indicators.
        ToolDisplayInfoRegistry.shared.register("terminal_operations", provider: TerminalOperationsTool.self)
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

        /// AUTHORIZATION CHECK using centralized guard Check authorization for restricted operations based on path/command location.
        if operation == "create_directory" {
            let operationKey = "terminal_operations.create_directory"

            if let path = parameters["path"] as? String {
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

                case .denied(let reason):
                    return operationError(operation, message: "Operation denied: \(reason)")

                case .requiresAuthorization(let reason):
                    let authError = MCPAuthorizationGuard.authorizationError(
                        operation: operationKey,
                        reason: reason,
                        suggestedPrompt: "May I create directory \(path)?"
                    )
                    if let errorMsg = authError["error"] as? String {
                        return operationError(operation, message: errorMsg)
                    }
                    return operationError(operation, message: "Authorization required for path: \(path)")
                }
            }
        }

        /// Trace terminal operation routing.
        logger.critical("DEBUG_TRACE: TerminalOperationsTool.routeOperation ENTRY - operation=\(operation) command=\(parameters["command"] as? String ?? "none")")

        switch operation {
        case "run_command":
            /// Inject working directory from context if not explicitly provided.
            var runCommandParameters = parameters
            if runCommandParameters["working_directory"] == nil, let workingDir = context.workingDirectory {
                runCommandParameters["working_directory"] = workingDir
                logger.debug("Injected working directory from context: \(workingDir)")
            }

            /// Commands within working directory are allowed by default Authorization guard handles this automatically.
            if let command = parameters["command"] as? String {
                let operationKey = "terminal_operations.run_command"
                let authResult = MCPAuthorizationGuard.checkCommandAuthorization(
                    command: command,
                    workingDirectory: context.workingDirectory,
                    conversationId: context.conversationId,
                    operation: operationKey,
                    isUserInitiated: context.isUserInitiated
                )

                if authResult.isAllowed {
                    runCommandParameters["confirm"] = true
                    logger.debug("Command authorized", metadata: [
                        "command": .string(command),
                        "reason": .string(authResult.reason)
                    ])
                }
            }

            let tool = RunInTerminalTool()
            return await tool.execute(parameters: runCommandParameters, context: context)

        case "get_terminal_output":
            let tool = GetTerminalOutputTool()
            return await tool.execute(parameters: parameters, context: context)

        case "get_terminal_buffer":
            /// Get current terminal buffer contents (what user sees).
            return await getTerminalBuffer(context: context)

        case "get_last_command":
            let tool = TerminalLastCommandTool()
            return await tool.execute(parameters: parameters, context: context)

        case "get_terminal_selection":
            let tool = TerminalSelectionTool()
            return await tool.execute(parameters: parameters, context: context)

        case "create_directory":
            /// Add confirm=true when authorized or user-initiated.
            var createDirParameters = parameters
            let operationKey = "terminal_operations.create_directory"
            let isAuthorized = context.conversationId.map {
                AuthorizationManager.shared.isAuthorized(conversationId: $0, operation: operationKey)
            } ?? false

            if isAuthorized || context.isUserInitiated {
                createDirParameters["confirm"] = true
                logger.debug("Adding confirm=true to create_directory (authorized=\(isAuthorized), userInitiated=\(context.isUserInitiated))")
            }

            let tool = CreateDirectoryTool()
            return await tool.execute(parameters: createDirParameters, context: context)

        /// Terminal session operations (merged from TerminalSessionTool).
        case "create_session":
            return await createSession(parameters: parameters, context: context)

        case "send_input":
            return await sendInput(parameters: parameters, context: context)

        case "get_output":
            return await getOutput(parameters: parameters, context: context)

        case "get_history":
            return await getHistory(parameters: parameters, context: context)

        case "close_session":
            return await closeSession(parameters: parameters, context: context)

        default:
            return operationError(operation, message: "Unknown operation")
        }
    }

    // MARK: - Parameter Validation

    private func validateParameters(operation: String, parameters: [String: Any]) -> MCPToolResult? {
        switch operation {
        case "run_command":
            guard parameters["command"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'command'.

                    Usage: {"operation": "run_command", "command": "shell command"}
                    Example: {"operation": "run_command", "command": "ls -la"}
                    """)
            }

        case "get_terminal_output":
            guard parameters["id"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'id'.

                    Usage: {"operation": "get_terminal_output", "id": "terminal_id"}
                    """)
            }

        case "create_directory":
            guard parameters["dirPath"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'dirPath'.

                    Usage: {"operation": "create_directory", "dirPath": "/path/to/directory"}
                    """)
            }

        /// Terminal session operations validation.
        case "send_input":
            guard parameters["session_id"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'session_id'.

                    Usage: {"operation": "send_input", "session_id": "session_id", "input": "command"}
                    """)
            }
            guard parameters["input"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'input'.

                    CRITICAL: Shell commands MUST end with \\r\\n to execute!

                    Usage:
                    - Shell command: {"operation": "send_input", "session_id": "...", "input": "ls -la\\r\\n"}
                    - Interactive keystrokes: {"operation": "send_input", "session_id": "...", "input": ":wq\\r"}

                    Without \\r\\n, commands will concatenate with next input!
                    """)
            }

        case "get_output", "get_history", "close_session":
            guard parameters["session_id"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'session_id'.

                    Usage: {"operation": "\(operation)", "session_id": "session_id"}
                    """)
            }

        default:
            break
        }

        return nil
    }

    // MARK: - Terminal Session Operations (merged from TerminalSessionTool)

    @MainActor
    private func createSession(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// CRITICAL: Resolve working directory properly
        /// If AI passes relative path like "./" - resolve against context.workingDirectory
        /// Always fall back to context.workingDirectory, then home directory
        let workingDirectory: String = {
            if let providedPath = parameters["working_directory"] as? String {
                // Resolve using canonical path resolution (handles relative paths, tilde expansion)
                let resolved = MCPAuthorizationGuard.resolvePath(providedPath, workingDirectory: context.workingDirectory)
                if providedPath != resolved {
                    logger.warning("Resolved relative working_directory: '\(providedPath)' → '\(resolved)'")
                }
                return resolved
            }
            // No working_directory provided - use context's working directory or home
            return context.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        }()

        /// Use context.conversationId automatically if not provided This enables conversation-scoped session persistence without agent needing to manage it.
        let conversationId = parameters["conversation_id"] as? String
            ?? context.conversationId?.uuidString

        /// CRITICAL: Check PTYSessionManager first - this is the source of truth
        /// If UI terminal exists for this conversation, reuse its session
        if let convId = conversationId {
            let activeSessions = PTYSessionManager.shared.listSessions()
            if let existingSession = activeSessions.first(where: { $0.id == convId }) {
                /// Session exists - check if working directory has changed
                let currentWorkingDir = existingSession.workingDir
                let requestedWorkingDir = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path

                if currentWorkingDir != requestedWorkingDir {
                    /// Working directory changed - restart session with new directory
                    logger.info("Working directory changed (\(currentWorkingDir) → \(requestedWorkingDir)), restarting terminal session")

                    /// Close existing session
                    try? PTYSessionManager.shared.closeSession(sessionId: convId)

                    /// Fall through to create new session with updated directory
                } else {
                    /// Same directory - return existing session (shared with UI terminal!)
                    logger.info("TERMINAL_SHARING: Reusing existing PTY session \(convId) (shared with UI terminal)")

                    let result = [
                        "session_id": convId,
                        "tty_name": "existing",
                        "status": "existing",
                        "working_directory": currentWorkingDir,
                        "message": "Terminal session already exists for this conversation. Use session_id for commands."
                    ]

                    do {
                        let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

                        return MCPToolResult(
                            toolName: name,
                            success: true,
                            output: MCPOutput(content: jsonString, mimeType: "application/json")
                        )
                    } catch {
                        logger.error("Failed to serialize terminal session info to JSON: \(error)")
                        return MCPToolResult(
                            toolName: name,
                            success: false,
                            output: MCPOutput(content: "Failed to serialize session info: \(error.localizedDescription)")
                        )
                    }
                }
            }
        }

        do {
            let (sessionId, ttyName) = try PTYSessionManager.shared.createSession(
                conversationId: conversationId,
                workingDirectory: workingDirectory
            )

            let result = [
                "session_id": sessionId,
                "tty_name": ttyName,
                "status": "created",
                "working_directory": workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path,
                "message": "Terminal session created. Use session_id for subsequent commands."
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            logger.debug("Created terminal session: \(sessionId) → \(ttyName)")
            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: jsonString, mimeType: "application/json")
            )

        } catch {
            logger.error("Failed to create session: \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    @MainActor
    private func sendInput(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let sessionId = parameters["session_id"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: session_id")
            )
        }

        guard let input = parameters["input"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: input")
            )
        }

        do {
            try PTYSessionManager.shared.sendInput(sessionId: sessionId, input: input)

            /// Wait a moment for command to execute and produce output.
            try await Task.sleep(nanoseconds: 500_000_000)

            /// Get the output.
            let (output, endIndex) = try await PTYSessionManager.shared.getOutput(sessionId: sessionId, fromIndex: 0)

            let result = [
                "session_id": sessionId,
                "status": "sent",
                "input": input,
                "output": output,
                "end_index": endIndex
            ] as [String: Any]

            let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            logger.debug("Sent input to session \(sessionId): \(input)")
            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: jsonString, mimeType: "application/json")
            )

        } catch {
            logger.error("Failed to send input: \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to send input: \(error.localizedDescription)")
            )
        }
    }

    @MainActor
    private func getOutput(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let sessionId = parameters["session_id"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: session_id")
            )
        }

        let fromIndex = parameters["from_index"] as? Int ?? 0

        do {
            let (output, endIndex) = try await PTYSessionManager.shared.getOutput(sessionId: sessionId, fromIndex: fromIndex)

            let result = [
                "session_id": sessionId,
                "output": output,
                "from_index": fromIndex,
                "end_index": endIndex
            ] as [String: Any]

            let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: jsonString, mimeType: "application/json")
            )

        } catch {
            logger.error("Failed to get output: \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to get output: \(error.localizedDescription)")
            )
        }
    }

    @MainActor
    private func getHistory(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let sessionId = parameters["session_id"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: session_id")
            )
        }

        do {
            let history = try await PTYSessionManager.shared.getHistory(sessionId: sessionId)

            let result = [
                "session_id": sessionId,
                "history": history
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: jsonString, mimeType: "application/json")
            )

        } catch {
            logger.error("Failed to get history: \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to get history: \(error.localizedDescription)")
            )
        }
    }

    @MainActor
    private func closeSession(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let sessionId = parameters["session_id"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: session_id")
            )
        }

        do {
            try PTYSessionManager.shared.closeSession(sessionId: sessionId)

            let result = [
                "session_id": sessionId,
                "status": "closed"
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            logger.debug("Closed terminal session: \(sessionId)")
            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: jsonString, mimeType: "application/json")
            )

        } catch {
            logger.error("Failed to close session: \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to close session: \(error.localizedDescription)")
            )
        }
    }

    /// Get current terminal buffer contents (visible to user).
    @MainActor
    private func getTerminalBuffer(context: MCPExecutionContext) async -> MCPToolResult {
        /// Get the terminal manager for this conversation.
        guard let conversationId = context.conversationId else {
            logger.error("No conversation ID in context")
            return MCPToolResult(
                toolName: "terminal_operations",
                success: false,
                output: MCPOutput(content: "ERROR: No conversation context")
            )
        }

        /// Note: Access to the conversation's terminal manager requires a registry or injection of TerminalManager instances by conversation
        logger.debug("Getting terminal buffer for conversation: \(conversationId)")

        /// For now, return instruction to use PTY session.
        return MCPToolResult(
            toolName: "terminal_operations",
            success: true,
            output: MCPOutput(content: "Terminal buffer access via conversation context - use terminal_session tool with get_output operation")
        )
    }
}

// MARK: - Protocol Conformance

extension TerminalOperationsTool: ToolDisplayInfoProvider {
    public static func extractDisplayInfo(from arguments: [String: Any]) -> String? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        switch operation.lowercased().replacingOccurrences(of: "_", with: "") {
        case "runcommand", "runinterminal":
            if let command = arguments["command"] as? String {
                /// Truncate at 80 characters for readability.
                if command.count > 80 {
                    let preview = command.prefix(77)
                    return "Running: \(preview)..."
                } else {
                    return "Running: \(command)"
                }
            }
            return "Running terminal command"

        case "getoutput", "getterminaloutput":
            if let id = arguments["id"] as? String {
                return "Getting terminal output: \(id)"
            } else if let sessionId = arguments["session_id"] as? String {
                return "Getting output from session: \(sessionId)"
            }
            return "Getting terminal output"

        case "getlastcommand":
            return "Getting last terminal command"

        case "getterminalselection":
            return "Getting terminal selection"

        case "createdirectory":
            if let dirPath = arguments["dirPath"] as? String {
                let dirName = (dirPath as NSString).lastPathComponent
                return "Creating directory: \(dirName.isEmpty ? dirPath : dirName)"
            }
            return "Creating directory"

        case "createsession":
            if let conversationId = arguments["conversation_id"] as? String {
                return "Creating terminal session: \(conversationId)"
            }
            return "Creating terminal session"

        case "sendinput":
            if let input = arguments["input"] as? String {
                let preview = input.count > 50 ? String(input.prefix(47)) + "..." : input
                return "Sending to terminal: \(preview)"
            }
            return "Sending input to terminal"

        case "gethistory":
            if let sessionId = arguments["session_id"] as? String {
                return "Getting history: \(sessionId)"
            }
            return "Getting terminal history"

        case "closesession":
            if let sessionId = arguments["session_id"] as? String {
                return "Closing session: \(sessionId)"
            }
            return "Closing terminal session"

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
        case "runcommand", "runinterminal":
            if let command = arguments["command"] as? String {
                let preview = command.count > 70 ? String(command.prefix(67)) + "..." : command
                details.append("Command: \(preview)")
            }
            if let isBackground = arguments["isBackground"] as? Bool, isBackground {
                details.append("Mode: Background process")
            } else {
                details.append("Mode: Foreground (wait for output)")
            }
            return details.isEmpty ? nil : details

        case "getoutput", "getterminaloutput":
            if let id = arguments["id"] as? String {
                details.append("Terminal ID: \(id)")
            } else if let sessionId = arguments["session_id"] as? String {
                details.append("Session ID: \(sessionId)")
            }
            return details.isEmpty ? nil : details

        case "getlastcommand":
            details.append("Getting last executed command from active terminal")
            return details

        case "getterminalselection":
            details.append("Getting current text selection from terminal")
            return details

        case "createdirectory":
            if let dirPath = arguments["dirPath"] as? String {
                let dirName = (dirPath as NSString).lastPathComponent
                details.append("Directory: \(dirName.isEmpty ? dirPath : dirName)")
            }
            return details.isEmpty ? nil : details

        case "createsession":
            if let conversationId = arguments["conversation_id"] as? String {
                details.append("Conversation: \(conversationId)")
            }
            details.append("Creating isolated terminal session")
            return details

        case "sendinput":
            if let input = arguments["input"] as? String {
                let preview = input.count > 60 ? String(input.prefix(57)) + "..." : input
                details.append("Input: \(preview)")
            }
            if let sessionId = arguments["session_id"] as? String {
                details.append("Session: \(sessionId)")
            }
            return details.isEmpty ? nil : details

        case "gethistory":
            if let sessionId = arguments["session_id"] as? String {
                details.append("Session: \(sessionId)")
            }
            details.append("Retrieving command history")
            return details

        case "closesession":
            if let sessionId = arguments["session_id"] as? String {
                details.append("Session: \(sessionId)")
            }
            details.append("Terminating session and cleaning up")
            return details

        default:
            return nil
        }
    }
}
