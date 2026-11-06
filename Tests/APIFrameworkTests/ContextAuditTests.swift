// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework

/// Regression tests for the 2026-11-06 context-management audit (CLIO baseline).
/// Each test pins a behavior CLIO's MessageValidator has that SAM's port lacked:
/// duplicate tool_result detection, multi-summary carryover, the single-artifact
/// invariant, and pinned-token reservation in the trim walk.
final class ContextAuditTests: XCTestCase {

    private func summaryMessage(_ text: String) -> OpenAIChatMessage {
        OpenAIChatMessage(role: "system", content: "<thread_summary>\n\(text)\n</thread_summary>")
    }

    private func assistantWithToolCall(_ id: String, content: String = "working") -> OpenAIChatMessage {
        OpenAIChatMessage(
            role: "assistant",
            content: content,
            toolCalls: [OpenAIToolCall(id: id, type: "function",
                                       function: OpenAIFunctionCall(name: "web_operations", arguments: "{}"))]
        )
    }

    // MARK: - Duplicate tool_result detection (CLIO parity)

    /// The same tool_call_id answered twice must keep the FIRST result and
    /// drop the duplicate - providers reject repeated result ids.
    func testValidateToolMessagePairs_KeepsFirstOfDuplicateResults() {
        let messages = [
            assistantWithToolCall("call_a"),
            OpenAIChatMessage(role: "tool", content: "result 1", toolCallId: "call_a"),
            OpenAIChatMessage(role: "tool", content: "result 2 (duplicate)", toolCallId: "call_a"),
            OpenAIChatMessage(role: "user", content: "next")
        ]

        let validated = MessageValidator.validateToolMessagePairs(messages)

        let results = validated.filter { $0.role == "tool" }
        XCTAssertEqual(results.count, 1, "duplicate result must be dropped")
        XCTAssertEqual(results.first?.content, "result 1", "first occurrence wins")
    }

    /// The byte-stability fast path must NOT pass an array with duplicate
    /// results through unchanged - it has to fall into the fixing path.
    func testTrimPath_FixesDuplicateResults() {
        let messages = [
            OpenAIChatMessage(role: "system", content: "sys prompt"),
            OpenAIChatMessage(role: "user", content: "task"),
            assistantWithToolCall("call_a"),
            OpenAIChatMessage(role: "tool", content: "result 1", toolCallId: "call_a"),
            OpenAIChatMessage(role: "tool", content: "result 2 (duplicate)", toolCallId: "call_a")
        ]
        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 8_000)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(messages: messages, config: config)

        let toolResults = result.messages.filter { $0.role == "tool" }
        XCTAssertEqual(toolResults.count, 1, "exactly one result survives")
        XCTAssertEqual(toolResults.first?.content, "result 1")
    }

    // MARK: - Multi-summary carryover (CLIO parity)

    /// Two leading summary artifacts: the newest is the regeneration slot and
    /// BOTH feed previousSummary, so nothing is silently lost.
    func testExtractPreservedUnits_CarriesForwardAllSummaryContent() {
        let units: [MessageValidator.MessageUnit] = [
            .init(messages: [summaryMessage("older summary state")], tokens: 40),
            .init(messages: [summaryMessage("newer summary state")], tokens: 40),
            .init(messages: [OpenAIChatMessage(role: "user", content: "current task")], tokens: 20)
        ]

        let extracted = MessageValidator.extractPreservedUnits(units)

        XCTAssertTrue(extracted.previousSummaryContent.contains("older summary state"))
        XCTAssertTrue(extracted.previousSummaryContent.contains("newer summary state"))
        XCTAssertEqual(extracted.summaryUnit?.messages.first?.content?
            .contains("newer summary state"), true, "the newest summary is the slot")
        XCTAssertEqual(extracted.startIdx, 2, "both summary units are excluded from the walk")
    }

    /// The regenerated output contains only ONE summary artifact even when the
    /// input carried two - old state is carried via previousSummary, not by
    /// keeping both messages.
    func testTrimPath_SingleSummaryArtifactSurvives() {
        let messages = [
            summaryMessage("older summary state"),
            summaryMessage("newer summary state"),
            OpenAIChatMessage(role: "user", content: "current task line"),
            assistantWithToolCall("call_a"),
            OpenAIChatMessage(role: "tool", content: "result", toolCallId: "call_a"),
            OpenAIChatMessage(role: "user", content: "follow-up question about the task")
        ]
        // Tiny budget forces the trim path.
        let caps = ContextCapabilities(contextWindow: 1_000, maxOutputTokens: 100)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(messages: messages, config: config)

        let summaries = result.messages.filter { MessageValidator.isThreadSummaryMessage($0) }
        XCTAssertLessThanOrEqual(summaries.count, 1, "single-artifact invariant")
    }

    // MARK: - Single-artifact helper

    func testRemoveExistingThreadSummaries_StripsArtifactsAndPreservesUserInput() {
        let messages = [
            summaryMessage("standalone summary"),
            OpenAIChatMessage(role: "user", content: "plain user text"),
            OpenAIChatMessage(role: "user", content: "<thread_summary>\nstale folded state\n</thread_summary>\n\nactual user question"),
            assistantWithToolCall("call_a", content: "reply")
        ]

        let cleaned = MessageValidator.removeExistingThreadSummaries(messages)

        XCTAssertEqual(cleaned.count, 3, "standalone summary removed")
        XCTAssertFalse(cleaned.contains(where: { MessageValidator.isThreadSummaryMessage($0) }))
        let foldedUser = cleaned.first { $0.content?.contains("actual user question") ?? false }
        XCTAssertNotNil(foldedUser, "user input preserved")
        XCTAssertFalse(foldedUser?.content?.contains("stale folded state") ?? true, "stale fold stripped")
        let plainUser = cleaned.first { $0.content == "plain user text" }
        XCTAssertNotNil(plainUser, "untouched user message survives verbatim")
    }

    // MARK: - Pinned-token reservation (CLIO parity)

    /// Pinned content (system + summary + last user) larger than the budget
    /// must bail out to the normalization path instead of walking and
    /// re-injecting an over-budget request.
    func testTrimPath_PinnedOverBudgetBailsOut() {
        let hugeUser = OpenAIChatMessage(role: "user", content: String(repeating: "x", count: 20_000))
        let messages = [
            OpenAIChatMessage(role: "system", content: String(repeating: "s", count: 20_000)),
            hugeUser
        ]
        // Budget far smaller than the pinned pair.
        let caps = ContextCapabilities(contextWindow: 2_000, maxOutputTokens: 100)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(messages: messages, config: config)

        // Bail-out path: both messages survive (normalized), nothing dropped.
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertEqual(result.droppedMessages.count, 0)
    }

    /// The pinned last user turn must survive the walk even when older turns
    /// exhaust the budget, and older units that fit stay OLDER than it.
    func testTrimPath_LastUserPinnedAndOrderedLast() {
        let messages = [
            OpenAIChatMessage(role: "user", content: "first task with plenty of detail to consume budget"),
            assistantWithToolCall("call_old", content: "old turn"),
            OpenAIChatMessage(role: "tool", content: "old result", toolCallId: "call_old"),
            assistantWithToolCall("call_old2", content: "old turn 2"),
            OpenAIChatMessage(role: "tool", content: "old result 2", toolCallId: "call_old2"),
            OpenAIChatMessage(role: "user", content: "the current request that must survive")
        ]
        // Small budget so the walk has to drop old units but keep the pinned user.
        let caps = ContextCapabilities(contextWindow: 1_200, maxOutputTokens: 100)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(messages: messages, config: config)

        let lastUser = result.messages.last { $0.role == "user" }
        XCTAssertEqual(lastUser?.content, "the current request that must survive",
                       "pinned last user survives the trim")
        // Whatever survived must be in chronological order.
        let userContents = result.messages.filter { $0.role == "user" }.compactMap { $0.content }
        if userContents.count > 1 {
            XCTAssertEqual(userContents.first, "first task with plenty of detail to consume budget",
                           "older kept content stays before the pinned turn")
        }
    }
}
