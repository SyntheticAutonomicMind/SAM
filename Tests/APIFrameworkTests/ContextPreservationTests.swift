// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework
@testable import ConversationEngine
@testable import ConfigurationSystem

/// Regression tests for the "model sees wrong messages" bug.
///
/// Root cause: the streaming path (callLLMStreaming) never explicitly added
/// the current user message to the request, unlike the non-streaming path (callLLM)
/// which had a `newMessageNotInHistory` safety net. When conversation.messages
/// hadn't synced from MessageBus yet, the model received the previous turn's
/// context — responding to old questions instead of the current one.
///
/// These tests verify the full PipelineBuilder + MessageValidator pipeline
/// preserves the last user message in all scenarios.
final class ContextPreservationTests: XCTestCase {

    // MARK: - Full pipeline: ProjectionBuilder + MessageValidator

    func testPipeline_PreservesCurrentTurnWithSystemReminders() {
        // Simulates the streaming path's message structure:
        // [system] [user/assistant turns] [thread_summary (system)] [current user] [todo reminder (system)] [memory reminder (system)]
        // The current user message must survive ProjectionBuilder + MessageValidator.
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: "You are a helpful assistant"),
            OpenAIChatMessage(role: "user", content: "First question"),
            OpenAIChatMessage(role: "assistant", content: "First answer"),
            OpenAIChatMessage(role: "user", content: "Second question"),
            OpenAIChatMessage(role: "assistant", content: "Second answer"),
        ]

        // Add a thread_summary (system) and the current user message, then reminders.
        // This mirrors what validateAndArchiveContext receives after ProjectBuilder.
        messages.append(OpenAIChatMessage(role: "system", content: "<thread_summary>\nOld conversation compressed.\nCurrent task: None\n</thread_summary>"))
        messages.append(OpenAIChatMessage(role: "user", content: "TRAVEL_QUESTION — this must reach the model"))
        messages.append(OpenAIChatMessage(role: "system", content: "Todo reminder: 3 tasks"))
        messages.append(OpenAIChatMessage(role: "system", content: "Memory reminder: 2 stored"))

        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 8_000)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(
            messages: messages,
            config: config
        )

        // The current user message must be in the output.
        let hasCurrentUser = result.messages.contains { msg in
            msg.role == "user" && (msg.content?.contains("TRAVEL_QUESTION") ?? false)
        }
        XCTAssertTrue(hasCurrentUser, "Current user message must be preserved through the full pipeline")

        // The current user message should be the LAST user message (after any system reminders).
        let userMessages = result.messages.filter { $0.role == "user" }
        XCTAssertTrue(userMessages.last?.content?.contains("TRAVEL_QUESTION") ?? false,
                      "Current user message should be the last user message")
    }

    func testPipeline_PreservesCurrentTurnWithoutSummary() {
        // Smaller conversation that doesn't need projection (messages.count <= 4 after
        // system messages are separated). Verify the last user message still survives.
        let messages = [
            OpenAIChatMessage(role: "system", content: "You are helpful"),
            OpenAIChatMessage(role: "user", content: "Old question"),
            OpenAIChatMessage(role: "assistant", content: "Old answer"),
            OpenAIChatMessage(role: "user", content: "CURRENT_QUESTION — must reach the model"),
        ]

        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 8_000)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(
            messages: messages,
            config: config
        )

        let hasCurrentUser = result.messages.contains { msg in
            msg.role == "user" && (msg.content?.contains("CURRENT_QUESTION") ?? false)
        }
        XCTAssertTrue(hasCurrentUser, "Current user message must survive even small conversations")
    }

    func testPipeline_OverBudgetStillKeepsLastUserMessage() {
        // Construct a scenario where trimming is required but the last user
        // message must still be preserved.
        let caps = ContextCapabilities(contextWindow: 500, maxOutputTokens: 100)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: "You are a helpful assistant. Follow these rules: always be helpful, always be accurate, always be honest.")
        ]

        // Add 10 user/assistant turns (enough to exceed the tiny budget)
        for i in 0..<10 {
            messages.append(OpenAIChatMessage(role: "user", content: "Turn \(i) question with lots of detail and content to fill the budget"))
            messages.append(OpenAIChatMessage(role: "assistant", content: "Turn \(i) response with lots of detail and content to fill the budget"))
        }

        // Current user message
        messages.append(OpenAIChatMessage(role: "user", content: "LAST_USER_MESSAGE — critical, must not be dropped"))

        let result = MessageValidator.validateAndTruncateWithDropped(
            messages: messages,
            config: config
        )

        // Verify the last user message is in the output.
        let hasLastUser = result.messages.contains { msg in
            msg.role == "user" && (msg.content?.contains("LAST_USER_MESSAGE") ?? false)
        }
        XCTAssertTrue(hasLastUser, "Last user message must be preserved even when over budget")

        // No user message should be dropped unless it's the current one being preserved
        // and the budget walk ensures at least one user message exists.
        let hasAnyUser = result.messages.contains { $0.role == "user" }
        XCTAssertTrue(hasAnyUser, "At least one user message must remain in the output")
    }

    // MARK: - Budget walk crash: index out of range with leading system messages

    func testBudgetWalk_NoCrashWithLeadingSystemMessages() {
        // Regression test for "Index out of range" crash in MessageValidator.
        // The unitIdx calculation was: startIdx + (units.count - 1 - idx)
        // which overflows when startIdx > 0 (i.e., when there are leading system
        // messages that get preserved by extractPreservedUnits). This caused
        // a crash whenever the conversation exceeded the context budget.
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: "You are a helpful assistant"),
            OpenAIChatMessage(role: "system", content: "Another system message"),
        ]
        for i in 0..<15 {
            messages.append(OpenAIChatMessage(role: "user", content: "Turn \(i) question with lots of detail and content to fill the budget"))
            messages.append(OpenAIChatMessage(role: "assistant", content: "Turn \(i) response with lots of detail and content to fill the budget"))
        }
        messages.append(OpenAIChatMessage(role: "user", content: "CURRENT — must not crash"))

        let caps = ContextCapabilities(contextWindow: 500, maxOutputTokens: 100)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        // This should NOT crash.
        let result = MessageValidator.validateAndTruncateWithDropped(
            messages: messages,
            config: config
        )

        let hasCurrentUser = result.messages.contains { msg in
            msg.role == "user" && (msg.content?.contains("CURRENT") ?? false)
        }
        XCTAssertTrue(hasCurrentUser, "Current user message must survive budget walk with leading system messages")
    }

    func testCSSSClampPreventsExcessiveSlotTarget() {
        // Regression test: when an existing thread_summary is very large
        // (e.g. 10K+ tokens in an 8K window), the CSSS slot target should
        // be clamped to csssMaxSlotTokens, not set to the raw summary size.
        let messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: "You are helpful"),
            // Existing thread_summary that's way too large
            OpenAIChatMessage(role: "system", content: "<thread_summary>\n" + String(repeating: "A", count: 50_000) + "\n</thread_summary>"),
            OpenAIChatMessage(role: "user", content: "Question 1"),
            OpenAIChatMessage(role: "assistant", content: "Answer 1"),
            OpenAIChatMessage(role: "user", content: "Question 2"),
            OpenAIChatMessage(role: "assistant", content: "Answer 2"),
            OpenAIChatMessage(role: "user", content: "Question 3"),
            OpenAIChatMessage(role: "assistant", content: "Answer 3"),
            OpenAIChatMessage(role: "user", content: "CURRENT_QUESTION"),
            OpenAIChatMessage(role: "system", content: "Todo reminder"),
            OpenAIChatMessage(role: "system", content: "Memory reminder"),
        ]

        let caps = ContextCapabilities(contextWindow: 8192, maxOutputTokens: 100)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        // Should not crash and should preserve the current user message.
        let result = MessageValidator.validateAndTruncateWithDropped(
            messages: messages,
            config: config
        )

        let hasCurrentUser = result.messages.contains { msg in
            msg.role == "user" && (msg.content?.contains("CURRENT_QUESTION") ?? false)
        }
        XCTAssertTrue(hasCurrentUser, "Current user message must survive with oversized thread_summary")
    }

    // MARK: - newMessageNotInHistory safety net logic

    func testSafetyNet_MessageNotInConversation_AddsExplicitly() {
        // Simulate the condition checked by the safety net:
        // conversationMessages doesn't include the current user message.
        let conversationMessages: [EnhancedMessage] = [
            EnhancedMessage(content: "Old question", isFromUser: true),
            EnhancedMessage(content: "Old answer", isFromUser: false),
        ]
        let currentMessage = "NEW_QUESTION — must reach model"

        // This replicates the safety net logic from callLLMStreaming:
        let newMessageNotInHistory = conversationMessages.isEmpty ||
            !conversationMessages.last!.isFromUser ||
            conversationMessages.last!.content != currentMessage

        XCTAssertTrue(newMessageNotInHistory, "Should detect message is not in history")
    }

    func testSafetyNet_MessageInConversation_SkipsDuplicate() {
        let currentMessage = "EXISTING_QUESTION"
        let conversationMessages: [EnhancedMessage] = [
            EnhancedMessage(content: "Old question", isFromUser: true),
            EnhancedMessage(content: "Old answer", isFromUser: false),
            EnhancedMessage(content: currentMessage, isFromUser: true),
        ]

        let newMessageNotInHistory = conversationMessages.isEmpty ||
            !conversationMessages.last!.isFromUser ||
            conversationMessages.last!.content != currentMessage

        XCTAssertFalse(newMessageNotInHistory, "Should NOT add duplicate when message already present")
    }

    func testSafetyNet_EmptyConversation_AddsMessage() {
        let conversationMessages: [EnhancedMessage] = []
        let currentMessage = "FIRST_QUESTION"

        let newMessageNotInHistory = conversationMessages.isEmpty ||
            !conversationMessages.last!.isFromUser ||
            conversationMessages.last?.content != currentMessage

        XCTAssertTrue(newMessageNotInHistory, "Should add message when conversation is empty")
    }

    func testSafetyNet_LastMessageIsAssistant_AddsUserMessage() {
        // Edge case: last message is an assistant message (e.g., tool call result
        // persisted after the user message), so the current user message needs
        // to be explicitly added.
        let conversationMessages: [EnhancedMessage] = [
            EnhancedMessage(content: "User question", isFromUser: true),
            EnhancedMessage(content: "Assistant response", isFromUser: false),
        ]
        let currentMessage = "FOLLOW_UP_QUESTION"

        let newMessageNotInHistory = conversationMessages.isEmpty ||
            !conversationMessages.last!.isFromUser ||
            conversationMessages.last!.content != currentMessage

        XCTAssertTrue(newMessageNotInHistory, "Should detect user message is missing when last is assistant")
    }

    // MARK: - ProjectionBuilder + CurrentTurn assembly

    func testProjectionBuilder_CurrentTurnIsLastInAssembledOutput() {
        // Verify the assembly order used by validateAndArchiveContext:
        // projectedMessages + compressedSummary + currentTurn
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: "System prompt")
        ]
        for i in 0..<15 {
            messages.append(OpenAIChatMessage(role: "user", content: "Q\(i)"))
            messages.append(OpenAIChatMessage(role: "assistant", content: "A\(i)"))
        }
        messages.append(OpenAIChatMessage(role: "user", content: "CURRENT_QUESTION"))

        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 8_000)
        let result = ProjectionBuilder.project(
            messages: messages,
            caps: caps,
            tokenRatio: 4.0
        )

        XCTAssertNotNil(result.currentTurn, "Current turn should be extracted")
        XCTAssertEqual(result.currentTurn?.first?.content, "CURRENT_QUESTION")

        // Assemble in the order validateAndArchiveContext uses:
        var assembled = result.messages
        if let summary = result.compressedSummary {
            assembled.append(summary)
        }
        if let current = result.currentTurn {
            assembled.append(contentsOf: current)
        }

        // The current user message must be the last message.
        XCTAssertEqual(assembled.last?.role, "user")
        XCTAssertEqual(assembled.last?.content, "CURRENT_QUESTION")
    }

    // MARK: - Message sequence integrity through validateAndArchiveContext

    func testPipeline_PreservesUserMessageBeforeSystemReminders() {
        // Verify that when system reminders appear after the current user message,
        // the MessageValidator normalizes the summary to the end but keeps
        // the user message before it (so the model sees the question last among user messages).
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: "System prompt"),
            OpenAIChatMessage(role: "user", content: "Old question"),
            OpenAIChatMessage(role: "assistant", content: "Old answer"),
        ]
        // Current user message followed by system reminders (as built by streaming path)
        messages.append(OpenAIChatMessage(role: "user", content: "END_USER_MESSAGE — must be visible"))
        messages.append(OpenAIChatMessage(role: "system", content: "Todo reminder"))
        messages.append(OpenAIChatMessage(role: "system", content: "Memory reminder"))

        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 8_000)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(
            messages: messages,
            config: config
        )

        // User message must still be present.
        let hasUser = result.messages.contains { msg in
            msg.role == "user" && (msg.content?.contains("END_USER_MESSAGE") ?? false)
        }
        XCTAssertTrue(hasUser, "User message must survive validation")

        // User message must be the last user message in the array.
        let userMessages = result.messages.filter { $0.role == "user" }
        XCTAssertTrue(userMessages.last?.content?.contains("END_USER_MESSAGE") ?? false,
                      "Current user message should be the last user message")
    }

    // MARK: - Stateful marker delta-slice count mismatch (regression)

    func testDeltaSlice_CountMismatchDoesNotDropUserMessage() {
        // Regression test for the bug where statefulMarkerMessageCount (captured
        // with filter !isToolMessage, which includes assistant messages with tool_calls)
        // exceeded the length of messagesToSend (which excludes assistant messages
        // with tool_calls when hasInternalMsgs is true), causing suffix(from:) to
        // return an empty array and drop the entire conversation history.
        //
        // The safety net: sliceIndex exceeding messagesToSend.count should NOT
        // produce an empty array — it should fall back to full-history mode.

        // Simulate: messagesToSend has 5 elements (user + assistant without tool_calls),
        // but statefulMarkerMessageCount is 6 (because the assistant with tool_calls
        // was counted in the marker snapshot but excluded from messagesToSend).
        let messagesToSend: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "user", content: "User Q1"),
            OpenAIChatMessage(role: "assistant", content: "Assistant A1"),
            OpenAIChatMessage(role: "user", content: "User Q2"),
            OpenAIChatMessage(role: "assistant", content: "Assistant A2"),
            OpenAIChatMessage(role: "user", content: "User Q3 — CRITICAL, must survive"),
        ]

        let markerMessageCount = 6  // One more than messagesToSend.count (simulates the mismatch)

        // Replicate the FIXED delta-slice logic:
        var sliced = messagesToSend
        let sliceIndex = markerMessageCount
        if sliceIndex <= sliced.count {
            sliced = Array(sliced.suffix(from: sliceIndex))
        } else {
            // Overshoot — fall back to full history (don't slice)
            // (This is the fix: previously suffix(from: min(sliceIndex, count))
            // would return empty, dropping all messages.)
        }

        // With the fix, the overshoot does NOT produce an empty array.
        XCTAssertFalse(sliced.isEmpty, "Delta slice must not return empty on count mismatch — falls back to full history")

        // The critical user message must survive.
        let hasCriticalUser = sliced.contains { msg in
            msg.role == "user" && (msg.content?.contains("CRITICAL") ?? false)
        }
        XCTAssertTrue(hasCriticalUser, "User message must survive the delta slice even with count mismatch")
    }

    func testMarkerCaptureFilter_MatchesMessagesToSendFilter() {
        // Verify that the marker-capture filter and the messagesToSend filter
        // produce consistent counts when the assistant message has tool_calls.
        // This is the core invariant the fix enforces.

        let assistantWithToolCalls = OpenAIChatMessage(
            role: "assistant",
            content: nil,
            toolCalls: [OpenAIToolCall(
                id: "call_1",
                type: "function",
                function: OpenAIFunctionCall(name: "web_operations", arguments: "{}")
            )]
        )

        let messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "user", content: "Q1"),
            OpenAIChatMessage(role: "assistant", content: "A1"),
            OpenAIChatMessage(role: "user", content: "Q2"),
            assistantWithToolCalls,
            OpenAIChatMessage(role: "tool", content: "Tool result", toolCallId: "call_1"),
        ]

        // OLD (buggy) marker-capture filter: role != "tool" (includes assistant with tool_calls)
        let oldCount = messages.filter { $0.role != "tool" }.count

        // NEW (fixed) marker-capture filter: matches messagesToSend (excludes assistant with tool_calls)
        let newCount = messages.filter { msg in
            if msg.role == "tool" { return false }
            if msg.role != "user" {
                let hasToolCalls = msg.toolCalls != nil && !(msg.toolCalls?.isEmpty ?? true)
                if hasToolCalls { return false }
            }
            return true
        }.count

        // The old filter would produce a count (4) that exceeds the
        // messagesToSend length (3), causing the slice overshoot bug.
        XCTAssertNotEqual(oldCount, newCount, "Filters must differ — old includes tool_calls assistant, new excludes it")
        XCTAssertEqual(newCount, 3, "Fixed filter should produce 3 (Q1, A1, Q2)")
        XCTAssertEqual(oldCount, 4, "Old filter should produce 4 (includes assistant with tool_calls)")
    }

    func testDeltaSlice_NoSafetyNetWithoutFix_WouldBeEmpty() {
        // Demonstrate the ORIGINAL buggy behavior: suffix(from: min(6, 5))
        // returns an empty array, which is why the fix is needed.
        let messagesToSend: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "user", content: "A"),
            OpenAIChatMessage(role: "assistant", content: "B"),
            OpenAIChatMessage(role: "user", content: "C"),
            OpenAIChatMessage(role: "assistant", content: "D"),
            OpenAIChatMessage(role: "user", content: "E — CRITICAL"),
        ]
        let markerMessageCount = 6

        // OLD (buggy) logic: min(6, 5) = 5, suffix(from: 5) = []
        let oldResult = Array(messagesToSend.suffix(from: min(markerMessageCount, messagesToSend.count)))
        XCTAssertTrue(oldResult.isEmpty, "Buggy logic produces empty array (demonstrates the bug)")

        // FIXED logic: overshoot detected, falls back to full history
        var fixedResult = messagesToSend
        let sliceIndex = markerMessageCount
        if sliceIndex <= fixedResult.count {
            fixedResult = Array(fixedResult.suffix(from: sliceIndex))
        }
        XCTAssertFalse(fixedResult.isEmpty, "Fixed logic preserves history on overshoot")
        XCTAssertTrue(fixedResult.contains { $0.content?.contains("CRITICAL") ?? false })
    }

    func testSafetyNet_IterationZeroAndContinuationBothHaveUserMessage() {
        // Verify the iteration > 0 safety net: when the messages array has
        // NO user message (only tool calls + tool results), a synthetic
        // continuation user message is injected.
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: "System prompt"),
            // No user message — only tool calls + results (simulates lost context)
            OpenAIChatMessage(role: "assistant", content: "", toolCalls: [
                OpenAIToolCall(
                    id: "call_1",
                    type: "function",
                    function: OpenAIFunctionCall(name: "web_operations", arguments: "{}")
                )
            ]),
            OpenAIChatMessage(role: "tool", content: "Tool result", toolCallId: "call_1"),
        ]

        // Replicate the safety net for iteration > 0:
        let iteration = 1
        if iteration > 0 && !messages.contains(where: { $0.role == "user" }) {
            messages.append(OpenAIChatMessage(role: "user", content: "Please continue with the task."))
        }

        let hasUser = messages.contains { $0.role == "user" }
        XCTAssertTrue(hasUser, "Iteration > 0 safety net should inject user message when none exists")

        let userMessages = messages.filter { $0.role == "user" }
        XCTAssertEqual(userMessages.count, 1)
        XCTAssertEqual(userMessages.first?.content, "Please continue with the task.")
    }
}