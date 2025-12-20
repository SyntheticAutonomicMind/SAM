// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for retrieving compilation and lint errors from the workspace Provides access to errors and warnings from the build system, helping agents understand code issues and validate their changes.
public class GetErrorsTool: MCPTool, @unchecked Sendable {
    public let name = "get_errors"
    public let description = "Get any compile or lint errors in a specific file or across all files. If the user mentions errors or problems in a file, they may be referring to these. Use the tool to see the same errors that the user is seeing. If the user asks you to analyze all errors, or does not specify a file, use this tool to gather errors for all files. Also use this tool after editing a file to validate the change."

    public var parameters: [String: MCPToolParameter] {
        return [
            "filePaths": MCPToolParameter(
                type: .array,
                description: "The absolute paths to the files to check for errors. Omit 'filePaths' when retrieving all errors.",
                required: false,
                arrayElementType: .string
            ),
            "workspace_path": MCPToolParameter(
                type: .string,
                description: "The root directory of the workspace to check (defaults to current directory). Use absolute paths.",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.GetErrorsTool")

    public init() {}

    public func initialize() async throws {
        logger.debug("[GetErrorsTool] Initialized")
    }

    public func validateParameters(_ params: [String: Any]) throws -> Bool {
        /// filePaths is optional - if provided, must be array of strings.
        if let filePaths = params["filePaths"] {
            guard let paths = filePaths as? [String], !paths.isEmpty else {
                throw MCPError.invalidParameters("filePaths must be a non-empty array of strings")
            }

            /// Validate each path is absolute.
            for path in paths {
                guard path.hasPrefix("/") else {
                    throw MCPError.invalidParameters("All file paths must be absolute paths")
                }
            }
        }

        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        let filePaths = parameters["filePaths"] as? [String]
        let workspacePath = parameters["workspace_path"] as? String ?? context.workingDirectory ?? FileManager.default.currentDirectoryPath

        do {
            /// Run build and capture errors.
            let errors = try await buildAndCaptureErrors(filePaths: filePaths, workspacePath: workspacePath)

            /// Convert to JSON.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(errors)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

            logger.debug("[GetErrorsTool] Found \(errors.count) errors/warnings")

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(
                    content: jsonString,
                    mimeType: "application/json"
                )
            )

        } catch {
            logger.error("[GetErrorsTool] Failed to get errors: \(error.localizedDescription)")

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "Failed to retrieve errors: \(error.localizedDescription)"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }
    }

    // MARK: - Helper Methods

    @MainActor
    private func buildAndCaptureErrors(filePaths: [String]?, workspacePath: String) async throws -> [CompilationError] {
        logger.debug("[GetErrorsTool] Checking errors in workspace: \(workspacePath)")

        /// Run swift build to capture errors.
        let buildOutput = try await runBuildCommand(in: workspacePath)

        /// Parse errors from build output.
        var errors = parseSwiftBuildErrors(buildOutput, workspaceRoot: workspacePath)

        /// Filter by requested files if specified.
        if let requestedPaths = filePaths {
            errors = errors.filter { error in
                requestedPaths.contains { requested in
                    error.file == requested || error.file.hasSuffix(requested)
                }
            }
        }

        return errors
    }

    @MainActor
    private func runBuildCommand(in workspaceRoot: String) async throws -> String {
        let process = Process()
        process.currentDirectoryPath = workspaceRoot
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["build", "--build-tests"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        /// Read both stdout and stderr (errors usually go to stderr).
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errors = String(data: errorData, encoding: .utf8) ?? ""

        /// Combine both outputs.
        return output + "\n" + errors
    }

    private func parseSwiftBuildErrors(_ output: String, workspaceRoot: String) -> [CompilationError] {
        var errors: [CompilationError] = []

        /// Swift compiler error format: /path/to/file.swift:line:column: error: message Warning format: /path/to/file.swift:line:column: warning: message.
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            /// Match pattern: <file>:<line>:<column>: <severity>: <message>.
            let pattern = #"^(.+?):(\d+):(\d+):\s+(error|warning):\s+(.+)$"#

            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) else {
                continue
            }

            /// Extract components.
            guard let fileRange = Range(match.range(at: 1), in: line),
                  let lineRange = Range(match.range(at: 2), in: line),
                  let columnRange = Range(match.range(at: 3), in: line),
                  let severityRange = Range(match.range(at: 4), in: line),
                  let messageRange = Range(match.range(at: 5), in: line) else {
                continue
            }

            let filePath = String(line[fileRange])
            let lineNumber = Int(String(line[lineRange])) ?? 0
            let columnNumber = Int(String(line[columnRange])) ?? 0
            let severity = String(line[severityRange])
            let message = String(line[messageRange])

            let error = CompilationError(
                file: filePath,
                line: lineNumber,
                column: columnNumber,
                severity: severity,
                message: message,
                code: nil
            )

            errors.append(error)
        }

        logger.debug("[GetErrorsTool] Parsed \(errors.count) errors from build output")
        return errors
    }
}

// MARK: - Supporting Types

private struct CompilationError: Codable {
    let file: String
    let line: Int
    let column: Int
    let severity: String
    let message: String
    let code: String?
}
