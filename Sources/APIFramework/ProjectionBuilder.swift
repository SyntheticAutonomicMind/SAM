// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import Crypto

/// Turn-based projection layer for context management.
/// Ported from CLIO's ContextBuilder.pm: splits conversation history into
/// turns, selects the most recent N turns (scaled by session length), compresses
/// older turns into a thread_summary, and collapses repeated cross-turn tool
/// calls. This is the "anchor + recent-N + compressed tail" structure that
/// SAM was missing before the YaRM alignment audit.
///
/// Unlike CLIO (which injects the compressed tail as prose in the dynamic
/// userContext), SAM produces a thread_summary system message — consistent
/// with MessageValidator's existing CSSS design.
public struct ProjectionBuilder {
    private static let logger = Logger(label: "com.sam.ProjectionBuilder")

    /// Scaling bands for the recent-turn window: [max_total_turns, recent_count].
    /// Short sessions get a small cache-stable prefix (min 3 floor); very long
    /// sessions get wider trajectory recall. Ported from CLIO's
    /// $RECENT_SCALING_BANDS.
    /// - short (0-30):   3 recent
    /// - medium (31-100): 5 recent
    /// - long (101-300):  8 recent
    /// - very long (301+): 10 recent (hard cap)
    public static let recentScalingBands: [(maxTurns: Int, recentCount: Int)] = [
        (30,  3),
        (100, 5),
        (300, 8),
        (Int.max, 10)
    ]

    /// Minimum recent turns to always keep (floor). Ported from CLIO's
    /// min_recent=3. Short sessions don't get starved of context.
    public static let minRecentTurns: Int = 3

    // MARK: - Turn Splitting

    /// Split messages into turns. A turn starts at a user message and includes
    /// all messages that follow until the next user message (or end of array).
    /// Non-user-leading messages (orphan tool results, etc.) are attached to
    /// the preceding turn or form their own leading group if no user message
    /// has appeared yet.
    ///
    /// Ported from CLIO's `_split_into_turns`.
    public static func splitIntoTurns(_ messages: [OpenAIChatMessage]) -> [[OpenAIChatMessage]] {
        var turns: [[OpenAIChatMessage]] = []
        var currentTurnIdx: Int? = nil

        for msg in messages {
            if msg.role == "user" {
                currentTurnIdx = turns.count
                turns.append([])
            }
            if currentTurnIdx == nil {
                // Messages before the first user message (system, orphan tool
                // results) — group them into a leading turn so they aren't lost.
                if turns.isEmpty {
                    turns.append([])
                    currentTurnIdx = 0
                }
            }
            if let idx = currentTurnIdx {
                turns[idx].append(msg)
            }
        }

        return turns
    }

    // MARK: - Turn Selection

    /// Determine the number of recent turns to keep based on total turn count.
    /// Ported from CLIO's `_recent_count_for_turns`.
    public static func recentCount(for totalTurns: Int) -> Int {
        guard totalTurns > 0 else { return 0 }
        for (maxTurns, recentCount) in recentScalingBands {
            if totalTurns <= maxTurns {
                return max(minRecentTurns, min(recentCount, totalTurns))
            }
        }
        return max(minRecentTurns, min(recentScalingBands.last!.recentCount, totalTurns))
    }

    /// Check if a turn is "pure" (exactly one assistant message with exactly
    /// one tool call, plus exactly one tool result, plus a user message).
    /// Used by the cross-turn dedup logic.
    private static func turnToolPair(_ turn: [OpenAIChatMessage]) -> (assistant: OpenAIChatMessage, tool: OpenAIChatMessage)? {
        guard !turn.isEmpty else { return nil }

        var assistant: OpenAIChatMessage?
        var tool: OpenAIChatMessage?
        var hasUser = false

        for msg in turn {
            switch msg.role {
            case "assistant":
                if assistant != nil { return nil } // more than one -> not pure
                assistant = msg
            case "tool":
                if tool != nil { return nil } // more than one -> not pure
                tool = msg
            case "user":
                hasUser = true
            default:
                return nil // system or other -> not pure
            }
        }

        guard let assistant = assistant, let tool = tool, hasUser else { return nil }
        guard let toolCalls = assistant.toolCalls, toolCalls.count == 1 else { return nil }
        // Allow short conclusion text but not long reasoning.
        guard let content = assistant.content, content.count <= 80 else { return nil }

        return (assistant, tool)
    }

    /// Compute a dedup signature for a pure tool turn: tool name + arguments
    /// + result digest. Tool call ID is intentionally excluded — it's an
    /// opaque identifier assigned per turn. Semantic identity is (name, args, result).
    private static func turnSignature(_ turn: [OpenAIChatMessage]) -> String? {
        guard let pair = turnToolPair(turn) else { return nil }
        let tc = pair.assistant.toolCalls![0]
        let resultContent = pair.tool.content ?? ""
        let resultDigest = resultContent.sha256Prefix(16)
        return "\(tc.function.name)|\(tc.function.arguments)|\(resultDigest)"
    }

    /// Check if a user message is a short continuation prompt.
    /// Ported from CLIO's `_is_continuation_prompt`.
    private static func isContinuationPrompt(_ text: String?) -> Bool {
        guard let text = text, !text.isEmpty, text.count <= 80 else { return false }

        let lowercased = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Common continuation phrases
        let continuationPhrases: [String] = [
            "continue", "continue.", "go on", "go on.", "ok", "ok.",
            "okay", "okay.", "proceed", "proceed.",
            "keep going", "keep going.", "yes", "yes.", "y", "y.",
            "please continue", "please continue.",
            "again", "again.", "same as before", "same as before."
        ]

        for phrase in continuationPhrases where lowercased == phrase {
            return true
        }

        // Short non-question, non-interrogative sentence
        if lowercased.hasSuffix("?") { return false }
        let interrogatives = ["why", "how", "what", "when", "where", "which", "who",
                              "can", "could", "would", "should", "will",
                              "do", "does", "did", "is", "are", "was", "were"]
        for word in lowercased.components(separatedBy: .whitespaces) {
            if interrogatives.contains(word) { return false }
        }
        return lowercased.count < 30
    }

    /// Collapse repeated tool calls across adjacent turns.
    /// Ported from CLIO's `collapse_repeated_tool_calls_across_turns`.
    ///
    /// For each pair of adjacent turns, checks the strict conditions:
    /// 1. Both turns are pure tool turns (one assistant + one tool call + one result + one user)
    /// 2. Tool calls have identical name, arguments, and result digest
    /// 3. Second turn's user message is a short continuation prompt
    ///
    /// If all hold, the second turn is dropped (already represented by the first).
    /// Returns the filtered turns array.
    public static func collapseRepeatedToolCalls(_ turns: [[OpenAIChatMessage]]) -> [[OpenAIChatMessage]] {
        guard turns.count > 1 else { return turns }

        var result: [[OpenAIChatMessage]] = []

        for i in 0..<turns.count {
            let turn = turns[i]

            if i > 0 && !result.isEmpty {
                let prevTurn = result[result.count - 1]
                if let prevSig = turnSignature(prevTurn),
                   let currSig = turnSignature(turn),
                   prevSig == currSig {
                    // Check continuation prompt condition
                    let userMsg = turn.first { $0.role == "user" }
                    if isContinuationPrompt(userMsg?.content) {
                        // Drop the duplicate turn — it's already represented by the previous one.
                        logger.debug("Projection: collapsed repeated tool call turn (sig: \(currSig.prefix(40)))")
                        continue
                    }
                }
            }

            result.append(turn)
        }

        return result
    }

    // MARK: - Turn Selection + Compression

    /// Select recent turns and dropped turns from a list of turns.
    /// Ported from CLIO's `_select_turns`:
    /// - Drops the current (incomplete) turn if it only has a user message
    /// - Preserves turns with tool_calls in the recent window
    /// - Selects the last N recent turns
    public static func selectTurns(_ turns: inout [[OpenAIChatMessage]]) -> (recent: [[OpenAIChatMessage]], dropped: [[OpenAIChatMessage]]) {
        guard !turns.isEmpty else { return ([], []) }

        var work = turns

        // Drop the current (incomplete) turn if it only contains user messages
        // (no assistant/tool responses yet).
        let lastTurn = work[work.count - 1]
        let hasAssistantOrTool = lastTurn.contains { $0.role == "assistant" || $0.role == "tool" }
        if !hasAssistantOrTool {
            let incompleteTurn = work.removeLast()
            // The current user message is delivered separately — don't compress it.
            // (It will be the last user message in the final message array.)
            work.append(incompleteTurn) // put it back at the end — caller will handle
            // Actually, we need to return the incomplete turn separately so the
            // caller can add it to the end as the "current user message".
            // But for SAM's architecture, the current user message is already
            // in the messages array passed to validateAndArchiveContext.
            // We just skip it for projection purposes.
            _ = work.removeLast() // discard — it's the current user input
        }

        // Recalculate total after potential drop
        let totalTurns = work.count
        guard totalTurns > 0 else { return ([], []) }

        let recentTarget = recentCount(for: totalTurns)
        var recentCount = min(recentTarget, totalTurns)

        // Tool-turn preservation: if the most recent turn(s) contain
        // assistant messages with tool_calls, always include them.
        var forceInclude = 0
        for offset in 0..<min(2, totalTurns) {
            let idx = totalTurns - 1 - offset
            let turn = work[idx]
            for msg in turn where msg.role == "assistant" {
                if msg.toolCalls != nil && !(msg.toolCalls?.isEmpty ?? true) {
                    forceInclude = offset + 1
                    break
                }
            }
            if forceInclude > 0 { break }
        }
        if forceInclude > 0, recentCount < forceInclude {
            recentCount = forceInclude
            logger.debug("Projection: tool-turn preservation — extending recent window to \(forceInclude)")
        }

        let startIndex = totalTurns - recentCount
        let recent = Array(work[startIndex..<totalTurns])
        let dropped = Array(work[0..<startIndex])

        return (recent, dropped)
    }

    // MARK: - Public API

    /// Result of a projection operation.
    public struct ProjectionResult {
        /// The projected message array: system messages + recent turns.
        public let messages: [OpenAIChatMessage]
        /// A thread_summary system message from compressed dropped turns (if any).
        public let compressedSummary: OpenAIChatMessage?
        /// Estimated token count of the projected messages.
        public let tokenEstimate: Int

        public init(messages: [OpenAIChatMessage], compressedSummary: OpenAIChatMessage?, tokenEstimate: Int) {
            self.messages = messages
            self.compressedSummary = compressedSummary
            self.tokenEstimate = tokenEstimate
        }
    }

    /// Project a full conversation message array into a cache-stable structure:
    /// - Leading system messages (always preserved at front for LCP cache stability)
    /// - A thread_summary from compressed older turns (at end, for cache stability)
    /// - Recent N turns of dialog (cache-stable prefix)
    ///
    /// The compressed tail uses MessageValidator.compressDropped, so it carries
    /// the same structured thread_summary format (Current task, Discussion, user
    /// requests, commits, files, decisions, tool usage) that parsePreviousSummary
    /// can round-trip.
    ///
    /// Ported from CLIO's `build_projection` + `_build_compressed_tail`.
    public static func project(
        messages: [OpenAIChatMessage],
        caps: ContextCapabilities,
        tokenRatio: Double
    ) -> ProjectionResult {
        guard messages.count > 4 else {
            // Too few messages to benefit from projection — return as-is.
            let tokens = MessageValidator.estimateTokens(messages, tokenRatio: tokenRatio)
            return ProjectionResult(messages: messages, compressedSummary: nil, tokenEstimate: tokens)
        }

        // Separate leading system messages from the rest.
        // System messages stay at the front for LCP cache stability.
        var systemMessages: [OpenAIChatMessage] = []
        var restStartIdx = 0
        while restStartIdx < messages.count, messages[restStartIdx].role == "system" {
            systemMessages.append(messages[restStartIdx])
            restStartIdx += 1
        }

        guard restStartIdx < messages.count else {
            // Only system messages — nothing to project.
            let tokens = MessageValidator.estimateTokens(messages, tokenRatio: tokenRatio)
            return ProjectionResult(messages: messages, compressedSummary: nil, tokenEstimate: tokens)
        }

        let conversationMessages = Array(messages[restStartIdx...])

        // Split into turns.
        var turns = splitIntoTurns(conversationMessages)
        guard turns.count > 0 else {
            let tokens = MessageValidator.estimateTokens(messages, tokenRatio: tokenRatio)
            return ProjectionResult(messages: messages, compressedSummary: nil, tokenEstimate: tokens)
        }

        // Select recent vs. dropped turns.
        var droppedTurnMessages: [OpenAIChatMessage] = []
        let (recentTurns, droppedTurns) = selectTurns(&turns)

        for turn in droppedTurns {
            droppedTurnMessages.append(contentsOf: turn)
        }

        // Cross-turn dedup on the recent + anchor turns.
        let dedupedRecent = collapseRepeatedToolCalls(recentTurns)

        // Build projected message array: system + recent turns (flattened)
        var projected: [OpenAIChatMessage] = systemMessages
        for turn in dedupedRecent {
            projected.append(contentsOf: turn)
        }

        // Compress dropped turns into a thread_summary.
        var compressedSummary: OpenAIChatMessage? = nil
        if !droppedTurnMessages.isEmpty {
            // Group dropped messages into units for compressDropped.
            let droppedUnits = groupDroppedForCompression(droppedTurnMessages)
            compressedSummary = MessageValidator.compressDropped(
                droppedUnits,
                lastUserUnit: nil,
                previousSummary: systemMessages.compactMap { $0.content }.joined(separator: "\n"),
                droppedMessagesContainFirstRequest: true
            )
        }

        let tokenEstimate = MessageValidator.estimateTokens(projected, tokenRatio: tokenRatio)

        logger.debug("Projection: \(messages.count) messages -> \(projected.count) projected + \(droppedTurnMessages.count) dropped (\(turns.count) turns, recent: \(dedupedRecent.count))")

        return ProjectionResult(
            messages: projected,
            compressedSummary: compressedSummary,
            tokenEstimate: tokenEstimate
        )
    }

    /// Group dropped messages into MessageUnit arrays for compressDropped.
    /// Preserves assistant+tool pairings.
    private static func groupDroppedForCompression(_ messages: [OpenAIChatMessage]) -> [MessageValidator.MessageUnit] {
        // Reuse MessageValidator's grouping logic by splitting into units.
        // We need to wrap messages that have tool_calls + following tool results.
        var units: [MessageValidator.MessageUnit] = []
        var i = 0

        while i < messages.count {
            let msg = messages[i]

            if msg.role == "assistant",
               let toolCalls = msg.toolCalls,
               !toolCalls.isEmpty {
                var group: [OpenAIChatMessage] = [msg]
                var j = i + 1
                while j < messages.count && messages[j].role == "tool" {
                    // Check if this tool result belongs to one of our tool calls
                    let toolMsg = messages[j]
                    if let tcId = toolMsg.toolCallId, toolCalls.contains(where: { $0.id == tcId }) {
                        group.append(toolMsg)
                    } else {
                        break
                    }
                    j += 1
                }
                units.append(MessageValidator.MessageUnit(
                    messages: group,
                    tokens: MessageValidator.estimateTokens(group),
                    toolCallIds: Set(toolCalls.map { $0.id }),
                    isOrphanToolResult: false,
                    orphanToolId: nil
                ))
                i = j
            } else if msg.role == "tool" {
                // Orphan tool result
                units.append(MessageValidator.MessageUnit(
                    messages: [msg],
                    tokens: MessageValidator.estimateTokens([msg]),
                    toolCallIds: Set<String>(),
                    isOrphanToolResult: true,
                    orphanToolId: msg.toolCallId
                ))
                i += 1
            } else {
                // Regular message
                units.append(MessageValidator.MessageUnit(
                    messages: [msg],
                    tokens: MessageValidator.estimateTokens([msg]),
                    toolCallIds: Set<String>(),
                    isOrphanToolResult: false,
                    orphanToolId: nil
                ))
                i += 1
            }
        }

        return units
    }
}

// MARK: - String SHA-256 Helper

private extension String {
    /// Compute the SHA-256 hash of this string and return the first `prefixLength` hex chars.
    func sha256Prefix(_ prefixLength: Int) -> String {
        guard let data = self.data(using: .utf8) else { return "" }
        let digest = SHA256.hash(data: data)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(prefixLength))
    }
}
