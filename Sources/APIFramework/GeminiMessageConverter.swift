// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Converts SAM's OpenAI-format messages to Google Gemini Content format This converter implements proper Gemini API message formatting, adapted from industry-standard patterns.
public struct GeminiMessageConverter {
    private static let logger = Logger(label: "com.sam.gemini.converter")

    /// Part types for Gemini API.
    public enum PartType: String {
        case text
        case inlineData
        case functionCall
        case functionResponse
    }

    /// Result of message conversion.
    public struct ConversionResult {
        let contents: [[String: Any]]
        let systemInstruction: [String: Any]?
    }

    // MARK: - Public API

    /// Convert OpenAI messages to Gemini format Returns (contents: [[String: Any]], systemInstruction: [String: Any]?).
    public static func convert(messages: [OpenAIChatMessage]) -> ConversionResult {
        var contents: [[String: Any]] = []
        var systemParts: [[String: Any]] = []

        for message in messages {
            if message.role == "system" {
                /// Extract system messages separately for systemInstruction.
                if let content = message.content, !content.isEmpty {
                    systemParts.append([
                        "text": content
                    ])
                }
            } else {
                /// Convert user/assistant messages.
                let role = message.role == "assistant" ? "model" : "user"
                let parts = convertContentToParts(message)

                if !parts.isEmpty {
                    contents.append([
                        "role": role,
                        "parts": parts
                    ])
                }
            }
        }

        /// Build systemInstruction if we have system messages.
        let systemInstruction: [String: Any]? = systemParts.isEmpty ? nil : [
            "role": "user",
            "parts": systemParts
        ]

        logger.debug("Converted \(messages.count) messages to \(contents.count) Gemini contents")
        if systemInstruction != nil {
            logger.debug("Created system instruction with \(systemParts.count) parts")
        }

        return ConversionResult(contents: contents, systemInstruction: systemInstruction)
    }

    // MARK: - Helper Methods

    /// Convert message content to Gemini parts.
    private static func convertContentToParts(_ message: OpenAIChatMessage) -> [[String: Any]] {
        var parts: [[String: Any]] = []

        /// Handle text content.
        if let text = message.content, !text.isEmpty {
            parts.append([
                "text": text
            ])
        }

        /// Handle tool calls (convert to functionCall parts).
        if let toolCalls = message.toolCalls {
            for toolCall in toolCalls {
                let function = toolCall.function

                /// Parse arguments (they come as JSON string).
                var args: [String: Any] = [:]
                let argsString = function.arguments
                if let argsData = argsString.data(using: .utf8),
                   let parsedArgs = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                    args = parsedArgs
                }

                parts.append([
                    "functionCall": [
                        "name": function.name,
                        "args": args
                    ]
                ])

                logger.debug("Converted tool call '\(function.name)' to functionCall part")
            }
        }

        /// Handle tool results (convert to functionResponse parts).
        if let toolCallId = message.toolCallId,
           let content = message.content {
            /// Extract function name from tool call ID (format: functionName_timestamp).
            let functionName = toolCallId.split(separator: "_").first.map(String.init) ?? "unknown_function"

            /// Try to parse content as JSON for structured response.
            var response: Any = content
            if let contentData = content.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: contentData) {
                response = jsonObject
            } else {
                /// Wrap plain text in object.
                response = ["result": content]
            }

            parts.append([
                "functionResponse": [
                    "name": functionName,
                    "response": response
                ]
            ])

            logger.debug("Converted tool result for '\(functionName)' to functionResponse part")
        }

        /// Future feature: Image data support (inlineData parts with base64 encoding) This would handle message.contentParts or similar multipart content.

        return parts
    }
}
