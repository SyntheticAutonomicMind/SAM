// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtaries)

import Foundation

// MARK: - OpenAIChatRequest Shared Request Builder

extension OpenAIChatRequest {
    /// Builds a fully-serialized OpenAI-compatible request dictionary with proper tool support.
    /// All OpenAI-compatible providers (OpenAI, Ollama, OpenRouter, DeepSeek, ZAI, etc.) should
    /// use this instead of manually constructing request bodies to ensure consistent tool calling.
    ///
    /// Handles:
    /// - Tool definitions from `self.tools`
    /// - Full message serialization including `tool_calls` and `tool_call_id`
    /// - Content trimming for trailing whitespace (prevents API rejection)
    /// - Tool result preview filtering (UI-only messages excluded)
    ///
    /// - Parameters:
    ///   - modelOverride: Override the model name (e.g., strip provider prefix). Uses `self.model` if nil.
    ///   - maxTokensOverride: Override max tokens. Uses request/config values if nil.
    ///   - temperatureOverride: Override temperature. Uses request/config values if nil.
    ///   - streamEnabled: Whether to enable streaming. Default false.
    ///   - extraFields: Additional fields to merge into the request body (e.g., ZAI's "thinking").
    /// - Returns: Dictionary ready for JSONSerialization.
    public func buildOpenAICompatibleRequestBody(
        modelOverride: String? = nil,
        maxTokensOverride: Int? = nil,
        temperatureOverride: Double? = nil,
        streamEnabled: Bool = false,
        extraFields: [String: Any]? = nil
    ) -> [String: Any] {
        let modelForAPI: String
        if let override = modelOverride {
            modelForAPI = override
        } else {
            modelForAPI = model.contains("/")
                ? model.components(separatedBy: "/").last ?? model
                : model
        }

        var requestBody: [String: Any] = [
            "model": modelForAPI,
            "messages": serializeMessages(),
            "max_tokens": max(maxTokensOverride ?? maxTokens ?? 4096, 2048),
            "temperature": temperatureOverride ?? temperature ?? 0.7,
            "stream": streamEnabled
        ]

        // Add tools if present
        if let tools = tools, !tools.isEmpty {
            requestBody["tools"] = tools.map { tool in
                let parameters: Any
                if let parametersData = tool.function.parametersJson.data(using: .utf8),
                   let parsedParameters = try? JSONSerialization.jsonObject(with: parametersData) {
                    parameters = parsedParameters
                } else {
                    parameters = [:]
                }

                return [
                    "type": tool.type,
                    "function": [
                        "name": tool.function.name,
                        "description": tool.function.description,
                        "parameters": parameters
                    ]
                ]
            }
        }

        // Add top_p if specified
        if let topP = topP {
            requestBody["top_p"] = topP
        }

        // Merge any extra provider-specific fields
        if let extra = extraFields {
            for (key, value) in extra {
                requestBody[key] = value
            }
        }

        return requestBody
    }

    /// Serializes messages into the OpenAI-compatible format, preserving tool_calls and tool_call_id.
    /// Filters out tool result preview messages (UI-only with [TOOL_RESULT_STORED]/[TOOL_RESULT_PREVIEW] markers).
    public func serializeMessages() -> [[String: Any]] {
        return messages.filter { message in
            // Filter out tool result preview messages (UI-only)
            if let content = message.content {
                return !content.contains("[TOOL_RESULT_STORED]") && !content.contains("[TOOL_RESULT_PREVIEW]")
            }
            return true
        }.map { message in

            var messageDict: [String: Any] = [
                "role": message.role
            ]

            // Include content if present (can be null for assistant messages with tool_calls)
            if let content = message.content {
                let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedContent.isEmpty {
                    messageDict["content"] = trimmedContent
                }
            } else {
                messageDict["content"] = NSNull()
            }

            // Include tool_calls for assistant messages
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                messageDict["tool_calls"] = toolCalls.map { toolCall in
                    return [
                        "id": toolCall.id,
                        "type": toolCall.type,
                        "function": [
                            "name": toolCall.function.name,
                            "arguments": toolCall.function.arguments
                        ]
                    ]
                }
            }

            // Include tool_call_id for tool result messages
            if let toolCallId = message.toolCallId {
                messageDict["tool_call_id"] = toolCallId
            }

            return messageDict
        }
    }
}
