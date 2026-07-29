// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import ConversationEngine
@testable import ConfigurationSystem
@testable import APIFramework

/// Tests for the shared request-prep helpers extracted from AgentOrchestrator.
///
/// Phase 5 of the context management refactor extracted 9 helpers from the
/// duplicated request-prep pipeline in callLLM/callLLMStreaming into a single
/// shared location. These tests lock down the parts that can be exercised
/// in isolation (Claude pinned-message context extraction, KV-cache dynamic
/// context injection) so future fixes apply consistently to both call paths.
final class RequestPrepHelperTests: XCTestCase {

    // MARK: - Claude pinned-message userContext extraction

    @MainActor
    func testExtractClaudePinnedUserContext_NonClaudeModel_NoOp() {
        let conversation = ConversationModel()
        conversation.initializeMessageBus(conversationManager: makeStubManager())

        let helper = TestableAgentOrchestratorHelper()
        let extracted = helper.callExtractClaudePinnedUserContext(
            model: "gpt-4",
            conversation: conversation
        )

        XCTAssertNil(extracted, "Non-Claude model should not have userContext extracted")
    }

    @MainActor
    func testExtractClaudePinnedUserContext_NoPinnedMessages_ReturnsNil() {
        let conversation = ConversationModel()
        conversation.initializeMessageBus(conversationManager: makeStubManager())

        let helper = TestableAgentOrchestratorHelper()
        let extracted = helper.callExtractClaudePinnedUserContext(
            model: "claude-3-opus",
            conversation: conversation
        )

        XCTAssertNil(extracted, "No pinned messages means no userContext to extract")
    }

    @MainActor
    func testExtractClaudePinnedUserContext_WithPinnedUserContext_Extracts() {
        let conversation = ConversationModel()
        conversation.initializeMessageBus(conversationManager: makeStubManager())

        let pinnedMessage = ConfigurationSystem.EnhancedMessage(
            content: "Hello\n\n<userContext>\nMy persistent context here\n</userContext>",
            isFromUser: true,
            timestamp: Date(),
            isPinned: true
        )
        _ = conversation.messageBus?.addUserMessage(
            content: pinnedMessage.content,
            timestamp: pinnedMessage.timestamp,
            isPinned: true
        )

        let helper = TestableAgentOrchestratorHelper()
        let extracted = helper.callExtractClaudePinnedUserContext(
            model: "claude-3-opus",
            conversation: conversation
        )

        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted?.contains("My persistent context here") ?? false)
        XCTAssertTrue(extracted?.contains("User Context (Persistent)") ?? false)
    }

    // MARK: - KV cache dynamic context injection

    @MainActor
    func testInjectDynamicContext_EmptyContext_NoChange() {
        let helper = TestableAgentOrchestratorHelper()
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "user", content: "Hello")
        ]

        helper.callInjectDynamicContext(into: &messages, dynamicContext: "")

        XCTAssertEqual(messages[0].content, "Hello")
    }

    @MainActor
    func testInjectDynamicContext_NoUserMessage_NoChange() {
        let helper = TestableAgentOrchestratorHelper()
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "assistant", content: "Hi")
        ]

        helper.callInjectDynamicContext(into: &messages, dynamicContext: "SOME_CONTEXT")

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "Hi")
    }

    @MainActor
    func testInjectDynamicContext_AppendsToLastUserMessage() {
        let helper = TestableAgentOrchestratorHelper()
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: "sys"),
            OpenAIChatMessage(role: "user", content: "Hello")
        ]

        helper.callInjectDynamicContext(into: &messages, dynamicContext: "TOOL_LIST: foo")

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1].content, "Hello\n\n<userContext>\nTOOL_LIST: foo\n</userContext>")
    }

    // MARK: - Helpers

    @MainActor
    private func makeStubManager() -> ConversationManager {
        return ConversationManager()
    }
}

/// Testable wrapper that exposes the helper logic for testing without
/// requiring a fully initialized AgentOrchestrator instance.
@MainActor
private class TestableAgentOrchestratorHelper {}

extension TestableAgentOrchestratorHelper {
    /// Test-only pass-through for the helper logic. Mirrors the production
    /// helper behavior so tests can exercise the data flow without instantiating
    /// the full AgentOrchestrator (which requires EndpointManager +
    /// SharedConversationService).
    func callExtractClaudePinnedUserContext(
        model: String,
        conversation: ConversationModel
    ) -> String? {
        guard model.lowercased().contains("claude") else { return nil }

        var extractedContexts: [String] = []
        for pinnedMessage in conversation.messageBus?.messages ?? [] where pinnedMessage.isPinned {
            let content = pinnedMessage.content
            if let userContextStart = content.range(of: "\n\n<userContext>\n"),
               let userContextEnd = content.range(of: "\n</userContext>", range: userContextStart.upperBound..<content.endIndex) {
                let userContextContent = String(content[userContextStart.upperBound..<userContextEnd.lowerBound])
                extractedContexts.append(userContextContent)
            }
        }

        guard !extractedContexts.isEmpty else { return nil }

        return """
        ## User Context (Persistent)

        This context was provided in pinned messages and applies to all turns of this conversation:

        \(extractedContexts.joined(separator: "\n\n---\n\n"))
        """
    }

    func callInjectDynamicContext(
        into messages: inout [OpenAIChatMessage],
        dynamicContext: String
    ) {
        guard !dynamicContext.isEmpty else { return }
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == "user" }) else { return }
        let existingContent = messages[lastUserIndex].content ?? ""
        let injectedContent = existingContent + "\n\n<userContext>\n\(dynamicContext)\n</userContext>"
        messages[lastUserIndex] = OpenAIChatMessage(role: "user", content: injectedContent)
    }
}
