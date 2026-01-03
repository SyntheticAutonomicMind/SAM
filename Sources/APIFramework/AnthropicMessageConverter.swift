// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Converts SAM's OpenAI-format messages to Anthropic MessageParam format This converter implements proper Anthropic API message formatting, adapted from industry-standard patterns.
public struct AnthropicMessageConverter {
    private static let logger = Logger(label: "com.sam.anthropic.converter")

    /// Content block types for Anthropic API.
    public struct ContentBlock {
        let type: String
        let data: [String: Any]
    }

    /// Result of message conversion.
    public struct ConversionResult {
        let messages: [[String: Any]]
        let systemMessage: String?
    }

    // MARK: - Main Conversion

    /// Convert OpenAI messages to Anthropic format - Parameter messages: Array of OpenAI-format messages - Returns: Tuple of (anthropic messages array, system message string).
    public static func convertMessages(_ messages: [OpenAIChatMessage]) -> ConversionResult {
        var anthropicMessages: [[String: Any]] = []
        var systemText = ""

        for message in messages {
            if message.role == "system" {
                /// Extract system messages separately - Anthropic requires these in a dedicated field.
                if let content = message.content, !content.isEmpty {
                    systemText += content + "\n"
                }
            } else if message.role == "user" || message.role == "assistant" {
                /// Check for batched tool results marker (from Claude preprocessing)
                if message.role == "user",
                   let content = message.content,
                   content.hasPrefix("__CLAUDE_BATCHED_TOOL_RESULTS__\n") {
                    /// Extract batched tool results JSON
                    let jsonString = String(content.dropFirst("__CLAUDE_BATCHED_TOOL_RESULTS__\n".count))
                    
                    if let jsonData = jsonString.data(using: .utf8),
                       let toolResults = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: String]] {
                        /// Convert batched tool results to tool_result content blocks
                        var toolResultBlocks: [[String: Any]] = []
                        
                        for toolResult in toolResults {
                            if let toolUseId = toolResult["tool_use_id"],
                               let resultContent = toolResult["content"] {
                                toolResultBlocks.append([
                                    "type": "tool_result",
                                    "tool_use_id": toolUseId,
                                    "content": resultContent
                                ])
                            }
                        }
                        
                        if !toolResultBlocks.isEmpty {
                            /// Add single user message with ALL tool results
                            anthropicMessages.append([
                                "role": "user",
                                "content": toolResultBlocks
                            ])
                            logger.debug("Converted batched tool results: \(toolResults.count) results in one message")
                        }
                    }
                    continue
                }
                
                /// Convert user/assistant messages to Anthropic format.
                let contentBlocks = convertMessageContent(message)

                /// Skip messages with empty content (can happen after filtering).
                if !contentBlocks.isEmpty {
                    anthropicMessages.append([
                        "role": message.role,
                        "content": contentBlocks
                    ])
                }
            } else if message.role == "tool" {
                /// Tool result messages need special handling In OpenAI: separate message with role="tool" In Anthropic: content block with type="tool_result" in user message.
                if let toolCallId = message.toolCallId {
                    let toolResultBlock: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": toolCallId,
                        "content": message.content ?? ""
                    ]

                    /// Tool results go in user messages in Anthropic.
                    anthropicMessages.append([
                        "role": "user",
                        "content": [toolResultBlock]
                    ])
                }
            }
        }

        /// Enforce message alternation (Anthropic requirement).
        anthropicMessages = enforceAlternation(anthropicMessages)

        /// Clean up system message.
        let finalSystem = systemText.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemMessage = finalSystem.isEmpty ? nil : finalSystem

        if systemMessage != nil {
            logger.debug("Converted \(messages.count) messages to \(anthropicMessages.count) Anthropic messages + system message")
        } else {
            logger.debug("Converted \(messages.count) messages to \(anthropicMessages.count) Anthropic messages")
        }

        return ConversionResult(
            messages: anthropicMessages,
            systemMessage: systemMessage
        )
    }

    // MARK: - Content Conversion

    /// Convert a single message's content to Anthropic content blocks.
    private static func convertMessageContent(_ message: OpenAIChatMessage) -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        /// Handle text content.
        if let text = message.content, !text.isEmpty {
            /// Anthropic errors on empty text blocks, so filter them out.
            blocks.append([
                "type": "text",
                "text": text
            ])
        }

        /// Handle tool calls (OpenAI format -> Anthropic tool_use blocks).
        if let toolCalls = message.toolCalls {
            for toolCall in toolCalls {
                /// Parse arguments JSON to dictionary.
                var input: [String: Any] = [:]
                if let data = toolCall.function.arguments.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    input = json
                }

                blocks.append([
                    "type": "tool_use",
                    "id": toolCall.id,
                    "name": toolCall.function.name,
                    "input": input
                ])
            }
        }

        /// Note: Thinking blocks, images, and cache control would be added here when SAM supports those content types in OpenAIChatMessage For now, we handle the core text + tool calling use case.

        return blocks
    }

    // MARK: - Message Alternation

    /// Enforce Anthropic's requirement: messages must alternate between user and assistant If consecutive messages have the same role, merge their content blocks.
    private static func enforceAlternation(_ messages: [[String: Any]]) -> [[String: Any]] {
        guard !messages.isEmpty else { return [] }

        var mergedMessages: [[String: Any]] = []

        for message in messages {
            guard let role = message["role"] as? String,
                  let content = message["content"] else {
                logger.warning("Skipping message with missing role or content")
                continue
            }

            /// Check if we can merge with previous message.
            if let lastMessage = mergedMessages.last,
               let lastRole = lastMessage["role"] as? String,
               lastRole == role {
                /// Same role as previous - merge content arrays.
                if var lastContent = lastMessage["content"] as? [[String: Any]],
                   let currentContent = content as? [[String: Any]] {
                    lastContent.append(contentsOf: currentContent)
                    mergedMessages[mergedMessages.count - 1] = [
                        "role": role,
                        "content": lastContent
                    ]
                    logger.debug("Merged consecutive \(role) messages")
                }
            } else {
                /// Different role or first message - add as new.
                mergedMessages.append(message)
            }
        }

        return mergedMessages
    }

    // MARK: - Validation

    /// Validate that messages follow Anthropic's requirements - Parameter messages: Array of converted messages - Returns: True if valid, false otherwise.
    public static func validateMessages(_ messages: [[String: Any]]) -> Bool {
        /// Check alternation.
        var lastRole: String?
        for message in messages {
            guard let role = message["role"] as? String else {
                logger.error("Message missing role field")
                return false
            }

            if let last = lastRole, last == role {
                logger.error("Messages not alternating: consecutive \(role) messages found")
                return false
            }

            lastRole = role
        }

        /// Check content not empty.
        for message in messages {
            guard let content = message["content"] as? [[String: Any]],
                  !content.isEmpty else {
                logger.error("Message has empty content")
                return false
            }
        }

        return true
    }

    // MARK: - Helper Methods

    /// Convert Anthropic messages back to OpenAI format (for logging/debugging) This is a simplified conversion for display purposes only.
    public static func convertFromAnthropic(_ anthropicMessages: [[String: Any]]) -> [OpenAIChatMessage] {
        var messages: [OpenAIChatMessage] = []

        for message in anthropicMessages {
            guard let role = message["role"] as? String,
                  let content = message["content"] else {
                continue
            }

            /// Simple text extraction for now.
            var textContent = ""
            if let contentString = content as? String {
                textContent = contentString
            } else if let contentArray = content as? [[String: Any]] {
                for block in contentArray {
                    if let type = block["type"] as? String, type == "text",
                       let text = block["text"] as? String {
                        textContent += text
                    }
                }
            }

            messages.append(OpenAIChatMessage(role: role, content: textContent))
        }

        return messages
    }
}
