// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtaries)

import Foundation

// MARK: - Deterministic JSON Serialization for Prompt Caching

/// Serializes a dictionary to JSON data with sorted keys for deterministic output.
/// This is critical for prompt caching: providers like Anthropic, OpenRouter, and OpenAI
/// compute cache keys from the request body. If keys are in different order each time,
/// the cache never hits. Sorted keys ensure byte-identical output across requests.
///
/// - Parameter dictionary: The dictionary to serialize
/// - Returns: JSON data with keys in sorted order
/// - Throws: JSONSerialization errors
public func deterministicJSONData(from dictionary: [String: Any]) throws -> Data {
    return try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
}

/// Serializes a dictionary to a JSON string with sorted keys for deterministic output.
/// Useful for debugging and logging cache-friendly requests.
///
/// - Parameter dictionary: The dictionary to serialize
/// - Returns: JSON string with keys in sorted order, or nil on failure
public func deterministicJSONString(from dictionary: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

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
    /// - Deterministic key ordering for cacheability
    /// - Cache control annotations for prompt caching
    ///
    /// - Parameters:
    ///   - modelOverride: Override the model name (e.g., strip provider prefix). Uses `self.model` if nil.
    ///   - maxTokensOverride: Override max tokens. Uses request/config values if nil.
    ///   - temperatureOverride: Override temperature. Uses request/config values if nil.
    ///   - streamEnabled: Whether to enable streaming. Default false.
    ///   - extraFields: Additional fields to merge into the request body (e.g., ZAI's "thinking").
    ///   - cacheControl: Whether to add cache_control annotations for prompt caching.
    ///   - thinking: Thinking/reasoning configuration for extended thinking models.
    /// - Returns: Dictionary ready for JSONSerialization.
    public func buildOpenAICompatibleRequestBody(
        modelOverride: String? = nil,
        maxTokensOverride: Int? = nil,
        temperatureOverride: Double? = nil,
        streamEnabled: Bool = false,
        extraFields: [String: Any]? = nil,
        cacheControl: Bool = false,
        thinking: ThinkingConfig? = nil
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
            "messages": serializeMessages(cacheControl: cacheControl),
            "max_tokens": max(maxTokensOverride ?? maxTokens ?? 4096, 2048),
            "temperature": temperatureOverride ?? temperature ?? 0.7,
            "stream": streamEnabled
        ]

        /// CachyLLama reads the OpenAI "user" field for slot affinity and
        /// per-user concurrency limits. Other providers (OpenAI, Anthropic,
        /// etc.) either use it for abuse detection or ignore it, so the
        /// field is always safe to send.
        ///
        /// Default to conversationId when user is not explicitly set, so
        /// the same conversation always lands on the same slot even if
        /// callers forget to populate the dedicated field.
        if let user = user ?? conversationId {
            requestBody["user"] = user
        }

        // Add tools if present
        if let tools = tools, !tools.isEmpty {
            var serializedTools = tools.map { tool in
                let parameters: Any
                if let parametersData = tool.function.parametersJson.data(using: .utf8),
                   let parsedParameters = try? JSONSerialization.jsonObject(with: parametersData) {
                    parameters = parsedParameters
                } else {
                    parameters = [:]
                }

                var toolDict: [String: Any] = [
                    "type": tool.type,
                    "function": [
                        "name": tool.function.name,
                        "description": tool.function.description,
                        "parameters": parameters
                    ]
                ]

                // Add cache_control on the last tool definition for prompt caching
                if cacheControl {
                    toolDict["cache_control"] = ["type": "ephemeral"]
                }

                return toolDict
            }

            // Mark only the last tool with cache_control (Anthropic pattern)
            if cacheControl && serializedTools.count > 1 {
                // Remove cache_control from all but the last tool
                for i in 0..<(serializedTools.count - 1) {
                    serializedTools[i].removeValue(forKey: "cache_control")
                }
            }

            requestBody["tools"] = serializedTools
        }

        // Add top_p if specified
        if let topP = topP {
            requestBody["top_p"] = topP
        }

        // Add thinking/reasoning configuration for providers that support it
        if let thinkingConfig = thinking ?? samConfig?.thinking {
            // Anthropic-style: thinking object with type and budget_tokens
            if let mode = thinkingConfig.mode {
                var thinkingDict: [String: Any] = ["type": mode]
                if let budget = thinkingConfig.budgetTokens {
                    thinkingDict["budget_tokens"] = budget
                }
                requestBody["thinking"] = thinkingDict
            }
            // OpenRouter/Responses API-style: reasoning object with effort
            if let effort = thinkingConfig.effort {
                requestBody["reasoning"] = ["effort": effort]
            }
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
    ///
    /// - Parameter cacheControl: When true, adds cache_control annotations on the system prompt
    ///   and last user/assistant message for prompt caching (Anthropic, OpenRouter).
    /// - Returns: Array of message dictionaries with deterministic key ordering.
    public func serializeMessages(cacheControl: Bool = false) -> [[String: Any]] {
        let filteredMessages = messages.filter { message in
            // Filter out tool result preview messages (UI-only)
            if let content = message.content {
                return !content.contains("[TOOL_RESULT_STORED]") && !content.contains("[TOOL_RESULT_PREVIEW]")
            }
            return true
        }

        // Find indices for cache_control placement:
        // - System prompt (first system message) gets cache_control
        // - Last user or assistant message gets cache_control
        let firstSystemIndex = filteredMessages.firstIndex(where: { $0.role == "system" })
        let lastUserAssistantIndex = filteredMessages.lastIndex(where: { $0.role == "user" || $0.role == "assistant" })

        return filteredMessages.enumerated().map { (index, message) in
            // Build with deterministic key ordering for cacheability
            var messageDict: [String: Any] = [:]
            messageDict["role"] = message.role

            // Include content if present (can be null for assistant messages with tool_calls)
            if let content = message.content {
                let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedContent.isEmpty {
                    messageDict["content"] = trimmedContent
                } else {
                    messageDict["content"] = NSNull()
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

            // Include reasoning_content for providers that use it (llama.cpp)
            if let reasoningContent = message.reasoningContent {
                messageDict["reasoning_content"] = reasoningContent
            }

            // Add cache_control annotation for prompt caching
            if cacheControl {
                let shouldCache = (index == firstSystemIndex) || (index == lastUserAssistantIndex)
                if shouldCache {
                    messageDict["cache_control"] = ["type": "ephemeral"]
                }
            }

            // Include cache_control from message itself (for Anthropic-style per-message caching)
            if let msgCacheControl = message.cacheControl {
                messageDict["cache_control"] = ["type": msgCacheControl.type]
            }

            return messageDict
        }
    }
}
