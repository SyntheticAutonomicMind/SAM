// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MessageValidator: Context budget management and tool message validation.
/// Ported from CLIO's MessageValidator - ensures context stays within model limits
/// using a newest-first budget walk with thread_summary compression for dropped messages.
///
/// Key design principles (from CLIO):
/// - Preserves tool_call/tool_result pairing (critical for agent workflows)
/// - Uses simple token estimation (char/4) - no ML model needed
/// - Compresses dropped messages into a thread_summary
/// - Always preserves system prompt + most recent user message
/// - Post-trim target at 50% of max to give headroom before next trim
public struct MessageValidator {
    private static let logger = Logger(label: "com.sam.MessageValidator")

    // MARK: - Message Unit Grouping

    /// A logical unit of messages that should stay together.
    /// An assistant message with tool_calls + all corresponding tool results form one unit.
    struct MessageUnit {
        var messages: [OpenAIChatMessage]
        var tokens: Int
        var toolCallIds: Set<String>
        var isOrphanToolResult: Bool
        var orphanToolId: String?
    }

    // MARK: - Result Type

    /// Result of validation/truncation including dropped messages for archival.
    public struct TruncationResult {
        /// Messages to send to the LLM.
        public let messages: [OpenAIChatMessage]
        /// Messages that were dropped (for archival).
        public let droppedMessages: [OpenAIChatMessage]
        /// Whether any trimming occurred.
        public var wasTrimmed: Bool { !droppedMessages.isEmpty }
    }

    // MARK: - Public API

    /// Validate and truncate messages to fit within model context budget.
    /// Returns cleaned messages array with:
    /// - System prompt always preserved
    /// - Thread summary for dropped context
    /// - Tool call/result pairs validated
    /// - Most recent user message preserved
    public static func validateAndTruncate(
        messages: [OpenAIChatMessage],
        maxPromptTokens: Int,
        toolTokens: Int = 0
    ) -> [OpenAIChatMessage] {
        guard !messages.isEmpty else { return [] }

        // Calculate effective limit: max - tools - 15% safety margin - response buffer
        let estimationMargin = Int(Double(maxPromptTokens) * 0.15)
        let responseBuffer = 8000
        var effectiveLimit = maxPromptTokens - toolTokens - estimationMargin - responseBuffer
        if effectiveLimit < 1000 { effectiveLimit = 1000 }

        let estimatedTokens = estimateTokens(messages)

        logger.debug("Token budget: max=\(maxPromptTokens), tools=\(toolTokens), effective=\(effectiveLimit), current=\(estimatedTokens)")

        if estimatedTokens <= effectiveLimit {
            // Within budget - just validate tool pairs
            logger.debug("Messages within budget (\(estimatedTokens)/\(effectiveLimit)), validating pairs only")
            return validateToolMessagePairs(messages)
        }

        // Need to truncate
        logger.info("Messages exceed budget: \(estimatedTokens) > \(effectiveLimit), truncating")

        // Group messages into logical units
        let units = groupIntoUnits(messages)
        logger.debug("Grouped \(messages.count) messages into \(units.count) units")

        // Extract preserved elements
        let (systemMsg, lastUserUnit, startIdx) = extractPreservedUnits(units)

        let systemTokens = systemMsg != nil ? estimateTokens([systemMsg!]) : 0

        // Find existing thread_summary. Note: extractPreservedUnits already
        // incremented startIdx past the summary, so we look just before startIdx.
        var existingSummaryMsg: OpenAIChatMessage?
        var summaryTokens = 0
        if startIdx > 0 && startIdx <= units.count {
            let summaryIdx = startIdx - 1
            let unit = units[summaryIdx]
            if let msg = unit.messages.first,
               msg.role == "system",
               (msg.content?.contains("<thread_summary>") ?? false) {
                existingSummaryMsg = msg
                summaryTokens = unit.tokens
            }
        }

        // Budget walk: newest to oldest
        // Post-trim target: 50% of max to give headroom before next trim
        var postTrimKeepLimit = Int(Double(maxPromptTokens) * 0.50)
        if postTrimKeepLimit < Int(Double(effectiveLimit) * 0.5) {
            postTrimKeepLimit = effectiveLimit
        }
        if postTrimKeepLimit < 32000 { postTrimKeepLimit = 32000 }

        logger.debug("Post-trim keep target: \(postTrimKeepLimit) tokens (50% of \(maxPromptTokens))")

        var currentTokens = systemTokens + summaryTokens
        var conversation: [OpenAIChatMessage] = []
        var includedToolIds = Set<String>()
        var droppedUnits: [MessageUnit] = []

        let remaining = Array(units[startIdx...])

        // Walk from newest to oldest
        for unit in remaining.reversed() {
            if unit.isOrphanToolResult {
                continue
            }

            if currentTokens + unit.tokens <= postTrimKeepLimit {
                conversation.insert(contentsOf: unit.messages, at: 0)
                currentTokens += unit.tokens
                includedToolIds.formUnion(unit.toolCallIds)
            } else {
                droppedUnits.append(unit)
            }
        }

        // Compress dropped units into thread_summary
        var summaryToUse: OpenAIChatMessage?
        if !droppedUnits.isEmpty {
            let previousSummary = existingSummaryMsg?.content ?? ""
            summaryToUse = compressDropped(
                droppedUnits,
                lastUserUnit: lastUserUnit,
                previousSummary: previousSummary,
                droppedMessagesContainFirstRequest: existingSummaryMsg == nil
            )
        } else if let existing = existingSummaryMsg {
            summaryToUse = existing
            logger.debug("PRESERVED_SUMMARY: No dropped messages - keeping existing thread_summary")
        }

        // Remove orphaned tool results from conversation
        var validated: [OpenAIChatMessage] = []
        for msg in conversation {
            if let toolCallId = msg.toolCallId, !includedToolIds.contains(toolCallId) {
                logger.debug("Dropping orphaned tool_result after truncation: \(toolCallId)")
                continue
            }
            validated.append(msg)
        }

        // Ensure at least one user message exists
        let hasUserMsg = validated.contains { $0.role == "user" }
        if !hasUserMsg, let lastUser = lastUserUnit {
            for msg in lastUser.messages where msg.role == "user" {
                if let content = msg.content, !content.isEmpty {
                    validated.insert(msg, at: 0)
                    logger.info("Injected preserved user message (budget walk dropped it)")
                    break
                }
            }
        }

        // If still no user message, extract task from thread_summary
        if !validated.contains(where: { $0.role == "user" }) {
            if let summaryContent = summaryToUse?.content,
               let taskRange = summaryContent.range(of: "Current task: ") {
                let taskStart = taskRange.upperBound
                let taskEnd = summaryContent[taskStart...].firstIndex(of: "\n") ?? summaryContent.endIndex
                let task = String(summaryContent[taskStart..<taskEnd])
                if !task.isEmpty {
                    validated.insert(OpenAIChatMessage(role: "user", content: task), at: 0)
                    logger.info("Injected synthetic user message from thread_summary task")
                }
            }
        }

        // Combine: system + summary + conversation
        var truncated: [OpenAIChatMessage] = []
        if let sys = systemMsg { truncated.append(sys) }
        if let summary = summaryToUse { truncated.append(summary) }
        truncated.append(contentsOf: validated)

        let finalTokens = estimateTokens(truncated)
        logger.info("Truncated: \(messages.count) -> \(truncated.count) messages, \(finalTokens) tokens")

        return truncated
    }

    /// Validate and truncate, returning both kept and dropped messages.
    /// Use this when you need to archive dropped messages.
    public static func validateAndTruncateWithDropped(
        messages: [OpenAIChatMessage],
        maxPromptTokens: Int,
        toolTokens: Int = 0
    ) -> TruncationResult {
        let kept = validateAndTruncate(
            messages: messages,
            maxPromptTokens: maxPromptTokens,
            toolTokens: toolTokens
        )

        // If no trimming occurred, nothing was dropped
        if kept.count >= messages.count {
            return TruncationResult(messages: kept, droppedMessages: [])
        }

        // Build a set of kept message identifiers (content+role hashes)
        // to identify which original messages were dropped
        var keptFingerprints = Set<String>()
        for msg in kept {
            let fp = "\(msg.role)|\(msg.content?.prefix(200) ?? "nil")|\(msg.toolCallId ?? "")"
            keptFingerprints.insert(fp)
        }

        var dropped: [OpenAIChatMessage] = []
        for msg in messages {
            // Skip system messages (they're compressed into summary, not "dropped")
            if msg.role == "system" { continue }
            let fp = "\(msg.role)|\(msg.content?.prefix(200) ?? "nil")|\(msg.toolCallId ?? "")"
            if !keptFingerprints.contains(fp) {
                dropped.append(msg)
            }
        }

        return TruncationResult(messages: kept, droppedMessages: dropped)
    }

    // MARK: - Tool Message Pair Validation

    /// Validate that every tool_call has a matching tool_result and vice versa.
    /// Removes orphaned tool_results and strips orphaned tool_calls from assistant messages.
    public static func validateToolMessagePairs(_ messages: [OpenAIChatMessage]) -> [OpenAIChatMessage] {
        guard !messages.isEmpty else { return [] }

        // Build bidirectional maps
        var tcIdToAssistantIdx: [String: Int] = [:]
        var trIdToResultIdx: [String: Int] = [:]

        for (i, msg) in messages.enumerated() {
            if msg.role == "assistant", let toolCalls = msg.toolCalls {
                for tc in toolCalls {
                    tcIdToAssistantIdx[tc.id] = i
                }
            }
            if msg.role == "tool", let toolCallId = msg.toolCallId {
                trIdToResultIdx[toolCallId] = i
            }
        }

        // Find orphaned tool_calls (no matching result)
        var orphanedTcIds = Set<String>()
        for tcId in tcIdToAssistantIdx.keys {
            if trIdToResultIdx[tcId] == nil {
                orphanedTcIds.insert(tcId)
            }
        }

        // Find orphaned tool_results (no matching call) OR out-of-order results
        var orphanedResultIndices = Set<Int>()
        for (trId, resultIdx) in trIdToResultIdx {
            if let assistantIdx = tcIdToAssistantIdx[trId] {
                // Tool result must come AFTER the assistant message with tool_calls
                if resultIdx < assistantIdx {
                    logger.debug("Tool result at index \(resultIdx) precedes its tool_calls at index \(assistantIdx) - removing")
                    orphanedResultIndices.insert(resultIdx)
                }
            } else {
                orphanedResultIndices.insert(resultIdx)
            }
        }

        // Build validated array
        var validated: [OpenAIChatMessage] = []
        for (i, msg) in messages.enumerated() {
            // Skip orphaned or misordered tool results
            if orphanedResultIndices.contains(i) {
                logger.debug("Removing orphaned/misordered tool_result at index \(i)")
                continue
            }

            // Strip orphaned tool_calls from assistant messages
            if msg.role == "assistant", let toolCalls = msg.toolCalls {
                let validCalls = toolCalls.filter { !orphanedTcIds.contains($0.id) }
                if validCalls.count != toolCalls.count {
                    logger.debug("Stripped \(toolCalls.count - validCalls.count) orphaned tool_calls from assistant at index \(i)")
                    // Rebuild message without orphaned tool calls
                    let cleaned = OpenAIChatMessage(
                        id: msg.id,
                        role: msg.role,
                        content: msg.content,
                        toolCalls: validCalls.isEmpty ? nil : validCalls,
                        toolCallId: msg.toolCallId
                    )
                    validated.append(cleaned)
                } else {
                    validated.append(msg)
                }
            } else {
                validated.append(msg)
            }
        }

        return validated
    }

    // MARK: - Token Estimation

    /// Estimate token count using char/4 heuristic (same approach as CLIO).
    public static func estimateTokens(_ messages: [OpenAIChatMessage]) -> Int {
        var total = 0
        for msg in messages {
            // Per-message overhead (role + formatting)
            total += 4

            if let content = msg.content {
                total += content.count / 4
            }

            // Tool call overhead
            if let toolCalls = msg.toolCalls {
                for tc in toolCalls {
                    total += tc.function.arguments.count / 4
                    total += tc.function.name.count / 4
                    total += 20 // tool call structure overhead
                }
            }
        }
        return total
    }

    // MARK: - Private Implementation

    /// Group messages into logical units that should stay together.
    private static func groupIntoUnits(_ messages: [OpenAIChatMessage]) -> [MessageUnit] {
        var units: [MessageUnit] = []
        var i = 0

        while i < messages.count {
            let msg = messages[i]

            if msg.role == "assistant" && msg.toolCalls != nil && !(msg.toolCalls?.isEmpty ?? true) {
                // Assistant message with tool_calls - group with following tool results
                var unit = MessageUnit(
                    messages: [msg],
                    tokens: 0,
                    toolCallIds: Set<String>(),
                    isOrphanToolResult: false,
                    orphanToolId: nil
                )

                // Collect tool call IDs
                if let toolCalls = msg.toolCalls {
                    for tc in toolCalls {
                        unit.toolCallIds.insert(tc.id)
                    }
                }

                // Collect subsequent tool results
                var j = i + 1
                while j < messages.count && messages[j].role == "tool" {
                    let toolMsg = messages[j]
                    unit.messages.append(toolMsg)
                    if let tcId = toolMsg.toolCallId {
                        unit.toolCallIds.insert(tcId)
                    }
                    j += 1
                }

                unit.tokens = estimateTokens(unit.messages)
                units.append(unit)
                i = j
            } else if msg.role == "tool" {
                // Orphan tool result (no preceding assistant with tool_calls)
                let unit = MessageUnit(
                    messages: [msg],
                    tokens: estimateTokens([msg]),
                    toolCallIds: Set<String>(),
                    isOrphanToolResult: true,
                    orphanToolId: msg.toolCallId
                )
                units.append(unit)
                i += 1
            } else {
                // Regular message (user, assistant without tools, system)
                let unit = MessageUnit(
                    messages: [msg],
                    tokens: estimateTokens([msg]),
                    toolCallIds: Set<String>(),
                    isOrphanToolResult: false,
                    orphanToolId: nil
                )
                units.append(unit)
                i += 1
            }
        }

        return units
    }

    /// Extract the system message and most recent user unit.
    private static func extractPreservedUnits(_ units: [MessageUnit]) -> (
        systemMsg: OpenAIChatMessage?,
        lastUserUnit: MessageUnit?,
        startIdx: Int
    ) {
        var systemMsg: OpenAIChatMessage?
        var lastUserUnit: MessageUnit?
        var startIdx = 0

        // System message is always first
        if let first = units.first, first.messages.first?.role == "system" {
            systemMsg = first.messages.first
            startIdx = 1
        }

        // Skip existing thread_summary (we'll re-add it)
        if startIdx < units.count,
           let content = units[startIdx].messages.first?.content,
           content.contains("<thread_summary>") {
            startIdx += 1
        }

        // Find most recent user unit
        for unit in units.reversed() {
            if unit.messages.first?.role == "user" {
                lastUserUnit = unit
                break
            }
        }

        return (systemMsg, lastUserUnit, startIdx)
    }

    /// Compress dropped message units into a thread_summary.
    /// Preserves cumulative history across multiple trim cycles by parsing the
    /// previous thread_summary and merging extracted buckets with new drops.
    /// Also preserves the original (first) user request when many requests exist,
    /// so the active task context is never lost across long sessions.
    static func compressDropped(
        _ droppedUnits: [MessageUnit],
        lastUserUnit: MessageUnit?,
        previousSummary: String,
        droppedMessagesContainFirstRequest: Bool = true
    ) -> OpenAIChatMessage {
        var currentTask = ""
        var userRequests: [String] = []
        var firstUserRequest: String?
        var filesModified: [String] = []
        var commits: [String] = []
        var decisions: [String] = []
        var collaborationExchanges: [(question: String, response: String)] = []
        var toolsUsed: [String: Int] = [:]

        // Seed buckets from previous summary so accumulated history isn't lost
        // across multiple trim cycles.
        if !previousSummary.isEmpty {
            parsePreviousSummary(
                previousSummary,
                commits: &commits,
                filesModified: &filesModified,
                decisions: &decisions,
                toolsUsed: &toolsUsed
            )
        }

        // Track interaction tool_call IDs so we can pair questions with responses.
        var collabToolCalls: [String: String] = [:]

        // Extract info from dropped messages
        for unit in droppedUnits {
            for msg in unit.messages {
                let content = msg.content ?? ""

                if msg.role == "user" {
                    let preview = content.count > 300 ? String(content.prefix(297)) + "..." : content
                    userRequests.append(preview)
                }

                // Track file paths from tool call arguments
                if let toolCalls = msg.toolCalls {
                    for tc in toolCalls {
                        let name = tc.function.name
                        let args = tc.function.arguments
                        toolsUsed[name, default: 0] += 1

                        // Capture interact calls (agent questions) for pairing
                        if name == "interact" {
                            if let question = extractJsonStringValue(args, key: "message"), !question.isEmpty {
                                collabToolCalls[tc.id] = question
                            }
                        }

                        // Capture file paths from tool arguments
                        if name == "file_operations" || name == "apply_patch" {
                            for path in extractJsonStringValues(args, keys: ["path", "new_path", "old_path"]) {
                                if !path.hasPrefix(".") && !filesModified.contains(path) {
                                    filesModified.append(path)
                                }
                            }
                        }

                        // Capture decisions marked with [COLLABORATION]
                        if name == "interact" && content.contains("[COLLABORATION]") {
                            let dec = content
                                .replacingOccurrences(of: "[COLLABORATION]", with: "")
                                .replacingOccurrences(of: "\n", with: " ")
                                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                                .trimmingCharacters(in: .whitespaces)
                            let truncated = dec.count > 250 ? String(dec.prefix(250)) : dec
                            if !truncated.isEmpty {
                                decisions.append(truncated)
                            }
                        }
                    }
                }

                if msg.role == "tool" {
                    // Pair collaboration responses with their questions
                    if let toolCallId = msg.toolCallId, let question = collabToolCalls[toolCallId] {
                        let response = content
                        let q = question.count > 1000 ? String(question.prefix(1000)) + "..." : question
                        let r = response.count > 1000 ? String(response.prefix(1000)) + "..." : response
                        collaborationExchanges.append((question: q, response: r))
                        collabToolCalls.removeValue(forKey: toolCallId)
                    }

                    // Git commit results: [abc1234] Commit subject line
                    let commitRegex = try? NSRegularExpression(
                        pattern: "^\\[([a-f0-9]{7,12})\\]\\s+(.{1,100})",
                        options: [.anchorsMatchLines]
                    )
                    if let regex = commitRegex {
                        let nsContent = content as NSString
                        let matches = regex.matches(
                            in: content,
                            range: NSRange(location: 0, length: nsContent.length)
                        )
                        for match in matches where match.numberOfRanges >= 3 {
                            let hash = nsContent.substring(with: match.range(at: 1))
                            let subject = nsContent.substring(with: match.range(at: 2))
                            commits.append("\(hash): \(subject)")
                        }
                    }

                    // git log --oneline output
                    let logRegex = try? NSRegularExpression(
                        pattern: "^([a-f0-9]{7,12})\\s+(.{1,100})",
                        options: [.anchorsMatchLines]
                    )
                    if let regex = logRegex {
                        let nsContent = content as NSString
                        let matches = regex.matches(
                            in: content,
                            range: NSRange(location: 0, length: nsContent.length)
                        )
                        for match in matches where match.numberOfRanges >= 3 {
                            let hash = nsContent.substring(with: match.range(at: 1))
                            let subject = nsContent.substring(with: match.range(at: 2))
                            let entry = "\(hash): \(subject)"
                            if !commits.contains(entry) {
                                commits.append(entry)
                            }
                        }
                    }
                }

                // Track file references from content (fallback when no tool_call info)
                for ref in extractFileRefs(from: content) where !filesModified.contains(ref) {
                    filesModified.append(ref)
                }
            }
        }

        // Deduplicate and limit files
        if filesModified.count > 30 {
            filesModified = Array(filesModified.prefix(30))
        }

        // Deduplicate commits while preserving order
        var seenCommits = Set<String>()
        commits = commits.filter { seenCommits.insert($0).inserted }
        if commits.count > 15 {
            commits = Array(commits.prefix(15))
        }

        // Keep last 3 decisions
        if decisions.count > 3 {
            decisions = Array(decisions.suffix(3))
        }

        // Keep last 5 collaboration exchanges
        if collaborationExchanges.count > 5 {
            collaborationExchanges = Array(collaborationExchanges.suffix(5))
        }

        // Always preserve the FIRST user request (the original session task).
        // When trimming to last N, we risk losing the original task context
        // that started the session. Keep it separately if we have many requests.
        if userRequests.count > 8 {
            firstUserRequest = userRequests.first
            userRequests = Array(userRequests.suffix(7))
        }

        // Find a substantive task description (>= 50 chars). Short confirmations
        // like "yes" or "go ahead" are useless as task context - scan user_requests
        // and the last user message for a better candidate.
        let lastUserContent = lastUserUnit?.messages.first(where: { $0.role == "user" })?.content ?? ""
        var allRequests: [String] = []
        if let first = firstUserRequest { allRequests.append(first) }
        allRequests.append(contentsOf: userRequests)
        currentTask = findSubstantiveTask(candidate: lastUserContent, messages: allRequests)

        // Build the structured thread_summary
        var parts: [String] = []
        parts.append("<thread_summary>")
        parts.append("")

        if !currentTask.isEmpty {
            let taskPreview = currentTask.count > 300 ? String(currentTask.prefix(300)) : currentTask
            parts.append("Current task: \(taskPreview)")
            parts.append("")
        }

        // Collaboration exchanges go FIRST - they represent active design discussions
        if !collaborationExchanges.isEmpty {
            parts.append("Active discussion (agent-user collaboration exchanges):")
            for (i, ex) in collaborationExchanges.enumerated() {
                parts.append("  Agent asked: \(ex.question)")
                parts.append("  User replied: \(ex.response)")
                if i < collaborationExchanges.count - 1 {
                    parts.append("")
                }
            }
            parts.append("")
        }

        if !userRequests.isEmpty || firstUserRequest != nil {
            parts.append("Recent user requests:")
            if let first = firstUserRequest, !userRequests.contains(first) {
                parts.append("- [original] \(first)")
            }
            for req in userRequests {
                parts.append("- \(req)")
            }
            parts.append("")
        }

        if !commits.isEmpty {
            parts.append("Git commits made during compressed period:")
            for c in commits {
                parts.append("- \(c)")
            }
            parts.append("")
        }

        if !filesModified.isEmpty {
            parts.append("Files created/modified:")
            for f in filesModified {
                parts.append("- \(f)")
            }
            parts.append("")
        }

        if !decisions.isEmpty {
            parts.append("Key decisions:")
            for d in decisions {
                parts.append("- \(d)")
            }
            parts.append("")
        }

        if !toolsUsed.isEmpty {
            parts.append("Tool usage:")
            for (tool, count) in toolsUsed.sorted(by: { $0.value > $1.value }) {
                parts.append("- \(tool): \(count) calls")
            }
            parts.append("")
        }

        parts.append("</thread_summary>")

        return OpenAIChatMessage(role: "system", content: parts.joined(separator: "\n"))
    }

    /// Parse structured sections from a previous thread_summary to seed extraction
    /// buckets. This preserves accumulated history across multiple trim cycles.
    static func parsePreviousSummary(
        _ summaryText: String,
        commits: inout [String],
        filesModified: inout [String],
        decisions: inout [String],
        toolsUsed: inout [String: Int]
    ) {
        let cleaned = summaryText
            .replacingOccurrences(of: "<thread_summary>", with: "")
            .replacingOccurrences(of: "</thread_summary>", with: "")

        // Parse each section by header (must match exact headers used in compressDropped)
        if let commitsBlock = extractSection(text: cleaned, header: "Git commits made during compressed period") {
            for line in commitsBlock.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    commits.append(String(trimmed.dropFirst(2)))
                }
            }
        }

        if let filesBlock = extractSection(text: cleaned, header: "Files created/modified") {
            for line in filesBlock.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    filesModified.append(String(trimmed.dropFirst(2)))
                }
            }
        }

        if let decisionsBlock = extractSection(text: cleaned, header: "Key decisions") {
            for line in decisionsBlock.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    decisions.append(String(trimmed.dropFirst(2)))
                }
            }
        }

        if let toolsBlock = extractSection(text: cleaned, header: "Tool usage") {
            for line in toolsBlock.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    let payload = String(trimmed.dropFirst(2))
                    if let colonIdx = payload.lastIndex(of: ":") {
                        let name = String(payload[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                        let countStr = String(payload[payload.index(after: colonIdx)...])
                            .replacingOccurrences(of: "calls", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        if let count = Int(countStr) {
                            toolsUsed[name, default: 0] += count
                        }
                    }
                }
            }
        }
    }

    /// Extract the content of a named section from a thread_summary.
    /// Sections are delimited by a header line ending in ":" and a blank line.
    static func extractSection(text: String, header: String) -> String? {
        guard let headerRange = text.range(of: header + ":") else { return nil }
        let afterHeader = String(text[headerRange.upperBound...])
        let lines = afterHeader.components(separatedBy: "\n")
        var collected: [String] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            collected.append(line)
        }
        return collected.isEmpty ? nil : collected.joined(separator: "\n")
    }

    /// Find a substantive task description (>= 50 chars). Falls back to the
    /// candidate if no better option is found in the message history.
    static func findSubstantiveTask(candidate: String, messages: [String]) -> String {
        let minLength = 50

        if candidate.count >= minLength {
            return candidate
        }

        // Scan messages newest-first for a substantive user message
        for msg in messages.reversed() where msg.count >= minLength {
            return msg
        }

        return candidate
    }

    /// Extract a single string value for a given key from a JSON string.
    /// Lightweight regex-based extractor (no full JSON parsing for performance).
    static func extractJsonStringValue(_ json: String, key: String) -> String? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return nil }
        let nsJson = json as NSString
        let matches = regex.matches(in: json, range: NSRange(location: 0, length: nsJson.length))
        guard let match = matches.first, match.numberOfRanges >= 2 else { return nil }
        let raw = nsJson.substring(with: match.range(at: 1))
        return raw
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Extract all string values for any of the given keys from a JSON string.
    static func extractJsonStringValues(_ json: String, keys: [String]) -> [String] {
        var results: [String] = []
        for key in keys {
            let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\"([^\"]+)\""
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsJson = json as NSString
            let matches = regex.matches(in: json, range: NSRange(location: 0, length: nsJson.length))
            for match in matches where match.numberOfRanges >= 2 {
                let value = nsJson.substring(with: match.range(at: 1))
                if !value.isEmpty {
                    results.append(value)
                }
            }
        }
        return results
    }

    /// Extract file paths from content strings.
    private static func extractFileRefs(from content: String) -> [String] {
        var files: [String] = []

        let patterns = [
            "(?:Sources|Tests|lib|src)/[\\w/.-]+\\.(?:swift|pm|py|ts|js|json|yaml|yml|md|txt)",
            "\\./[\\w/.-]+\\.(?:swift|pm|py|ts|js|json|yaml|yml)"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(content.startIndex..., in: content)
                let matches = regex.matches(in: content, range: range)
                for match in matches {
                    if let matchRange = Range(match.range, in: content) {
                        files.append(String(content[matchRange]))
                    }
                }
            }
        }

        return files
    }
}
