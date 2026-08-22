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
/// - Deinterleaves tool_results to END, drops oldest first
/// - Places thread_summary at END of output (not after system) for LCP cache stability
/// - Preserves ALL leading system messages (not just first) for cache stability
/// - Uses compute_prompt_budget (context_window - output_reserve - estimation_buffer)
///   with tool-calling output reserve optimization (caps at 8K when tools active)
/// - Uses learned char/token ratio from API feedback (DriftTracker)
/// - Supports drift-aware trim threshold (tightens proactive trim when heuristic drifts)
/// - CSSS (Cache-Stable Summary Slot) with min/max bounds + proactive growth
public struct MessageValidator {
    private static let logger = Logger(label: "com.sam.MessageValidator")

    // MARK: - Message Unit Grouping

    /// A logical unit of messages that should stay together.
    /// An assistant message with tool_calls + all corresponding tool results form one unit.
    public struct MessageUnit {
        public var messages: [OpenAIChatMessage]
        public var tokens: Int
        public var toolCallIds: Set<String>
        public var isOrphanToolResult: Bool
        public var orphanToolId: String?

        public init(
            messages: [OpenAIChatMessage] = [],
            tokens: Int = 0,
            toolCallIds: Set<String> = [],
            isOrphanToolResult: Bool = false,
            orphanToolId: String? = nil
        ) {
            self.messages = messages
            self.tokens = tokens
            self.toolCallIds = toolCallIds
            self.isOrphanToolResult = isOrphanToolResult
            self.orphanToolId = orphanToolId
        }
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
    ///
    /// Uses the new TrimConfig-based API with:
    /// - compute_prompt_budget (context_window - output_reserve - estimation_buffer)
    /// - Tool-calling output reserve optimization (caps at 8K when tools active)
    /// - Learned char/token ratio (DriftTracker)
    /// - Drift-aware trim threshold (when drift > threshold)
    /// - CSSS slot management with min/max bounds + proactive growth
    /// - Summary placed at END for LCP cache stability
    /// - Deinterleaved tool_results layout with orphan guard
    public static func validateAndTruncate(
        messages: [OpenAIChatMessage],
        config: TrimConfig
    ) -> [OpenAIChatMessage] {
        return validateAndTruncateWithDropped(messages: messages, config: config).messages
    }

    /// Validate and truncate, returning both kept and dropped messages.
    ///
    /// Ported from CLIO's `validate_and_truncate` with all bug fixes:
    /// - Budget from `compute_prompt_budget` (not 50% of context)
    /// - Summary at END (not position 1 after system)
    /// - Deinterleave tool_results to END with orphan guard
    /// - Preserve ALL leading system messages (context_files, etc.)
    /// - CSSS slot management (min 8K floor, max 12K ceiling, proactive growth)
    /// - Unit-based dropped-message identification (not content fingerprinting)
    public static func validateAndTruncateWithDropped(
        messages: [OpenAIChatMessage],
        config: TrimConfig
    ) -> TruncationResult {
        guard !messages.isEmpty else { return TruncationResult(messages: [], droppedMessages: []) }

        let effectiveBudget = config.effectiveBudget
        let tokenRatio = config.tokenRatio

        let estimatedTokens = estimateTokens(messages, tokenRatio: tokenRatio)

        if estimatedTokens <= effectiveBudget {
            // Within budget - still run deinterleave + summary-at-end (CLIO behavior:
            // structural normalization happens even when no trimming is needed).
            logger.debug("Context: within budget (\(estimatedTokens)/\(effectiveBudget)), normalizing structure only")
            let normalized = validateToolMessagePairs(messages)
            return TruncationResult(messages: normalizeSummaryToEnd(messages: normalized), droppedMessages: [])
        }

        // Need to truncate
        logger.info("Context: messages exceed budget: \(estimatedTokens) > \(effectiveBudget), truncating")

        // Group messages into logical units (atomic: assistant+tool_calls+tool_results)
        let units = groupIntoUnits(messages, tokenRatio: tokenRatio)
        logger.debug("Context: grouped \(messages.count) messages into \(units.count) units")

        // Extract preserved elements (system, last user, summary, leading system msgs)
        let (systemMsgs, lastUserUnit, startIdx, summaryUnit, summaryTokens,
             preservedUserContexts, preservedGeneralSystem) = extractPreservedUnits(units, tokenRatio: tokenRatio)

        let systemTokens = estimateTokens(systemMsgs, tokenRatio: tokenRatio)

        // CSSS (Cache-Stable Summary Slot) slot target.
        // If an existing summary exists, use its token count as the slot target
        // (clamped to [min, max]). Proactive growth when dropped content > 1.5x slot.
        // First trim: use MIN_CSSS_SLOT_TOKENS as floor so the summary isn't
        // naturally tiny and starving subsequent trims.
        var summarySlotTarget: Int = 0
        if let summary = summaryUnit {
            let currentSlot = summary.tokens
            summarySlotTarget = max(currentSlot, ContextBudget.minCSSSlotTokens)
            logger.debug("Context: CSSS base slot target \(summarySlotTarget) (current: \(currentSlot), min: \(ContextBudget.minCSSSlotTokens))")
        } else if startIdx < units.count {
            summarySlotTarget = ContextBudget.minCSSSlotTokens
            logger.debug("Context: CSSS first-trim slot target \(summarySlotTarget)")
        }

        // Budget walk: newest to oldest.
        // Deinterleave: dialog at front (LCP-critical), tool_results deferred to END.
        var conversation: [OpenAIChatMessage] = []
        var deferredToolResults: [OpenAIChatMessage] = []
        var currentTokens = systemTokens + summaryTokens
        var includedToolIds = Set<String>()
        var droppedUnitStartIndices: Set<Int> = []  // Unit indices that were dropped

        let remaining = Array(units[startIdx..<units.count])

        for (idx, unit) in remaining.reversed().enumerated() {
            let unitIdx = startIdx + (units.count - 1 - idx)

            if unit.isOrphanToolResult {
                continue
            }

            // Deinterleave: separate dialog (assistant/user) from tool_results within the unit.
            // Dialog stays at front; tool_results are deferred to END.
            let (unitDialog, unitToolResults, unitDialogTokens) = deinterleaveUnit(unit, tokenRatio: tokenRatio)

            // Always keep dialog if budget allows. Tool_results deferred to second pass.
            if !unitDialog.isEmpty && currentTokens + unitDialogTokens <= effectiveBudget {
                conversation.insert(contentsOf: unitDialog, at: 0)
                currentTokens += unitDialogTokens
                includedToolIds.formUnion(unit.toolCallIds)
            } else if !unitDialog.isEmpty {
                // Dialog alone exceeds budget - drop entire unit (rare)
                droppedUnitStartIndices.insert(unitIdx)
            }

            // Defer tool_results without consuming budget
            if !unitToolResults.isEmpty {
                deferredToolResults.insert(contentsOf: unitToolResults, at: 0)
            }
        }

        // Calculate dropped tokens for CSSS proactive growth
        var droppedTokens = 0
        for idx in droppedUnitStartIndices {
            droppedTokens += units[idx].tokens
        }
        for tr in deferredToolResults {
            droppedTokens += estimateTokens([tr], tokenRatio: tokenRatio)
        }

        // CSSS proactive growth: if dropped content > 1.5x slot, grow the slot
        if summarySlotTarget > 0 && droppedTokens > summarySlotTarget * 1 {
            let maxSlot = ContextBudget.maxCSSSlotTokens
            let newSlot = min(Int(Double(summarySlotTarget) * 1.5), maxSlot)
            if newSlot > summarySlotTarget {
                logger.info("Context: CSSS proactive growth \(summarySlotTarget) -> \(newSlot) (dropped: \(droppedTokens) tokens)")
                summarySlotTarget = newSlot
            }
        }

        // Second pass: add deferred tool_results from NEWEST to OLDEST until budget reached.
        // CRITICAL: a tool_result must only be kept if its tool_call is in the kept dialog.
        // The deinterleaved layout can produce orphaned tool_calls when the first-pass
        // dialog walk keeps an older assistant-with-tool_calls but the second pass drops
        // its older tool_result due to budget.
        var keptToolResults: [OpenAIChatMessage] = []
        for tr in deferredToolResults.reversed() {
            guard let toolCallId = tr.toolCallId else { continue }
            guard includedToolIds.contains(toolCallId) else { continue }
            let trTokens = estimateTokens([tr], tokenRatio: tokenRatio)
            if currentTokens + trTokens <= effectiveBudget {
                keptToolResults.insert(tr, at: 0)
                currentTokens += trTokens
            }
        }

        // Build the set of dropped messages for archival (unit-based, not fuzzy matching)
        var droppedMessages: [OpenAIChatMessage] = []
        var keptMessageIds = Set<String>()
        for msg in conversation + keptToolResults {
            let id = messageIdentity(msg)
            keptMessageIds.insert(id)
        }
        for i in startIdx..<units.count {
            let unit = units[i]
            if unit.isOrphanToolResult { continue }
            for msg in unit.messages {
                if !keptMessageIds.contains(messageIdentity(msg)) {
                    // Skip system messages - they go into summary, not dropped
                    // Skip thread_summary (regenerated by CSSS)
                    if msg.role != "system" && !(msg.content?.contains("<thread_summary>") ?? false) {
                        droppedMessages.append(msg)
                    }
                }
            }
        }
        // Add deferred tool results that weren't kept
        for tr in deferredToolResults {
            if !keptMessageIds.contains(messageIdentity(tr)) {
                droppedMessages.append(tr)
            }
        }

        // Strip orphaned tool_calls from conversation (defense in depth for Anthropic)
        let (validated, strippedOrphans) = stripOrphanToolCalls(conversation + keptToolResults, includedToolIds: includedToolIds.union(keptToolResults.compactMap { $0.toolCallId }))

        // Ensure at least one user message exists
        var finalMessages = validated
        let hasUserMsg = finalMessages.contains { $0.role == "user" }
        if !hasUserMsg, let lastUser = lastUserUnit {
            for msg in lastUser.messages where msg.role == "user" {
                if let content = msg.content, !content.isEmpty {
                    finalMessages.insert(msg, at: 0)
                    logger.info("Context: injected preserved user message (budget walk dropped it)")
                    break
                }
            }
        }
        if !finalMessages.contains(where: { $0.role == "user" }) {
            // Extract task from thread_summary as fallback
            if let summaryContent = summaryUnit?.messages.first?.content,
               let taskRange = summaryContent.range(of: "Current task: ") {
                let taskStart = taskRange.upperBound
                let rest = summaryContent[taskStart...]
                let taskEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
                let task = String(rest[taskStart..<taskEnd])
                if !task.isEmpty {
                    finalMessages.insert(OpenAIChatMessage(role: "user", content: task), at: 0)
                    logger.info("Context: injected synthetic user message from thread_summary task")
                }
            }
        }

        // Compress dropped into thread_summary (placed at END)
        var summaryToUse: OpenAIChatMessage?
        if !droppedMessages.isEmpty {
            let previousSummary = summaryUnit?.messages.first?.content ?? ""
            summaryToUse = compressDropped(
                droppedUnitMessages(droppedMessages),
                lastUserUnit: lastUserUnit,
                previousSummary: previousSummary,
                droppedMessagesContainFirstRequest: summaryUnit == nil
            )
        } else if let existing = summaryUnit?.messages.first {
            summaryToUse = existing
            logger.debug("Context: no dropped messages - keeping existing thread_summary")
        }

        // Assemble final output:
        // [all system msgs][user_context anchors][dialog + tool_results][summary at END]
        // user_context anchors go AFTER system msgs but BEFORE dialog, so the dynamic
        // context block (which changes every turn) doesn't participate in the stable
        // prefix that CLIO's LCP cache keys on.
        var truncated: [OpenAIChatMessage] = []
        truncated.append(contentsOf: systemMsgs)
        // Re-inject user_context anchors that were extracted from leading position.
        // These contain dynamicContext/sessionGoals that change per turn.
        for unit in preservedUserContexts {
            for msg in unit.messages where msg.role == "system" {
                truncated.append(msg)
            }
        }
        // preservedGeneralSystem is already captured in systemMessages (above); no
        // double-injection needed.
        _ = preservedGeneralSystem
        truncated.append(contentsOf: finalMessages)
        if let summary = summaryToUse {
            truncated.append(summary)
        }

        let finalTokens = estimateTokens(truncated, tokenRatio: tokenRatio)
        logger.info("Context: trimmed \(messages.count) -> \(truncated.count) messages, \(finalTokens) tokens (budget: \(effectiveBudget))")

        return TruncationResult(messages: truncated, droppedMessages: droppedMessages)
    }

    // MARK: - Structural Normalization (CLIO: deinterleave + summary-at-end)

    /// Normalize message structure: move any existing `<thread_summary>` system
    /// message to the END, and deinterleave tool results after regular dialog.
    /// Runs even when no trimming occurs (CLIO always normalizes structure).
    public static func normalizeSummaryToEnd(messages: [OpenAIChatMessage]) -> [OpenAIChatMessage] {
        var summaryMsg: OpenAIChatMessage?
        var dialog: [OpenAIChatMessage] = []
        var toolResults: [OpenAIChatMessage] = []

        for msg in messages {
            if msg.role == "system", let content = msg.content, content.contains("<thread_summary>") {
                summaryMsg = msg
            } else if msg.role == "tool" {
                toolResults.append(msg)
            } else {
                dialog.append(msg)
            }
        }

        // Rebuild: dialog first, then tool results, then summary at END
        var result = dialog + toolResults
        if let summary = summaryMsg {
            result.append(summary)
        }
        return result
    }

    // MARK: - Backward-Compatible API

    /// Legacy API preserved for call sites that haven't been migrated to TrimConfig.
    /// Delegates to the new TrimConfig-based path with a default ContextCapabilities
    /// built from maxPromptTokens.
    public static func validateAndTruncate(
        messages: [OpenAIChatMessage],
        maxPromptTokens: Int,
        toolTokens: Int = 0
    ) -> [OpenAIChatMessage] {
        validateAndTruncateWithDropped(messages: messages, maxPromptTokens: maxPromptTokens, toolTokens: toolTokens).messages
    }

    /// Legacy wrapper preserved for call sites that haven't been migrated.
    public static func validateAndTruncateWithDropped(
        messages: [OpenAIChatMessage],
        maxPromptTokens: Int,
        toolTokens: Int = 0
    ) -> TruncationResult {
        let caps = ContextCapabilities(contextWindow: maxPromptTokens)
        let config = TrimConfig(caps: caps, toolTokens: toolTokens)
        return validateAndTruncateWithDropped(messages: messages, config: config)
    }

    // MARK: - Message Identity (for dropped-message tracking)

    /// Stable identity for a message, used to identify which messages were dropped
    /// without fuzzy content fingerprinting. Uses toolCallId when available,
    /// otherwise a combination of role + id + content hash.
    private static func messageIdentity(_ msg: OpenAIChatMessage) -> String {
        if let toolCallId = msg.toolCallId {
            return "tool:\(toolCallId)"
        }
        let contentSig = msg.content?.prefix(100).hashValue ?? 0
        let idSig = msg.id?.hashValue ?? 0
        return "\(msg.role):\(idSig):\(contentSig)"
    }

    // MARK: - Deinterleave

    /// Split a message unit into dialog messages (assistant/user) and tool_result messages.
    /// Tool calls (from assistant messages) are classified as dialog (they travel with
    /// the assistant message in the prompt).
    private static func deinterleaveUnit(_ unit: MessageUnit, tokenRatio: Double) -> (
        dialog: [OpenAIChatMessage],
        toolResults: [OpenAIChatMessage],
        dialogTokens: Int
    ) {
        var dialog: [OpenAIChatMessage] = []
        var toolResults: [OpenAIChatMessage] = []
        var dialogTokens = 0

        for msg in unit.messages {
            let isToolResult = msg.toolCallId != nil || msg.role == "tool"
            if isToolResult {
                toolResults.append(msg)
            } else {
                dialog.append(msg)
                dialogTokens += estimateTokens([msg], tokenRatio: tokenRatio)
                // Include tool_call JSON tokens
                if let toolCalls = msg.toolCalls {
                    for tc in toolCalls {
                        let tcJson = "\(tc.function.name)\(tc.function.arguments)"
                        dialogTokens += max(1, Int(Double(tcJson.count) / tokenRatio))
                        dialogTokens += ContextBudget.toolCallOverhead
                    }
                }
            }
        }

        return (dialog, toolResults, dialogTokens)
    }

    // MARK: - Orphan Tool Call Stripping

    /// Strip orphaned tool_calls from assistant messages and drop orphaned tool_results.
    /// `retainedToolResultIds` = set of tool_call_ids that have matching results in the output.
    private static func stripOrphanToolCalls(
        _ messages: [OpenAIChatMessage],
        includedToolIds: Set<String>
    ) -> ([OpenAIChatMessage], Int) {
        // Build set of tool_call_ids that ARE present as tool results
        let presentResultIds = Set(messages.compactMap { msg in
            msg.role == "tool" ? msg.toolCallId : nil
        })

        var validated: [OpenAIChatMessage] = []
        var strippedCount = 0

        for msg in messages {
            // Drop orphaned tool_results (no matching tool_call in kept dialog)
            if msg.role == "tool", let toolCallId = msg.toolCallId {
                if !includedToolIds.contains(toolCallId) {
                    logger.debug("Context: dropping orphaned tool_result: \(toolCallId)")
                    continue
                }
            }

            // Strip orphan tool_calls from assistant messages
            if msg.role == "assistant", let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                let matched = toolCalls.filter { presentResultIds.contains($0.id) }
                let orphan = toolCalls.filter { !presentResultIds.contains($0.id) }
                if !orphan.isEmpty {
                    strippedCount += orphan.count
                    logger.debug("Context: stripped \(orphan.count) orphaned tool_calls from assistant")
                    if matched.isEmpty {
                        // All tool_calls were orphan - keep as plain text
                        validated.append(OpenAIChatMessage(
                            id: msg.id, role: msg.role, content: msg.content,
                            toolCalls: nil, toolCallId: msg.toolCallId
                        ))
                    } else {
                        validated.append(OpenAIChatMessage(
                            id: msg.id, role: msg.role, content: msg.content,
                            toolCalls: matched, toolCallId: msg.toolCallId
                        ))
                    }
                    continue
                }
            }

            validated.append(msg)
        }

        return (validated, strippedCount)
    }

    // MARK: - Token Estimation (with learned ratio)

    /// Estimate token count for a message array using learned char/token ratio.
    public static func estimateTokens(_ messages: [OpenAIChatMessage], tokenRatio: Double? = nil) -> Int {
        let ratio = tokenRatio ?? DriftTracker.shared.learnedRatio
        var total = 0
        for msg in messages {
            total += 4 // per-message overhead
            if let content = msg.content {
                total += max(1, Int(Double(content.count) / ratio))
            }
            if let toolCalls = msg.toolCalls {
                for tc in toolCalls {
                    let tcText = tc.function.name + tc.function.arguments
                    total += max(1, Int(Double(tcText.count) / ratio))
                    total += ContextBudget.toolCallOverhead
                }
            }
        }
        return total
    }

    /// Estimate tokens for text only (used in budget walk for individual messages).
    private static func estimateTokens(_ text: String, tokenRatio: Double? = nil) -> Int {
        let ratio = tokenRatio ?? DriftTracker.shared.learnedRatio
        return text.isEmpty ? 0 : max(1, Int(Double(text.count) / ratio))
    }

    // MARK: - Group into Units

    /// Group messages into logical units that should stay together.
    /// An assistant message with tool_calls groups with subsequent tool results.
    public static func groupIntoUnits(_ messages: [OpenAIChatMessage], tokenRatio: Double? = nil) -> [MessageUnit] {
        var units: [MessageUnit] = []
        var i = 0

        while i < messages.count {
            let msg = messages[i]

            if msg.role == "assistant" && msg.toolCalls != nil && !(msg.toolCalls?.isEmpty ?? true) {
                // Assistant with tool_calls - group with following tool results
                var unit = MessageUnit(messages: [msg], tokens: 0, toolCallIds: Set<String>(),
                                       isOrphanToolResult: false, orphanToolId: nil)
                if let toolCalls = msg.toolCalls {
                    for tc in toolCalls {
                        unit.toolCallIds.insert(tc.id)
                    }
                }
                var j = i + 1
                while j < messages.count && messages[j].role == "tool" {
                    let toolMsg = messages[j]
                    unit.messages.append(toolMsg)
                    if let tcId = toolMsg.toolCallId {
                        unit.toolCallIds.insert(tcId)
                    }
                    j += 1
                }
                unit.tokens = estimateTokens(unit.messages, tokenRatio: tokenRatio)
                units.append(unit)
                i = j
            } else if msg.role == "tool" {
                // Orphan tool result (no preceding assistant with tool_calls)
                let unit = MessageUnit(
                    messages: [msg],
                    tokens: estimateTokens([msg], tokenRatio: tokenRatio),
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
                    tokens: estimateTokens([msg], tokenRatio: tokenRatio),
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

    // MARK: - Extract Preserved Units

    /// Extract system messages, last user unit, existing summary, and preserved
    /// leading system messages (user_context anchors, context_files, etc.).
    ///
    /// Ported from CLIO's `_extract_preserved_units`. Preserves ALL leading
    /// system messages at their original position for LCP cache stability.
    public static func extractPreservedUnits(_ units: [MessageUnit], tokenRatio: Double? = nil) -> (
        systemMessages: [OpenAIChatMessage],
        lastUserUnit: MessageUnit?,
        startIdx: Int,
        summaryUnit: MessageUnit?,
        summaryTokens: Int,
        preservedUserContexts: [MessageUnit],
        preservedGeneralSystem: [MessageUnit]
    ) {
        var systemMessages: [OpenAIChatMessage] = []
        var startIdx = 0
        var summaryUnit: MessageUnit?
        var summaryTokens = 0
        var preservedUserContexts: [MessageUnit] = []
        var preservedGeneralSystem: [MessageUnit] = []

        // Collect ALL leading system messages (not just the first).
        // These include: system_prompt, thread_summary, user_context anchors,
        // context_files, and any other system-level instructions.
        while startIdx < units.count {
            let firstMsg = units[startIdx].messages.first
            guard firstMsg?.role == "system" else { break }

            let content = firstMsg?.content ?? ""

            // Existing thread_summary (CSSS slot - will be regenerated/updated)
            if content.contains("<thread_summary>") {
                summaryUnit = units[startIdx]
                summaryTokens = units[startIdx].tokens
                startIdx += 1
                continue
            }

            // user_context anchors (<dynamicContext>/<userContext>/<sessionGoals>)
            // These render as <system>...</system> in the chat template. If dropped,
            // the chat template output diverges in the prefix region and llama.cpp's
            // LCP cache match fails.
            if content.range(of: "<(userContext|dynamicContext|sessionGoals)", options: .regularExpression) != nil {
                preservedUserContexts.append(units[startIdx])
                startIdx += 1
                continue
            }

            // Other general system messages (context_files, recovery notices, etc.)
            // Previously these were silently dropped, changing prompt_stable_prefix_tokens
            // on the first trim and collapsing the LCP cache.
            preservedGeneralSystem.append(units[startIdx])
            systemMessages.append(firstMsg!)
            startIdx += 1
        }

        // Find the most recent user unit
        var lastUserUnit: MessageUnit?
        for unit in units.reversed() {
            if unit.messages.first?.role == "user" {
                lastUserUnit = unit
                break
            }
        }

        if let lastUser = lastUserUnit {
            logger.debug("Context: found most recent user message (tokens=\(lastUser.tokens))")
        }

        return (systemMessages, lastUserUnit, startIdx, summaryUnit, summaryTokens,
                preservedUserContexts, preservedGeneralSystem)
    }

    /// Helper to extract unit messages into a flat array for compressDropped.
    private static func droppedUnitMessages(_ droppedMsgs: [OpenAIChatMessage]) -> [MessageUnit] {
        // Wrap dropped messages in units for compressDropped (which expects MessageUnit[])
        // Group consecutive assistant+tool pairs that may have been split
        var units: [MessageUnit] = []
        var i = 0
        while i < droppedMsgs.count {
            let msg = droppedMsgs[i]
            if msg.role == "assistant" && msg.toolCalls != nil && !(msg.toolCalls?.isEmpty ?? true) {
                var group: [OpenAIChatMessage] = [msg]
                var j = i + 1
                while j < droppedMsgs.count && droppedMsgs[j].role == "tool" {
                    group.append(droppedMsgs[j])
                    j += 1
                }
                let toolIds = Set(group.compactMap { $0.toolCallId })
                units.append(MessageUnit(
                    messages: group,
                    tokens: estimateTokens(group),
                    toolCallIds: toolIds,
                    isOrphanToolResult: false,
                    orphanToolId: nil
                ))
                i = j
            } else {
                units.append(MessageUnit(
                    messages: [msg],
                    tokens: estimateTokens([msg]),
                    toolCallIds: Set<String>(),
                    isOrphanToolResult: msg.role == "tool",
                    orphanToolId: msg.toolCallId
                ))
                i += 1
            }
        }
        return units
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
                if resultIdx < assistantIdx {
                    logger.debug("Context: tool result at index \(resultIdx) precedes its tool_calls at index \(assistantIdx) - removing")
                    orphanedResultIndices.insert(resultIdx)
                }
            } else {
                orphanedResultIndices.insert(resultIdx)
            }
        }

        if orphanedTcIds.isEmpty && orphanedResultIndices.isEmpty {
            return messages
        }

        // Rebuild: remove orphaned results, selectively strip orphaned tool_calls
        var validated: [OpenAIChatMessage] = []
        for (i, msg) in messages.enumerated() {
            if orphanedResultIndices.contains(i) {
                logger.debug("Context: removing orphaned/misordered tool_result at index \(i)")
                continue
            }

            if msg.role == "assistant", let toolCalls = msg.toolCalls {
                let validCalls = toolCalls.filter { !orphanedTcIds.contains($0.id) }
                if validCalls.count != toolCalls.count {
                    logger.debug("Context: stripped \(toolCalls.count - validCalls.count) orphaned tool_calls from assistant at index \(i)")
                    validated.append(OpenAIChatMessage(
                        id: msg.id, role: msg.role, content: msg.content,
                        toolCalls: validCalls.isEmpty ? nil : validCalls,
                        toolCallId: msg.toolCallId
                    ))
                } else {
                    validated.append(msg)
                }
            } else {
                validated.append(msg)
            }
        }

        return validated
    }

    // MARK: - Compress Dropped

    /// Compress dropped message units into a thread_summary.
    /// Preserves cumulative history across multiple trim cycles by parsing the
    /// previous thread_summary and merging extracted buckets with new drops.
    /// Also preserves the original (first) user request when many requests exist.
    public static func compressDropped(
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

        // Seed buckets from previous summary (accumulates across trim cycles)
        if !previousSummary.isEmpty {
            parsePreviousSummary(
                previousSummary,
                commits: &commits,
                filesModified: &filesModified,
                decisions: &decisions,
                toolsUsed: &toolsUsed
            )
        }

        // Track interaction tool_call IDs for pairing questions with responses
        var collabToolCalls: [String: String] = [:]

        // Extract info from dropped messages
        for unit in droppedUnits {
            for msg in unit.messages {
                let content = msg.content ?? ""

                if msg.role == "user" {
                    let preview = content.count > 300 ? String(content.prefix(297)) + "..." : content
                    userRequests.append(preview)
                }

                // Track file paths and decisions from tool calls
                if let toolCalls = msg.toolCalls {
                    for tc in toolCalls {
                        let name = tc.function.name
                        let args = tc.function.arguments
                        toolsUsed[name, default: 0] += 1

                        if name == "interact" {
                            if let question = extractJsonStringValue(args, key: "message"), !question.isEmpty {
                                collabToolCalls[tc.id] = question
                            }
                        }

                        if name == "file_operations" || name == "apply_patch" {
                            for path in extractJsonStringValues(args, keys: ["path", "new_path", "old_path"]) {
                                if !path.hasPrefix(".") && !filesModified.contains(path) {
                                    filesModified.append(path)
                                }
                            }
                        }

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
                    // Pair collaboration responses
                    if let toolCallId = msg.toolCallId, let question = collabToolCalls[toolCallId] {
                        let q = question.count > 1000 ? String(question.prefix(1000)) + "..." : question
                        let r = content.count > 1000 ? String(content.prefix(1000)) + "..." : content
                        collaborationExchanges.append((question: q, response: r))
                        collabToolCalls.removeValue(forKey: toolCallId)
                    }

                    // Git commit results
                    let commitRegex = try? NSRegularExpression(
                        pattern: "^\\[([a-f0-9]{7,12})\\]\\s+(.{1,100})",
                        options: [.anchorsMatchLines]
                    )
                    if let regex = commitRegex {
                        let nsContent = content as NSString
                        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
                        for match in matches where match.numberOfRanges >= 3 {
                            let hash = nsContent.substring(with: match.range(at: 1))
                            let subject = nsContent.substring(with: match.range(at: 2))
                            commits.append("\(hash): \(subject)")
                        }
                    }

                    // git log --oneline
                    let logRegex = try? NSRegularExpression(
                        pattern: "^([a-f0-9]{7,12})\\s+(.{1,100})",
                        options: [.anchorsMatchLines]
                    )
                    if let regex = logRegex {
                        let nsContent = content as NSString
                        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
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

                for ref in extractFileRefs(from: content) where !filesModified.contains(ref) {
                    filesModified.append(ref)
                }
            }
        }

        // Deduplicate and limit
        if filesModified.count > 30 {
            filesModified = Array(filesModified.prefix(30))
        }
        var seenCommits = Set<String>()
        commits = commits.filter { seenCommits.insert($0).inserted }
        if commits.count > 15 {
            commits = Array(commits.prefix(15))
        }
        if decisions.count > 3 {
            decisions = Array(decisions.suffix(3))
        }
        if collaborationExchanges.count > 5 {
            collaborationExchanges = Array(collaborationExchanges.suffix(5))
        }

        // Always preserve the FIRST user request (original session task)
        if userRequests.count > 8 {
            firstUserRequest = userRequests.first
            userRequests = Array(userRequests.suffix(7))
        }

        // Find substantive task (>= 50 chars)
        let lastUserContent = lastUserUnit?.messages.first(where: { $0.role == "user" })?.content ?? ""
        var allRequests: [String] = []
        if let first = firstUserRequest { allRequests.append(first) }
        allRequests.append(contentsOf: userRequests)
        currentTask = findSubstantiveTask(candidate: lastUserContent, messages: allRequests)

        // Build structured thread_summary
        var parts: [String] = []
        parts.append("<thread_summary>")
        parts.append("")

        if !currentTask.isEmpty {
            let taskPreview = currentTask.count > 300 ? String(currentTask.prefix(300)) : currentTask
            parts.append("Current task: \(taskPreview)")
            parts.append("")
        }

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

    // MARK: - Summary Parse-and-Merge

    /// Parse structured sections from a previous thread_summary to seed extraction buckets.
    public static func parsePreviousSummary(
        _ summaryText: String,
        commits: inout [String],
        filesModified: inout [String],
        decisions: inout [String],
        toolsUsed: inout [String: Int]
    ) {
        let cleaned = summaryText
            .replacingOccurrences(of: "<thread_summary>", with: "")
            .replacingOccurrences(of: "</thread_summary>", with: "")

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
    public static func extractSection(text: String, header: String) -> String? {
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

    // MARK: - Task Extraction

    /// Find a substantive task description (>= 50 chars).
    public static func findSubstantiveTask(candidate: String, messages: [String]) -> String {
        let minLength = 50
        if candidate.count >= minLength {
            return candidate
        }
        for msg in messages.reversed() where msg.count >= minLength {
            return msg
        }
        return candidate
    }

    // MARK: - JSON Helpers

    public static func extractJsonStringValue(_ json: String, key: String) -> String? {
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

    public static func extractJsonStringValues(_ json: String, keys: [String]) -> [String] {
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
