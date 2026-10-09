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
}