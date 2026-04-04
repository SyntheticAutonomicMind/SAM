// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Unified security pipeline that orchestrates all security components.
///
/// Provides single-call methods for common security operations:
/// - Sanitizing untrusted input (invisible char filtering)
/// - Redacting secrets from tool output before sending to AI
///
/// Usage:
/// ```swift
/// // Sanitize user input before processing
/// let clean = SecurityPipeline.sanitizeInput(userText)
///
/// // Redact secrets from tool output before sending to LLM
/// let safe = SecurityPipeline.sanitizeToolOutput(toolResult)
/// ```
public struct SecurityPipeline: Sendable {

    private static let logger = Logger(label: "com.sam.security.pipeline")

    // MARK: - Input Sanitization

    /// Sanitize untrusted input text.
    ///
    /// Applies invisible character filtering to remove potential prompt injection vectors.
    /// Use on: user messages, custom instructions, system prompt includes, file content
    /// read by tools that will be included in AI context.
    ///
    /// - Parameter text: Raw input text
    /// - Returns: Sanitized text with invisible characters removed/normalized
    public static func sanitizeInput(_ text: String?) -> String? {
        guard let text = text else { return nil }

        let hadInvisible = InvisibleCharFilter.hasInvisibleChars(text)

        if hadInvisible {
            let description = InvisibleCharFilter.describe(text)
            logger.warning("Invisible characters detected in input: \(description.summary)")
        }

        return InvisibleCharFilter.filter(text)
    }

    /// Sanitize untrusted input, returning empty string instead of nil.
    ///
    /// - Parameter text: Raw input text
    /// - Returns: Sanitized text (never nil)
    public static func sanitizeInputNonNil(_ text: String) -> String {
        return sanitizeInput(text) ?? ""
    }

    // MARK: - Tool Output Sanitization

    /// Sanitize tool output before sending to AI provider.
    ///
    /// Applies:
    /// 1. Invisible character filtering (defense against injection via file content)
    /// 2. Secret redaction (prevent credential leakage to AI provider)
    ///
    /// - Parameters:
    ///   - text: Raw tool output
    ///   - redactionLevel: Secret redaction level (default: .pii)
    /// - Returns: Sanitized, redacted tool output
    public static func sanitizeToolOutput(
        _ text: String,
        redactionLevel: SecretRedactor.Level = .pii
    ) -> String {
        // Step 1: Remove invisible characters (file content read by tools could contain them)
        let filtered = InvisibleCharFilter.filter(text) ?? text

        // Step 2: Redact secrets
        let redacted = SecretRedactor.shared.redact(filtered, level: redactionLevel)

        return redacted
    }

    // MARK: - Batch Operations

    /// Sanitize an array of message contents (for conversation history).
    ///
    /// - Parameter messages: Array of message content strings
    /// - Returns: Array of sanitized strings
    public static func sanitizeMessages(_ messages: [String]) -> [String] {
        return messages.map { sanitizeInputNonNil($0) }
    }
}
