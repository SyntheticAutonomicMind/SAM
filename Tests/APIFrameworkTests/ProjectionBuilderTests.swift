// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework
@testable import ConversationEngine

final class ProjectionBuilderTests: XCTestCase {

    // MARK: - Turn Splitting

    func testSplitIntoTurns_BasicCases() {
        let system = OpenAIChatMessage(role: "system", content: "You are helpful")
        let user1 = OpenAIChatMessage(role: "user", content: "Hello")
        let assistant1 = OpenAIChatMessage(role: "assistant", content: "Hi there")
        let user2 = OpenAIChatMessage(role: "user", content: "How are you?")
        let assistant2 = OpenAIChatMessage(role: "assistant", content: "Good!")

        let messages = [system, user1, assistant1, user2, assistant2]
        let turns = ProjectionBuilder.splitIntoTurns(messages)

        // System goes in the first turn (no preceding user message)
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns[0].count, 1) // system only
        XCTAssertEqual(turns[0][0].role, "system")
        XCTAssertEqual(turns[1].count, 2) // user1 + assistant1
        XCTAssertEqual(turns[1][0].role, "user")
        XCTAssertEqual(turns[1][1].role, "assistant")
        XCTAssertEqual(turns[2].count, 2) // user2 + assistant2
    }

    func testSplitIntoTurns_ToolResultsAttachedToTurn() {
        let user1 = OpenAIChatMessage(role: "user", content: "Do something")
        let assistant1 = OpenAIChatMessage(
            role: "assistant", content: nil,
            toolCalls: [OpenAIToolCall(id: "tc1", function: OpenAIFunctionCall(name: "test", arguments: "{}"))]
        )
        let tool1 = OpenAIChatMessage(role: "tool", content: "result", toolCallId: "tc1")
        let user2 = OpenAIChatMessage(role: "user", content: "Next")

        let messages = [user1, assistant1, tool1, user2]
        let turns = ProjectionBuilder.splitIntoTurns(messages)

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].count, 3) // user1 + assistant1 + tool1
        XCTAssertEqual(turns[1].count, 1) // user2 only (incomplete turn)
    }

    // MARK: - Recent Count Scaling

    func testRecentCount_ScalingBands() {
        XCTAssertEqual(ProjectionBuilder.recentCount(for: 0), 0)
        XCTAssertEqual(ProjectionBuilder.recentCount(for: 1), 3)  // min 3 floor, clamped to total
        XCTAssertEqual(ProjectionBuilder.recentCount(for: 5), 3)  // short band
        XCTAssertEqual(ProjectionBuilder.recentCount(for: 30), 3) // short band, max 30
        XCTAssertEqual(ProjectionBuilder.recentCount(for: 31), 5) // medium band
        XCTAssertEqual(ProjectionBuilder.recentCount(for: 100), 5) // medium band, max 100
        XCTAssertEqual(ProjectionBuilder.recentCount(for: 101), 8) // long band
        XCTAssertEqual(ProjectionBuilder.recentCount(for: 300), 8) // long band, max 300
        XCTAssertEqual(ProjectionBuilder.recentCount(for: 301), 10) // very long band (hard cap)
        XCTAssertEqual(ProjectionBuilder.recentCount(for: 1000), 10) // hard cap
    }

    // MARK: - Turn Selection

    func testSelectTurns_KeepsRecentAndDropsOld() {
        var turns: [[OpenAIChatMessage]] = []
        for i in 0..<10 {
            let user = OpenAIChatMessage(role: "user", content: "Turn \(i)")
            let assistant = OpenAIChatMessage(role: "assistant", content: "Response \(i)")
            turns.append([user, assistant])
        }

        let (recent, dropped, _) = ProjectionBuilder.selectTurns(&turns)

        // 10 turns in short band (<= 30 turns -> 3 recent)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(dropped.count, 7)
    }

    func testSelectTurns_PreservesIncompleteLastTurnAsCurrent() {
        // When the last turn is incomplete (user only, no assistant/tool response),
        // it should be returned as `current`, NOT dropped or compressed.
        // This is the critical regression test: at request-prep time, the current
        // user message has no assistant response yet, and it must reach the model.
        var turns: [[OpenAIChatMessage]] = []
        for i in 0..<5 {
            let user = OpenAIChatMessage(role: "user", content: "Turn \(i)")
            let assistant = OpenAIChatMessage(role: "assistant", content: "Response \(i)")
            turns.append([user, assistant])
        }
        // Add incomplete turn (user only — simulating the current user message)
        turns.append([OpenAIChatMessage(role: "user", content: "Current question")])

        let (recent, dropped, current) = ProjectionBuilder.selectTurns(&turns)

        // 5 completed turns (short band, <= 30 -> 3 recent), incomplete turn returned separately
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(dropped.count, 2)
        XCTAssertNotNil(current, "Incomplete turn should be returned as current, not dropped")
        XCTAssertEqual(current?.count, 1, "Current turn should contain exactly one message")
        XCTAssertEqual(current?.first?.role, "user")
        XCTAssertEqual(current?.first?.content, "Current question")
    }

    func testSelectTurns_ToolTurnPreservation() {
        // Last turn has a tool_call — should be force-included in recent window
        var turns: [[OpenAIChatMessage]] = []
        for i in 0..<10 {
            let user = OpenAIChatMessage(role: "user", content: "Turn \(i)")
            let assistant = OpenAIChatMessage(role: "assistant", content: "Response \(i)")
            turns.append([user, assistant])
        }
        // Last turn has a tool call
        turns.append([
            OpenAIChatMessage(role: "user", content: "Do something with tools"),
            OpenAIChatMessage(
                role: "assistant", content: "Calling tool",
                toolCalls: [OpenAIToolCall(id: "tc1", function: OpenAIFunctionCall(name: "test", arguments: "{}"))]
            )
        ])

        let (recent, dropped, _) = ProjectionBuilder.selectTurns(&turns)

        // 11 turns, short band -> 3 recent. Force-include the tool turn.
        XCTAssertEqual(recent.count, 3)
        XCTAssertTrue(recent.last?.contains { $0.role == "assistant" && $0.toolCalls != nil } ?? false,
                      "Last recent turn should contain the tool_call turn")
    }

    // MARK: - Cross-Turn Dedup

    func testCollapseRepeatedToolCalls_NoCollapseForDifferentContent() {
        let turn1 = [
            OpenAIChatMessage(role: "user", content: "What is 2+2?"),
            OpenAIChatMessage(
                role: "assistant", content: "Calculating",
                toolCalls: [OpenAIToolCall(id: "tc1", function: OpenAIFunctionCall(name: "calc", arguments: "{\"expr\": \"2+2\"}"))]
            ),
            OpenAIChatMessage(role: "tool", content: "4", toolCallId: "tc1")
        ]
        let turn2 = [
            OpenAIChatMessage(role: "user", content: "What is 3+3?"),
            OpenAIChatMessage(
                role: "assistant", content: "Calculating",
                toolCalls: [OpenAIToolCall(id: "tc2", function: OpenAIFunctionCall(name: "calc", arguments: "{\"expr\": \"3+3\"}"))]
            ),
            OpenAIChatMessage(role: "tool", content: "6", toolCallId: "tc2")
        ]

        let result = ProjectionBuilder.collapseRepeatedToolCalls([turn1, turn2])
        XCTAssertEqual(result.count, 2, "Different tool calls should not collapse")
    }

    func testCollapseRepeatedToolCalls_CollapsesIdenticalWithContinuation() {
        let turn1 = [
            OpenAIChatMessage(role: "user", content: "What is 2+2?"),
            OpenAIChatMessage(
                role: "assistant", content: "Calculating",
                toolCalls: [OpenAIToolCall(id: "tc1", function: OpenAIFunctionCall(name: "calc", arguments: "{\"expr\": \"2+2\"}"))]
            ),
            OpenAIChatMessage(role: "tool", content: "4", toolCallId: "tc1")
        ]
        let turn2 = [
            OpenAIChatMessage(role: "user", content: "continue"),
            OpenAIChatMessage(
                role: "assistant", content: "Calculating",
                toolCalls: [OpenAIToolCall(id: "tc2", function: OpenAIFunctionCall(name: "calc", arguments: "{\"expr\": \"2+2\"}"))]
            ),
            OpenAIChatMessage(role: "tool", content: "4", toolCallId: "tc2")
        ]

        let result = ProjectionBuilder.collapseRepeatedToolCalls([turn1, turn2])
        XCTAssertEqual(result.count, 1, "Identical tool calls with continuation prompt should collapse")
    }

    // MARK: - Full Projection

    func testProject_SmallConversation_ReturnsAsIs() {
        // 3 messages: system + user + assistant — too few for projection
        let messages = [
            OpenAIChatMessage(role: "system", content: "You are helpful"),
            OpenAIChatMessage(role: "user", content: "Hello"),
            OpenAIChatMessage(role: "assistant", content: "Hi there")
        ]

        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 8_000)
        let result = ProjectionBuilder.project(messages: messages, caps: caps, tokenRatio: 4.0)

        XCTAssertEqual(result.messages.count, 3)
        XCTAssertNil(result.compressedSummary)
        XCTAssertNil(result.currentTurn)
    }

    func testProject_LargeConversation_ProducesCompressedSummary() {
        // 25 complete turns — should trigger projection
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: "You are helpful")
        ]
        for i in 0..<25 {
            messages.append(OpenAIChatMessage(role: "user", content: "Turn \(i) question with some content here"))
            messages.append(OpenAIChatMessage(role: "assistant", content: "Turn \(i) response with some content here"))
        }

        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 8_000)
        let result = ProjectionBuilder.project(messages: messages, caps: caps, tokenRatio: 4.0)

        // System message preserved at front
        XCTAssertEqual(result.messages[0].role, "system")

        // Compressed summary should be generated
        XCTAssertNotNil(result.compressedSummary)
        XCTAssertTrue(result.compressedSummary?.content?.contains("<thread_summary>") ?? false)

        // Projected messages should be fewer than original
        // (system + recent turns, not all 51 original messages)
        XCTAssertLessThan(result.messages.count, messages.count)

        // No current turn — conversation is complete (last message is assistant)
        XCTAssertNil(result.currentTurn, "Complete conversation should have no current turn")
    }

    func testProject_PreservesRecentTurns() {
        // Build a conversation with 15 complete turns
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: "System prompt")
        ]
        for i in 0..<15 {
            messages.append(OpenAIChatMessage(role: "user", content: "Question \(i)"))
            messages.append(OpenAIChatMessage(role: "assistant", content: "Answer \(i)"))
        }

        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 8_000)
        let result = ProjectionBuilder.project(messages: messages, caps: caps, tokenRatio: 4.0)

        // System preserved
        XCTAssertEqual(result.messages[0].role, "system")

        // Should still contain the most recent user message
        let hasRecentUser = result.messages.contains { msg in
            msg.role == "user" && (msg.content?.contains("Question 14") ?? false)
        }
        XCTAssertTrue(hasRecentUser, "Projected messages should contain the most recent user message")

        // Should NOT contain the oldest user messages
        let hasOldUser = result.messages.contains { msg in
            msg.role == "user" && (msg.content?.contains("Question 0") ?? false)
        }
        XCTAssertFalse(hasOldUser, "Projected messages should not contain the oldest user message")

        // No current turn — conversation is complete
        XCTAssertNil(result.currentTurn)
    }

    func testProject_UnrespondedToUserMessage_PreservesCurrentTurn() {
        // Regression test for the "same response over and over" bug.
        // The conversation ends with a user message that hasn't been answered yet
        // (the current request). project() must return this message in currentTurn
        // so the caller can append it as the last message sent to the model.
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: "You are helpful")
        ]
        for i in 0..<15 {
            messages.append(OpenAIChatMessage(role: "user", content: "Question \(i)"))
            messages.append(OpenAIChatMessage(role: "assistant", content: "Answer \(i)"))
        }
        // Add the CURRENT user message (no assistant response yet)
        messages.append(OpenAIChatMessage(role: "user", content: "CURRENT QUESTION — this must reach the model"))

        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 8_000)
        let result = ProjectionBuilder.project(messages: messages, caps: caps, tokenRatio: 4.0)

        // System message preserved at front
        XCTAssertEqual(result.messages[0].role, "system")

        // currentTurn should carry the current user message
        XCTAssertNotNil(result.currentTurn, "currentTurn should be non-nil for unfinished conversation")
        XCTAssertEqual(result.currentTurn?.count, 1)
        XCTAssertEqual(result.currentTurn?.first?.content, "CURRENT QUESTION — this must reach the model")
        XCTAssertEqual(result.currentTurn?.first?.role, "user")

        // The current user message should NOT be in result.messages — it's in currentTurn
        let hasCurrentUserInMessages = result.messages.contains { msg in
            msg.content?.contains("CURRENT QUESTION") ?? false
        }
        XCTAssertFalse(hasCurrentUserInMessages, "Current user message should be in currentTurn, not in messages")

        // When assembled in the order AgentOrchestrator uses
        // (messages + compressedSummary + currentTurn), the current user
        // message is the LAST message — this is what fixes the bug.
        var assembled = result.messages
        if let summary = result.compressedSummary {
            assembled.append(summary)
        }
        if let current = result.currentTurn {
            assembled.append(contentsOf: current)
        }
        XCTAssertEqual(assembled.last?.content, "CURRENT QUESTION — this must reach the model")
        XCTAssertEqual(assembled.last?.role, "user")
    }
}
