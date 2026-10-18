// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Shared utility for converting non-streaming OpenAI-compatible responses
/// into simulated streaming chunks.
///
/// This is the fallback streaming implementation used by providers that don't
/// have native SSE support. Providers with native SSE (OpenRouter, MiniMax,
/// GitHub Copilot, RemoteLlama) override `processStreamingChatCompletion`
/// and don't call this.
///
/// Previously this logic was duplicated verbatim across 7 providers with 3
/// different variants. This single implementation is the superset:
/// - Handles `reasoning_content` (from llama.cpp-style servers) via ThinkTagFormatter
/// - Emits tool call deltas individually
/// - Preserves blank lines for markdown rendering
/// - Computes the correct finish reason based on whether tool calls are present
public struct OpenAIStreamConverter {

    /// Simulated streaming delay in nanoseconds (50ms).
    /// Providers using the fallback streaming implementation sleep for this
    /// duration between chunks to simulate real-time token delivery.
    public static let fallbackStreamDelay: UInt64 = 50_000_000

    /// Convert a non-streaming OpenAI-compatible response into an array of
    /// streaming chunks suitable for `AsyncThrowingStream` continuation.
    ///
    /// - Parameter response: The full non-streaming response to convert.
    /// - Parameter logger: Optional logger for debug diagnostics. If nil,
    ///   no diagnostic output is produced.
    /// - Returns: Array of `ServerOpenAIChatStreamChunk` chunks.
    public static func convertToStreamChunks(
        _ response: ServerOpenAIChatResponse,
        logger: Logger? = nil
    ) -> [ServerOpenAIChatStreamChunk] {
        guard let choice = response.choices.first else {
            logger?.debug("convertToStreamChunks: No choices in response, returning empty")
            return []
        }

        var chunks: [ServerOpenAIChatStreamChunk] = []
        var mainContent = choice.message.content ?? ""
        let reasoningContent = choice.message.reasoningContent

        logger?.debug("convertToStreamChunks: content=\(mainContent.prefix(100)), reasoningContent=\(reasoningContent?.prefix(100) ?? "nil")")

        // Process reasoning content through ThinkTagFormatter (for llama.cpp-style
        // servers that put reasoning in the reasoning_content field).
        if let reasoning = reasoningContent, !reasoning.isEmpty {
            var formatter = ThinkTagFormatter(hideThinking: false)
            let (formattedReasoning, _) = formatter.processChunk(reasoning)
            let flushedReasoning = formatter.flushBuffer()
            let fullReasoning = formattedReasoning + flushedReasoning

            if !fullReasoning.isEmpty {
                // Yield reasoning as a thinking tool message to trigger thinking card UI.
                chunks.append(ServerOpenAIChatStreamChunk(
                    id: response.id,
                    object: "chat.completion.chunk",
                    created: response.created,
                    model: response.model,
                    choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: nil))],
                    isToolMessage: true,
                    toolName: "thinking",
                    toolDetails: [fullReasoning]
                ))
            }

            // If content was empty and we had reasoning, the thinking IS the response.
            // Don't add empty content — the thinking was the response.
            if mainContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mainContent = ""
            }
        }

        // First chunk: set role to "assistant".
        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(role: "assistant", content: nil))]
        ))

        // Handle tool calls if present.
        if let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty {
            for toolCall in toolCalls {
                chunks.append(ServerOpenAIChatStreamChunk(
                    id: response.id,
                    object: "chat.completion.chunk",
                    created: response.created,
                    model: response.model,
                    choices: [OpenAIChatStreamChoice(
                        index: 0,
                        delta: OpenAIChatDelta(
                            content: nil,
                            toolCalls: [toolCall]
                        )
                    )]
                ))
            }

            // Final chunk: signal tool_calls finish.
            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "tool_calls")]
            ))
        } else {
            // No tool calls: stream text content word-by-word, preserving newlines.
            let lines = mainContent.components(separatedBy: .newlines)
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)

                if trimmedLine.isEmpty {
                    // Preserve blank line (paragraph break) for markdown rendering.
                    chunks.append(ServerOpenAIChatStreamChunk(
                        id: response.id,
                        object: "chat.completion.chunk",
                        created: response.created,
                        model: response.model,
                        choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: "\n"))]
                    ))
                    continue
                }

                let words = trimmedLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                for (index, word) in words.enumerated() {
                    let suffix = index < words.count - 1 ? " " : "\n"
                    chunks.append(ServerOpenAIChatStreamChunk(
                        id: response.id,
                        object: "chat.completion.chunk",
                        created: response.created,
                        model: response.model,
                        choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(content: word + suffix))]
                    ))
                }
            }

            // Final chunk: signal stop.
            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(index: 0, delta: OpenAIChatDelta(), finishReason: "stop")]
            ))
        }

        return chunks
    }
}
