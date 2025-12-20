// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for getting changed files in a git repository Lists files that have been modified, added, or deleted in the current git repository.
public class GetChangedFilesTool: MCPTool, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.tools.get_changed_files")

    public let name = "get_changed_files"
    public let description = "Get git diffs of current file changes in a git repository. Don't forget that you can use run_in_terminal to run git commands in a terminal as well."

    public var parameters: [String: MCPToolParameter] {
        return [
            "repositoryPath": MCPToolParameter(
                type: .string,
                description: "The absolute path to the git repository to look for changes in. If not provided, the active git repository will be used.",
                required: false
            ),
            "sourceControlState": MCPToolParameter(
                type: .array,
                description: "The kinds of git state to filter by. Allowed values are: 'staged', 'unstaged', and 'merge-conflicts'. If not provided, all states will be included.",
                required: false,
                arrayElementType: .string
            )
        ]
    }

    public init() {}

    public func initialize() async throws {}

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        let repoPath = parameters["repositoryPath"] as? String ?? context.workingDirectory ?? FileManager.default.currentDirectoryPath
        let stateFilter = parameters["sourceControlState"] as? [String]

        /// Verify git repository.
        let gitPath = (repoPath as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitPath) else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Not a git repository: \(repoPath)")
            )
        }

        /// Get current branch.
        let branchName = getGitBranch(repoPath: repoPath)

        /// Get changed files.
        var changedFiles: [[String: Any]] = []

        /// Get staged files if requested or no filter.
        if stateFilter == nil || stateFilter?.contains("staged") == true {
            changedFiles.append(contentsOf: getStagedFiles(repoPath: repoPath))
        }

        /// Get unstaged files if requested or no filter.
        if stateFilter == nil || stateFilter?.contains("unstaged") == true {
            changedFiles.append(contentsOf: getUnstagedFiles(repoPath: repoPath))
        }

        /// Get merge conflicts if requested or no filter.
        if stateFilter == nil || stateFilter?.contains("merge-conflicts") == true {
            changedFiles.append(contentsOf: getMergeConflicts(repoPath: repoPath))
        }

        let result: [String: Any] = [
            "files": changedFiles,
            "repository": repoPath,
            "branch": branchName,
            "totalFiles": changedFiles.count
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to encode result")
            )
        }

        logger.debug("Found \(changedFiles.count) changed files in repository: \(repoPath)")
        return MCPToolResult(
            toolName: name,
            success: true,
            output: MCPOutput(content: jsonString, mimeType: "application/json")
        )
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        /// All parameters optional.
        return true
    }

    private func runGitCommand(_ args: [String], in repoPath: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            logger.error("Failed to run git command: \(error)")
            return ""
        }
    }

    private func getGitBranch(repoPath: String) -> String {
        let output = runGitCommand(["branch", "--show-current"], in: repoPath)
        return output.isEmpty ? "unknown" : output
    }

    private func getStagedFiles(repoPath: String) -> [[String: Any]] {
        let output = runGitCommand(["diff", "--cached", "--name-status"], in: repoPath)
        return parseGitStatus(output, staged: true)
    }

    private func getUnstagedFiles(repoPath: String) -> [[String: Any]] {
        let output = runGitCommand(["diff", "--name-status"], in: repoPath)
        return parseGitStatus(output, staged: false)
    }

    private func getMergeConflicts(repoPath: String) -> [[String: Any]] {
        let output = runGitCommand(["diff", "--name-only", "--diff-filter=U"], in: repoPath)
        return output.split(separator: "\n").map { path in
            return [
                "path": String(path),
                "status": "conflict",
                "staged": false
            ]
        }
    }

    private func parseGitStatus(_ output: String, staged: Bool) -> [[String: Any]] {
        var files: [[String: Any]] = []

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let statusChar = String(parts[0])
            let path = String(parts[1])

            let status: String
            switch statusChar {
            case "M": status = "modified"
            case "A": status = "added"
            case "D": status = "deleted"
            case "R": status = "renamed"
            case "C": status = "copied"
            case "U": status = "conflict"
            default: status = "unknown"
            }

            files.append([
                "path": path,
                "status": status,
                "staged": staged
            ])
        }

        return files
    }
}
