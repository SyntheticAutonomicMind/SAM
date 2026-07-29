// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import ConversationEngine
@testable import ConfigurationSystem

/// Tests for assistant message persistence with tool_calls.
///
/// Phase 2 of the context management refactor exposed that the non-streaming
/// orchestrator path (`AgentOrchestrator.swift:1441`) called
/// `addAssistantMessage` WITHOUT passing `toolCalls`. The streaming path
/// already does this correctly via `updateMessage(id:, toolCalls:)`.
///
/// When tool_calls are not persisted on the assistant message:
/// - On conversation reload, the model has no record of past tool usage
/// - The UI shows tool result cards but no parent assistant message linking them
/// - Reconstructed messages have orphaned tool results without their
///   assistant+tool_calls parent in the OpenAI alternation sequence
///
/// These tests check the messageBus directly (not conversation.messages)
/// because messageBus -> conversation.messages sync is throttled and
/// happens on a background Task. The messageBus IS the source of truth -
/// conversation.messages is a throttled mirror for SwiftUI rendering.
final class AssistantMessagePersistenceTests: XCTestCase {

    // MARK: - MessageBus direct checks

    @MainActor
    func testAddAssistantMessage_PreservesToolCalls() {
        let conversation = ConversationModel()
        conversation.initializeMessageBus(conversationManager: makeStubManager())

        let toolCall = ConfigurationSystem.SimpleToolCall(
            id: "call_test_123",
            type: "function",
            function: ConfigurationSystem.SimpleFunctionCall(
                name: "file_operations",
                arguments: "{\"operation\":\"read\",\"path\":\"/tmp/test.txt\"}"
            )
        )

        let messageId = conversation.messageBus?.addAssistantMessage(
            content: "I'll read that file for you.",
            timestamp: Date(),
            toolCalls: [toolCall]
        )

        XCTAssertNotNil(messageId, "addAssistantMessage should return a message ID")

        let stored = conversation.messageBus?.messages.first { $0.id == messageId }
        XCTAssertNotNil(stored, "Persisted message should be findable by ID in messageBus")
        XCTAssertEqual(stored?.toolCalls?.count, 1, "Tool calls must be preserved on the persisted message")
        XCTAssertEqual(stored?.toolCalls?.first?.id, "call_test_123")
        XCTAssertEqual(stored?.toolCalls?.first?.function.name, "file_operations")
        XCTAssertEqual(stored?.toolCalls?.first?.function.arguments, "{\"operation\":\"read\",\"path\":\"/tmp/test.txt\"}")
    }

    @MainActor
    func testUpdateMessage_AddsToolCallsToExistingMessage() {
        let conversation = ConversationModel()
        conversation.initializeMessageBus(conversationManager: makeStubManager())

        let messageId = conversation.messageBus?.addAssistantMessage(
            content: "I'll read that file for you.",
            timestamp: Date()
        )

        let toolCall = ConfigurationSystem.SimpleToolCall(
            id: "call_test_456",
            type: "function",
            function: ConfigurationSystem.SimpleFunctionCall(
                name: "web_operations",
                arguments: "{\"operation\":\"search\",\"query\":\"weather\"}"
            )
        )

        conversation.messageBus?.updateMessage(
            id: messageId!,
            toolCalls: [toolCall]
        )

        let stored = conversation.messageBus?.messages.first { $0.id == messageId }
        XCTAssertEqual(stored?.toolCalls?.count, 1)
        XCTAssertEqual(stored?.toolCalls?.first?.function.name, "web_operations")
    }

    // MARK: - Codable round-trip

    @MainActor
    func testEnhancedMessage_RoundTripsToolCallsThroughCodable() throws {
        let original = ConfigurationSystem.EnhancedMessage(
            id: UUID(),
            content: "Tool call response",
            isFromUser: false,
            timestamp: Date(),
            toolCalls: [
                ConfigurationSystem.SimpleToolCall(
                    id: "call_abc",
                    type: "function",
                    function: ConfigurationSystem.SimpleFunctionCall(
                        name: "todo_operations",
                        arguments: "{\"operation\":\"write\"}"
                    )
                ),
                ConfigurationSystem.SimpleToolCall(
                    id: "call_def",
                    type: "function",
                    function: ConfigurationSystem.SimpleFunctionCall(
                        name: "file_operations",
                        arguments: "{\"operation\":\"read\",\"path\":\"/tmp/foo\"}"
                    )
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConfigurationSystem.EnhancedMessage.self, from: data)

        XCTAssertEqual(decoded.toolCalls?.count, 2)
        XCTAssertEqual(decoded.toolCalls?[0].id, "call_abc")
        XCTAssertEqual(decoded.toolCalls?[0].function.name, "todo_operations")
        XCTAssertEqual(decoded.toolCalls?[1].id, "call_def")
        XCTAssertEqual(decoded.toolCalls?[1].function.arguments, "{\"operation\":\"read\",\"path\":\"/tmp/foo\"}")
    }

    // MARK: - Streaming pattern (the correct one)

    @MainActor
    func testStreamingPattern_AddEmptyThenUpdateWithToolCalls() {
        let conversation = ConversationModel()
        conversation.initializeMessageBus(conversationManager: makeStubManager())

        let messageId = conversation.messageBus?.addAssistantMessage(
            content: "",
            timestamp: Date(),
            isStreaming: true
        )

        conversation.messageBus?.updateStreamingMessage(id: messageId!, content: "")

        let toolCall = ConfigurationSystem.SimpleToolCall(
            id: "call_stream_1",
            type: "function",
            function: ConfigurationSystem.SimpleFunctionCall(
                name: "terminal_operations",
                arguments: "{\"command\":\"ls\"}"
            )
        )

        conversation.messageBus?.updateMessage(
            id: messageId!,
            toolCalls: [toolCall]
        )

        conversation.messageBus?.completeStreamingMessage(id: messageId!)

        let stored = conversation.messageBus?.messages.first { $0.id == messageId }
        XCTAssertEqual(stored?.toolCalls?.count, 1, "Streaming pattern must result in tool_calls on the persisted message")
        XCTAssertEqual(stored?.toolCalls?.first?.function.name, "terminal_operations")
        XCTAssertFalse(stored?.isStreaming ?? true, "Message should be marked complete")
    }

// MARK: - OpenAI alternation correctness

    /// After addAssistantMessage(toolCalls: [...]) + addToolMessage, the
    /// messageBus should produce the OpenAI-correct sequence:
    /// assistant(role=.assistant, tool_calls=[...]) -> tool(role=.tool, tool_call_id=...)
    /// This is what the LLM provider expects for proper alternation.
    @MainActor
    func testAssistantWithToolCalls_PairsCorrectlyWithToolResults() {
        let conversation = ConversationModel()
        conversation.initializeMessageBus(conversationManager: makeStubManager())

        let toolCall = ConfigurationSystem.SimpleToolCall(
            id: "call_pair_test",
            type: "function",
            function: ConfigurationSystem.SimpleFunctionCall(
                name: "file_operations",
                arguments: "{\"operation\":\"read\"}"
            )
        )

        _ = conversation.messageBus?.addAssistantMessage(
            content: "Let me read that file.",
            timestamp: Date(),
            toolCalls: [toolCall]
        )

        conversation.messageBus?.addToolMessage(
            name: "file_operations",
            status: .success,
            details: "file contents here",
            toolCallId: "call_pair_test"
        )

        let messages = conversation.messageBus?.messages ?? []
        XCTAssertEqual(messages.count, 2)

        let assistantMsg = messages[0]
        XCTAssertFalse(assistantMsg.isFromUser)
        XCTAssertEqual(assistantMsg.toolCalls?.count, 1, "Assistant message must have tool_calls")
        XCTAssertEqual(assistantMsg.toolCalls?.first?.id, "call_pair_test")
        XCTAssertEqual(assistantMsg.toolCalls?.first?.function.name, "file_operations")

        let toolMsg = messages[1]
        XCTAssertTrue(toolMsg.isToolMessage, "Tool message must be marked as tool message")
        XCTAssertEqual(toolMsg.toolCallId, "call_pair_test", "Tool message must reference the assistant's tool_call_id")
    }

    // MARK: - Duplication preservation

    /// ConversationManager.duplicateConversation() copies messages via messageBus.
    /// Must preserve tool_calls so the duplicate's tool history isn't lost.
    /// Regression guard for c2592ff.
    @MainActor
    func testDuplicateConversation_PreservesToolCallsOnAssistantMessages() {
        let source = ConversationModel()
        source.initializeMessageBus(conversationManager: makeStubManager())

        let originalToolCall = ConfigurationSystem.SimpleToolCall(
            id: "call_dup_orig",
            type: "function",
            function: ConfigurationSystem.SimpleFunctionCall(
                name: "terminal_operations",
                arguments: "{\"command\":\"ls\"}"
            )
        )

        _ = source.messageBus?.addAssistantMessage(
            content: "Let me check that file.",
            timestamp: Date(),
            toolCalls: [originalToolCall]
        )

        /// Simulate the duplication logic (the actual duplicateConversation is on
        /// ConversationManager and needs full app state to test in isolation).
        let duplicate = ConversationModel()
        duplicate.initializeMessageBus(conversationManager: makeStubManager())

        for message in source.messageBus?.messages ?? [] {
            if message.isFromUser {
                _ = duplicate.messageBus?.addUserMessage(content: message.content, timestamp: message.timestamp)
            } else {
                /// Mirrors the fix in ConversationManager.duplicateConversation.
                _ = duplicate.messageBus?.addAssistantMessage(
                    content: message.content,
                    timestamp: message.timestamp,
                    toolCalls: message.toolCalls
                )
            }
        }

        let duplicatedMessages = duplicate.messageBus?.messages ?? []
        XCTAssertEqual(duplicatedMessages.count, 1)
        XCTAssertEqual(duplicatedMessages[0].toolCalls?.count, 1, "Duplicated assistant message must keep its tool_calls")
        XCTAssertEqual(duplicatedMessages[0].toolCalls?.first?.id, "call_dup_orig")
    }

    // MARK: - Import/merge preservation

    /// ConversationImportExportService.importConversation() (merge path) copies
    /// messages via messageBus. Must preserve tool_calls on imported messages.
    /// Regression guard for c127c5e.
    @MainActor
    func testImportMerge_PreservesToolCallsOnAssistantMessages() {
        let source = ConfigurationSystem.EnhancedMessage(
            content: "Let me check that.",
            isFromUser: false,
            timestamp: Date(),
            toolCalls: [
                ConfigurationSystem.SimpleToolCall(
                    id: "call_imp_orig",
                    type: "function",
                    function: ConfigurationSystem.SimpleFunctionCall(
                        name: "file_operations",
                        arguments: "{\"operation\":\"read\"}"
                    )
                )
            ]
        )

        let target = ConversationModel()
        target.initializeMessageBus(conversationManager: makeStubManager())

        /// Mirrors the fix in ConversationImportExportService.importConversation (merge branch).
        if source.isToolMessage, let toolCallId = source.toolCallId {
            target.messageBus?.addToolMessage(
                name: source.toolName ?? "tool",
                status: source.toolStatus ?? .success,
                details: source.content,
                toolCallId: toolCallId
            )
        } else if source.isFromUser {
            target.messageBus?.addUserMessage(content: source.content, timestamp: source.timestamp)
        } else {
            target.messageBus?.addAssistantMessage(
                content: source.content,
                timestamp: source.timestamp,
                toolCalls: source.toolCalls
            )
        }

        let messages = target.messageBus?.messages ?? []
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].toolCalls?.count, 1, "Imported assistant message must keep its tool_calls")
        XCTAssertEqual(messages[0].toolCalls?.first?.id, "call_imp_orig")
    }

    // MARK: - Helper

    /// Create a ConversationManager stub for testing MessageBus without
    /// requiring a full SAM app environment.
    @MainActor
    private func makeStubManager() -> ConversationManager {
        return ConversationManager()
    }
}