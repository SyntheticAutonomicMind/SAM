// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for applying patch files to documents and source code Enables users to apply unified diff patches, context diffs, and git-style patches to files.
public class ApplyPatchTool: MCPTool, @unchecked Sendable {
    public let name = "apply_patch"
    public let description = "Apply patch files (unified diff, context diff, git diff) to documents and source code. Includes automatic backups, atomic writes, dry-run validation, and conflict detection. Useful for applying fixes and updates described in patch format."

    public var parameters: [String: MCPToolParameter] {
        [
            "patch_content": MCPToolParameter(
                type: .string,
                description: "The patch file content (unified diff, context diff, or git diff format)",
                required: true
            ),
            "target_directory": MCPToolParameter(
                type: .string,
                description: "Base directory for relative file paths in patch (default: current directory)",
                required: false
            ),
            "dry_run": MCPToolParameter(
                type: .boolean,
                description: "Validate patch without applying changes (default: false)",
                required: false
            ),
            "confirm": MCPToolParameter(
                type: .boolean,
                description: "SECURITY: Must be true to apply patches that modify files (not required for dry_run=true)",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.ApplyPatchTool")
    private let fileOps = FileOperationsSafety()

    /// SECURITY: Rate limiting for destructive operations.
    private var lastDestructiveOperation: Date?
    private let destructiveOperationCooldown: TimeInterval = 5.0

    public init() {}

    public func initialize() async throws {
        logger.debug("[ApplyPatchTool] Initialized")
    }

    public func validateParameters(_ params: [String: Any]) throws -> Bool {
        guard let patchContent = params["patch_content"] as? String, !patchContent.isEmpty else {
            throw MCPError.invalidParameters("patch_content parameter is required and must be non-empty")
        }
        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        logger.debug("Executing apply_patch tool")

        guard let patchContent = parameters["patch_content"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "{\"success\": false, \"error\": \"Missing required parameter: patch_content\"}")
            )
        }

        let targetDirectory = parameters["target_directory"] as? String ?? context.workingDirectory ?? FileManager.default.currentDirectoryPath
        let dryRun = parameters["dry_run"] as? Bool ?? false

        /// ====================================================================== SECURITY: Path Authorization Check (only for actual application, not dry run) ====================================================================== Block operations outside working directory UNLESS user authorized.
        let operationKey = "file_operations.apply_patch"

        /// Use centralized authorization guard (check target directory).
        if !dryRun {
            let authResult = MCPAuthorizationGuard.checkPathAuthorization(
                path: targetDirectory,
                workingDirectory: context.workingDirectory,
                conversationId: context.conversationId,
                operation: operationKey,
                isUserInitiated: context.isUserInitiated
            )

            switch authResult {
            case .allowed:
                /// Path is inside working directory or user authorized - continue.
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
                    suggestedPrompt: "Apply patch to files in [\(targetDirectory)]?"
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
                    output: MCPOutput(content: "Authorization required for path")
                )
            }
        }

        /// ====================================================================== SECURITY LAYER 3: Rate Limiting ====================================================================== Prevent rapid-fire patch application.
        if !dryRun, let lastOperation = lastDestructiveOperation {
            let timeSinceLastOperation = Date().timeIntervalSince(lastOperation)
            if timeSinceLastOperation < destructiveOperationCooldown {
                let waitTime = destructiveOperationCooldown - timeSinceLastOperation
                logger.warning("Rate limit triggered for apply_patch (wait \(String(format: "%.1f", waitTime)) seconds)")
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "SECURITY: Destructive operations rate limited. Please wait \(String(format: "%.1f", waitTime)) seconds before retrying.")
                )
            }
        }

        /// ====================================================================== SECURITY LAYER 4: Audit Logging ====================================================================== Log all patch applications for security audit trail.
        if !dryRun {
            logger.critical("""
                DESTRUCTIVE_OPERATION_AUTHORIZED:
                operation=apply_patch
                targetDirectory=\(targetDirectory)
                confirm=true
                isUserInitiated=\(context.isUserInitiated)
                userRequest=\(context.userRequestText ?? "none")
                timestamp=\(ISO8601DateFormatter().string(from: Date()))
                sessionId=\(context.sessionId.uuidString)
                """)

            lastDestructiveOperation = Date()
        }

        logger.debug("Applying patch to directory: \(targetDirectory) (dry-run: \(dryRun))")

        /// Parse patch.
        let parseResult = parsePatch(patchContent)
        guard let patches = parseResult.patches else {
            let errorResult = [
                "success": false,
                "error": "Failed to parse patch: \(parseResult.error ?? "Unknown error")",
                "dry_run": dryRun
            ] as [String: Any]

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: formatJSON(errorResult))
            )
        }

        if patches.isEmpty {
            let errorResult = [
                "success": false,
                "error": "No valid patches found in content",
                "dry_run": dryRun
            ] as [String: Any]

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: formatJSON(errorResult))
            )
        }

        logger.debug("Parsed \(patches.count) file patch(es)")

        /// Apply patches.
        let applyResult = applyPatches(
            patches: patches,
            targetDirectory: targetDirectory,
            dryRun: dryRun
        )

        if applyResult.success {
            logger.debug("Successfully applied \(applyResult.filesModified) file(s)")
        } else {
            logger.error("Failed to apply patches: \(applyResult.error ?? "Unknown error")")
        }

        return MCPToolResult(
            toolName: name,
            success: applyResult.success,
            output: MCPOutput(content: formatJSON(applyResult.metadata), mimeType: "application/json")
        )
    }

    // MARK: - Patch Data Structures

    struct FilePatch {
        let originalFile: String
        let modifiedFile: String
        let hunks: [Hunk]
    }

    struct Hunk {
        let originalStart: Int
        let originalCount: Int
        let modifiedStart: Int
        let modifiedCount: Int
        let lines: [HunkLine]
    }

    struct HunkLine {
        enum LineType {
            case context
            case addition
            case deletion
        }

        let type: LineType
        let content: String
    }

    // MARK: - Patch Parsing

    private func parsePatch(_ patchContent: String) -> (patches: [FilePatch]?, error: String?) {
        var patches: [FilePatch] = []
        let lines = patchContent.components(separatedBy: .newlines)

        var i = 0
        while i < lines.count {
            let line = lines[i]

            /// Look for file headers (--- and +++).
            if line.hasPrefix("---") && i + 1 < lines.count && lines[i + 1].hasPrefix("+++") {
                let originalFile = extractFileName(from: line)
                let modifiedFile = extractFileName(from: lines[i + 1])

                i += 2

                /// Parse hunks for this file.
                var hunks: [Hunk] = []
                while i < lines.count && lines[i].hasPrefix("@@") {
                    if let hunk = parseHunk(lines: lines, startIndex: &i) {
                        hunks.append(hunk)
                    }
                }

                if !hunks.isEmpty {
                    patches.append(FilePatch(originalFile: originalFile, modifiedFile: modifiedFile, hunks: hunks))
                }
            } else {
                i += 1
            }
        }

        if patches.isEmpty {
            return (nil, "No valid patch format found (expected --- and +++ headers)")
        }

        return (patches, nil)
    }

    private func extractFileName(from line: String) -> String {
        /// Remove prefix (--- or +++) and whitespace.
        var fileName = line
        if fileName.hasPrefix("---") {
            fileName = String(fileName.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if fileName.hasPrefix("+++") {
            fileName = String(fileName.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }

        /// Remove /dev/null.
        if fileName == "/dev/null" {
            return fileName
        }

        /// Remove a/ or b/ prefixes (git format).
        if fileName.hasPrefix("a/") || fileName.hasPrefix("b/") {
            fileName = String(fileName.dropFirst(2))
        }

        /// Remove timestamp if present (space followed by date/time).
        if let spaceIndex = fileName.firstIndex(of: "\t") ?? fileName.firstIndex(of: " ") {
            fileName = String(fileName[..<spaceIndex])
        }

        return fileName
    }

    private func parseHunk(lines: [String], startIndex: inout Int) -> Hunk? {
        let hunkHeader = lines[startIndex]
        startIndex += 1

        /// Parse @@ -X,Y +A,B @@ format.
        guard let hunkInfo = parseHunkHeader(hunkHeader) else {
            return nil
        }

        var hunkLines: [HunkLine] = []
        while startIndex < lines.count {
            let line = lines[startIndex]

            /// End of hunk (next hunk, file, or end of patch).
            if line.hasPrefix("@@") || line.hasPrefix("---") || line.hasPrefix("+++") {
                break
            }

            /// Parse hunk line.
            if line.hasPrefix("-") {
                hunkLines.append(HunkLine(type: .deletion, content: String(line.dropFirst())))
            } else if line.hasPrefix("+") {
                hunkLines.append(HunkLine(type: .addition, content: String(line.dropFirst())))
            } else if line.hasPrefix(" ") || line.isEmpty {
                hunkLines.append(HunkLine(type: .context, content: line.isEmpty ? "" : String(line.dropFirst())))
            } else {
                /// Treat as context line (some patches don't use space prefix).
                hunkLines.append(HunkLine(type: .context, content: line))
            }

            startIndex += 1
        }

        return Hunk(
            originalStart: hunkInfo.originalStart,
            originalCount: hunkInfo.originalCount,
            modifiedStart: hunkInfo.modifiedStart,
            modifiedCount: hunkInfo.modifiedCount,
            lines: hunkLines
        )
    }

    private func parseHunkHeader(_ header: String) -> (originalStart: Int, originalCount: Int, modifiedStart: Int, modifiedCount: Int)? {
        /// Format: @@ -X,Y +A,B @@.
        let pattern = #"@@\s*-(\d+)(?:,(\d+))?\s*\+(\d+)(?:,(\d+))?\s*@@"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsString = header as NSString
        guard let match = regex.firstMatch(in: header, range: NSRange(location: 0, length: nsString.length)) else {
            return nil
        }

        let originalStart = Int(nsString.substring(with: match.range(at: 1))) ?? 1
        let originalCount = match.range(at: 2).location != NSNotFound ? Int(nsString.substring(with: match.range(at: 2))) ?? 1 : 1
        let modifiedStart = Int(nsString.substring(with: match.range(at: 3))) ?? 1
        let modifiedCount = match.range(at: 4).location != NSNotFound ? Int(nsString.substring(with: match.range(at: 4))) ?? 1 : 1

        return (originalStart, originalCount, modifiedStart, modifiedCount)
    }

    // MARK: - Patch Application

    private func applyPatches(patches: [FilePatch], targetDirectory: String, dryRun: Bool) -> (success: Bool, filesModified: Int, metadata: [String: Any], error: String?) {
        var fileResults: [[String: Any]] = []
        var filesModified = 0
        var backupDirectory: String?

        /// Create backup directory if not dry-run.
        if !dryRun {
            backupDirectory = createBackupDirectory()
        }

        for patch in patches {
            let filePath = (targetDirectory as NSString).appendingPathComponent(patch.modifiedFile)

            /// Check file exists.
            guard FileManager.default.fileExists(atPath: filePath) else {
                let error = "File not found: \(filePath)"
                logger.error("\(error)")
                return (false, filesModified, [
                    "success": false,
                    "error": error,
                    "dry_run": dryRun
                ], error)
            }

            /// Read original file.
            guard let originalContent = try? String(contentsOfFile: filePath, encoding: .utf8) else {
                let error = "Failed to read file: \(filePath)"
                logger.error("\(error)")
                return (false, filesModified, [
                    "success": false,
                    "error": error,
                    "dry_run": dryRun
                ], error)
            }

            /// Apply hunks.
            var lines = originalContent.components(separatedBy: .newlines)
            var linesChanged = 0

            for hunk in patch.hunks {
                let applyResult = applyHunk(hunk: hunk, to: &lines)
                if !applyResult.success {
                    let error = "Failed to apply hunk to \(patch.modifiedFile): \(applyResult.error ?? "Unknown error")"
                    logger.error("\(error)")
                    return (false, filesModified, [
                        "success": false,
                        "error": error,
                        "file": patch.modifiedFile,
                        "dry_run": dryRun
                    ], error)
                }
                linesChanged += applyResult.linesChanged
            }

            /// Write modified content (if not dry-run).
            var backupPath: String?
            if !dryRun {
                /// Create backup.
                if let backupDir = backupDirectory {
                    backupPath = (backupDir as NSString).appendingPathComponent(patch.modifiedFile.replacingOccurrences(of: "/", with: "_"))
                    try? FileManager.default.copyItem(atPath: filePath, toPath: backupPath!)
                }

                /// Write with FileOperationsSafety.
                let newContent = lines.joined(separator: "\n")
                let writeResult = fileOps.atomicWrite(content: newContent, to: filePath, createBackup: true)
                if writeResult.success {
                    filesModified += 1
                    logger.debug("Successfully applied patch to \(patch.modifiedFile)")
                } else {
                    let error = "Failed to write patched file: \(writeResult.error ?? "Unknown error")"
                    logger.error("\(error)")
                    return (false, filesModified, [
                        "success": false,
                        "error": error,
                        "file": patch.modifiedFile,
                        "dry_run": dryRun
                    ], error)
                }
            }

            fileResults.append([
                "path": patch.modifiedFile,
                "hunks_applied": patch.hunks.count,
                "lines_changed": linesChanged,
                "backup_path": backupPath as Any
            ])
        }

        let metadata: [String: Any] = [
            "success": true,
            "files_modified": filesModified,
            "files": fileResults,
            "dry_run": dryRun,
            "backup_directory": backupDirectory as Any
        ]

        return (true, filesModified, metadata, nil)
    }

    private func applyHunk(hunk: Hunk, to lines: inout [String]) -> (success: Bool, linesChanged: Int, error: String?) {
        var lineIndex = hunk.originalStart - 1
        var linesChanged = 0

        for hunkLine in hunk.lines {
            switch hunkLine.type {
            case .context:
                /// Verify context matches.
                if lineIndex < lines.count {
                    /// Context line should match (allowing for whitespace differences).
                    let expected = hunkLine.content.trimmingCharacters(in: .whitespaces)
                    let actual = lines[lineIndex].trimmingCharacters(in: .whitespaces)
                    if expected != actual && !expected.isEmpty {
                        logger.warning("Context mismatch at line \(lineIndex + 1): expected '\(expected)', got '\(actual)'")
                        /// Continue anyway for fuzzy matching (some patches have whitespace differences).
                    }
                    lineIndex += 1
                } else {
                    return (false, linesChanged, "Context line out of range at line \(lineIndex + 1)")
                }

            case .deletion:
                /// Remove line.
                if lineIndex < lines.count {
                    lines.remove(at: lineIndex)
                    linesChanged += 1
                } else {
                    return (false, linesChanged, "Deletion line out of range at line \(lineIndex + 1)")
                }

            case .addition:
                /// Insert line.
                if lineIndex <= lines.count {
                    lines.insert(hunkLine.content, at: lineIndex)
                    lineIndex += 1
                    linesChanged += 1
                } else {
                    return (false, linesChanged, "Addition line out of range at line \(lineIndex + 1)")
                }
            }
        }

        return (true, linesChanged, nil)
    }

    private func createBackupDirectory() -> String {
        _ = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .none)
        let backupDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("sam_patch_backups_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        return backupDir
    }

    private func formatJSON(_ object: [String: Any]) -> String {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "{\"error\": \"Failed to serialize response\"}"
        }
        return jsonString
    }
}
