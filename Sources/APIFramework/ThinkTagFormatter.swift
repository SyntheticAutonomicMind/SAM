// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

private let formatterLogger = Logger(label: "com.sam.formatter.ThinkTagFormatter")

/// Universal formatter for <think></think> tags in LLM output Handles streaming content where think blocks may arrive across multiple chunks Used by both llama.cpp and MLX local model providers.
public struct ThinkTagFormatter {
    /// State machine for tracking think tag parsing across streaming chunks.
    private var insideThinkTag: Bool = false
    private var thinkingBuffer: String = ""

    /// Whether to show formatted thinking or hide it completely.
    private let hideThinking: Bool

    public init(hideThinking: Bool = false) {
        self.hideThinking = hideThinking
        if hideThinking {
            formatterLogger.info("ThinkTagFormatter: Initialized with hideThinking=TRUE (reasoning disabled)")
        } else {
            formatterLogger.info("ThinkTagFormatter: Initialized with hideThinking=FALSE (reasoning enabled)")
        }
    }

    /// Process a streaming text chunk and handle think tags Returns: (processedText, isBuffering) - processedText: Formatted text to yield (may be empty if buffering) - isBuffering: true if currently inside a think block (content buffered, not yielded).
    public mutating func processChunk(_ text: String) -> (processedText: String, isBuffering: Bool) {
        var processedText = text
        var output = ""

        /// Check if we're entering a <think> tag.
        if text.contains("<think>") && !insideThinkTag {
            insideThinkTag = true
            thinkingBuffer = ""

            /// Extract any content BEFORE <think> tag and yield it.
            if let thinkStartRange = text.range(of: "<think>") {
                let beforeThink = String(text[..<thinkStartRange.lowerBound])
                if !beforeThink.isEmpty {
                    output += beforeThink
                }
                /// Start accumulating from <think> onwards.
                thinkingBuffer = String(text[thinkStartRange.lowerBound...])
                processedText = ""
            }
        }

        /// If inside <think> tag, accumulate content.
        if insideThinkTag {
            thinkingBuffer += processedText

            /// Check if we've received the closing </think> tag.
            if thinkingBuffer.contains("</think>") {
                /// Complete thinking block received.
                if let thinkEndRange = thinkingBuffer.range(of: "</think>") {
                    let thinkContent = String(thinkingBuffer[..<thinkEndRange.upperBound])
                    let afterThinkContent = String(thinkingBuffer[thinkEndRange.upperBound...])

                    formatterLogger.info("ThinkTagFormatter: Complete <think> block detected, hideThinking=\(hideThinking)")

                    /// Format or hide the thinking block based on setting.
                    if !hideThinking {
                        formatterLogger.info("ThinkTagFormatter: Formatting thinking block for display")
                        /// Extract content between <think> and </think> and format it.
                        if let thinkStartRange = thinkContent.range(of: "<think>"),
                           let thinkEndRange = thinkContent.range(of: "</think>") {
                            let contentRange = thinkStartRange.upperBound..<thinkEndRange.lowerBound
                            let reasoning = String(thinkContent[contentRange])
                            let formatted = "Thinking: \(reasoning.trimmingCharacters(in: .whitespacesAndNewlines))\n\n---\n\n"

                            /// Yield formatted thinking block with divider.
                            output += formatted
                        }
                    } else {
                        formatterLogger.info("ThinkTagFormatter: HIDING thinking block (not outputting to user)")
                    }
                    /// If hideThinking is true, we simply don't output anything for the think block.

                    /// Exit thinking mode.
                    insideThinkTag = false
                    thinkingBuffer = ""

                    /// Process any content after </think> tag.
                    if !afterThinkContent.isEmpty {
                        output += afterThinkContent
                    }
                }
            }
            /// Don't yield text while inside <think> block (buffering).
            return (output, true)
        } else {
            /// Not inside <think> tag - yield text normally.
            output += processedText
            return (output, false)
        }
    }

    /// Flush any buffered think content when generation completes Call this when stream ends to handle incomplete think blocks Returns: Formatted buffered content (empty if no buffering occurred or if hiding).
    public mutating func flushBuffer() -> String {
        guard insideThinkTag && !thinkingBuffer.isEmpty else {
            return ""
        }

        /// If hiding thinking, just clear the buffer and return empty.
        if hideThinking {
            insideThinkTag = false
            thinkingBuffer = ""
            return ""
        }

        formatterLogger.warning("Generation stopped mid-<think> block - flushing \(thinkingBuffer.count) buffered chars")

        /// Format partial thinking block with divider.
        let formatted = "Thinking: \(thinkingBuffer.replacingOccurrences(of: "<think>", with: "").trimmingCharacters(in: .whitespacesAndNewlines))\n\n---\n\n"

        /// Reset state.
        insideThinkTag = false
        thinkingBuffer = ""

        return formatted
    }

    /// Reset formatter state (useful for new generation).
    public mutating func reset() {
        insideThinkTag = false
        thinkingBuffer = ""
    }
}
