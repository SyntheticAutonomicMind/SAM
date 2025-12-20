// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// Utility for estimating token counts in text content Uses a simple heuristic: 1 token ≈ 4 characters (conservative estimate for English text) This is faster than tokenization and sufficient for preventing context window overflows.
public enum TokenEstimator {
    /// Characters per token (conservative estimate).
    private static let charsPerToken: Double = 4.0

    /// Estimate token count for a string - Parameter text: The text to estimate tokens for - Returns: Estimated number of tokens.
    public static func estimateTokens(_ text: String) -> Int {
        let charCount = text.count
        return Int(ceil(Double(charCount) / charsPerToken))
    }

    /// Check if text would exceed a token limit - Parameters: - text: The text to check - limit: Maximum token count allowed - Returns: True if text exceeds limit.
    public static func exceedsLimit(_ text: String, limit: Int) -> Bool {
        return estimateTokens(text) > limit
    }

    /// Truncate text to fit within a token limit - Parameters: - text: The text to truncate - limit: Maximum token count allowed - Returns: Truncated text that fits within limit.
    public static func truncate(_ text: String, toTokenLimit limit: Int) -> String {
        let estimatedTokens = estimateTokens(text)

        guard estimatedTokens > limit else {
            return text
        }

        /// Calculate character limit (with some buffer).
        let maxChars = Int(Double(limit) * charsPerToken * 0.95)

        guard text.count > maxChars else {
            return text
        }

        /// Truncate to character limit.
        let truncated = String(text.prefix(maxChars))
        return truncated + "\n\n[Content truncated to fit token limit. Original size: \(estimatedTokens) tokens, truncated to \(limit) tokens]"
    }

    /// Split text into chunks that fit within a token limit - Parameters: - text: The text to split - chunkLimit: Maximum tokens per chunk - Returns: Array of text chunks, each within the token limit.
    public static func splitIntoChunks(_ text: String, chunkLimit: Int) -> [String] {
        let totalTokens = estimateTokens(text)

        guard totalTokens > chunkLimit else {
            return [text]
        }

        /// Split by lines first.
        let lines = text.components(separatedBy: .newlines)
        var chunks: [String] = []
        var currentChunk: [String] = []
        var currentTokens = 0

        for line in lines {
            let lineTokens = estimateTokens(line)

            if currentTokens + lineTokens > chunkLimit && !currentChunk.isEmpty {
                /// Current chunk is full, start new one.
                chunks.append(currentChunk.joined(separator: "\n"))
                currentChunk = [line]
                currentTokens = lineTokens
            } else {
                currentChunk.append(line)
                currentTokens += lineTokens
            }
        }

        /// Add remaining chunk.
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.joined(separator: "\n"))
        }

        return chunks
    }
}
