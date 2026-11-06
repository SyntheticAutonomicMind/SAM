// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework

/// Replays the exact request assembled in sam_server.log on 2026-11-04 10:50:39
/// (conversation E4717610, "taco pie", iteration 2) through the production trim
/// path, so the shape that reached MiniMax is pinned by a test.
///
/// That log run showed two defects at once: the tool results separated from
/// their assistant (the 2013 rejection), and the assistant message carrying the
/// tool's own 8.9 KB JSON output as its content. The adjacency fix addresses
/// the first; the second is produced by the workflow layer and cannot be
/// repaired downstream, so this test documents what the trim path does with
/// each shape.
final class WireShapeAuditTests: XCTestCase {

    private func logInput(pollutedAssistantContent: String? = nil) -> [OpenAIChatMessage] {
        let mainPrompt = OpenAIChatMessage(
            role: "system",
            content: "<instructions>\n" + String(repeating: "x", count: 42_384)
        )
        let autoRetrieval = OpenAIChatMessage(
            role: "system",
            content: "=== AUTOMATIC CONTEXT RETRIEVAL ===\ncontext"
        )
        let user = OpenAIChatMessage(
            role: "user",
            content: "provide a recipe for taco pie\n\n<userContext>\n**User:** Angie"
        )
        let assistant = OpenAIChatMessage(
            role: "assistant",
            content: pollutedAssistantContent,
            toolCalls: [
                OpenAIToolCall(id: "call_01a1a7410baf7745ae8f160b", type: "function",
                               function: OpenAIFunctionCall(name: "web_operations", arguments: "{\"query\":\"taco pie\"}")),
                OpenAIToolCall(id: "call_01a1a7410c1b74deb935e869", type: "function",
                               function: OpenAIFunctionCall(name: "web_operations", arguments: "{\"query\":\"taco pie ingredients\"}"))
            ]
        )
        let result1 = OpenAIChatMessage(role: "tool", content: "{ small result }",
                                        toolCallId: "call_01a1a7410baf7745ae8f160b")
        let result2 = OpenAIChatMessage(role: "tool", content: "{ large result }",
                                        toolCallId: "call_01a1a7410c1b74deb935e869")
        let reminder = OpenAIChatMessage(
            role: "user",
            content: "<system-reminder>\nContinue working on the task.\n</system-reminder>"
        )
        return [mainPrompt, autoRetrieval, user, assistant, result1, result2, reminder]
    }

    /// Clean shape: the tool results must stay immediately after their
    /// assistant and the 42 KB main prompt must stay at the front of the
    /// array. Before the adjacency fix the results landed behind the nudge.
    func testCleanShape_KeepsAdjacencyAndPromptFirst() {
        let caps = ContextCapabilities(contextWindow: 1_048_576, maxOutputTokens: 131_072)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(messages: logInput(), config: config)

        XCTAssertEqual(result.messages.count, 7)
        XCTAssertEqual(result.messages.first?.role, "system")
        XCTAssertTrue(result.messages[0].content?.hasPrefix("<instructions>") ?? false)

        let assistantIdx = result.messages.firstIndex { $0.role == "assistant" } ?? -1
        XCTAssertNotEqual(assistantIdx, -1)
        XCTAssertEqual(result.messages[assistantIdx + 1].role, "tool")
        XCTAssertEqual(result.messages[assistantIdx + 1].toolCallId, "call_01a1a7410baf7745ae8f160b")
        XCTAssertEqual(result.messages[assistantIdx + 2].role, "tool")
        XCTAssertEqual(result.messages[assistantIdx + 2].toolCallId, "call_01a1a7410c1b74deb935e869")
        XCTAssertEqual(result.messages.last?.role, "user")
        XCTAssertTrue(MessageValidator.hasToolResultAdjacency(result.messages))
    }

    /// The log-confirmed pollution: the assistant carried the tool's raw JSON
    /// output as content. The trim path passes content through untouched - the
    /// pollution has to be fixed where it is created (the workflow layer), so
    /// this test pins that the validator does not silently "repair" or drop
    /// the content, keeping the wire faithful to what upstream produced.
    func testPollutedShape_ContentIsPassedThroughUntouched() {
        let polluted = "{\n  \"topic\" : \"taco pie recipe\"" + String(repeating: "y", count: 8_900)
        let caps = ContextCapabilities(contextWindow: 1_048_576, maxOutputTokens: 131_072)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(
            messages: logInput(pollutedAssistantContent: polluted),
            config: config
        )

        let assistant = result.messages.first { $0.role == "assistant" }
        XCTAssertEqual(assistant?.content, polluted)
        XCTAssertTrue(MessageValidator.hasToolResultAdjacency(result.messages))
    }
}
