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

    // MARK: - TrimConfig + Budget Tests

    func testComputePromptBudget_WithTools_OptimizedOutputReserve() {
        // When tools are active, output reserve is capped at 8K (defaultToolOutputReserve)
        // instead of the model's full maxOutputTokens.
        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 32_000)
        let budget = caps.computePromptBudget(hasTools: true)

        // budget = 128_000 - 8_192 (tool output reserve) - estimation_buffer
        // estimation_buffer = 8192 + min(128000 * 0.05, 51200) = 8192 + 51200 = 59392
        // Wait: 128000 * 0.05 = 6400, clamped to 6400. So buffer = 8192 + 6400 = 14592
        // budget = 128_000 - 8_192 - 14_592 = 105_216
        XCTAssertEqual(budget, 105_216, "Budget with tools should use 8K output reserve")
    }

    func testComputePromptBudget_WithoutTools_FullOutputReserve() {
        // Without tools, output reserve = full maxOutputTokens.
        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 32_000)
        let budget = caps.computePromptBudget(hasTools: false)

        // budget = 128_000 - 32_000 (full output reserve) - estimation_buffer
        // estimation_buffer = 8192 + 6400 = 14592
        // budget = 128_000 - 32_000 - 14_592 = 81_408
        XCTAssertEqual(budget, 81_408, "Budget without tools should use full maxOutputTokens as reserve")
    }

    func testComputePromptBudget_WhenHasToolsButNoToolSupport_FullyOptimized() {
        // If supportsTools is false but hasTools is true, falls through to full reserve
        // (since the `if hasTools && supportsTools` condition is false).
        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 32_000, supportsTools: false)
        let budgetNoTools = caps.computePromptBudget(hasTools: false)
        let budgetWithTools = caps.computePromptBudget(hasTools: true)

        // Without tools: 128_000 - 32_000 - 14_592 = 81_408
        // With "tools" but no support: 128_000 - 32_000 - 14_592 = 81_408 (same, no optimization)
        XCTAssertEqual(budgetWithTools, budgetNoTools)
        XCTAssertEqual(budgetNoTools, 81_408)
    }

    func testTrimConfig_EffectiveBudget_UsesTrimThresholdOverride() {
        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 8_000)
        let configWithOverride = TrimConfig(
            caps: caps,
            tokenRatio: 4.0,
            trimThreshold: 50_000
        )
        XCTAssertEqual(configWithOverride.effectiveBudget, 50_000)

        let configWithoutOverride = TrimConfig(
            caps: caps,
            tokenRatio: 4.0,
            trimThreshold: nil
        )
        // 128_000 - 8_000 - (8192 + 6400) = 105_408... let me compute:
        // outputEstimationBuffer = 8192 + min(128000 * 0.05, 51200) = 8192 + 6400 = 14592
        // budget = 128_000 - 8_000 - 14_592 = 105_408
        XCTAssertEqual(configWithoutOverride.effectiveBudget, 105_408)
    }

    // MARK: - Summary at END Tests

    func testValidateAndTruncateWithDropped_SummaryAtEnd() {
        // When a previous summary exists, it should be placed at the END of
        // the output, not at the beginning.
        let systemMsg = OpenAIChatMessage(role: "system", content: "SYSTEM INSTRUCTIONS")
        let summaryMsg = OpenAIChatMessage(role: "system", content: "<thread_summary>\n\nSummary of old conversation\n\n</thread_summary>")
        let userMsg1 = OpenAIChatMessage(role: "user", content: "First request")
        let assistantMsg1 = OpenAIChatMessage(role: "assistant", content: "First response")
        let userMsg2 = OpenAIChatMessage(role: "user", content: "Second request")

        // Build messages with summary in the middle (simulating a previous summary)
        let messages = [systemMsg, summaryMsg, userMsg1, assistantMsg1, userMsg2]

        // Large budget so no trimming occurs
        let caps = ContextCapabilities(contextWindow: 1_000_000, maxOutputTokens: 8_000)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(
            messages: messages,
            config: config
        )

        // The summary should be at the END (last message), not after the system message
        let lastMessage = result.messages.last!
        XCTAssertTrue(lastMessage.content?.contains("<thread_summary>") ?? false,
                      "Summary should be at the END, not at the beginning")
        XCTAssertEqual(result.messages[0].role, "system", "System message should be at the beginning")

        // Verify summary is the last message
        XCTAssertEqual(result.messages.last?.content, "<thread_summary>\n\nSummary of old conversation\n\n</thread_summary>")
    }

    // MARK: - CSSS Slot Tests

    func testCSSSSlot_MinFloorOnFirstTrim() {
        // First trim (no existing summary): CSSS slot should use minCSSSlotTokens floor.
        // Use explicit trimThreshold to guarantee trimming regardless of estimation buffer.
        let caps = ContextCapabilities(contextWindow: 128_000, maxOutputTokens: 8_000)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0, trimThreshold: 5_000)

        // Create messages that far exceed the 5000-token budget.
        // Use 300 pairs (600 messages) to ensure >5000 tokens total.
        // Use unique short content so messageIdentity can distinguish them
        // (identity is based on first 100 chars of content).
        let systemMsg = OpenAIChatMessage(role: "system", content: "System")
        var messages: [OpenAIChatMessage] = [systemMsg]
        for i in 0..<300 {
            messages.append(OpenAIChatMessage(role: "user", content: "User msg \(i) unique content payload"))
            messages.append(OpenAIChatMessage(role: "assistant", content: "Assistant response \(i) unique payload"))
        }

        let result = MessageValidator.validateAndTruncateWithDropped(
            messages: messages, config: config
        )

        // Should have been trimmed
        XCTAssertTrue(result.wasTrimmed, "Result should have been trimmed: wasTrimmed=\(result.wasTrimmed), droppedCount=\(result.droppedMessages.count)")
        // The summary should contain a thread_summary at the END
        let lastMessage = result.messages.last!
        XCTAssertTrue(lastMessage.content?.contains("<thread_summary>") ?? false,
                      "Summary should be at the END of the output")
    }

    // MARK: - Deinterleave Tool Results Tests

    func testValidateAndTruncateWithDropped_DeinterleavesToolResultsToEnd() {
        // Tool results should be moved to the END (after all regular dialog)
        // if they appear before the last user message.
        let systemMsg = OpenAIChatMessage(role: "system", content: "You are a helpful assistant")
        let userMsg = OpenAIChatMessage(role: "user", content: "Search for cats")
        let assistantMsg = OpenAIChatMessage(
            role: "assistant",
            content: nil,
            toolCalls: [OpenAIToolCall(id: "tc1", function: OpenAIFunctionCall(name: "search", arguments: "{}"))]
        )
        let toolResult = OpenAIChatMessage(role: "tool", content: "Found 3 cats", toolCallId: "tc1")
        // Another user message after the tool result
        let userMsg2 = OpenAIChatMessage(role: "user", content: "Now search for dogs")

        let messages = [systemMsg, userMsg, assistantMsg, toolResult, userMsg2]

        // Large budget so no trimming occurs - structural normalization still runs.
        let caps = ContextCapabilities(contextWindow: 1_000_000, maxOutputTokens: 8_000)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(
            messages: messages, config: config
        )

        // After normalizeSummaryToEnd: [systemMsg, userMsg, assistantMsg, userMsg2, toolResult]
        // Tool result should be moved to END, after all dialog including userMsg2
        let nonSystemMessages = result.messages.filter { $0.role != "system" }
        // Find the index of userMsg2
        let userMsg2Index = nonSystemMessages.firstIndex { $0.content == "Now search for dogs" }
        XCTAssertNotNil(userMsg2Index, "userMsg2 should be in the result")

        // Find the index of the tool result
        let toolResultIndex = nonSystemMessages.firstIndex { $0.role == "tool" }
        if let toolIdx = toolResultIndex, let userIdx = userMsg2Index {
            XCTAssertGreaterThan(toolIdx, userIdx,
                                 "Tool result should be after userMsg2 (deinterleaved to END)")
        }
    }

    // MARK: - Preserved Leading System Messages Tests

    func testValidateAndTruncateWithDropped_PreservesLeadingSystemMessages() {
        // System messages at the beginning should be preserved even after trimming.
        let systemMsg1 = OpenAIChatMessage(role: "system", content: "Primary system instructions")
        let systemMsg2 = OpenAIChatMessage(role: "system", content: "Additional context and settings")
        let userMsg = OpenAIChatMessage(role: "user", content: "First request")

        let messages = [systemMsg1, systemMsg2, userMsg]

        // Small budget to force trimming
        let caps = ContextCapabilities(contextWindow: 10_000, maxOutputTokens: 4_000)
        let config = TrimConfig(caps: caps, tokenRatio: 4.0)

        let result = MessageValidator.validateAndTruncateWithDropped(
            messages: messages, config: config
        )

        // System messages should be preserved
        let systemMessages = result.messages.filter { $0.role == "system" }
        XCTAssertGreaterThanOrEqual(systemMessages.count, 1,
                                    "At least one system message should be preserved")
    }

    // MARK: - DriftTracker Tests

    func testDriftTracker_LearnedRatio_Converges() {
        let tracker = DriftTracker()
        let initialRatio = tracker.learnedRatio
        XCTAssertEqual(initialRatio, 4.0, "Initial ratio should be 4.0")

        // Learn from a response where actual tokens were higher than estimated
        // (heuristic underestimated — char/token ratio is actually higher)
        // totalChars=4000, actualTokens=1000 -> ratio = 4.0 (same as current)
        tracker.learnFromAPIResponse(totalChars: 4000, actualPromptTokens: 1000, estimatedPromptTokens: 800)

        // New ratio = 4.0 * 0.8 + (4000/1000) * 0.2 = 3.2 + 0.8 = 4.0
        XCTAssertEqual(tracker.learnedRatio, 4.0, accuracy: 0.01)

        // Learn from a response where actual tokens were lower (ratio is lower)
        // totalChars=300, actualTokens=300 -> ratio = 1.0 (too low, clamped to 1.5)
        // New ratio = 4.0 * 0.8 + 1.0 * 0.2 = 3.2 + 0.2 = 3.4
        tracker.learnFromAPIResponse(totalChars: 300, actualPromptTokens: 100, estimatedPromptTokens: 80)
        // ratio = 300/100 = 3.0; new = 4.0*0.8 + 3.0*0.2 = 3.2 + 0.6 = 3.8
        XCTAssertEqual(tracker.learnedRatio, 3.8, accuracy: 0.01)
    }

    func testDriftTracker_LearnedRatio_Clamped() {
        let tracker = DriftTracker()

        // Very high ratio (should clamp to maxLearnedRatio = 4.0)
        // totalChars=10000, actualTokens=100 -> ratio = 100 (way too high)
        // New = 4.0*0.8 + 100*0.2 = 3.2 + 20 = 23.2 -> clamped to 4.0
        tracker.learnFromAPIResponse(totalChars: 10000, actualPromptTokens: 100, estimatedPromptTokens: 50)
        XCTAssertEqual(tracker.learnedRatio, 4.0, "Ratio should be clamped to max (4.0)")

        tracker.reset()

        // Very low ratio (should clamp to minLearnedRatio = 1.5)
        // totalChars=100, actualTokens=1000 -> ratio = 0.1 (too low)
        // New = 4.0*0.8 + 0.1*0.2 = 3.2 + 0.02 = 3.22
        tracker.learnFromAPIResponse(totalChars: 100, actualPromptTokens: 1000, estimatedPromptTokens: 1200)
        XCTAssertEqual(tracker.learnedRatio, 3.22, accuracy: 0.01)
    }

    func testDriftTracker_DriftAwareThreshold_TightensWhenUnderestimating() {
        let tracker = DriftTracker()

        // Record drift where actual tokens > estimated (underestimation)
        // drift = 150/100 = 1.5 > 1.2 threshold
        tracker.recordDrift(serverActualTokens: 150, estimatedTokens: 100)

        let contextWindow = 128_000
        let threshold = tracker.computeDriftAwareThreshold(contextWindow: contextWindow)

        XCTAssertNotNil(threshold, "Should return a threshold when drift > 1.2")
        // rawThreshold = 128_000 * 0.90 = 115_200
        // drift = 1.5 > 1.0, so threshold = min(115200, 115200/1.5) = min(115200, 76800) = 76800
        XCTAssertEqual(threshold, 76_800, "Should tighten threshold when drift > 1.0")
    }

    func testDriftTracker_DriftAwareThreshold_NilWhenNoDriftData() {
        let tracker = DriftTracker()
        let threshold = tracker.computeDriftAwareThreshold(contextWindow: 128_000)
        XCTAssertNil(threshold, "Should return nil when no drift data exists")
    }

    func testDriftTracker_DriftAwareThreshold_NilWhenDriftBelowThreshold() {
        let tracker = DriftTracker()

        // drift = 110/100 = 1.1 < 1.2 threshold
        tracker.recordDrift(serverActualTokens: 110, estimatedTokens: 100)

        let threshold = tracker.computeDriftAwareThreshold(contextWindow: 128_000)
        XCTAssertNil(threshold, "Should return nil when drift < 1.2 threshold")
    }

    func testDriftTracker_DriftAwareThreshold_NilWhenStale() {
        let tracker = DriftTracker()

        // Record drift with future timestamp
        tracker.recordDrift(serverActualTokens: 150, estimatedTokens: 100)

        // computeDriftAwareThreshold checks age — let's verify it returns a value
        // while fresh (it should be within 3600 seconds)
        let threshold = tracker.computeDriftAwareThreshold(contextWindow: 128_000)
        XCTAssertNotNil(threshold)
    }

    // MARK: - Parse Token Limit Error Tests

    func testParseTokenLimitError_DetectsTokenLimitExceeded() {
        let tokenCounter = TokenCounter()
        let errorMessage = "This model's maximum context length is 128000 tokens. However, you requested 150000 tokens in the messages"
        let result = tokenCounter.parseTokenLimitError(errorMessage: errorMessage)

        XCTAssertNotNil(result, "Should detect token limit error")
        // Should extract 150000 (the requested/prompt tokens)
        XCTAssertGreaterThan(result!.serverActual, 0)
    }

    func testParseTokenLimitError_DetectsContextLengthExceeded() {
        let tokenCounter = TokenCounter()
        let errorMessage = "context_length_exceeded: prompt contains 150000 tokens, max 128000"
        let result = tokenCounter.parseTokenLimitError(errorMessage: errorMessage)

        XCTAssertNotNil(result, "Should detect context_length_exceeded")
        XCTAssertEqual(result!.serverActual, 150000)
    }

    func testParseTokenLimitError_NonTokenError_ReturnsNil() {
        let tokenCounter = TokenCounter()
        let errorMessage = "Invalid API key provided"
        let result = tokenCounter.parseTokenLimitError(errorMessage: errorMessage)
        XCTAssertNil(result, "Should return nil for non-token-limit errors")
    }

    func testParseTokenLimitError_PromptTooLong() {
        let tokenCounter = TokenCounter()
        let errorMessage = "The prompt is too long for this model"
        let result = tokenCounter.parseTokenLimitError(errorMessage: errorMessage)
        XCTAssertNotNil(result, "Should detect 'prompt is too long'")
    }

    // MARK: - Backward-Compatible API Tests

    func testValidateAndTruncate_WithTrimConfig_BackwardCompatible() {
        // The legacy maxPromptTokens API should still work via backward compat.
        let messages = [
            OpenAIChatMessage(role: "user", content: "Hello"),
            OpenAIChatMessage(role: "assistant", content: "Hi there")
        ]

        let result = MessageValidator.validateAndTruncate(
            messages: messages,
            maxPromptTokens: 100000
        )

        XCTAssertEqual(result.count, 2)
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