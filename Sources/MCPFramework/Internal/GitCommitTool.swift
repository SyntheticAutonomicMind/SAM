// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for staging and committing changes to git repository Stages files (specific files, all tracked changes, or all including untracked) and creates a commit.
public class GitCommitTool: MCPTool, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.tools.git_commit")

    /// SECURITY: Rate limiting for destructive operations.
    private var lastDestructiveOperation: Date?
    private let destructiveOperationCooldown: TimeInterval = 5.0

    public let name = "git_commit"
    public let description = "Stage and commit changes to git repository. Creates a commit with the specified message after staging files."

    public var parameters: [String: MCPToolParameter] {
        return [
            "message": MCPToolParameter(
                type: .string,
                description: "Commit message",
                required: true
            ),
            "repository_path": MCPToolParameter(
                type: .string,
                description: "Path to git repository (defaults to current directory). Use absolute paths or ~/relative paths.",
                required: false
            ),
            "files": MCPToolParameter(
                type: .array,
                description: "Specific files to stage (omit to stage all changes)",
                required: false,
                arrayElementType: .string
            ),
            "all": MCPToolParameter(
                type: .boolean,
                description: "Stage all changes including untracked files (default: true)",
                required: false
            )
        ]
    }

    public init() {}

    public func initialize() async throws {}

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// SECURITY: Block autonomous destructive operations UNLESS authorized.
        let operationKey = "build_and_version_control.git_commit"
        let isAuthorized = context.conversationId.map {
            AuthorizationManager.shared.isAuthorized(conversationId: $0, operation: operationKey)
        } ?? false

        guard context.isUserInitiated || isAuthorized else {
            logger.critical("SECURITY: Autonomous git_commit attempt BLOCKED - userRequest=\(context.userRequestText ?? "none")")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: """
                    SECURITY VIOLATION: Git commits must be user-initiated or authorized.

                    This operation was autonomously decided by the agent and requires authorization.

                    Please use user_collaboration to request authorization:
                    {
                      "prompt": "Commit changes to git?",
                      "authorize_operation": "\(operationKey)"
                    }
                    """)
            )
        }

        /// SECURITY LAYER 3: Rate limiting check.
        let currentTime = Date()
        if let lastOp = lastDestructiveOperation, currentTime.timeIntervalSince(lastOp) < destructiveOperationCooldown {
            let remaining = destructiveOperationCooldown - currentTime.timeIntervalSince(lastOp)
            logger.warning("SECURITY: git_commit rate limited - \(String(format: "%.1f", remaining))s remaining")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "SECURITY: Destructive operations rate limited. Please wait \(String(format: "%.0f", remaining)) seconds before retrying.")
            )
        }

        /// Extract parameters.
        guard let message = parameters["message"] as? String, !message.isEmpty else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Missing required parameter: message")
            )
        }

        let files = parameters["files"] as? [String]
        /// Default to true (git add -A) to include untracked files This is more intuitive for LLMs and matches common use case.
        let all = parameters["all"] as? Bool ?? true

        /// Use explicit repository path from parameters or fall back to working directory or current directory.
        let repoPath: String
        if let explicitPath = parameters["repository_path"] as? String {
            repoPath = (explicitPath as NSString).expandingTildeInPath
        } else if let workingDir = context.workingDirectory {
            repoPath = workingDir
        } else {
            repoPath = FileManager.default.currentDirectoryPath
        }

        /// SECURITY LAYER 4: Comprehensive audit logging.
        logger.critical("""
            DESTRUCTIVE_OPERATION_AUTHORIZED:
            operation=git_commit
            message=\(message)
            repoPath=\(repoPath)
            all=\(all)
            fileCount=\(files?.count ?? 0)
            confirm=true
            isUserInitiated=\(context.isUserInitiated)
            userRequest=\(context.userRequestText ?? "none")
            timestamp=\(ISO8601DateFormatter().string(from: Date()))
            sessionId=\(context.sessionId)
            """)

        /// Update rate limiter.
        lastDestructiveOperation = currentTime

        /// Validate git repository.
        let gitPath = (repoPath as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitPath) else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Not a git repository: \(repoPath)")
            )
        }

        /// Stage files.
        let stageResult = stageFiles(files: files, all: all, repoPath: repoPath)
        if !stageResult.success {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to stage files: \(stageResult.error ?? "unknown error")")
            )
        }

        /// Create commit.
        let commitResult = createCommit(message: message, repoPath: repoPath)
        if !commitResult.success {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to create commit: \(commitResult.error ?? "unknown error")")
            )
        }

        /// Get commit hash.
        let commitHash = getCommitHash(repoPath: repoPath)

        let result: [String: Any] = [
            "success": true,
            "hash": commitHash,
            "message": message,
            "filesStaged": stageResult.filesStaged ?? 0,
            "output": commitResult.output ?? ""
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to encode result")
            )
        }

        logger.debug("Successfully created commit with hash: \(commitHash)")
        return MCPToolResult(
            toolName: name,
            success: true,
            output: MCPOutput(content: jsonString, mimeType: "application/json")
        )
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        /// Validate message parameter exists and is not empty.
        guard let message = parameters["message"] as? String, !message.isEmpty else {
            return false
        }
        return true
    }

    // MARK: - Helper Methods

    private func runGitCommand(_ args: [String], in repoPath: String) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            let combinedOutput = output + errorOutput

            return (combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
        } catch {
            logger.error("Failed to run git command: \(error)")
            return ("Failed to execute git command: \(error.localizedDescription)", 1)
        }
    }

    private func stageFiles(files: [String]?, all: Bool, repoPath: String) -> (success: Bool, filesStaged: Int?, error: String?) {
        var args = ["add"]

        if let files = files, !files.isEmpty {
            /// Stage specific files.
            args.append(contentsOf: files)
        } else if all {
            /// Stage all including untracked.
            args.append("-A")
        } else {
            /// Stage all tracked changes (default).
            args.append("-u")
        }

        let result = runGitCommand(args, in: repoPath)

        if result.exitCode != 0 {
            logger.error("Git add failed: \(result.output)")
            return (false, nil, result.output)
        }

        /// Count staged files.
        let statusResult = runGitCommand(["diff", "--cached", "--name-only"], in: repoPath)
        let stagedCount = statusResult.output.split(separator: "\n").count

        logger.debug("Successfully staged \(stagedCount) file(s)")
        return (true, stagedCount, nil)
    }

    private func createCommit(message: String, repoPath: String) -> (success: Bool, output: String?, error: String?) {
        /// Ensure git user config exists before committing Check if user.name is configured (local or global).
        let checkName = runGitCommand(["config", "user.name"], in: repoPath)
        if checkName.output.isEmpty {
            /// Configure locally for this repo only (not global) to avoid breaking user's setup Use configured value from UserDefaults or fallback.
            let configuredName = UserDefaults.standard.string(forKey: "git.userName") ?? "Assistant SAM"
            logger.debug("Git user.name not configured, setting local fallback: \(configuredName)")
            let setName = runGitCommand(["config", "--local", "user.name", configuredName], in: repoPath)
            if setName.exitCode != 0 {
                logger.error("Failed to set git user.name: \(setName.output)")
                return (false, nil, "Failed to configure git user.name: \(setName.output)")
            }
        }

        /// Check if user.email is configured (local or global).
        let checkEmail = runGitCommand(["config", "user.email"], in: repoPath)
        if checkEmail.output.isEmpty {
            /// Configure locally for this repo only (not global) Use configured value from UserDefaults or fallback.
            let configuredEmail = UserDefaults.standard.string(forKey: "git.userEmail") ?? "sam@syntheticautonomicmind.com"
            logger.debug("Git user.email not configured, setting local fallback: \(configuredEmail)")
            let setEmail = runGitCommand(["config", "--local", "user.email", configuredEmail], in: repoPath)
            if setEmail.exitCode != 0 {
                logger.error("Failed to set git user.email: \(setEmail.output)")
                return (false, nil, "Failed to configure git user.email: \(setEmail.output)")
            }
        }

        let result = runGitCommand(["commit", "-m", message], in: repoPath)

        if result.exitCode != 0 {
            /// Check if failure is due to nothing to commit.
            if result.output.contains("nothing to commit") || result.output.contains("no changes added") {
                logger.warning("No changes to commit")
                return (false, nil, "No changes to commit")
            }

            logger.error("Git commit failed: \(result.output)")
            return (false, nil, result.output)
        }

        logger.debug("Commit created successfully")
        return (true, result.output, nil)
    }

    private func getCommitHash(repoPath: String) -> String {
        let result = runGitCommand(["rev-parse", "HEAD"], in: repoPath)
        if result.exitCode == 0 {
            return result.output
        }
        logger.warning("Failed to get commit hash")
        return ""
    }
}
