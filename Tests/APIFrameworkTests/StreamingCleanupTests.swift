// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import ConversationEngine
@testable import ConfigurationSystem

/// Regression tests for the streaming cleanup behavior added when fixing
/// the partial-message leak in cancellation/error paths.
///
/// The cleanup is exercised indirectly: these tests verify that
/// MessageBus.completeStreamingMessage flips isStreaming to false on the
/// targeted messages. The actual integration (callLLMStreaming calling
/// cleanupPartialStreamingMessages on cancel/error) is verified by the
/// full workflow tests; this file locks down the building block.
final class StreamingCleanupTests: XCTestCase {

    @MainActor
    func testCompleteStreamingMessage_ClearsIsStreamingFlag() {
        let conversation = ConversationModel()
        conversation.initializeMessageBus(conversationManager: makeStubManager())

        let id = conversation.messageBus?.addAssistantMessage(
            content: "Partial response",
            timestamp: Date(),
            isStreaming: true
        )
        XCTAssertNotNil(id)
        XCTAssertEqual(conversation.messageBus?.messages.first { $0.id == id }?.isStreaming, true)

        conversation.messageBus?.completeStreamingMessage(id: id!)

        let cleaned = conversation.messageBus?.messages.first { $0.id == id }
        XCTAssertEqual(cleaned?.isStreaming, false, "completeStreamingMessage must clear isStreaming")
        XCTAssertEqual(cleaned?.content, "Partial response", "Content must be preserved")
    }

    @MainActor
    func testCompleteStreamingMessage_PreservesAllOtherFields() {
        let conversation = ConversationModel()
        conversation.initializeMessageBus(conversationManager: makeStubManager())

        // Add a streaming message with tool_calls set (the streaming pattern
        // creates empty then updateMessage adds tool_calls).
        let id = conversation.messageBus?.addAssistantMessage(
            content: "Calling a tool",
            timestamp: Date(),
            isStreaming: true
        )
        let toolCall = ConfigurationSystem.SimpleToolCall(
            id: "call_xyz",
            type: "function",
            function: ConfigurationSystem.SimpleFunctionCall(
                name: "file_operations",
                arguments: "{\"operation\":\"read\"}"
            )
        )
        conversation.messageBus?.updateMessage(id: id!, toolCalls: [toolCall])

        conversation.messageBus?.completeStreamingMessage(id: id!)

        let cleaned = conversation.messageBus?.messages.first { $0.id == id }
        XCTAssertEqual(cleaned?.isStreaming, false)
        XCTAssertEqual(cleaned?.toolCalls?.count, 1, "Tool calls must be preserved through completeStreamingMessage")
        XCTAssertEqual(cleaned?.toolCalls?.first?.function.name, "file_operations")
    }

    @MainActor
    func testCompleteStreamingMessage_NonexistentID_DoesNotCrash() {
        let conversation = ConversationModel()
        conversation.initializeMessageBus(conversationManager: makeStubManager())

        // Should be a no-op, not a crash.
        conversation.messageBus?.completeStreamingMessage(id: UUID())
        XCTAssertEqual(conversation.messageBus?.messages.count, 0)
    }

    @MainActor
    private func makeStubManager() -> ConversationManager {
        return ConversationManager()
    }
}
