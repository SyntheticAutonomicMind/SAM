// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework
@testable import ConfigurationSystem

/// Regression tests for defects found in the 2026-11-05 orchestrator audit:
/// - Tool outputs must never drive session naming or workflow markers.
/// - Repeated tool_call ids must not let dedup strip newer results.
/// - Persisted reasoning must round-trip to providers that expect it.
final class OrchestratorAuditTests: XCTestCase {

    // MARK: - Helpers

    private func assistantWithToolCalls(_ ids: [String], content: String? = nil) -> OpenAIChatMessage {
        OpenAIChatMessage(
            role: "assistant",
            content: content,
            toolCalls: ids.map {
                OpenAIToolCall(id: $0, type: "function",
                               function: OpenAIFunctionCall(name: "web_operations", arguments: "{}"))
            }
        )
    }

    private func toolResult(_ id: String, content: String = "result") -> OpenAIChatMessage {
        OpenAIChatMessage(role: "tool", content: content, toolCallId: id)
    }

    private func allToolCallIds(in messages: [OpenAIChatMessage]) -> [String] {
        messages.flatMap { message -> [String] in
            var ids: [String] = []
            if message.role == "assistant", let toolCalls = message.toolCalls {
                ids.append(contentsOf: toolCalls.map { $0.id })
            }
            if message.role == "tool", let toolCallId = message.toolCallId {
                ids.append(toolCallId)
            }
            return ids
        }
    }

    // MARK: - Tool call ID renormalization

    @MainActor
    func testFreshToolCallIds_LeavesUniqueIdsAlone() {
        let existing = [assistantWithToolCalls(["call_a"]), toolResult("call_a")]
        let map = AgentOrchestrator.freshToolCallIds(for: ["call_b", "call_c"], in: existing)
        XCTAssertTrue(map.isEmpty, "no collisions means no remapping")
    }

    @MainActor
    func testFreshToolCallIds_MapsCollidingIdsToFreshUniqueIds() {
        let existing = [assistantWithToolCalls(["call_a"]), toolResult("call_a")]
        let map = AgentOrchestrator.freshToolCallIds(for: ["call_a", "call_b"], in: existing)

        XCTAssertEqual(map.count, 1, "only the colliding id is remapped")
        let fresh = try! XCTUnwrap(map["call_a"])
        XCTAssertNotEqual(fresh, "call_a")
        XCTAssertFalse(allToolCallIds(in: existing).contains(fresh), "fresh id must not collide either")
    }

    /// A model that repeats an identical call with the SAME tool_call id must
    /// not have its newer result stripped by first-occurrence-wins dedup.
    /// Renormalized pairs stay consistent and adjacent.
    @MainActor
    func testRepeatedIterationIds_RenormalizeWithoutOrphans() {
        // Iteration 1 produced this pair.
        var internalMessages = [
            assistantWithToolCalls(["call_a"], content: "first"),
            toolResult("call_a", content: "result 1")
        ]

        // Iteration 2: the model repeats the call with the same id.
        let map = AgentOrchestrator.freshToolCallIds(for: ["call_a"], in: internalMessages)
        let mapped = try! XCTUnwrap(map["call_a"])
        internalMessages.append(assistantWithToolCalls([mapped], content: ""))
        internalMessages.append(toolResult(mapped, content: "result 2"))

        // Two tool calls, two distinct ids; each id appears exactly twice
        // (its tool_call and its matching result). Pairs stay adjacent and
        // validation leaves everything in place instead of stripping.
        let ids = allToolCallIds(in: internalMessages)
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(Set(ids).count, 2, "two tool calls keep two distinct ids after renormalization")
        for id in Set(ids) {
            XCTAssertEqual(ids.filter { $0 == id }.count, 2, "each id pairs exactly one call with one result")
        }
        XCTAssertTrue(MessageValidator.hasToolResultAdjacency(internalMessages))

        let validated = MessageValidator.validateToolMessagePairs(internalMessages)
        XCTAssertEqual(validated.count, 4, "no pair may be stripped by dedup")
        XCTAssertTrue(validated.contains { $0.role == "tool" && $0.content == "result 2" },
                      "the newer result survives")
    }

    // MARK: - Reasoning round-trip

    func testConvertEnhancedToAPIMessage_PreservesReasoningContent() {
        let message = EnhancedMessage(
            content: "The answer.",
            isFromUser: false,
            timestamp: Date(),
            reasoningContent: "the model's prior reasoning"
        )

        let converted = convertEnhancedToAPIMessage(message)
        XCTAssertEqual(converted.reasoningContent, "the model's prior reasoning")
    }

    @MainActor
    func testMiniMaxMessages_WrapsPersistedReasoningIntoThinkTags() throws {
        let config = ProviderConfiguration(
            providerId: "minimax-test",
            providerType: .minimax,
            isEnabled: true,
            apiKey: "test-key",
            baseURL: "https://api.minimax.io/v1",
            models: ["MiniMax-M3.1-Flash"]
        )
        let provider = MiniMaxProvider(config: config)

        let message = OpenAIChatMessage(
            id: nil,
            role: "assistant",
            content: "The answer.",
            reasoningContent: "prior reasoning"
        )
        let built = provider.buildMiniMaxMessages(from: [message], requestId: "test-request")

        let content = try XCTUnwrap(built.first?["content"] as? String)
        XCTAssertTrue(content.hasPrefix("\n\nThe answer."),
                      "reasoning is wrapped in think tags ahead of the reply, got: \(content.prefix(60))")
    }

    @MainActor
    func testMiniMaxMessages_LeavesPlainContentUnwrapped() throws {
        let config = ProviderConfiguration(
            providerId: "minimax-test",
            providerType: .minimax,
            isEnabled: true,
            apiKey: "test-key",
            baseURL: "https://api.minimax.io/v1",
            models: ["MiniMax-M3.1-Flash"]
        )
        let provider = MiniMaxProvider(config: config)

        let message = OpenAIChatMessage(id: nil, role: "assistant", content: "Plain reply")
        let built = provider.buildMiniMaxMessages(from: [message], requestId: "test-request")

        let content = try XCTUnwrap(built.first?["content"] as? String)
        XCTAssertEqual(content, "Plain reply")
    }
}
