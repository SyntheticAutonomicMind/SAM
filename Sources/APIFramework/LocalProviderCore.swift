// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import Tokenizers

/// Internal event produced by a `LocalProviderEngine` while generating a response.
///
/// Providers yield a stream of these events; the public `processChatCompletion` and
/// `processStreamingChatCompletion` methods translate them into OpenAI-compatible
/// responses. Keeping the event format engine-agnostic means non-streaming and
/// streaming paths share the same translation logic.
public enum LocalProviderEvent: Sendable {
    /// Incremental text delta from the model.
    case textDelta(String)
    /// Prompt and completion token counts (emitted exactly once, at the end).
    case usage(promptTokens: Int, completionTokens: Int)
    /// Generation finished with a reason.
    case finished(reason: FinishReason)

    public enum FinishReason: String, Sendable {
        /// Model emitted an end-of-turn token.
        case stop
        /// Model emitted tool call(s).
        case toolCalls = "tool_calls"
        /// Reached the max token limit.
        case length
        /// The streaming task was cancelled.
        case cancelled
        /// Sampler requested an explicit stop string.
        case stopSequence = "stop_sequence"
    }
}

/// Abstraction over a local inference engine (llama.cpp, MLX, etc.).
///
/// Each engine is responsible for loading its model, building the prompt from the
/// engine's chat template, and producing a stream of `LocalProviderEvent`s.
///
/// Engines are `Sendable` and must be safe to use from any actor that owns them.
/// The provider that wraps the engine owns the actor boundary and serializes access.
public protocol LocalProviderEngine: Sendable {
    /// Build the prompt string from messages, applying the engine's chat template.
    ///
    /// - Parameters:
    ///   - messages: The conversation history, already shaped (system merged,
    ///     alternation enforced) by `LocalProviderCore.processMessages`.
    ///   - tools: Optional tool definitions to surface in the system prompt.
    ///   - reasoningEnabled: Whether to enable the model's native reasoning mode.
    /// - Returns: The fully-formatted prompt string to feed into `generateStream`.
    func buildPrompt(
        messages: [OpenAIChatMessage],
        tools: [OpenAITool]?,
        reasoningEnabled: Bool
    ) async throws -> String

    /// Generate a stream of events for the given prompt.
    ///
    /// - Parameters:
    ///   - prompt: The fully-formatted prompt from `buildPrompt`.
    ///   - maxTokens: Maximum number of tokens to generate.
    ///   - temperature: Sampling temperature (0.0 = greedy, 1.0 = standard).
    ///   - topP: Optional nucleus sampling cutoff.
    ///   - repetitionPenalty: Optional repetition penalty.
    ///   - stopSequences: Optional stop strings; generation halts when any are produced.
    /// - Returns: An async stream of provider events.
    func generateStream(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float?,
        repetitionPenalty: Float?,
        stopSequences: [String]?
    ) -> AsyncThrowingStream<LocalProviderEvent, Error>
}

/// Shared, stateless helpers used by both `LlamaProvider` and `MLXProvider`.
///
/// All message shaping, tool-calling prompt construction, response parsing, and
/// OpenAI-format translation lives here so the providers can focus on engine
/// specifics. Static-only: no state, no actors, no side effects.
public enum LocalProviderCore {
    private static let logger = Logger(label: "com.sam.localprovider.core")

    // MARK: - Request shaping

    /// Prepend a `/nothink` directive to the last user message when reasoning is disabled.
    ///
    /// Some models (DeepSeek-R1, QwQ) emit `<think>...</think>` blocks by default.
    /// Disabling reasoning asks the model to skip that block, but the directive must
    /// appear in the last user turn to take effect.
    ///
    /// - Parameter request: The original request.
    /// - Returns: A modified request with the directive prepended, or the original request
    ///   if reasoning is enabled, no system config is present, or no user message exists.
    public static func injectNothinkIfNeeded(_ request: OpenAIChatRequest) -> OpenAIChatRequest {
        let reasoningEnabled = request.samConfig?.enableReasoning ?? true
        guard !reasoningEnabled else { return request }

        guard let lastUserMessageIndex = request.messages.lastIndex(where: { $0.role == "user" }) else {
            return request
        }

        guard let lastUserContent = request.messages[lastUserMessageIndex].content else {
            return request
        }

        let modifiedContent = "/nothink (ignore this if you don't understand it)\n\n\(lastUserContent)"

        var modifiedMessages = request.messages
        modifiedMessages[lastUserMessageIndex] = OpenAIChatMessage(
            id: nil,
            role: "user",
            content: modifiedContent
        )

        logger.info("REASONING: Disabled - prepended /nothink instruction to last user message")
        return OpenAIChatRequest(
            model: request.model,
            messages: modifiedMessages,
            temperature: request.temperature,
            topP: request.topP,
            repetitionPenalty: request.repetitionPenalty,
            maxTokens: request.maxTokens,
            stream: request.stream,
            tools: request.tools,
            samConfig: request.samConfig,
            contextId: request.contextId,
            enableMemory: request.enableMemory,
            sessionId: request.sessionId,
            conversationId: request.conversationId,
            statefulMarker: request.statefulMarker,
            iterationNumber: request.iterationNumber,
            topic: request.topic,
            customInstructions: request.customInstructions,
            personalityId: request.personalityId
        )
    }

    /// Shape a request's message list for local-model consumption.
    ///
    /// Performs three transformations:
    /// 1. Merges all system messages into one at position [0]. Some chat templates
    ///    (Mistral, Qwen) only accept a single system message at the head of the
    ///    conversation.
    /// 2. Converts `role: "tool"` messages to user messages with a labeled block.
    ///    Strict-alternation templates (Qwen, Llama) reject tool messages outright.
    /// 3. Enforces strict user/assistant alternation by merging consecutive same-role
    ///    messages. Duplicate system messages and tool result gaps can otherwise
    ///    produce `user -> user` or `assistant -> assistant` sequences that crash the
    ///    chat template engine.
    ///
    /// - Parameter messages: Raw message list from the request.
    /// - Returns: A shaped message list suitable for chat-template rendering.
    public static func processMessages(_ messages: [OpenAIChatMessage]) -> [OpenAIChatMessage] {
        var allSystemContent = ""
        var nonSystemMessages: [OpenAIChatMessage] = []

        for msg in messages {
            if msg.role == "system" {
                if let content = msg.content, !content.isEmpty {
                    if !allSystemContent.isEmpty {
                        allSystemContent += "\n\n"
                    }
                    allSystemContent += content
                }
            } else if msg.role == "tool" {
                let toolContent = msg.content ?? "{}"
                let labeledContent = "Tool Result:\n\(toolContent)"
                nonSystemMessages.append(OpenAIChatMessage(role: "user", content: labeledContent))
                logger.debug("Converted tool message to user message for strict alternation")
            } else {
                nonSystemMessages.append(msg)
            }
        }

        var processedMessages: [OpenAIChatMessage] = []
        if !allSystemContent.isEmpty {
            processedMessages.append(OpenAIChatMessage(role: "system", content: allSystemContent))
        }
        processedMessages.append(contentsOf: nonSystemMessages)

        var alternatingMessages: [OpenAIChatMessage] = []
        var lastRole: String?
        var accumulatedContent = ""
        var accumulatedToolCalls: [OpenAIToolCall] = []

        for msg in processedMessages {
            if msg.role == lastRole {
                if let content = msg.content, !content.isEmpty {
                    if !accumulatedContent.isEmpty {
                        accumulatedContent += "\n\n"
                    }
                    accumulatedContent += content
                }
                if let toolCalls = msg.toolCalls {
                    accumulatedToolCalls.append(contentsOf: toolCalls)
                }
            } else {
                if let role = lastRole {
                    alternatingMessages.append(OpenAIChatMessage(
                        id: nil,
                        role: role,
                        content: accumulatedContent.isEmpty ? "" : accumulatedContent,
                        toolCalls: accumulatedToolCalls.isEmpty ? nil : accumulatedToolCalls
                    ))
                }
                lastRole = msg.role
                accumulatedContent = msg.content ?? ""
                accumulatedToolCalls = msg.toolCalls ?? []
            }
        }

        if let role = lastRole {
            alternatingMessages.append(OpenAIChatMessage(
                id: nil,
                role: role,
                content: accumulatedContent.isEmpty ? "" : accumulatedContent,
                toolCalls: accumulatedToolCalls.isEmpty ? nil : accumulatedToolCalls
            ))
        }

        return alternatingMessages
    }

    // MARK: - Tool instruction building

    /// Build the tool-calling instructions appended to the system prompt.
    ///
    /// Produces a compact, ChatML-friendly directive that the universal
    /// `ToolCallExtractor` can parse back out. The format is intentionally minimal
    /// because it is appended to the system prompt on every turn - verbose
    /// instructions eat into the context window.
    ///
    /// - Parameter tools: The tool definitions to advertise.
    /// - Returns: A multi-line instruction string, or an empty string when no tools are present.
    public static func buildToolInstructions(_ tools: [OpenAITool]?) -> String {
        guard let tools = tools, !tools.isEmpty else { return "" }

        var instructions = """
        # Available Tools

        When making a tool call, respond with the EXACT tool request in raw JSON with no other response. Do not use code blocks, and do not respond conversationally.
        Format: {"name": "tool_name", "arguments": {"param": "value"}}

        """

        for tool in tools {
            instructions += "\(tool.function.name): \(tool.function.description)\n"

            if let paramsData = tool.function.parametersJson.data(using: .utf8),
               let params = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any],
               let properties = params["properties"] as? [String: Any] {
                let required = (params["required"] as? [String]) ?? []
                var paramList: [String] = []

                for (paramName, paramInfo) in properties.sorted(by: { $0.key < $1.key }) {
                    if let paramDict = paramInfo as? [String: Any] {
                        let paramType = paramDict["type"] as? String ?? "any"
                        let reqMark = required.contains(paramName) ? "*" : ""
                        paramList.append("\(paramName)\(reqMark):\(paramType)")
                    }
                }

                if !paramList.isEmpty {
                    instructions += "  Args: " + paramList.joined(separator: ", ") + "\n"
                }
            }
            instructions += "\n"
        }

        return instructions
    }

    // MARK: - Response parsing

    /// Extract the assistant's content from a ChatML response.
    ///
    /// Local models often echo the full chat template even when the chat-template
    /// engine is supposed to mask it. The response may look like:
    /// ```
    /// <|im_start|>assistant
    /// actual response
    /// <|im_end|>
    /// ```
    /// This strips the role tags and returns just the content. Falls back to the
    /// original string when no tags are present.
    public static func extractAssistantContent(_ response: String) -> String {
        var cleaned = response

        if let assistantStart = cleaned.range(of: "<|im_start|>assistant") {
            let afterTag = cleaned[assistantStart.upperBound...]

            var contentStart = afterTag.startIndex
            if afterTag.first == "\n" || afterTag.first == " " {
                contentStart = afterTag.index(after: contentStart)
            }

            if let endTag = afterTag.range(of: "<|im_end|>") {
                cleaned = String(afterTag[contentStart..<endTag.lowerBound])
            } else {
                cleaned = String(afterTag[contentStart...])
            }
        }

        cleaned = cleaned
            .replacingOccurrences(of: "<|im_start|>system", with: "")
            .replacingOccurrences(of: "<|im_start|>user", with: "")
            .replacingOccurrences(of: "<|im_start|>assistant", with: "")
            .replacingOccurrences(of: "<|im_start|>", with: "")
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<|endoftext|>", with: "")
            .replacingOccurrences(of: "</s>", with: "")

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse a model's raw output into cleaned content and tool calls.
    ///
    /// Wraps the universal `ToolCallExtractor` and converts its internal format
    /// into OpenAI-compatible `OpenAIToolCall`s. Both providers call this on the
    /// final accumulated text.
    public static func parseToolCalls(from response: String) -> (content: String, toolCalls: [OpenAIToolCall]?) {
        let cleanedResponse = extractAssistantContent(response)
        let (extractedCalls, cleanedContent, _) = toolCallExtractor.extract(from: cleanedResponse)

        guard !extractedCalls.isEmpty else {
            return (cleanedContent, nil)
        }

        let openAIToolCalls = extractedCalls.map { tc in
            OpenAIToolCall(
                id: tc.id ?? "call_\(UUID().uuidString)",
                type: "function",
                function: OpenAIFunctionCall(name: tc.name, arguments: tc.arguments)
            )
        }
        return (cleanedContent, openAIToolCalls)
    }

    // MARK: - System prompt and tool spec helpers

    /// Pull all consecutive system messages from the start of the conversation
    /// and return them concatenated plus the remaining non-system messages.
    ///
    /// The OpenAI request shape lets callers send multiple system messages
    /// (or none). Most chat templates expect a single system message at the
    /// top, so we merge everything before the first non-system message into
    /// one string and return that separately.
    ///
    /// - Returns: A tuple `(systemPrompt, nonSystemMessages)`. The system
    ///   prompt is `""` when the conversation has no system messages. The
    ///   non-system list preserves order from the original array.
    public static func extractSystemPrompt(from messages: [OpenAIChatMessage]) -> (systemPrompt: String, nonSystemMessages: [OpenAIChatMessage]) {
        var systemContent = ""
        var nonSystem: [OpenAIChatMessage] = []

        for (index, msg) in messages.enumerated() {
            if msg.role == "system" {
                if let content = msg.content, !content.isEmpty {
                    if !systemContent.isEmpty {
                        systemContent += "\n\n"
                    }
                    systemContent += content
                }
            } else {
                /// Once we hit a non-system message, append it plus the rest.
                nonSystem.append(contentsOf: messages[index...])
                break
            }
        }

        return (systemContent, nonSystem)
    }

    /// Convert OpenAI tool definitions to MLX's `ToolSpec` shape.
    ///
    /// MLX's chat template and `applyChatTemplate` consume tools as
    /// `[String: any Sendable]` dictionaries. This helper builds the
    /// structure the same way the original MLXProvider did inline.
    ///
    /// - Returns: The converted tools, or `nil` when input is nil/empty.
    public static func convertToolsToMLXSpec(_ tools: [OpenAITool]?) -> [ToolSpec]? {
        guard let tools = tools, !tools.isEmpty else { return nil }
        return tools.map { tool in
            var toolSpec: ToolSpec = [:]
            toolSpec["type"] = "function"

            var parameters: [String: any Sendable] = [:]
            if let data = tool.function.parametersJson.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: any Sendable] {
                parameters = parsed
            }

            toolSpec["function"] = [
                "name": tool.function.name,
                "description": tool.function.description,
                "parameters": parameters
            ] as [String: any Sendable]
            return toolSpec
        }
    }

    // MARK: - Response and chunk construction

    /// Build the final OpenAI-compatible non-streaming response.
    public static func buildChatResponse(
        model: String,
        content: String,
        toolCalls: [OpenAIToolCall]?,
        promptTokens: Int,
        completionTokens: Int,
        finishReason: LocalProviderEvent.FinishReason
    ) -> ServerOpenAIChatResponse {
        let finalContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasonString: String
        if let toolCalls = toolCalls, !toolCalls.isEmpty {
            reasonString = "tool_calls"
        } else {
            reasonString = finishReason.rawValue
        }

        return ServerOpenAIChatResponse(
            id: "chatcmpl-\(UUID().uuidString)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: model,
            choices: [
                OpenAIChatChoice(
                    index: 0,
                    message: OpenAIChatMessage(
                        role: "assistant",
                        content: finalContent,
                        toolCalls: toolCalls
                    ),
                    finishReason: reasonString
                )
            ],
            usage: ServerOpenAIUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: promptTokens + completionTokens
            )
        )
    }

    /// Build a streaming chunk. The final chunk carries the `finishReason` and the
    /// full `toolCalls` list (so the consumer sees them exactly once).
    public static func buildStreamChunk(
        model: String,
        content: String?,
        toolCalls: [OpenAIToolCall]?,
        finishReason: LocalProviderEvent.FinishReason?,
        includeRole: Bool = false
    ) -> ServerOpenAIChatStreamChunk {
        let choice: OpenAIChatStreamChoice
        if let text = content {
            choice = OpenAIChatStreamChoice(
                index: 0,
                delta: OpenAIChatDelta(
                    role: includeRole ? "assistant" : nil,
                    content: text,
                    toolCalls: nil
                ),
                finishReason: nil
            )
        } else if let calls = toolCalls {
            choice = OpenAIChatStreamChoice(
                index: 0,
                delta: OpenAIChatDelta(
                    role: includeRole ? "assistant" : nil,
                    content: nil,
                    toolCalls: calls
                ),
                finishReason: finishReason?.rawValue
            )
        } else {
            choice = OpenAIChatStreamChoice(
                index: 0,
                delta: OpenAIChatDelta(
                    role: includeRole ? "assistant" : nil,
                    content: nil,
                    toolCalls: nil
                ),
                finishReason: finishReason?.rawValue
            )
        }

        return ServerOpenAIChatStreamChunk(
            id: "chatcmpl-\(UUID().uuidString)",
            object: "chat.completion.chunk",
            created: Int(Date().timeIntervalSince1970),
            model: model,
            choices: [choice]
        )
    }

    // MARK: - Internals

    /// Shared universal tool-call extractor. `ToolCallExtractor.extract` is a pure
    /// function; the class is stateless. `nonisolated(unsafe)` lets us keep it as a
    /// static singleton rather than constructing a new instance per call.
    private nonisolated(unsafe) static let toolCallExtractor = ToolCallExtractor()
}
