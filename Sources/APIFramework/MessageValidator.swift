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

        // Find existing thread_summary
        var existingSummaryMsg: OpenAIChatMessage?
        var summaryTokens = 0
        for unit in units {
            for msg in unit.messages {
                if msg.role == "system" && (msg.content?.contains("<thread_summary>") ?? false) {
                    existingSummaryMsg = msg
                    summaryTokens = estimateTokens([msg])
                    break
                }
            }
            if existingSummaryMsg != nil { break }
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
            summaryToUse = compressDropped(droppedUnits, lastUserUnit: lastUserUnit, previousSummary: previousSummary)
        } else if let existing = existingSummaryMsg {
            summaryToUse = existing
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

        // Find orphaned tool_results (no matching call)
        var orphanedResultIndices = Set<Int>()
        for (trId, idx) in trIdToResultIdx {
            if tcIdToAssistantIdx[trId] == nil {
                orphanedResultIndices.insert(idx)
            }
        }

        // Build validated array
        var validated: [OpenAIChatMessage] = []
        for (i, msg) in messages.enumerated() {
            // Skip orphaned tool results
            if orphanedResultIndices.contains(i) {
                logger.debug("Removing orphaned tool_result at index \(i)")
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
    private static func compressDropped(
        _ droppedUnits: [MessageUnit],
        lastUserUnit: MessageUnit?,
        previousSummary: String
    ) -> OpenAIChatMessage {
        var taskSummary = ""
        var recentRequests: [String] = []
        var filesModified = Set<String>()
        var toolsUsed: [String: Int] = [:]

        // Extract info from dropped messages
        for unit in droppedUnits {
            for msg in unit.messages {
                let content = msg.content ?? ""

                if msg.role == "user" {
                    let preview = content.count > 150 ? String(content.prefix(147)) + "..." : content
                    recentRequests.append(preview)
                }

                // Track file operations from content
                extractFileRefs(from: content).forEach { filesModified.insert($0) }

                // Track tool usage
                if let toolCalls = msg.toolCalls {
                    for tc in toolCalls {
                        toolsUsed[tc.function.name, default: 0] += 1
                    }
                }
            }
        }

        // Extract current task from most recent user message
        if let lastUser = lastUserUnit?.messages.first(where: { $0.role == "user" }) {
            taskSummary = lastUser.content ?? ""
            if taskSummary.count > 300 {
                taskSummary = String(taskSummary.prefix(297)) + "..."
            }
        }

        // Build thread_summary
        var summary = "<thread_summary>\n"

        if !taskSummary.isEmpty {
            summary += "\nCurrent task: \(taskSummary)\n"
        }

        if !recentRequests.isEmpty {
            let recent = recentRequests.suffix(3)
            summary += "\nRecent user requests:\n"
            for req in recent {
                summary += "- \(req)\n"
            }
        }

        if !filesModified.isEmpty {
            let files = Array(filesModified).sorted().prefix(20)
            summary += "\nFiles created/modified:\n"
            for file in files {
                summary += "- \(file)\n"
            }
        }

        if !toolsUsed.isEmpty {
            summary += "\nTool usage:\n"
            for (tool, count) in toolsUsed.sorted(by: { $0.key < $1.key }) {
                summary += "- \(tool): \(count) calls\n"
            }
        }

        summary += "\n</thread_summary>"

        return OpenAIChatMessage(role: "system", content: summary)
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
