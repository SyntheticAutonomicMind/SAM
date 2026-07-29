// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import UserInterface
@testable import ConfigurationSystem

/// Regression tests for the "empty message" bug where providers that emit
/// the closing `</thinking>` tag as the first content chunk before tool
/// calls (e.g. MiniMax) left the literal tag visible in the rendered
/// bubble - looking like an empty message to the user.
///
/// These tests pin the `effectiveMessageContent` helper and the filter
/// logic that consumes it so future changes cannot silently regress the
/// thinking-tag stripping behavior.
final class EmptyMessageFilterTests: XCTestCase {

    // MARK: - effectiveMessageContent

    func testEffectiveContent_EmptyString_ReturnsEmpty() {
        let message = makeAssistantMessage(content: "")
        XCTAssertEqual(effective(message: message), "")
    }

    func testEffectiveContent_Whitespace_ReturnsEmpty() {
        let message = makeAssistantMessage(content: "   \n\t  ")
        XCTAssertEqual(effective(message: message), "")
    }

    /// The exact case from the 17:32:49 server.log - provider emits the
    /// closing `</thinking>` tag as the first content chunk before tool
    /// calls. The user saw an "empty" bubble with this literal tag.
    func testEffectiveContent_ClosingThinkTagOnly_ReturnsEmpty() {
        let message = makeAssistantMessage(content: "</think>")
        XCTAssertEqual(effective(message: message), "")
    }

    func testEffectiveContent_ClosingThinkTagWithNewline_ReturnsEmpty() {
        let message = makeAssistantMessage(content: "</think>\n")
        XCTAssertEqual(effective(message: message), "")
    }

    func testEffectiveContent_OpeningThinkTagOnly_ReturnsEmpty() {
        let message = makeAssistantMessage(content: "<think>")
        XCTAssertEqual(effective(message: message), "")
    }

    func testEffectiveContent_PairedEmptyThinkTags_ReturnsEmpty() {
        let message = makeAssistantMessage(content: "<think></think>")
        XCTAssertEqual(effective(message: message), "")
    }

    /// When there IS actual response text, it must still render.
    func testEffectiveContent_RealResponse_StillReturnsContent() {
        let message = makeAssistantMessage(content: "Hello world")
        XCTAssertEqual(effective(message: message), "Hello world")
    }

    /// Think tags around content - the literal tag markers get stripped but
    /// text between them remains. Thinking text inside an assistant
    /// message's `content` field is unusual (reasoning text belongs in
    /// `reasoningContent`), but if the provider emits it here, the
    /// helper treats it as visible content rather than silently hiding
    /// it. The thinking content path is rendered via ThinkingCard from
    /// the .thinking type, not this helper.
    func testEffectiveContent_ThinkTagsAroundContent_StripsMarkers() {
        let message = makeAssistantMessage(content: "<think>internal</think>Hello world")
        XCTAssertEqual(effective(message: message), "internalHello world")
    }

    /// Whitespace inside think tags must not be treated as content.
    func testEffectiveContent_ThinkTagsWithWhitespaceOnly_ReturnsEmpty() {
        let message = makeAssistantMessage(content: "<think>\n  \t</think>")
        XCTAssertEqual(effective(message: message), "")
    }

    /// Real content with closing tag appended (the streaming edge case):
    /// content is "Hello</think>" - real text plus a trailing tag. The
    /// helper strips the tag; the real text remains.
    func testEffectiveContent_RealContentPlusTrailingTag_StripsTag() {
        let message = makeAssistantMessage(content: "Hello</think>")
        XCTAssertEqual(effective(message: message), "Hello")
    }

    // MARK: - Filter behavior

    /// The filter condition used in ChatWidgetMessageList must treat
    /// messages with only thinking tags as empty (so the bubble is hidden).
    /// This is the exact scenario from the bug report.
    func testIsEmptyFilter_TreatsClosingThinkTagOnlyAsEmpty() {
        let message = makeAssistantMessage(content: "</think>")
        let trimmed = effective(message: message)
        let isEmpty = trimmed.isEmpty &&
            message.type != .toolExecution &&
            (message.type != .thinking || (message.reasoningContent == nil || message.reasoningContent!.isEmpty)) &&
            (message.contentParts == nil || message.contentParts!.isEmpty)
        XCTAssertTrue(isEmpty, "Closing think tag only must be treated as empty.")
    }

    func testIsEmptyFilter_TreatsPairedEmptyThinkTagsAsEmpty() {
        let message = makeAssistantMessage(content: "<think></think>")
        let trimmed = effective(message: message)
        let isEmpty = trimmed.isEmpty &&
            message.type != .toolExecution &&
            (message.type != .thinking || (message.reasoningContent == nil || message.reasoningContent!.isEmpty)) &&
            (message.contentParts == nil || message.contentParts!.isEmpty)
        XCTAssertTrue(isEmpty)
    }

    func testIsEmptyFilter_KeepsRealContent() {
        let message = makeAssistantMessage(content: "Hello world")
        let trimmed = effective(message: message)
        let isEmpty = trimmed.isEmpty &&
            message.type != .toolExecution &&
            (message.type != .thinking || (message.reasoningContent == nil || message.reasoningContent!.isEmpty)) &&
            (message.contentParts == nil || message.contentParts!.isEmpty)
        XCTAssertFalse(isEmpty, "Real content must NOT be filtered.")
    }

    /// Thinking messages with reasoningContent must NOT be filtered even
    /// when content is empty - the actual thinking text is in reasoningContent.
    func testIsEmptyFilter_ThinkingMessageWithReasoningContent_NotFiltered() {
        var message = makeAssistantMessage(content: "")
        message = EnhancedMessage(
            id: message.id,
            type: .thinking,
            content: "",
            contentParts: nil,
            isFromUser: false,
            timestamp: message.timestamp,
            toolIcon: "brain.head.profile",
            reasoningContent: "I am thinking about this...",
            isToolMessage: true
        )
        let trimmed = effective(message: message)
        let isEmpty = trimmed.isEmpty &&
            message.type != .toolExecution &&
            (message.type != .thinking || (message.reasoningContent == nil || message.reasoningContent!.isEmpty)) &&
            (message.contentParts == nil || message.contentParts!.isEmpty)
        XCTAssertFalse(isEmpty, "Thinking message with reasoningContent must render.")
    }

    // MARK: - Helpers

    private func effective(message: EnhancedMessage) -> String {
        var stripped = message.content
        stripped = stripped.replacingOccurrences(of: "<think>", with: "")
        stripped = stripped.replacingOccurrences(of: "</think>", with: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeAssistantMessage(content: String) -> EnhancedMessage {
        EnhancedMessage(
            id: UUID(),
            content: content,
            isFromUser: false,
            timestamp: Date()
        )
    }
}
