// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import ConversationEngine
@testable import ConfigurationSystem

@MainActor
final class ContextArchiveDurableThreadTests: XCTestCase {

    // MARK: - Durable Thread Storage

    func testStoreAndRetrieveDurableThread() async throws {
        let manager = ContextArchiveManager()
        let convId = UUID()

        let messages = [
            makeEnhancedMessage(content: "What is the capital of France?", isFromUser: true, toolCallId: nil),
            makeEnhancedMessage(content: "The capital of France is Paris.", isFromUser: false, toolCallId: nil),
            makeEnhancedMessage(content: "What about Germany?", isFromUser: true, toolCallId: nil),
        ]

        try await manager.storeDurableThread(messages: messages, conversationId: convId, turnNumber: 0)

        let recovered = try await manager.recoverLastMessages(conversationId: convId, limit: 10)
        XCTAssertEqual(recovered.count, 3)
        XCTAssertEqual(recovered[0].content, "What is the capital of France?")
        XCTAssertEqual(recovered[0].isFromUser, true)
        XCTAssertEqual(recovered[1].content, "The capital of France is Paris.")
        XCTAssertEqual(recovered[1].isFromUser, false)
    }

    func testRecoverSubstantiveTask() async throws {
        let manager = ContextArchiveManager()
        let convId = UUID()

        // Short message should not be recovered as the task
        let messages = [
            makeEnhancedMessage(content: "Hi", isFromUser: true, toolCallId: nil),
            makeEnhancedMessage(content: "Hello!", isFromUser: false, toolCallId: nil),
            makeEnhancedMessage(
                content: "Investigate the context management gaps between CLIO and SAM",
                isFromUser: true, toolCallId: nil
            ),
        ]

        try await manager.storeDurableThread(messages: messages, conversationId: convId, turnNumber: 0)

        let task = try await manager.recoverSubstantiveTask(conversationId: convId)
        XCTAssertEqual(task, "Investigate the context management gaps between CLIO and SAM")
    }

    func testRecoverSubstantiveTask_NoSubstantiveMessage() async throws {
        let manager = ContextArchiveManager()
        let convId = UUID()

        let messages = [
            makeEnhancedMessage(content: "Hi", isFromUser: true, toolCallId: nil),
        ]

        try await manager.storeDurableThread(messages: messages, conversationId: convId, turnNumber: 0)

        let task = try await manager.recoverSubstantiveTask(conversationId: convId)
        XCTAssertNil(task, "No substantive task should be found for very short messages")
    }

    func testStoreDurableThread_MultipleTurns() async throws {
        let manager = ContextArchiveManager()
        let convId = UUID()

        let turn0 = [
            makeEnhancedMessage(content: "First question", isFromUser: true, toolCallId: nil),
            makeEnhancedMessage(content: "First answer", isFromUser: false, toolCallId: nil),
        ]
        let turn1 = [
            makeEnhancedMessage(content: "Second question", isFromUser: true, toolCallId: nil),
            makeEnhancedMessage(content: "Second answer", isFromUser: false, toolCallId: nil),
        ]

        try await manager.storeDurableThread(messages: turn0, conversationId: convId, turnNumber: 0)
        try await manager.storeDurableThread(messages: turn1, conversationId: convId, turnNumber: 1)

        let recovered = try await manager.recoverLastMessages(conversationId: convId, limit: 10)
        XCTAssertEqual(recovered.count, 4)
        XCTAssertEqual(recovered[0].content, "First question")
        XCTAssertEqual(recovered[2].content, "Second question")
    }

    func testRecoverLastMessages_RespectsLimit() async throws {
        let manager = ContextArchiveManager()
        let convId = UUID()

        var messages: [EnhancedMessage] = []
        for i in 0..<10 {
            messages.append(makeEnhancedMessage(content: "Message \(i)", isFromUser: true, toolCallId: nil))
        }

        try await manager.storeDurableThread(messages: messages, conversationId: convId, turnNumber: 0)

        let recovered = try await manager.recoverLastMessages(conversationId: convId, limit: 3)
        XCTAssertEqual(recovered.count, 3)
        XCTAssertEqual(recovered[0].content, "Message 7")
        XCTAssertEqual(recovered[2].content, "Message 9")
    }

    // MARK: - Helpers

    private func makeEnhancedMessage(content: String, isFromUser: Bool, toolCallId: String?) -> EnhancedMessage {
        if isFromUser {
            return EnhancedMessage(content: content, isFromUser: true)
        } else if let tcId = toolCallId {
            return EnhancedMessage(content: content, isFromUser: false, toolCallId: tcId)
        } else {
            return EnhancedMessage(content: content, isFromUser: false)
        }
    }
}
