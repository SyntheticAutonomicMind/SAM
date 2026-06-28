// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework

final class LocalProviderCoreTests: XCTestCase {

    // MARK: - injectNothinkIfNeeded

    func testInjectNothinkNoOpsWhenReasoningEnabled() {
        let request = makeRequest(messages: [.user("hi")], enableReasoning: true)
        let result = LocalProviderCore.injectNothinkIfNeeded(request)
        XCTAssertEqual(result.messages.count, request.messages.count)
        XCTAssertEqual(result.messages.map { $0.content }, request.messages.map { $0.content })
    }

    func testInjectNothinkPrependsToLastUserMessage() {
        let request = makeRequest(
            messages: [.system("you are helpful"), .user("first"), .assistant("ok"), .user("second")],
            enableReasoning: false
        )
        let result = LocalProviderCore.injectNothinkIfNeeded(request)
        let lastUserContent = result.messages.last { $0.role == "user" }?.content
        XCTAssertNotNil(lastUserContent)
        XCTAssertTrue(lastUserContent!.hasPrefix("/nothink (ignore this if you don't understand it)"))
        XCTAssertTrue(lastUserContent!.contains("second"))
    }

    func testInjectNothinkNoOpWhenNoUserMessage() {
        let request = makeRequest(messages: [.system("system only")], enableReasoning: false)
        let result = LocalProviderCore.injectNothinkIfNeeded(request)
        XCTAssertEqual(result.messages.count, request.messages.count)
        XCTAssertEqual(result.messages.map { $0.content }, request.messages.map { $0.content })
    }

    func testInjectNothinkNoOpWhenLastUserContentIsNil() {
        let request = makeRequest(
            messages: [OpenAIChatMessage(role: "user", content: nil, toolCalls: nil)],
            enableReasoning: false
        )
        let result = LocalProviderCore.injectNothinkIfNeeded(request)
        XCTAssertEqual(result.messages.count, request.messages.count)
        XCTAssertEqual(result.messages.map { $0.content }, request.messages.map { $0.content })
    }

    func testInjectNothinkDefaultsToEnabledWhenConfigMissing() {
        let request = OpenAIChatRequest(
            model: "x", messages: [.user("hi")], temperature: nil, topP: nil,
            repetitionPenalty: nil, maxTokens: nil, stream: nil, tools: nil,
            samConfig: nil, contextId: nil, enableMemory: nil,
            sessionId: nil, conversationId: nil, statefulMarker: nil,
            iterationNumber: nil, topic: nil, customInstructions: nil, personalityId: nil
        )
        let result = LocalProviderCore.injectNothinkIfNeeded(request)
        XCTAssertEqual(result.messages.count, request.messages.count)
        XCTAssertEqual(result.messages.map { $0.content }, request.messages.map { $0.content })
    }

    // MARK: - processMessages

    func testProcessMessagesMergesMultipleSystemMessages() {
        let messages: [OpenAIChatMessage] = [
            .system("first"),
            .system("second"),
            .user("hi")
        ]
        let processed = LocalProviderCore.processMessages(messages)
        XCTAssertEqual(processed.count, 2)
        XCTAssertEqual(processed[0].role, "system")
        XCTAssertEqual(processed[0].content, "first\n\nsecond")
        XCTAssertEqual(processed[1].role, "user")
    }

    func testProcessMessagesNoSystemStaysAsIs() {
        let messages: [OpenAIChatMessage] = [.user("a"), .assistant("b"), .user("c")]
        let processed = LocalProviderCore.processMessages(messages)
        XCTAssertEqual(processed.count, 3)
        XCTAssertEqual(processed.map { $0.content }, ["a", "b", "c"])
    }

    func testProcessMessagesConvertsToolToUserWithLabel() {
        let messages: [OpenAIChatMessage] = [
            .user("ask"),
            OpenAIChatMessage(role: "tool", content: "result data", toolCallId: "abc"),
            .user("next")
        ]
        let processed = LocalProviderCore.processMessages(messages)
        /// Tool messages are converted to user messages and merged with the surrounding
        /// user content via the alternation pass - the chat template requires strict
        /// user/assistant alternation so we cannot leave user->user gaps.
        XCTAssertEqual(processed.count, 1)
        XCTAssertEqual(processed[0].role, "user")
        XCTAssertTrue(processed[0].content!.contains("Tool Result:"))
        XCTAssertTrue(processed[0].content!.contains("result data"))
        XCTAssertTrue(processed[0].content!.contains("next"))
    }

    func testProcessMessagesEnforcesAlternation() {
        let messages: [OpenAIChatMessage] = [
            .user("a"),
            .user("b"),
            .assistant("c"),
            .assistant("d"),
            .user("e")
        ]
        let processed = LocalProviderCore.processMessages(messages)
        XCTAssertEqual(processed.count, 3)
        XCTAssertEqual(processed[0].role, "user")
        XCTAssertEqual(processed[0].content, "a\n\nb")
        XCTAssertEqual(processed[1].role, "assistant")
        XCTAssertEqual(processed[1].content, "c\n\nd")
        XCTAssertEqual(processed[2].role, "user")
        XCTAssertEqual(processed[2].content, "e")
    }

    func testProcessMessagesPreservesToolCallsAcrossMergedConsecutive() {
        let tool1 = OpenAIToolCall(id: "t1", type: "function", function: OpenAIFunctionCall(name: "n1", arguments: "{}"))
        let tool2 = OpenAIToolCall(id: "t2", type: "function", function: OpenAIFunctionCall(name: "n2", arguments: "{}"))
        let messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "assistant", content: nil, toolCalls: [tool1]),
            OpenAIChatMessage(role: "assistant", content: nil, toolCalls: [tool2])
        ]
        let processed = LocalProviderCore.processMessages(messages)
        XCTAssertEqual(processed.count, 1)
        XCTAssertNotNil(processed[0].toolCalls)
        XCTAssertEqual(processed[0].toolCalls!.count, 2)
        XCTAssertEqual(processed[0].toolCalls!.map { $0.id }, ["t1", "t2"])
    }

    func testProcessMessagesDropsEmptySystemMessage() {
        let messages: [OpenAIChatMessage] = [.system(""), .user("hi")]
        let processed = LocalProviderCore.processMessages(messages)
        XCTAssertEqual(processed.count, 1)
        XCTAssertEqual(processed[0].role, "user")
    }

    // MARK: - buildToolInstructions

    func testBuildToolInstructionsEmpty() {
        XCTAssertEqual(LocalProviderCore.buildToolInstructions(nil), "")
        XCTAssertEqual(LocalProviderCore.buildToolInstructions([]), "")
    }

    func testBuildToolInstructionsSingleTool() {
        let tool = OpenAITool(
            type: "function",
            function: OpenAIFunction(
                name: "get_weather",
                description: "Get the weather",
                parametersJson: #"{"properties":{"city":{"type":"string"}},"required":["city"]}"#
            )
        )
        let result = LocalProviderCore.buildToolInstructions([tool])
        XCTAssertTrue(result.contains("get_weather"))
        XCTAssertTrue(result.contains("Get the weather"))
        XCTAssertTrue(result.contains("city*:string"))
    }

    func testBuildToolInstructionsMultipleTools() {
        let tool1 = OpenAITool(
            type: "function",
            function: OpenAIFunction(name: "a", description: "desc a", parametersJson: "{}")
        )
        let tool2 = OpenAITool(
            type: "function",
            function: OpenAIFunction(name: "b", description: "desc b", parametersJson: "{}")
        )
        let result = LocalProviderCore.buildToolInstructions([tool1, tool2])
        XCTAssertTrue(result.contains("a: desc a"))
        XCTAssertTrue(result.contains("b: desc b"))
    }

    func testBuildToolInstructionsHandlesMalformedParametersJson() {
        let tool = OpenAITool(
            type: "function",
            function: OpenAIFunction(name: "t", description: "d", parametersJson: "not json")
        )
        let result = LocalProviderCore.buildToolInstructions([tool])
        XCTAssertTrue(result.contains("t: d"))
        XCTAssertFalse(result.contains("Args:"))
    }

    // MARK: - extractAssistantContent

    func testExtractAssistantContentStripsChatMLTags() {
        let response = "<|im_start|>assistant\nHello world\n<|im_end|>"
        let extracted = LocalProviderCore.extractAssistantContent(response)
        XCTAssertEqual(extracted, "Hello world")
    }

    func testExtractAssistantContentStripsWithLeadingNewline() {
        let response = "<|im_start|>assistant\n<|im_end|>"
        let extracted = LocalProviderCore.extractAssistantContent(response)
        XCTAssertEqual(extracted, "")
    }

    func testExtractAssistantContentStripsStrayTags() {
        let response = "<|im_start|>user\nSome content<|im_end|><|im_start|>assistant\nReal answer"
        let extracted = LocalProviderCore.extractAssistantContent(response)
        XCTAssertTrue(extracted.contains("Real answer"))
        XCTAssertFalse(extracted.contains("<|im_start|>"))
    }

    func testExtractAssistantContentPlainTextPassthrough() {
        let response = "just text"
        XCTAssertEqual(LocalProviderCore.extractAssistantContent(response), "just text")
    }

    func testExtractAssistantContentRemovesEosTokens() {
        let response = "answer</s>"
        let extracted = LocalProviderCore.extractAssistantContent(response)
        XCTAssertEqual(extracted, "answer")
    }

    func testExtractAssistantContentHandlesMissingClosingTag() {
        let response = "<|im_start|>assistant\nincomplete response"
        let extracted = LocalProviderCore.extractAssistantContent(response)
        XCTAssertEqual(extracted, "incomplete response")
    }

    // MARK: - buildChatResponse

    func testBuildChatResponseShape() {
        let response = LocalProviderCore.buildChatResponse(
            model: "test-model",
            content: "hello",
            toolCalls: nil,
            promptTokens: 10,
            completionTokens: 5,
            finishReason: .stop
        )
        XCTAssertEqual(response.model, "test-model")
        XCTAssertEqual(response.choices.count, 1)
        XCTAssertEqual(response.choices[0].finishReason, "stop")
        XCTAssertEqual(response.choices[0].message.content, "hello")
        XCTAssertEqual(response.usage.promptTokens, 10)
        XCTAssertEqual(response.usage.completionTokens, 5)
        XCTAssertEqual(response.usage.totalTokens, 15)
        XCTAssertNil(response.choices[0].message.toolCalls)
    }

    func testBuildChatResponseWithToolCallsOverridesFinishReason() {
        let tool = OpenAIToolCall(
            id: "tc1",
            type: "function",
            function: OpenAIFunctionCall(name: "n", arguments: "{}")
        )
        let response = LocalProviderCore.buildChatResponse(
            model: "m",
            content: "",
            toolCalls: [tool],
            promptTokens: 1,
            completionTokens: 1,
            finishReason: .stop
        )
        XCTAssertEqual(response.choices[0].finishReason, "tool_calls")
        XCTAssertNotNil(response.choices[0].message.toolCalls)
        XCTAssertEqual(response.choices[0].message.toolCalls!.count, 1)
    }

    func testBuildChatResponseLengthFinishReason() {
        let response = LocalProviderCore.buildChatResponse(
            model: "m", content: "x", toolCalls: nil,
            promptTokens: 1, completionTokens: 1, finishReason: .length
        )
        XCTAssertEqual(response.choices[0].finishReason, "length")
    }

    // MARK: - buildStreamChunk

    func testBuildStreamChunkContentDelta() {
        let chunk = LocalProviderCore.buildStreamChunk(
            model: "m", content: "tok", toolCalls: nil, finishReason: nil
        )
        XCTAssertEqual(chunk.model, "m")
        XCTAssertEqual(chunk.choices.count, 1)
        XCTAssertEqual(chunk.choices[0].delta.content, "tok")
        XCTAssertNil(chunk.choices[0].delta.toolCalls)
        XCTAssertNil(chunk.choices[0].finishReason)
    }

    func testBuildStreamChunkFinalWithToolCalls() {
        let tool = OpenAIToolCall(id: "tc", type: "function", function: OpenAIFunctionCall(name: "n", arguments: "{}"))
        let chunk = LocalProviderCore.buildStreamChunk(
            model: "m", content: nil, toolCalls: [tool], finishReason: .toolCalls
        )
        XCTAssertNil(chunk.choices[0].delta.content)
        XCTAssertEqual(chunk.choices[0].delta.toolCalls?.count, 1)
        XCTAssertEqual(chunk.choices[0].finishReason, "tool_calls")
    }

    func testBuildStreamChunkStopWithoutContent() {
        let chunk = LocalProviderCore.buildStreamChunk(
            model: "m", content: nil, toolCalls: nil, finishReason: .stop
        )
        XCTAssertNil(chunk.choices[0].delta.content)
        XCTAssertNil(chunk.choices[0].delta.toolCalls)
        XCTAssertEqual(chunk.choices[0].finishReason, "stop")
    }

    func testBuildStreamChunkIncludesRoleWhenRequested() {
        let chunk = LocalProviderCore.buildStreamChunk(
            model: "m", content: "x", toolCalls: nil, finishReason: nil, includeRole: true
        )
        XCTAssertEqual(chunk.choices[0].delta.role, "assistant")
    }

    // MARK: - parseToolCalls

    func testParseToolCallsNoToolCallsInResponse() {
        let (content, toolCalls) = LocalProviderCore.parseToolCalls(from: "just a plain response")
        XCTAssertEqual(content, "just a plain response")
        XCTAssertNil(toolCalls)
    }

    func testParseToolCallsExtractsJsonToolCall() {
        let response = "{\"name\": \"get_weather\", \"arguments\": {\"city\": \"Paris\"}}"
        let (_, toolCalls) = LocalProviderCore.parseToolCalls(from: response)
        XCTAssertNotNil(toolCalls)
        XCTAssertEqual(toolCalls!.count, 1)
        XCTAssertEqual(toolCalls![0].function.name, "get_weather")
        XCTAssertTrue(toolCalls![0].function.arguments.contains("Paris"))
    }

    // MARK: - Helpers

    private func makeRequest(
        messages: [OpenAIChatMessage],
        enableReasoning: Bool
    ) -> OpenAIChatRequest {
        let config = SAMConfig(enableReasoning: enableReasoning)
        return OpenAIChatRequest(
            model: "test", messages: messages, temperature: nil, topP: nil,
            repetitionPenalty: nil, maxTokens: nil, stream: nil, tools: nil,
            samConfig: config, contextId: nil, enableMemory: nil,
            sessionId: nil, conversationId: nil, statefulMarker: nil,
            iterationNumber: nil, topic: nil, customInstructions: nil, personalityId: nil
        )
    }

    // MARK: - extractSystemPrompt

    func testExtractSystemPromptConcatenatesLeadingSystemMessages() {
        let messages: [OpenAIChatMessage] = [
            .system("first system"),
            .system("second system"),
            .user("hello"),
            .assistant("hi")
        ]
        let (systemPrompt, nonSystem) = LocalProviderCore.extractSystemPrompt(from: messages)
        XCTAssertEqual(systemPrompt, "first system\n\nsecond system")
        XCTAssertEqual(nonSystem.map { $0.content ?? "" }, ["hello", "hi"])
    }

    func testExtractSystemPromptReturnsEmptyWhenNoSystem() {
        let messages: [OpenAIChatMessage] = [.user("hello"), .assistant("hi")]
        let (systemPrompt, nonSystem) = LocalProviderCore.extractSystemPrompt(from: messages)
        XCTAssertEqual(systemPrompt, "")
        XCTAssertEqual(nonSystem.count, 2)
    }

    func testExtractSystemPromptStopsAtFirstNonSystem() {
        let messages: [OpenAIChatMessage] = [
            .user("before system"),
            .system("this should not be picked up"),
            .assistant("reply")
        ]
        let (systemPrompt, nonSystem) = LocalProviderCore.extractSystemPrompt(from: messages)
        XCTAssertEqual(systemPrompt, "")
        XCTAssertEqual(nonSystem.count, 3)
    }

    // MARK: - convertToolsToMLXSpec

    func testConvertToolsToMLXSpecReturnsNilForEmpty() {
        XCTAssertNil(LocalProviderCore.convertToolsToMLXSpec(nil))
        XCTAssertNil(LocalProviderCore.convertToolsToMLXSpec([]))
    }

    func testConvertToolsToMLXSpecPreservesNamesAndDescriptions() {
        let tool = OpenAITool(
            type: "function",
            function: OpenAIFunction(
                name: "search",
                description: "Search for things",
                parameters: ["type": "object"]
            )
        )
        guard let result = LocalProviderCore.convertToolsToMLXSpec([tool]) else {
            XCTFail("Expected a converted spec")
            return
        }
        XCTAssertEqual(result.count, 1)
        let spec = result[0]
        XCTAssertEqual(spec["type"] as? String, "function")
        if let function = spec["function"] as? [String: Any] {
            XCTAssertEqual(function["name"] as? String, "search")
            XCTAssertEqual(function["description"] as? String, "Search for things")
        } else {
            XCTFail("Expected function dict")
        }
    }
}

private extension OpenAIChatMessage {
    static func system(_ content: String) -> OpenAIChatMessage {
        OpenAIChatMessage(role: "system", content: content)
    }
    static func user(_ content: String) -> OpenAIChatMessage {
        OpenAIChatMessage(role: "user", content: content)
    }
    static func assistant(_ content: String) -> OpenAIChatMessage {
        OpenAIChatMessage(role: "assistant", content: content)
    }
}
