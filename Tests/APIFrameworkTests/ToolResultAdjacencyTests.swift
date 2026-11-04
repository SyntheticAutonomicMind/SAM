// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework
@testable import ConfigurationSystem

/// Tests for tool_call / tool_result adjacency.
///
/// A tool result has to sit in the block that answers the assistant message
/// whose `tool_calls` requested it. Strict OpenAI-compatible providers
/// (MiniMax, Moonshot) reject the whole request when a dialog message
/// separates the two, and SAM's own unit grouping, orphan guard and payload
/// trimming all assume the same layout.
final class ToolResultAdjacencyTests: XCTestCase {

    // MARK: - Helpers

    private func assistantWithTools(_ ids: [String], name: String = "web_operations") -> OpenAIChatMessage {
        OpenAIChatMessage(
            role: "assistant",
            content: nil,
            toolCalls: ids.map {
                OpenAIToolCall(id: $0, function: OpenAIFunctionCall(name: name, arguments: "{}"))
            }
        )
    }

    private func toolResult(_ id: String, content: String = "result") -> OpenAIChatMessage {
        OpenAIChatMessage(role: "tool", content: content, toolCallId: id)
    }

    // MARK: - The shape that broke MiniMax

    /// Reproduces the message array from sam_server.log: the main system prompt,
    /// an auto-retrieval system message, the user request, an assistant with two
    /// tool calls, the two tool results, and the ephemeral "Continue working on
    /// the task" nudge appended at the end.
    ///
    /// Before the fix this array was rebuilt as `dialog + toolResults`, which
    /// pushed the tool results behind the nudge and produced the 400
    /// "invalid params, tool call result does not follow tool call (2013)".
    func testNormalizeSummaryToEnd_KeepsToolResultsWithTheirAssistant() {
        let mainSystem = OpenAIChatMessage(role: "system", content: "<instructions>\nMain prompt\n</instructions>")
        let autoContext = OpenAIChatMessage(role: "system", content: "=== AUTOMATIC CONTEXT RETRIEVAL ===")
        let userMsg = OpenAIChatMessage(role: "user", content: "provide a recipe for taco pie")
        let assistant = assistantWithTools(["call_a", "call_b"])
        let resultA = toolResult("call_a", content: "search results")
        let resultB = toolResult("call_b", content: "research results")
        let nudge = OpenAIChatMessage(role: "user", content: "<system-reminder>\nContinue working on the task.\n</system-reminder>")

        let messages = [mainSystem, autoContext, userMsg, assistant, resultA, resultB, nudge]

        let normalized = MessageValidator.normalizeSummaryToEnd(messages: messages)

        XCTAssertEqual(normalized.count, 7)

        let assistantIdx = try? XCTUnwrap(normalized.firstIndex { $0.role == "assistant" && $0.toolCalls != nil })
        let resultAIdx = normalized.firstIndex { $0.role == "tool" && $0.toolCallId == "call_a" }
        let resultBIdx = normalized.firstIndex { $0.role == "tool" && $0.toolCallId == "call_b" }

        XCTAssertNotNil(resultAIdx)
        XCTAssertNotNil(resultBIdx)
        if let assistantIdx = assistantIdx, let resultAIdx = resultAIdx, let resultBIdx = resultBIdx {
            XCTAssertEqual(resultAIdx, assistantIdx + 1,
                           "First tool result must immediately follow the assistant that requested it")
            XCTAssertEqual(resultBIdx, assistantIdx + 2,
                           "Second tool result must immediately follow the first")
        }

        XCTAssertTrue(MessageValidator.hasToolResultAdjacency(normalized),
                      "Normalized array must satisfy the tool adjacency contract")
    }

    /// The main system prompt mentions the literal `<thread_summary>` tag in its
    /// context-recovery guidance. Matching on `contains` treated the whole 42KB
    /// prompt as a summary and relocated it into the middle of the conversation.
    func testNormalizeSummaryToEnd_MainSystemPromptIsNotTreatedAsSummary() {
        let mainSystem = OpenAIChatMessage(
            role: "system",
            content: "<instructions>\n- If you see a <thread_summary> section, earlier messages were trimmed\n</instructions>"
        )
        let userMsg = OpenAIChatMessage(role: "user", content: "hello")
        let assistant = assistantWithTools(["call_a"])
        let resultA = toolResult("call_a")

        let messages = [mainSystem, userMsg, assistant, resultA]
        let normalized = MessageValidator.normalizeSummaryToEnd(messages: messages)

        XCTAssertEqual(normalized.count, 4)
        XCTAssertEqual(normalized.first?.role, "system",
                       "The main system prompt must stay at the front of the request")
        XCTAssertEqual(normalized.first?.content, mainSystem.content)
    }

    // MARK: - Thread summary detection

    func testIsThreadSummaryMessage_RequiresTagAtStart() {
        let realSummary = OpenAIChatMessage(
            role: "system",
            content: "<thread_summary>\n\nCurrent task: do the thing\n\n</thread_summary>"
        )
        let mentionsTag = OpenAIChatMessage(
            role: "system",
            content: "<instructions>\n- If you see a <thread_summary> section...\n</instructions>"
        )
        let userMessage = OpenAIChatMessage(role: "user", content: "<thread_summary>")

        XCTAssertTrue(MessageValidator.isThreadSummaryMessage(realSummary))
        XCTAssertFalse(MessageValidator.isThreadSummaryMessage(mentionsTag))
        XCTAssertFalse(MessageValidator.isThreadSummaryMessage(userMessage))
    }

    // MARK: - Enforcement

    func testEnforceToolResultAdjacency_PullsToolResultBackToItsAssistant() {
        let assistant = assistantWithTools(["call_a"])
        let userMsg = OpenAIChatMessage(role: "user", content: "Continue working on the task.")
        let resultA = toolResult("call_a")

        let broken = [assistant, userMsg, resultA]
        XCTAssertFalse(MessageValidator.hasToolResultAdjacency(broken),
                       "A dialog message between the assistant and its result breaks the contract")

        let fixed = MessageValidator.enforceToolResultAdjacency(broken)
        XCTAssertEqual(fixed.count, 3)
        XCTAssertEqual(fixed[0].role, "assistant")
        XCTAssertEqual(fixed[1].role, "tool")
        XCTAssertEqual(fixed[1].toolCallId, "call_a")
        XCTAssertEqual(fixed[2].role, "user")
        XCTAssertTrue(MessageValidator.hasToolResultAdjacency(fixed))
    }

    func testEnforceToolResultAdjacency_IsIdempotent() {
        let assistant = assistantWithTools(["call_a", "call_b"])
        let userMsg = OpenAIChatMessage(role: "user", content: "Continue working on the task.")
        let resultA = toolResult("call_a")
        let resultB = toolResult("call_b")

        let once = MessageValidator.enforceToolResultAdjacency([assistant, userMsg, resultA, resultB])
        let twice = MessageValidator.enforceToolResultAdjacency(once)

        XCTAssertEqual(once.map { $0.role }, twice.map { $0.role })
        XCTAssertEqual(once.map { $0.toolCallId }, twice.map { $0.toolCallId })
    }

    func testEnforceToolResultAdjacency_DropsOrphanToolResult() {
        let assistant = assistantWithTools(["call_a"])
        let orphan = toolResult("call_orphan")

        let fixed = MessageValidator.enforceToolResultAdjacency([assistant, orphan])

        XCTAssertEqual(fixed.count, 1)
        XCTAssertEqual(fixed[0].role, "assistant")
    }

    func testEnforceToolResultAdjacency_NoToolMessages_ReturnsUnchanged() {
        let messages = [
            OpenAIChatMessage(role: "system", content: "prompt"),
            OpenAIChatMessage(role: "user", content: "hello"),
            OpenAIChatMessage(role: "assistant", content: "hi")
        ]
        XCTAssertEqual(MessageValidator.enforceToolResultAdjacency(messages).count, 3)
    }

    func testHasToolResultAdjacency_IgnoresToolCallsWithoutResults() {
        // An assistant whose tool call has no result yet is not a violation —
        // the result arrives with the next request.
        let assistant = assistantWithTools(["call_a"])
        let userMsg = OpenAIChatMessage(role: "user", content: "hello")
        XCTAssertTrue(MessageValidator.hasToolResultAdjacency([assistant, userMsg]))
    }

    // MARK: - Trim path

    /// When the context is over budget the trim path runs its own budget walk
    /// and assembles the result separately. It has to preserve adjacency too.
    func testValidateAndTruncateWithDropped_OverBudget_KeepsToolResultsAdjacent() {
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: "You are helpful.")
        ]
        for i in 0..<12 {
            messages.append(OpenAIChatMessage(role: "user", content: "Request number \(i) with a reasonably long body so the budget walk has something to chew on."))
            messages.append(assistantWithTools(["call_\(i)"]))
            messages.append(toolResult("call_\(i)", content: String(repeating: "tool output ", count: 200)))
            messages.append(OpenAIChatMessage(role: "assistant", content: "Reply number \(i)"))
        }

        let caps = ContextCapabilities(contextWindow: 4_000, maxOutputTokens: 1_000)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(messages: messages, config: config)

        XCTAssertTrue(
            MessageValidator.hasToolResultAdjacency(result.messages),
            "Trimmed context must keep every tool result next to its assistant"
        )
    }

    // MARK: - Continuation prompt filtering

    /// A model that calls a tool without saying anything alongside it produces
    /// an assistant message with no content. That message is structurally
    /// required — dropping it orphans the tool results, which are then dropped
    /// too, and the model never sees what its tools returned.
    func testFilterContinuationPrompts_KeepsToolCallMessages() {
        let assistant = assistantWithTools(["call_a"])
        let resultA = toolResult("call_a")

        let filtered = MessageValidator.filterContinuationPrompts([
            OpenAIChatMessage(role: "system", content: "prompt"),
            OpenAIChatMessage(role: "user", content: "Find the recipe"),
            assistant,
            resultA
        ])

        XCTAssertEqual(filtered.count, 4, "Tool call and tool result messages must survive")
        XCTAssertTrue(filtered.contains { $0.role == "assistant" && $0.toolCalls != nil })
        XCTAssertTrue(filtered.contains { $0.role == "tool" && $0.toolCallId == "call_a" })
    }

    func testFilterContinuationPrompts_DropsTrivialContinuationPrompts() {
        let filtered = MessageValidator.filterContinuationPrompts([
            OpenAIChatMessage(role: "user", content: "Continue"),
            OpenAIChatMessage(role: "user", content: "ok"),
            OpenAIChatMessage(role: "user", content: "Do the thing")
        ])

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.content, "Do the thing")
    }

    /// End to end through the validator: a tool-only assistant message and its
    /// result have to reach the provider intact.
    func testValidateAndTruncateWithDropped_KeepsToolOnlyAssistantMessage() {
        let messages = [
            OpenAIChatMessage(role: "system", content: "You are helpful."),
            OpenAIChatMessage(role: "user", content: "Find the recipe"),
            assistantWithTools(["call_a"]),
            toolResult("call_a", content: "Found the recipe")
        ]

        let config = TrimConfig(caps: ContextCapabilities(contextWindow: 100_000), tokenRatio: 4.0)
        let result = MessageValidator.validateAndTruncateWithDropped(messages: messages, config: config)

        XCTAssertTrue(result.messages.contains { $0.role == "assistant" && $0.toolCalls != nil },
                      "Assistant message with tool calls must survive validation")
        XCTAssertTrue(result.messages.contains { $0.role == "tool" && $0.toolCallId == "call_a" },
                      "Tool result must survive validation")
        XCTAssertTrue(MessageValidator.hasToolResultAdjacency(result.messages))
    }

    /// End to end through the validator: the exact request that MiniMax
    /// rejected. The main system prompt mentions `<thread_summary>` in its
    /// context-recovery guidance, so it used to be mistaken for a summary and
    /// pulled out of position 0 — which also dragged the tool results out of
    /// their block and produced the 400.
    func testValidateAndTruncateWithDropped_MiniMaxRequestShapeSurvivesIntact() {
        let mainSystem = OpenAIChatMessage(
            role: "system",
            content: "<instructions>\n- If you see a <thread_summary> section, earlier messages were trimmed\n</instructions>"
        )
        let autoContext = OpenAIChatMessage(role: "system", content: "=== AUTOMATIC CONTEXT RETRIEVAL ===")
        let userMsg = OpenAIChatMessage(role: "user", content: "provide a recipe for taco pie")
        let assistant = assistantWithTools(["call_a", "call_b"])
        let resultA = toolResult("call_a", content: "search results")
        let resultB = toolResult("call_b", content: "research results")
        let nudge = OpenAIChatMessage(role: "user", content: "<system-reminder>\nContinue working on the task.\n</system-reminder>")

        let messages = [mainSystem, autoContext, userMsg, assistant, resultA, resultB, nudge]

        let config = TrimConfig(caps: ContextCapabilities(contextWindow: 1_000_000, maxOutputTokens: 8_000), tokenRatio: 4.0)
        let result = MessageValidator.validateAndTruncateWithDropped(messages: messages, config: config)

        XCTAssertEqual(result.messages.count, 7)

        // The main system prompt stays first — it is the stable cache prefix.
        XCTAssertEqual(result.messages.first?.role, "system")
        XCTAssertEqual(result.messages.first?.content, mainSystem.content)

        // The tool results stay inside the assistant's block.
        let assistantIdx = result.messages.firstIndex { $0.role == "assistant" && $0.toolCalls != nil }
        let resultAIdx = result.messages.firstIndex { $0.role == "tool" && $0.toolCallId == "call_a" }
        let resultBIdx = result.messages.firstIndex { $0.role == "tool" && $0.toolCallId == "call_b" }
        XCTAssertNotNil(assistantIdx)
        XCTAssertNotNil(resultAIdx)
        XCTAssertNotNil(resultBIdx)
        if let assistantIdx = assistantIdx, let resultAIdx = resultAIdx, let resultBIdx = resultBIdx {
            XCTAssertEqual(resultAIdx, assistantIdx + 1)
            XCTAssertEqual(resultBIdx, assistantIdx + 2)
        }

        XCTAssertTrue(MessageValidator.hasToolResultAdjacency(result.messages))
    }

    // MARK: - MiniMax wire format

    /// MiniMax rejects the request outright when a tool result is not
    /// immediately preceded by its assistant message, so the provider has to
    /// enforce the ordering itself rather than trusting the caller.
    @MainActor
    func testMiniMaxMessages_KeepsToolResultsAdjacentToAssistant() {
        let config = ProviderConfiguration(
            providerId: "minimax-test",
            providerType: .minimax,
            isEnabled: true,
            apiKey: "test-key",
            baseURL: "https://api.minimax.io/v1",
            models: ["MiniMax-M3.1-Flash"]
        )
        let provider = MiniMaxProvider(config: config)

        let assistant = assistantWithTools(["call_a", "call_b"])
        let userMsg = OpenAIChatMessage(role: "user", content: "Continue working on the task.")
        let resultA = toolResult("call_a", content: "search results")
        let resultB = toolResult("call_b", content: "research results")

        let built = provider.buildMiniMaxMessages(
            from: [assistant, userMsg, resultA, resultB],
            requestId: "test-request"
        )

        let roles = built.map { $0["role"] as? String ?? "" }
        XCTAssertEqual(roles, ["assistant", "tool", "tool", "user"])

        let toolCallIds = built.compactMap { $0["tool_call_id"] as? String }
        XCTAssertEqual(toolCallIds, ["call_a", "call_b"])
    }

    /// MiniMax accepts only one system message and it must be first.
    @MainActor
    func testMiniMaxMessages_ConsolidatesSystemMessagesFirst() {
        let config = ProviderConfiguration(
            providerId: "minimax-test",
            providerType: .minimax,
            isEnabled: true,
            apiKey: "test-key",
            baseURL: "https://api.minimax.io/v1",
            models: ["MiniMax-M3.1-Flash"]
        )
        let provider = MiniMaxProvider(config: config)

        let built = provider.buildMiniMaxMessages(
            from: [
                OpenAIChatMessage(role: "system", content: "main prompt"),
                OpenAIChatMessage(role: "system", content: "auto context"),
                OpenAIChatMessage(role: "user", content: "hello")
            ],
            requestId: "test-request"
        )

        XCTAssertEqual(built.count, 2)
        XCTAssertEqual(built.first?["role"] as? String, "system")
        XCTAssertTrue((built.first?["content"] as? String ?? "").contains("main prompt"))
        XCTAssertTrue((built.first?["content"] as? String ?? "").contains("auto context"))
        XCTAssertEqual(built.last?["role"] as? String, "user")
    }
}
