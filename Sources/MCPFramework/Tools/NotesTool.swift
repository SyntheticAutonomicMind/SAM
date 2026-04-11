// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for Apple Notes via AppleScript.
/// Provides search, read, and create operations for Apple Notes.
public class NotesTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "notes_operations"

    public let description = """
    Search, read, and create Apple Notes using macOS AppleScript.

    OPERATIONS:
    • search - Search notes by keyword (query, optional: folder, max_results)
    • get_note - Get full content of a note (note_name, optional: folder)
    • create_note - Create a new note (title, body, optional: folder)
    • list_folders - List all note folders
    • list_notes - List notes in a folder (optional: folder, max_results)
    • append_note - Append text to an existing note (note_name, text, optional: folder)

    Notes are returned as plain text. HTML formatting in note bodies is stripped for readability.
    """

    public var supportedOperations: [String] {
        return ["search", "get_note", "create_note", "list_folders", "list_notes", "append_note"]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: "Notes operation to perform",
                required: true,
                enumValues: supportedOperations
            ),
            "query": MCPToolParameter(
                type: .string,
                description: "Search query for notes",
                required: false
            ),
            "note_name": MCPToolParameter(
                type: .string,
                description: "Note title/name for get_note or append_note",
                required: false
            ),
            "title": MCPToolParameter(
                type: .string,
                description: "Title for new note",
                required: false
            ),
            "body": MCPToolParameter(
                type: .string,
                description: "Body content for new note (plain text or HTML)",
                required: false
            ),
            "text": MCPToolParameter(
                type: .string,
                description: "Text to append to an existing note",
                required: false
            ),
            "folder": MCPToolParameter(
                type: .string,
                description: "Notes folder name (defaults to default account)",
                required: false
            ),
            "max_results": MCPToolParameter(
                type: .integer,
                description: "Maximum results to return (default: 20)",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.notes")

    @MainActor
    public func initialize() async throws {
        logger.debug("NotesTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard parameters["operation"] is String else {
            throw MCPError.invalidParameters("Missing 'operation' parameter")
        }
        return true
    }

    @MainActor
    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        switch operation {
        case "search":
            return await searchNotes(parameters: parameters)
        case "get_note":
            return await getNote(parameters: parameters)
        case "create_note":
            return await createNote(parameters: parameters)
        case "list_folders":
            return await listFolders()
        case "list_notes":
            return await listNotes(parameters: parameters)
        case "append_note":
            return await appendNote(parameters: parameters)
        default:
            return operationError(operation, message: "Unknown operation")
        }
    }

    // MARK: - AppleScript Execution

    private func runAppleScript(_ script: String) async -> (output: String, success: Bool) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                logger.error("AppleScript error: \(errStr)")

                if errStr.contains("Not authorized") || errStr.contains("not allowed") {
                    return ("Apple Notes access denied. Please grant automation permission in System Settings > Privacy & Security > Automation.", false)
                }
                return ("AppleScript error: \(errStr)", false)
            }

            return (output, true)
        } catch {
            return ("Failed to run AppleScript: \(error.localizedDescription)", false)
        }
    }

    private func escapeAppleScript(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func stripHTML(_ html: String) -> String {
        // Simple HTML tag stripping for readable output
        var text = html
        // Replace common HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "<br>", with: "\n")
        text = text.replacingOccurrences(of: "<br/>", with: "\n")
        text = text.replacingOccurrences(of: "<br />", with: "\n")
        text = text.replacingOccurrences(of: "</p>", with: "\n")
        text = text.replacingOccurrences(of: "</div>", with: "\n")
        text = text.replacingOccurrences(of: "</li>", with: "\n")
        // Strip remaining tags
        while let range = text.range(of: "<[^>]+>", options: .regularExpression) {
            text.replaceSubrange(range, with: "")
        }
        // Clean up extra whitespace
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Operations

    @MainActor
    private func searchNotes(parameters: [String: Any]) async -> MCPToolResult {
        guard let query = parameters["query"] as? String, !query.isEmpty else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: query"))
        }

        let maxResults = parameters["max_results"] as? Int ?? 20
        let folder = parameters["folder"] as? String
        let escapedQuery = escapeAppleScript(query.lowercased())

        var folderFilter = ""
        if let folder = folder {
            folderFilter = " of folder \"\(escapeAppleScript(folder))\""
        }

        let script = """
        tell application "Notes"
            set matchingNotes to {}
            set noteCount to 0
            repeat with n in notes\(folderFilter)
                if noteCount >= \(maxResults) then exit repeat
                set noteName to name of n
                set noteBody to plaintext of n
                if (noteName contains "\(escapedQuery)") or (noteBody contains "\(escapedQuery)") then
                    set noteDate to modification date of n
                    set end of matchingNotes to noteName & "|||" & (noteDate as string) & "|||" & (text 1 thru (min of {200, length of noteBody}) of noteBody)
                    set noteCount to noteCount + 1
                end if
            end repeat
            set AppleScript's text item delimiters to ":::"
            return matchingNotes as string
        end tell
        """

        let (output, success) = await runAppleScript(script)

        if !success {
            return MCPToolResult(success: false, output: MCPOutput(content: output))
        }

        if output.isEmpty {
            return MCPToolResult(success: true, output: MCPOutput(content: "No notes matching '\(query)'."))
        }

        let entries = output.components(separatedBy: ":::")
        var formatted = "Notes matching '\(query)' (\(entries.count) found):\n\n"

        for entry in entries {
            let parts = entry.components(separatedBy: "|||")
            if parts.count >= 3 {
                formatted += "- **\(parts[0])**\n"
                formatted += "  Modified: \(parts[1])\n"
                formatted += "  Preview: \(stripHTML(parts[2]))...\n\n"
            } else if !entry.isEmpty {
                formatted += "- \(entry)\n\n"
            }
        }

        return MCPToolResult(success: true, output: MCPOutput(content: formatted))
    }

    @MainActor
    private func getNote(parameters: [String: Any]) async -> MCPToolResult {
        guard let noteName = parameters["note_name"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: note_name"))
        }

        let folder = parameters["folder"] as? String
        let escapedName = escapeAppleScript(noteName)

        var folderFilter = ""
        if let folder = folder {
            folderFilter = " of folder \"\(escapeAppleScript(folder))\""
        }

        let script = """
        tell application "Notes"
            repeat with n in notes\(folderFilter)
                if name of n is "\(escapedName)" then
                    set noteBody to plaintext of n
                    set noteDate to modification date of n
                    set noteCreated to creation date of n
                    return name of n & "|||" & (noteCreated as string) & "|||" & (noteDate as string) & "|||" & noteBody
                end if
            end repeat
            return ""
        end tell
        """

        let (output, success) = await runAppleScript(script)

        if !success {
            return MCPToolResult(success: false, output: MCPOutput(content: output))
        }

        if output.isEmpty {
            return MCPToolResult(success: false, output: MCPOutput(content: "Note '\(noteName)' not found."))
        }

        let parts = output.components(separatedBy: "|||")
        if parts.count >= 4 {
            var formatted = "**\(parts[0])**\n"
            formatted += "Created: \(parts[1])\n"
            formatted += "Modified: \(parts[2])\n\n"
            formatted += stripHTML(parts[3])
            return MCPToolResult(success: true, output: MCPOutput(content: formatted))
        }

        return MCPToolResult(success: true, output: MCPOutput(content: stripHTML(output)))
    }

    @MainActor
    private func createNote(parameters: [String: Any]) async -> MCPToolResult {
        guard let title = parameters["title"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: title"))
        }
        guard let body = parameters["body"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: body"))
        }

        let folder = parameters["folder"] as? String
        let escapedTitle = escapeAppleScript(title)
        let escapedBody = escapeAppleScript(body)

        let htmlBody = "<h1>\(escapedTitle)</h1><br>\(escapedBody.replacingOccurrences(of: "\n", with: "<br>"))"

        let folderTarget: String
        if let folder = folder {
            folderTarget = "folder \"\(escapeAppleScript(folder))\" of default account"
        } else {
            folderTarget = "default account"
        }

        let script = """
        tell application "Notes"
            make new note at \(folderTarget) with properties {name:"\(escapedTitle)", body:"\(htmlBody)"}
            return "ok"
        end tell
        """

        let (output, success) = await runAppleScript(script)

        if !success {
            return MCPToolResult(success: false, output: MCPOutput(content: output))
        }

        logger.info("Created note: \(title)")
        return MCPToolResult(success: true, output: MCPOutput(content: "Created note '\(title)'."))
    }

    @MainActor
    private func listFolders() async -> MCPToolResult {
        let script = """
        tell application "Notes"
            set folderList to {}
            repeat with f in folders
                set end of folderList to name of f
            end repeat
            set AppleScript's text item delimiters to ":::"
            return folderList as string
        end tell
        """

        let (output, success) = await runAppleScript(script)

        if !success {
            return MCPToolResult(success: false, output: MCPOutput(content: output))
        }

        if output.isEmpty {
            return MCPToolResult(success: true, output: MCPOutput(content: "No note folders found."))
        }

        let folders = output.components(separatedBy: ":::")
        var formatted = "Note Folders (\(folders.count)):\n\n"
        for folder in folders {
            formatted += "- \(folder)\n"
        }

        return MCPToolResult(success: true, output: MCPOutput(content: formatted))
    }

    @MainActor
    private func listNotes(parameters: [String: Any]) async -> MCPToolResult {
        let maxResults = parameters["max_results"] as? Int ?? 20
        let folder = parameters["folder"] as? String

        var folderFilter = ""
        if let folder = folder {
            folderFilter = " of folder \"\(escapeAppleScript(folder))\""
        }

        let script = """
        tell application "Notes"
            set noteList to {}
            set noteCount to 0
            repeat with n in notes\(folderFilter)
                if noteCount >= \(maxResults) then exit repeat
                set noteDate to modification date of n
                set end of noteList to name of n & "|||" & (noteDate as string)
                set noteCount to noteCount + 1
            end repeat
            set AppleScript's text item delimiters to ":::"
            return noteList as string
        end tell
        """

        let (output, success) = await runAppleScript(script)

        if !success {
            return MCPToolResult(success: false, output: MCPOutput(content: output))
        }

        if output.isEmpty {
            let scope = folder.map { " in '\($0)'" } ?? ""
            return MCPToolResult(success: true, output: MCPOutput(content: "No notes found\(scope)."))
        }

        let entries = output.components(separatedBy: ":::")
        let scope = folder.map { " in '\($0)'" } ?? ""
        var formatted = "Notes\(scope) (\(entries.count) shown):\n\n"

        for entry in entries {
            let parts = entry.components(separatedBy: "|||")
            if parts.count >= 2 {
                formatted += "- **\(parts[0])** (modified: \(parts[1]))\n"
            } else if !entry.isEmpty {
                formatted += "- \(entry)\n"
            }
        }

        return MCPToolResult(success: true, output: MCPOutput(content: formatted))
    }

    @MainActor
    private func appendNote(parameters: [String: Any]) async -> MCPToolResult {
        guard let noteName = parameters["note_name"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: note_name"))
        }
        guard let text = parameters["text"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: text"))
        }

        let folder = parameters["folder"] as? String
        let escapedName = escapeAppleScript(noteName)
        let escapedText = escapeAppleScript(text).replacingOccurrences(of: "\n", with: "<br>")

        var folderFilter = ""
        if let folder = folder {
            folderFilter = " of folder \"\(escapeAppleScript(folder))\""
        }

        let script = """
        tell application "Notes"
            repeat with n in notes\(folderFilter)
                if name of n is "\(escapedName)" then
                    set currentBody to body of n
                    set body of n to currentBody & "<br><br>" & "\(escapedText)"
                    return "ok"
                end if
            end repeat
            return "not_found"
        end tell
        """

        let (output, success) = await runAppleScript(script)

        if !success {
            return MCPToolResult(success: false, output: MCPOutput(content: output))
        }

        if output == "not_found" {
            return MCPToolResult(success: false, output: MCPOutput(content: "Note '\(noteName)' not found."))
        }

        logger.info("Appended to note: \(noteName)")
        return MCPToolResult(success: true, output: MCPOutput(content: "Appended text to note '\(noteName)'."))
    }
}
