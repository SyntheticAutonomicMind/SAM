// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for listing all usages of a code symbol (function, class, method, variable, etc.) Uses intelligent grep-based searching within a scoped workspace to find all references to a specified symbol.
public class ListCodeUsagesTool: MCPTool, @unchecked Sendable {
    public let name = "list_code_usages"
    public let description = "Request to list all usages (references, definitions, implementations etc) of a function, class, method, variable etc. Use this tool when looking for a sample implementation of an interface or class, checking how a function is used throughout the codebase, or when including and updating all usages when changing a function, method, or constructor."

    public var parameters: [String: MCPToolParameter] {
        return [
            "symbolName": MCPToolParameter(
                type: .string,
                description: "Symbol name (function, class, method, variable)",
                required: true
            ),
            "filePaths": MCPToolParameter(
                type: .array,
                description: "Paths likely containing definition (optional, improves speed)",
                required: false,
                arrayElementType: .string
            ),
            "rootPath": MCPToolParameter(
                type: .string,
                description: "Search root directory (defaults to current)",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.ListCodeUsagesTool")

    public init() {}

    public func initialize() async throws {
        logger.debug("[ListCodeUsagesTool] Initialized")
    }

    public func validateParameters(_ params: [String: Any]) throws -> Bool {
        /// symbolName is required.
        guard let symbolName = params["symbolName"] as? String, !symbolName.isEmpty else {
            throw MCPError.invalidParameters("symbolName parameter is required and must be a non-empty string")
        }

        /// filePaths is optional - if provided, must be array of strings.
        if let filePaths = params["filePaths"] {
            guard let paths = filePaths as? [String], !paths.isEmpty else {
                throw MCPError.invalidParameters("filePaths must be a non-empty array of strings")
            }
        }

        /// rootPath is optional - if provided, must exist.
        if let rootPath = params["rootPath"] as? String {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw MCPError.invalidParameters("rootPath must be an existing directory")
            }
        }

        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let symbolName = parameters["symbolName"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "symbolName parameter is required"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }

        let filePaths = parameters["filePaths"] as? [String]
        let rootPath = parameters["rootPath"] as? String ?? context.workingDirectory ?? FileManager.default.currentDirectoryPath

        do {
            /// Search for symbol usages.
            let usages = try await findSymbolUsages(
                symbolName: symbolName,
                definitionFiles: filePaths,
                rootPath: rootPath
            )

            /// Convert to JSON.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(usages)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

            logger.debug("[ListCodeUsagesTool] Found \(usages.count) usages of '\(symbolName)'")

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(
                    content: jsonString,
                    mimeType: "application/json"
                )
            )

        } catch {
            logger.error("[ListCodeUsagesTool] Failed to find usages: \(error.localizedDescription)")

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "Failed to find symbol usages: \(error.localizedDescription)"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }
    }

    // MARK: - Helper Methods

    @MainActor
    private func findSymbolUsages(
        symbolName: String,
        definitionFiles: [String]?,
        rootPath: String
    ) async throws -> [CodeUsage] {
        logger.debug("[ListCodeUsagesTool] Searching for '\(symbolName)' in \(rootPath)")

        /// Use grep to find all occurrences of the symbol Pattern matches: word boundaries to avoid partial matches.
        let pattern = "\\b\(symbolName)\\b"

        let process = Process()
        process.currentDirectoryPath = rootPath
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")

        /// Grep arguments: -r: recursive -n: show line numbers -E: extended regex -I: ignore binary files --include: only search code files.
        process.arguments = [
            "-r",
            "-n",
            "-E",
            "-I",
            "--include=*.swift",
            "--include=*.m",
            "--include=*.h",
            "--include=*.mm",
            "--include=*.c",
            "--include=*.cpp",
            pattern,
            "."
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        /// Parse grep output.
        var usages = parseGrepOutput(output, symbolName: symbolName, rootPath: rootPath)

        /// If definition files were provided, prioritize those results.
        if let defFiles = definitionFiles {
            usages = prioritizeDefinitionFiles(usages, definitionFiles: defFiles)
        }

        logger.debug("[ListCodeUsagesTool] Found \(usages.count) usages")
        return usages
    }

    private func parseGrepOutput(_ output: String, symbolName: String, rootPath: String) -> [CodeUsage] {
        var usages: [CodeUsage] = []

        /// Grep output format: file:line:content.
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            guard !line.isEmpty else { continue }

            /// Split by first two colons.
            let components = line.components(separatedBy: ":")
            guard components.count >= 3 else { continue }

            let filePath = components[0]
            guard let lineNumber = Int(components[1]) else { continue }

            /// Rest is the line content.
            let content = components.dropFirst(2).joined(separator: ":")

            /// Find column number (position of symbol in line).
            let columnNumber = findSymbolColumn(in: content, symbolName: symbolName)

            /// Determine usage kind based on context.
            let kind = determineUsageKind(content: content, symbolName: symbolName)

            /// Convert relative path to absolute.
            let absolutePath = filePath.hasPrefix("/") ? filePath : "\(rootPath)/\(filePath)"

            let usage = CodeUsage(
                file: absolutePath,
                line: lineNumber,
                column: columnNumber,
                context: content.trimmingCharacters(in: .whitespaces),
                kind: kind
            )

            usages.append(usage)
        }

        return usages
    }

    private func findSymbolColumn(in content: String, symbolName: String) -> Int {
        /// Find first occurrence of symbol in content.
        if let range = content.range(of: "\\b\(symbolName)\\b", options: .regularExpression) {
            return content.distance(from: content.startIndex, to: range.lowerBound) + 1
        }
        return 1
    }

    private func determineUsageKind(content: String, symbolName: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespaces)

        /// Check for various patterns.
        if trimmed.contains("func \(symbolName)") || trimmed.contains("class \(symbolName)") ||
           trimmed.contains("struct \(symbolName)") || trimmed.contains("enum \(symbolName)") {
            return "definition"
        } else if trimmed.contains("\(symbolName)(") {
            return "call"
        } else if trimmed.contains("let \(symbolName)") || trimmed.contains("var \(symbolName)") {
            return "declaration"
        } else {
            return "reference"
        }
    }

    private func prioritizeDefinitionFiles(_ usages: [CodeUsage], definitionFiles: [String]) -> [CodeUsage] {
        /// Move usages from definition files to the front.
        let inDefFiles = usages.filter { usage in
            definitionFiles.contains { defFile in
                usage.file == defFile || usage.file.hasSuffix(defFile)
            }
        }

        let others = usages.filter { usage in
            !definitionFiles.contains { defFile in
                usage.file == defFile || usage.file.hasSuffix(defFile)
            }
        }

        return inDefFiles + others
    }
}

// MARK: - Supporting Types

private struct CodeUsage: Codable {
    let file: String
    let line: Int
    let column: Int
    let context: String
    let kind: String
}
