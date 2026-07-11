// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework

/// Tests for the MessageValidator - the core of SAM's context management.
/// These tests verify that the CLIO sync port behaves correctly:
/// - Atomic unit grouping keeps tool_calls and tool_results together
/// - Tool pair validation strips orphans in both directions
/// - Thread summary compression produces structured output
/// - Previous summary is parsed and merged across cycles
final class MessageValidatorTests: XCTestCase {

    // MARK: - Tool Pair Validation

    func testValidateToolMessagePairs_NoOrphans_ReturnsUnchanged() {
        let messages = [
            OpenAIChatMessage(role: "user", content: "Search for cats"),
            OpenAIChatMessage(
                role: "assistant",
                content: nil,
                toolCalls: [
                    OpenAIToolCall(id: "tc1", function: OpenAIFunctionCall(name: "search", arguments: "{}"))
                ]
            ),
            OpenAIChatMessage(role: "tool", content: "Result", toolCallId: "tc1"),
            OpenAIChatMessage(role: "assistant", content: "Found 3 cats")
        ]

        let validated = MessageValidator.validateToolMessagePairs(messages)

        XCTAssertEqual(validated.count, 4)
        XCTAssertEqual(validated[2].content, "Result")
        XCTAssertEqual(validated[2].toolCallId, "tc1")
    }

    func testValidateToolMessagePairs_OrphanToolResult_Removed() {
        let messages = [
            OpenAIChatMessage(role: "user", content: "Hello"),
            OpenAIChatMessage(role: "tool", content: "Old result", toolCallId: "missing_tc")
        ]

        let validated = MessageValidator.validateToolMessagePairs(messages)

        XCTAssertEqual(validated.count, 1)
        XCTAssertEqual(validated[0].role, "user")
    }

    func testValidateToolMessagePairs_OrphanToolCall_StrippedFromAssistant() {
        let messages = [
            OpenAIChatMessage(role: "user", content: "Search"),
            OpenAIChatMessage(
                role: "assistant",
                content: "I'll search",
                toolCalls: [
                    OpenAIToolCall(id: "tc_orphan", function: OpenAIFunctionCall(name: "search", arguments: "{}")),
                    OpenAIToolCall(id: "tc_valid", function: OpenAIFunctionCall(name: "read", arguments: "{}"))
                ]
            ),
            OpenAIChatMessage(role: "tool", content: "Valid result", toolCallId: "tc_valid")
        ]

        let validated = MessageValidator.validateToolMessagePairs(messages)

        XCTAssertEqual(validated.count, 3)
        let assistantCalls = validated[1].toolCalls
        XCTAssertNotNil(assistantCalls)
        XCTAssertEqual(assistantCalls?.count, 1)
        XCTAssertEqual(assistantCalls?.first?.id, "tc_valid")
    }

    func testValidateToolMessagePairs_MisorderedToolResult_Removed() {
        // Tool result that precedes its tool_call is invalid
        let messages = [
            OpenAIChatMessage(role: "tool", content: "Result", toolCallId: "tc1"),
            OpenAIChatMessage(
                role: "assistant",
                content: nil,
                toolCalls: [
                    OpenAIToolCall(id: "tc1", function: OpenAIFunctionCall(name: "search", arguments: "{}"))
                ]
            )
        ]

        let validated = MessageValidator.validateToolMessagePairs(messages)

        // The misordered tool_result should be removed
        let toolResults = validated.filter { $0.role == "tool" }
        XCTAssertEqual(toolResults.count, 0)
    }

    // MARK: - Token Estimation

    func testEstimateTokens_BasicContent() {
        let messages = [
            OpenAIChatMessage(role: "user", content: "Hello world"),
            OpenAIChatMessage(role: "assistant", content: "Hi there!")
        ]
        let tokens = MessageValidator.estimateTokens(messages)
        // Each message has 4 base overhead + content/4 = 4 + 11/4 = ~7 for "Hello world"
        // Total: 4 + 3 + 4 + 3 = ~14
        XCTAssertGreaterThan(tokens, 10)
        XCTAssertLessThan(tokens, 25)
    }

    func testEstimateTokens_ToolCallCounted() {
        let messages = [
            OpenAIChatMessage(
                role: "assistant",
                content: nil,
                toolCalls: [
                    OpenAIToolCall(id: "tc1", function: OpenAIFunctionCall(name: "search", arguments: "{\"query\":\"cats\"}"))
                ]
            )
        ]
        let tokens = MessageValidator.estimateTokens(messages)
        XCTAssertGreaterThan(tokens, 4)
    }

    // MARK: - validateAndTruncate

    func testValidateAndTruncate_WithinBudget_ReturnsValidated() {
        let messages = [
            OpenAIChatMessage(role: "user", content: "Hello"),
            OpenAIChatMessage(role: "assistant", content: "Hi there")
        ]

        let result = MessageValidator.validateAndTruncate(
            messages: messages,
            maxPromptTokens: 100000
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].role, "user")
    }

    func testValidateAndTruncate_EmptyMessages_ReturnsEmpty() {
        let result = MessageValidator.validateAndTruncate(
            messages: [],
            maxPromptTokens: 100000
        )
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - Thread Summary Compression

    func testCompressDropped_ExtractsUserRequests() {
        let assistantMsg = OpenAIChatMessage(role: "assistant", content: "OK")
        let droppedUnit = MessageValidator.MessageUnit(
            messages: [assistantMsg],
            tokens: 10,
            toolCallIds: [],
            isOrphanToolResult: false,
            orphanToolId: nil
        )
        let userRequest = OpenAIChatMessage(role: "user", content: "Implement the long-context message validator for SAM with atomic unit grouping and thread_summary compression")

        let dropped = MessageUnit_with([userRequest], toolCallIds: [])
        _ = droppedUnit  // silence unused

        let summary = MessageValidator.compressDropped(
            [dropped],
            lastUserUnit: nil,
            previousSummary: ""
        )

        XCTAssertTrue(summary.content?.contains("<thread_summary>") ?? false)
        XCTAssertTrue(summary.content?.contains("Current task:") ?? false)
    }

    func testCompressDropped_PreservesFirstUserRequestWhenManyRequests() {
        var units: [MessageValidator.MessageUnit] = []
        for i in 0..<10 {
            let msg = OpenAIChatMessage(role: "user", content: "User request number \(i) with substantive content that should be preserved in the summary as the task context for this conversation")
            units.append(MessageUnit_with([msg], toolCallIds: []))
        }

        let summary = MessageValidator.compressDropped(
            units,
            lastUserUnit: nil,
            previousSummary: ""
        )

        // First user request should be preserved with "[original]" prefix
        XCTAssertTrue(summary.content?.contains("[original]") ?? false,
                      "First user request should be preserved with [original] marker when there are many requests")
        XCTAssertTrue(summary.content?.contains("User request number 0") ?? false)
    }

    func testCompressDropped_ExtractsToolCounts() {
        let toolCalls = (0..<3).map { i in
            OpenAIToolCall(id: "tc\(i)", function: OpenAIFunctionCall(name: "file_operations", arguments: "{}"))
        }
        let assistant = OpenAIChatMessage(role: "assistant", content: nil, toolCalls: toolCalls)
        let dropped = MessageUnit_with([assistant], toolCallIds: Set(toolCalls.map { $0.id }))

        let summary = MessageValidator.compressDropped(
            [dropped],
            lastUserUnit: nil,
            previousSummary: ""
        )

        XCTAssertTrue(summary.content?.contains("Tool usage:") ?? false)
        XCTAssertTrue(summary.content?.contains("file_operations") ?? false)
        XCTAssertTrue(summary.content?.contains("3 calls") ?? false)
    }

    func testCompressDropped_ExtractsGitCommits() {
        let toolCall = OpenAIToolCall(id: "tc1", function: OpenAIFunctionCall(name: "terminal_operations", arguments: "{}"))
        let assistant = OpenAIChatMessage(role: "assistant", content: nil, toolCalls: [toolCall])
        let result = OpenAIChatMessage(role: "tool", content: "[abc1234] Add message validator for context trimming", toolCallId: "tc1")
        let dropped = MessageUnit_with([assistant, result], toolCallIds: ["tc1"])

        let summary = MessageValidator.compressDropped(
            [dropped],
            lastUserUnit: nil,
            previousSummary: ""
        )

        XCTAssertTrue(summary.content?.contains("Git commits") ?? false)
        XCTAssertTrue(summary.content?.contains("abc1234") ?? false)
        XCTAssertTrue(summary.content?.contains("Add message validator") ?? false)
    }

    // MARK: - Previous Summary Parse-and-Merge

    func testParsePreviousSummary_AccumulatesAcrossCycles() {
        let firstSummary = """
        <thread_summary>

        Git commits made during compressed period:
        - abc1234: First commit
        - def5678: Second commit

        Files created/modified:
        - Sources/APIFramework/MessageValidator.swift

        Tool usage:
        - file_operations: 5 calls

        </thread_summary>
        """

        var commits: [String] = []
        var files: [String] = []
        var decisions: [String] = []
        var tools: [String: Int] = [:]

        MessageValidator.parsePreviousSummary(
            firstSummary,
            commits: &commits,
            filesModified: &files,
            decisions: &decisions,
            toolsUsed: &tools
        )

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0], "abc1234: First commit")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0], "Sources/APIFramework/MessageValidator.swift")
        XCTAssertEqual(tools["file_operations"], 5)
    }

    func testCompressDropped_MergesWithPreviousSummary() {
        let previousSummary = """
        <thread_summary>

        Git commits made during compressed period:
        - abc1234: Existing commit

        Tool usage:
        - file_operations: 3 calls

        </thread_summary>
        """

        let newCommit = OpenAIChatMessage(role: "tool", content: "[def5678] New commit during this cycle", toolCallId: "tc1")
        let newAssistant = OpenAIChatMessage(
            role: "assistant",
            content: nil,
            toolCalls: [OpenAIToolCall(id: "tc1", function: OpenAIFunctionCall(name: "terminal_operations", arguments: "{}"))]
        )
        let dropped = MessageUnit_with([newAssistant, newCommit], toolCallIds: ["tc1"])

        let summary = MessageValidator.compressDropped(
            [dropped],
            lastUserUnit: nil,
            previousSummary: previousSummary
        )

        // Both old and new commits should be present
        XCTAssertTrue(summary.content?.contains("abc1234") ?? false, "Old commit should be merged from previous summary")
        XCTAssertTrue(summary.content?.contains("def5678") ?? false, "New commit should be added")
        XCTAssertTrue(summary.content?.contains("file_operations: 3 calls") ?? false, "Old tool count from previous summary preserved")
        XCTAssertTrue(summary.content?.contains("terminal_operations: 1 calls") ?? false, "New tool count from this cycle added")
    }

    // MARK: - Find Substantive Task

    func testFindSubstantiveTask_RejectsShortCandidate() {
        let candidate = "yes"
        let messages = [
            "First request",
            "go ahead",
            "Implement the long-context message validator with proper atomic unit grouping and thread_summary compression"
        ]

        let result = MessageValidator.findSubstantiveTask(candidate: candidate, messages: messages)
        XCTAssertTrue(result.contains("Implement the long-context message validator"))
    }

    func testFindSubstantiveTask_AcceptsLongCandidate() {
        let candidate = "Implement atomic unit grouping for tool_calls and tool_results so they stay paired during context trimming"
        let messages = ["short", "messages"]

        let result = MessageValidator.findSubstantiveTask(candidate: candidate, messages: messages)
        XCTAssertEqual(result, candidate)
    }

    // MARK: - JSON Helpers

    func testExtractJsonStringValue() {
        let json = "{\"message\": \"Hello world\", \"other\": 42}"
        XCTAssertEqual(MessageValidator.extractJsonStringValue(json, key: "message"), "Hello world")
        XCTAssertNil(MessageValidator.extractJsonStringValue(json, key: "missing"))
    }

    func testExtractJsonStringValues_MultipleKeys() {
        let json = "{\"path\": \"/tmp/foo.swift\", \"old_path\": \"/tmp/bar.swift\"}"
        let paths = MessageValidator.extractJsonStringValues(json, keys: ["path", "old_path", "new_path"])
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.contains("/tmp/foo.swift"))
        XCTAssertTrue(paths.contains("/tmp/bar.swift"))
    }

    func testExtractJsonStringValue_HandlesEscapes() {
        let json = "{\"message\": \"Hello\\\\nWorld\", \"other\": \"value\"}"
        let result = MessageValidator.extractJsonStringValue(json, key: "message")
        XCTAssertNotNil(result)
    }

    // MARK: - Helper

    private func MessageUnit_with(_ messages: [OpenAIChatMessage], toolCallIds: Set<String>) -> MessageValidator.MessageUnit {
        return MessageValidator.MessageUnit(
            messages: messages,
            tokens: MessageValidator.estimateTokens(messages),
            toolCallIds: toolCallIds,
            isOrphanToolResult: false,
            orphanToolId: nil
        )
    }
}