// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for executing shell commands in a terminal **CRITICAL**: This tool enables version control workflows, testing, and command execution.
public class RunInTerminalTool: MCPTool, @unchecked Sendable {
    public let name = "run_in_terminal"
    public let description = """
        This tool allows you to execute shell commands in a persistent terminal session, preserving environment variables, working directory, and other context across multiple commands.

        READ FIRST, ACT SECOND - Verification Protocol:
        - Check exit code and output before running next command
        - If command fails, analyze error before retrying
        - Verify working directory with 'pwd' before path operations
        - Check tool availability with 'which' or 'command -v' before using
        - Don't blindly chain commands without checking results

        Command Execution:
        - Does NOT support multi-line commands

        Directory Management:
        - Must use absolute paths to avoid navigation issues.

        Program Execution:
        - Supports Python, Node.js, and other executables.
        - Install dependencies via pip, npm, etc.

        Background Processes:
        - For long-running tasks (e.g., servers), set isBackground=true.
        - Returns a terminal ID for checking status and runtime later.

        Output Management:
        - Output is automatically truncated if longer than 60KB to prevent context overflow
        - Use filters like 'head', 'tail', 'grep' to limit output size
        - For pager commands, disable paging: use 'git --no-pager' or add '| cat'

        Best Practices:
        - Be specific with commands to avoid excessive output
        - Use targeted queries instead of broad scans
        - Consider using 'wc -l' to count before listing many items
        """

    public var parameters: [String: MCPToolParameter] {
        return [
            "command": MCPToolParameter(
                type: .string,
                description: "Shell command to execute",
                required: true
            ),
            "explanation": MCPToolParameter(
                type: .string,
                description: "One-sentence description (shown to user)",
                required: true
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
            "working_directory": MCPToolParameter(
                type: .string,
                description: "Working directory (absolute path, defaults to current)",
                required: false
            ),
            "confirm": MCPToolParameter(
                type: .boolean,
                description: "SECURITY: Must be true for destructive operations (rm, mv, git commit, etc.)",
                required: false
            )
        ]
    }

    public struct TerminalResult: Codable {
        let terminalId: String
        let command: String
        let output: String
        let exitCode: Int32
        let executionTime: Double
        let isBackground: Bool
        let pid: Int32?
        let truncated: Bool
    }

    private let logger = Logger(label: "com.sam.mcp.RunInTerminalTool")
    private static let outputSizeLimit = 60 * 1024

    /// COMMAND DEDUPLICATION: Prevent AI from running identical commands multiple times.
    private struct CommandCacheEntry {
        let command: String
        let result: MCPToolResult
        let timestamp: Date
    }
    nonisolated(unsafe) private static var commandCache: [String: CommandCacheEntry] = [:]
    private static let cacheLock = NSLock()
    private static let cacheWindow: TimeInterval = 30.0

    /// SECURITY: Rate limiting for destructive operations.
    private var lastDestructiveOperation: Date?
    private let destructiveOperationCooldown: TimeInterval = 5.0

    /// Background process tracking.
    nonisolated(unsafe) private static var backgroundProcesses: [String: Process] = [:]
    nonisolated(unsafe) private static var processOutputs: [String: String] = [:]
    private static let processLock = NSLock()

    /// Interactive command patterns (require PTY support).
    private static let interactiveCommands = [
        "vim", "vi", "nano", "emacs", "less", "more",
        "top", "htop", "man", "python", "python3", "node",
        "irb", "pry", "rails console", "ssh", "telnet",
        "ftp", "sftp", "mysql", "psql", "sqlite3",
        "bash", "zsh", "sh", "fish"
    ]

    public init() {}

    public func initialize() async throws {
        logger.debug("RunInTerminalTool initialized")
    }

    public func validateParameters(_ params: [String: Any]) throws -> Bool {
        guard let command = params["command"] as? String, !command.isEmpty else {
            throw MCPError.invalidParameters("command parameter is required and must be a non-empty string")
        }
        guard let explanation = params["explanation"] as? String, !explanation.isEmpty else {
            throw MCPError.invalidParameters("explanation parameter is required and must be a non-empty string")
        }
        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// Trace execute entry.
        logger.critical("DEBUG_TRACE: RunInTerminalTool.execute ENTRY - command=\(parameters["command"] as? String ?? "none")")

        guard let command = parameters["command"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: command")
            )
        }

        guard let explanation = parameters["explanation"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: explanation")
            )
        }

        /// DEDUPLICATION: Check if this exact command was recently executed.
        let cacheKey = command.trimmingCharacters(in: .whitespacesAndNewlines)

        /// Check cache with minimal lock time.
        let cachedResult = Self.commandCache[cacheKey]

        if let cached = cachedResult {
            let age = Date().timeIntervalSince(cached.timestamp)
            if age < Self.cacheWindow {
                logger.warning("DEDUPLICATION: Identical command executed \(String(format: "%.1f", age))s ago - returning cached result")
                logger.warning("DEDUPLICATION: Command: \(command)")
                return cached.result
            } else {
                /// Cache expired, remove it.
                Self.commandCache.removeValue(forKey: cacheKey)
            }
        }

        /// SECURITY: Check if command is potentially destructive.
        let isDestructive = isDestructiveCommand(command)

        if isDestructive {
            /// SECURITY: Use centralized command authorization guard.
            let operationKey = "terminal_operations.run_command"
            let authResult = MCPAuthorizationGuard.checkCommandAuthorization(
                command: command,
                workingDirectory: context.workingDirectory,
                conversationId: context.conversationId,
                operation: operationKey,
                isUserInitiated: context.isUserInitiated
            )

            switch authResult {
            case .allowed:
                /// Command will execute in working directory sandbox - continue.
                break

            case .denied(let reason):
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "Operation denied: \(reason)")
                )

            case .requiresAuthorization(let reason):
                let authError = MCPAuthorizationGuard.authorizationError(
                    operation: operationKey,
                    reason: reason,
                    suggestedPrompt: "Run terminal command: \(command)?"
                )
                if let errorMsg = authError["error"] as? String {
                    return MCPToolResult(
                        toolName: name,
                        success: false,
                        output: MCPOutput(content: errorMsg)
                    )
                }
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "Authorization required for command")
                )
            }

            /// SECURITY LAYER 3: Rate limiting check.
            let currentTime = Date()
            if let lastOp = lastDestructiveOperation, currentTime.timeIntervalSince(lastOp) < destructiveOperationCooldown {
                let remaining = destructiveOperationCooldown - currentTime.timeIntervalSince(lastOp)
                logger.warning("SECURITY: run_in_terminal rate limited - \(String(format: "%.1f", remaining))s remaining")
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "SECURITY: Destructive operations rate limited. Please wait \(String(format: "%.0f", remaining)) seconds before retrying.")
                )
            }

            /// SECURITY LAYER 4: Comprehensive audit logging.
            logger.critical("""
                DESTRUCTIVE_OPERATION_AUTHORIZED:
                operation=run_in_terminal
                command=\(command)
                confirm=true
                isUserInitiated=\(context.isUserInitiated)
                userRequest=\(context.userRequestText ?? "none")
                timestamp=\(ISO8601DateFormatter().string(from: Date()))
                sessionId=\(context.sessionId)
                """)

            /// Update rate limiter.
            lastDestructiveOperation = currentTime
        }

        let isBackground = parameters["isBackground"] as? Bool ?? false

        /// CRITICAL: Resolve working directory properly
        /// If AI passes relative path like "./" - resolve against context.workingDirectory
        /// Always fall back to context.workingDirectory, then current directory
        let workingDirectory: String = {
            if let providedPath = parameters["working_directory"] as? String {
                // Resolve using canonical path resolution (handles relative paths, tilde expansion)
                let resolved = MCPAuthorizationGuard.resolvePath(providedPath, workingDirectory: context.workingDirectory)
                if providedPath != resolved {
                    logger.warning("Resolved relative working_directory: '\(providedPath)' → '\(resolved)'")
                }
                return resolved
            }
            // No working_directory provided - use context's working directory or current directory
            return context.workingDirectory ?? FileManager.default.currentDirectoryPath
        }()

        /// ========================================================================== CONVERSATION-SCOPED PTY SESSION PERSISTENCE ========================================================================== ALL commands (local or remote) execute in a persistent PTY session scoped to the conversation.

        if !isBackground {
            logger.debug("Checking for conversation-scoped PTY session...")

            /// Use conversationId as sessionId (PTYSessionManager supports this).
            let sessionId = context.conversationId?.uuidString ?? UUID().uuidString

            /// Check if PTY session already exists for this conversation.
            let activeSessions = PTYSessionManager.shared.listSessions()
            let hasActiveSession = activeSessions.contains { $0.id == sessionId }

            if hasActiveSession {
                /// ============================================================ EXISTING SESSION: Send command to persistent PTY ============================================================.
                logger.debug("Using existing PTY session for conversation: \(sessionId)")

                do {
                    /// Send command to session (PTY handles echoing and output).
                    try PTYSessionManager.shared.sendInput(sessionId: sessionId, input: command + "\r")

                    /// Poll for command completion instead of fixed wait time Previous bug: 500ms fixed wait caused workflow to continue before command finished New behavior: Poll output until we detect command completion.
                    logger.debug("Polling for command completion...")

                    var lastOutputLength = 0
                    var stableCount = 0
                    let maxStableChecks = 3
                    let pollInterval: UInt64 = 500_000_000
                    let maxPollTime: TimeInterval = 300.0
                    let startTime = Date()

                    while Date().timeIntervalSince(startTime) < maxPollTime {
                        try await Task.sleep(nanoseconds: pollInterval)

                        /// Get current output.
                        let (output, _) = try await PTYSessionManager.shared.getOutput(sessionId: sessionId, fromIndex: 0)

                        /// Check if output is stable (no new output for multiple checks).
                        if output.count == lastOutputLength {
                            stableCount += 1
                            if stableCount >= maxStableChecks {
                                logger.debug("Command completed - output stable for \(stableCount) checks")
                                break
                            }
                        } else {
                            /// Output changed, reset stable counter.
                            stableCount = 0
                            lastOutputLength = output.count
                            logger.debug("Command still executing - output length: \(output.count)")
                        }
                    }

                    if Date().timeIntervalSince(startTime) >= maxPollTime {
                        logger.warning("Command polling timeout after \(maxPollTime)s - returning current output")
                    }

                    /// Get final output from PTY session (from beginning to capture full context).
                    let (output, _) = try await PTYSessionManager.shared.getOutput(sessionId: sessionId, fromIndex: 0)

                    logger.debug("PTY session command completed - output length: \(output.count)")

                    let result = MCPToolResult(
                        toolName: name,
                        success: true,
                        output: MCPOutput(content: output.isEmpty ? "Command executed (no output)" : output)
                    )

                    /// DEDUPLICATION: Cache this result.
                    Self.commandCache[cacheKey] = CommandCacheEntry(command: command, result: result, timestamp: Date())

                    return result

                } catch {
                    logger.error("Failed to execute command in PTY session: \(error)")
                    return MCPToolResult(
                        toolName: name,
                        success: false,
                        output: MCPOutput(content: "PTY session error: \(error.localizedDescription)")
                    )
                }

            } else {
                /// ============================================================ NEW SESSION: Create persistent PTY for this conversation ============================================================.
                logger.debug("Creating new PTY session for conversation: \(sessionId)")

                do {
                    /// Create session with conversationId as sessionId.
                    let (createdSessionId, ttyName) = try PTYSessionManager.shared.createSession(
                        conversationId: sessionId,
                        workingDirectory: workingDirectory
                    )

                    logger.debug("PTY session created: \(createdSessionId) → \(ttyName)")

                    /// Wait for shell to initialize.
                    try await Task.sleep(nanoseconds: 500_000_000)

                    /// Send first command.
                    try PTYSessionManager.shared.sendInput(sessionId: createdSessionId, input: command + "\r")

                    /// Poll for command completion instead of fixed wait time.
                    logger.debug("Polling for first command completion in new PTY session...")

                    var lastOutputLength = 0
                    var stableCount = 0
                    let maxStableChecks = 3
                    let pollInterval: UInt64 = 500_000_000
                    let maxPollTime: TimeInterval = 300.0
                    let startTime = Date()

                    while Date().timeIntervalSince(startTime) < maxPollTime {
                        try await Task.sleep(nanoseconds: pollInterval)

                        let (output, _) = try await PTYSessionManager.shared.getOutput(sessionId: createdSessionId, fromIndex: 0)

                        if output.count == lastOutputLength {
                            stableCount += 1
                            if stableCount >= maxStableChecks {
                                logger.debug("Command completed - output stable for \(stableCount) checks")
                                break
                            }
                        } else {
                            stableCount = 0
                            lastOutputLength = output.count
                            logger.debug("Command still executing - output length: \(output.count)")
                        }
                    }

                    if Date().timeIntervalSince(startTime) >= maxPollTime {
                        logger.warning("Command polling timeout after \(maxPollTime)s - returning current output")
                    }

                    /// Get output.
                    let (output, _) = try await PTYSessionManager.shared.getOutput(sessionId: createdSessionId, fromIndex: 0)

                    logger.debug("PTY session first command completed - output length: \(output.count)")

                    let result = MCPToolResult(
                        toolName: name,
                        success: true,
                        output: MCPOutput(content: "PTY session created (\(ttyName))\n\n\(output)")
                    )

                    /// DEDUPLICATION: Cache this result.
                    Self.commandCache[cacheKey] = CommandCacheEntry(command: command, result: result, timestamp: Date())

                    return result

                } catch {
                    logger.error("Failed to create PTY session: \(error)")
                    return MCPToolResult(
                        toolName: name,
                        success: false,
                        output: MCPOutput(content: "Failed to create PTY session: \(error.localizedDescription)")
                    )
                }
            }
        }

        /// ========================================================================== LEGACY PATH: Background processes only ========================================================================== Background processes (servers, daemons, etc.) use independent process lifecycle and don't participate in conversation-scoped PTY sessions ==========================================================================.

        logger.debug("Executing background process (not using PTY session)")

        let terminalId = UUID().uuidString

        /// Execute as background process.
        return await executeBackgroundCommand(
            command: command,
            terminalId: terminalId,
            explanation: explanation,
            workingDirectory: workingDirectory
        )
    }

    private func executePTYCommand(
        command: String,
        terminalId: String,
        startTime: Date,
        explanation: String,
        workingDirectory: String
    ) async -> MCPToolResult {
        do {
            let pty = PseudoTerminal()
            let result = try await pty.executeCommand(
                command,
                workingDirectory: workingDirectory,
                isInteractive: true
            )

            /// Update last command tracking.
            TerminalLastCommandTool.updateLastCommand(command, exitCode: result.exitCode)

            let terminalResult = TerminalResult(
                terminalId: result.terminalId,
                command: result.command,
                output: result.output,
                exitCode: result.exitCode,
                executionTime: result.executionTime,
                isBackground: false,
                pid: result.pid != nil ? Int32(result.pid!) : nil,
                truncated: false
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let jsonData = try? encoder.encode(terminalResult),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                logger.debug("PTY command completed with exit code \(result.exitCode)")
                return MCPToolResult(
                    toolName: name,
                    success: result.exitCode == 0,
                    output: MCPOutput(content: jsonString, mimeType: "application/json")
                )
            }

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to encode terminal result")
            )

        } catch {
            logger.error("Failed to execute PTY command: \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to execute command: \(error.localizedDescription)")
            )
        }
    }

    private func executeForegroundCommand(
        command: String,
        terminalId: String,
        startTime: Date,
        explanation: String,
        workingDirectory: String
    ) async -> MCPToolResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/bash")

        /// Reset terminal settings BEFORE executing command This ensures proper control character mappings (^C, ^U, ^?, etc) The 'sane' stty preset configures standard terminal behavior.
        let commandWithReset = "stty sane 2>/dev/null; \(command)"
        process.arguments = ["-c", commandWithReset]

        process.standardOutput = outputPipe
        process.standardError = errorPipe

        /// Use specified working directory.
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        /// Set proper terminal environment variables Without these, terminal programs don't configure TTY settings correctly.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["CLICOLOR"] = "1"
        env["COLORTERM"] = "truecolor"
        process.environment = env

        var outputData = Data()
        var errorData = Data()

        do {
            try process.run()

            /// Read output.
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            process.waitUntilExit()

            let executionTime = Date().timeIntervalSince(startTime)
            let exitCode = process.terminationStatus

            /// Update last command tracking.
            TerminalLastCommandTool.updateLastCommand(command, exitCode: exitCode)

            /// Combine stdout and stderr.
            var fullOutput = ""
            if !outputData.isEmpty {
                fullOutput += (String(data: outputData, encoding: .utf8) ?? "")
            }
            if !errorData.isEmpty {
                if !fullOutput.isEmpty { fullOutput += "\n" }
                fullOutput += (String(data: errorData, encoding: .utf8) ?? "")
            }

            /// Truncate if necessary.
            let (truncatedOutput, wasTruncated) = truncateOutput(fullOutput)

            let result = TerminalResult(
                terminalId: terminalId,
                command: command,
                output: truncatedOutput,
                exitCode: exitCode,
                executionTime: executionTime,
                isBackground: false,
                pid: nil,
                truncated: wasTruncated
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let jsonData = try? encoder.encode(result),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                logger.debug("Command completed with exit code \(exitCode)")
                return MCPToolResult(
                    toolName: name,
                    success: exitCode == 0,
                    output: MCPOutput(content: jsonString, mimeType: "application/json")
                )
            }

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to encode terminal result")
            )

        } catch {
            logger.error("Failed to execute command: \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to execute command: \(error.localizedDescription)")
            )
        }
    }

    nonisolated private func captureBackgroundOutput(
        terminalId: String,
        outputHandle: FileHandle,
        errorHandle: FileHandle,
        process: Process,
        logger: Logger
    ) {
        Task.detached { @Sendable in
            let outputData = outputHandle.readDataToEndOfFile()
            let errorData = errorHandle.readDataToEndOfFile()

            var fullOutput = ""
            if !outputData.isEmpty {
                fullOutput += (String(data: outputData, encoding: .utf8) ?? "")
            }
            if !errorData.isEmpty {
                if !fullOutput.isEmpty { fullOutput += "\n" }
                fullOutput += (String(data: errorData, encoding: .utf8) ?? "")
            }

            Self.processOutputs[terminalId] = fullOutput
            logger.debug("Background process \(terminalId) completed with exit code \(process.terminationStatus)")
        }
    }

    @MainActor
    private func executeBackgroundCommand(
        command: String,
        terminalId: String,
        explanation: String,
        workingDirectory: String
    ) async -> MCPToolResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/bash")

        /// Reset terminal settings before command execution.
        let commandWithReset = "stty sane 2>/dev/null; \(command)"
        process.arguments = ["-c", commandWithReset]

        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        /// Set proper terminal environment variables.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["CLICOLOR"] = "1"
        env["COLORTERM"] = "truecolor"
        process.environment = env

        do {
            try process.run()

            let pid = process.processIdentifier
            logger.debug("Background process started with PID \(pid)")

            /// Store process and set up output capture.
            Self.backgroundProcesses[terminalId] = process
            Self.processOutputs[terminalId] = ""

            /// Capture output asynchronously.
            captureBackgroundOutput(
                terminalId: terminalId,
                outputHandle: outputPipe.fileHandleForReading,
                errorHandle: errorPipe.fileHandleForReading,
                process: process,
                logger: logger
            )

            let result = TerminalResult(
                terminalId: terminalId,
                command: command,
                output: "Background process started. Use get_terminal_output(\(terminalId)) to check status.",
                exitCode: 0,
                executionTime: 0.0,
                isBackground: true,
                pid: pid,
                truncated: false
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let jsonData = try? encoder.encode(result),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return MCPToolResult(
                    toolName: name,
                    success: true,
                    output: MCPOutput(content: jsonString, mimeType: "application/json")
                )
            }

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to encode terminal result")
            )

        } catch {
            logger.error("Failed to start background process: \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to start background process: \(error.localizedDescription)")
            )
        }
    }

    private func truncateOutput(_ output: String) -> (String, Bool) {
        let data = output.data(using: .utf8) ?? Data()
        if data.count > Self.outputSizeLimit {
            let truncatedData = data.prefix(Self.outputSizeLimit)
            let truncatedString = String(data: truncatedData, encoding: .utf8) ?? output
            let warning = "\n\n[OUTPUT TRUNCATED - exceeded 60KB limit. Use filters like 'head', 'tail', or 'grep' to limit output size]"
            return (truncatedString + warning, true)
        }
        return (output, false)
    }

    // MARK: - Helper Methods

    /// Determines if a shell command is potentially destructive.
    private func isDestructiveCommand(_ command: String) -> Bool {
        /// Normalize command for analysis.
        let normalized = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        /// Destructive command patterns.
        let destructivePatterns = [
            "rm ", "rm\t",
            "mv ", "mv\t",
            "cp ", "cp\t",
            "dd ", "dd\t",
            "mkfs",
            "fdisk", "parted",
            ">", ">>",
            "truncate",
            "shred",
            "chmod", "chown",
            "git commit", "git push",
            "git rebase", "git reset",
            "npm install", "npm uninstall",
            "brew install", "brew uninstall",
            "pip install", "pip uninstall",
            "apt install", "apt remove",
            "yum install", "yum remove",
            "make install",
            "sudo ", "doas ",
            "curl.*|", "wget.*|",
            "xargs rm", "xargs mv"
        ]

        /// Check if command contains any destructive patterns.
        for pattern in destructivePatterns {
            if normalized.contains(pattern) {
                return true
            }
        }

        /// Allow read-only operations.
        let safeReadOnlyCommands = ["ls", "cat", "grep", "find", "head", "tail", "wc", "echo", "pwd", "cd", "which", "man", "help"]
        let firstWord = normalized.split(separator: " ").first?.description ?? ""
        if safeReadOnlyCommands.contains(firstWord) {
            return false
        }

        /// Conservative approach: if uncertain, treat as potentially destructive.
        return false
    }

    /// Determines if a shell command requires interactive terminal (PTY) support.
    private func isInteractiveCommand(_ command: String) -> Bool {
        /// Normalize command for analysis.
        let normalized = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        /// Extract the first command (before pipes, redirects, etc.).
        let firstCommand: String
        if let pipeIndex = normalized.firstIndex(of: "|") {
            firstCommand = String(normalized[..<pipeIndex]).trimmingCharacters(in: .whitespaces)
        } else if let redirectIndex = normalized.firstIndex(of: ">") {
            firstCommand = String(normalized[..<redirectIndex]).trimmingCharacters(in: .whitespaces)
        } else {
            firstCommand = normalized
        }

        /// Get the command name (first word).
        let commandName = firstCommand.split(separator: " ").first?.description ?? ""

        /// Check if it matches any interactive command pattern.
        return Self.interactiveCommands.contains(commandName)
    }

    /// Public API for get_terminal_output tool.
    public static func getProcessOutput(terminalId: String) -> (output: String, isRunning: Bool, exitCode: Int32?) {

        guard let process = backgroundProcesses[terminalId] else {
            return ("Terminal ID not found", false, nil)
        }

        let isRunning = process.isRunning
        let output = processOutputs[terminalId] ?? ""
        let exitCode = isRunning ? nil : process.terminationStatus

        return (output, isRunning, exitCode)
    }
}
