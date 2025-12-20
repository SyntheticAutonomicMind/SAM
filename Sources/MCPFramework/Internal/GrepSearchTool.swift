// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

// Clean, single-definition GrepSearchTool to replace the previously corrupted file.
public class GrepSearchTool: MCPTool, @unchecked Sendable {
    public let name = "grep_search"
    public let description = "Search for text within files (literal search)."

    public var parameters: [String: MCPToolParameter] { ["query": MCPToolParameter(type: .string, description: "Search text", required: true)] }

    public struct GrepMatch: Codable, Sendable { let filePath: String; let lineNumber: Int; let lineText: String; let matchText: String }
    public struct GrepSearchResult: Codable { let matches: [GrepMatch]; let totalCount: Int }

    public init() {}
    public func initialize() async throws {}
    public func validateParameters(_ parameters: [String: Any]) throws -> Bool { guard parameters["query"] is String else { throw MCPError.invalidParameters("query required") }; return true }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let query = parameters["query"] as? String else { return MCPToolResult(toolName: name, success: false, output: MCPOutput(content: "Missing query")) }
        do {
            // Run synchronous search in detached task
            let wd = context.workingDirectory
            let matches = try await Task.detached {
                try GrepSearchTool.quickSearch(query: query, workingDirectory: wd)
            }.value
            let result = GrepSearchResult(matches: matches, totalCount: matches.count)
            let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
            let data = try enc.encode(result)
            return MCPToolResult(toolName: name, success: true, output: MCPOutput(content: String(data: data, encoding: .utf8) ?? "{}", mimeType: "application/json"))
        } catch {
            return MCPToolResult(toolName: name, success: false, output: MCPOutput(content: "Search error: \(error.localizedDescription)"))
        }
    }

    private static func quickSearch(query: String, workingDirectory: String?) throws -> [GrepMatch] {
        var results: [GrepMatch] = []
        let fm = FileManager.default
        let root = workingDirectory ?? fm.currentDirectoryPath
        let url = URL(fileURLWithPath: root)
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let regex = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: query), options: .caseInsensitive)
        for case let fileURL as URL in enumerator {
            if let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), rv.isRegularFile == true {
                if let s = try? String(contentsOf: fileURL, encoding: .utf8) {
                    let lines = s.components(separatedBy: .newlines)
                    for (i, line) in lines.enumerated() {
                        let nsr = NSRange(line.startIndex..<line.endIndex, in: line)
                        if regex.firstMatch(in: line, options: [], range: nsr) != nil {
                            results.append(GrepMatch(filePath: fileURL.path.replacingOccurrences(of: root + "/", with: ""), lineNumber: i+1, lineText: line, matchText: query))
                        }
                    }
                }
            }
        }
        return results
    }
}
