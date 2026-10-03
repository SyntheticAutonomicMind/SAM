// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework

final class APIFrameworkTests: XCTestCase {
    func testOpenAIModelsCreation() throws {
        let model = ServerOpenAIModel(
            id: "test-model",
            object: "model",
            created: 1234567890,
            ownedBy: "sam"
        )
        
        XCTAssertEqual(model.id, "test-model")
        XCTAssertEqual(model.object, "model")
        XCTAssertEqual(model.ownedBy, "sam")
    }
    
    func testOpenAIChatRequestCreation() throws {
        let message = OpenAIChatMessage(role: "user", content: "Hello")
        let request = OpenAIChatRequest(
            model: "gpt-4",
            messages: [message],
            temperature: 0.7,
            maxTokens: 100,
            stream: false,
            samConfig: nil,
            contextId: nil,
            enableMemory: nil
        )
        
        XCTAssertEqual(request.model, "gpt-4")
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.messages.first?.content, "Hello")
        XCTAssertEqual(request.temperature, 0.7)
    }

    // MARK: - Streaming Tool Call Decode Tests

    /// Verify that a streaming delta chunk WITHOUT a tool_call `id` decodes successfully.
    /// OpenAI-compatible APIs (OpenRouter, Copilot) only send `id` in the first chunk;
    /// subsequent chunks only have `index`, `type`, and `function.arguments`.
    func testStreamingToolCallDeltaWithoutIdDecodes() throws {
        let chunk1 = ServerOpenAIChatStreamChunk(
            id: "chatcmpl-123",
            object: "chat.completion.chunk",
            created: 1700000000,
            model: "gpt-4",
            choices: [OpenAIChatStreamChoice(
                index: 0,
                delta: OpenAIChatDelta(
                    toolCalls: [OpenAIToolCall(
                        id: "",
                        type: "function",
                        function: OpenAIFunctionCall(name: "", arguments: "arg1"),
                        index: 0
                    )]
                ),
                finishReason: nil
            )],
            isToolMessage: nil,
            toolName: nil,
            toolIcon: nil,
            toolStatus: nil,
            toolDisplayData: nil,
            toolDetails: nil,
            parentToolName: nil,
            toolExecutionId: nil,
            toolMetadata: nil,
            messageId: nil
        )

        /// Re-encode to JSON then decode back to verify round-trip works even
        /// when id and name are empty strings (simulating a streaming delta).
        let encoder = JSONEncoder()
        let data = try encoder.encode(chunk1)
        let decoded = try JSONDecoder().decode(ServerOpenAIChatStreamChunk.self, from: data)

        XCTAssertEqual(decoded.choices.count, 1)
        let toolCall = decoded.choices.first!.delta.toolCalls!.first!
        XCTAssertEqual(toolCall.id, "")
        XCTAssertEqual(toolCall.function.name, "")
        XCTAssertEqual(toolCall.function.arguments, "arg1")
    }

    /// Verify that a raw JSON streaming chunk WITHOUT id in tool_calls
    /// decodes successfully. This is the exact scenario from the OpenRouter
    /// SSE stream where subsequent tool_call delta chunks omit `id` and
    /// `function.name` (only `index`, `type`, and `function.arguments` remain).
    func testRawStreamingDeltaWithoutIdFromJsonDecodes() throws {
        let dict: [String: Any] = [
            "id": "chatcmpl-123",
            "object": "chat.completion.chunk",
            "created": 1700000000,
            "model": "gpt-4",
            "choices": [
                [
                    "index": 0,
                    "delta": [
                        "tool_calls": [
                            [
                                "index": 0,
                                "type": "function",
                                "function": [
                                    "name": "web_operations",
                                    "arguments": "{\"query\": \"hello world\"}"
                                ]
                            ]
                        ]
                    ],
                    "finish_reason": nil
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        let chunk = try JSONDecoder().decode(ServerOpenAIChatStreamChunk.self, from: data)
        let toolCall = chunk.choices.first!.delta.toolCalls!.first!
        XCTAssertEqual(toolCall.id, "")
        XCTAssertEqual(toolCall.function.name, "web_operations")
        XCTAssertEqual(toolCall.function.arguments, "{\"query\": \"hello world\"}")
    }

    /// Verify that the first chunk WITH id and name decodes correctly.
    func testStreamingToolCallFirstChunkWithIdDecodes() throws {
        let json = """
        {
          "id": "chatcmpl-123",
          "object": "chat.completion.chunk",
          "created": 1700000000,
          "model": "gpt-4",
          "choices": [{
            "index": 0,
            "delta": {
              "tool_calls": [{
                "id": "call_abc123",
                "index": 0,
                "type": "function",
                "function": {
                  "name": "web_operations",
                  "arguments": ""
                }
              }]
            },
            "finish_reason": null
          }]
        }
        """

        let data = json.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(ServerOpenAIChatStreamChunk.self, from: data)
        let toolCall = chunk.choices.first!.delta.toolCalls!.first!
        XCTAssertEqual(toolCall.id, "call_abc123")
        XCTAssertEqual(toolCall.function.name, "web_operations")
        XCTAssertEqual(toolCall.function.arguments, "")
    }

    /// Verify that a chunk with neither id nor name (just arguments) decodes.
    func testStreamingToolCallArgumentsOnlyDecodes() throws {
        let json = """
        {
          "id": "chatcmpl-123",
          "object": "chat.completion.chunk",
          "created": 1700000000,
          "model": "gpt-4",
          "choices": [{
            "index": 0,
            "delta": {
              "tool_calls": [{
                "index": 0,
                "type": "function",
                "function": {
                  "arguments": "world"
                }
              }]
            },
            "finish_reason": null
          }]
        }
        """

        let data = json.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(ServerOpenAIChatStreamChunk.self, from: data)
        let toolCall = chunk.choices.first!.delta.toolCalls!.first!
        XCTAssertEqual(toolCall.id, "")
        XCTAssertEqual(toolCall.function.name, "")
        XCTAssertEqual(toolCall.function.arguments, "world")
    }
}