// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Automatic secret and PII redaction with configurable levels.
///
/// Detects and redacts sensitive information from text before display or transmission to AI providers.
///
/// Pattern categories:
/// - **PII**: SSN, phone numbers, credit cards, email addresses
/// - **Crypto**: Private keys, database connection strings with passwords
/// - **API keys**: AWS, GitHub, Stripe, Google, OpenAI, Anthropic, Slack, Discord, etc.
/// - **Tokens**: JWT, Bearer tokens, Basic auth headers
///
/// Redaction levels:
/// ```
/// Category       | strict | standard | api_permissive | pii | off
/// PII            | redact | redact   | redact         | yes |
/// Private keys   | redact | redact   | redact         |     |
/// DB passwords   | redact | redact   | redact         |     |
/// API keys       | redact | redact   | allow          |     |
/// Tokens         | redact | redact   | allow          |     |
/// ```
public final class SecretRedactor: @unchecked Sendable {

    private static let logger = Logger(label: "com.sam.security.SecretRedactor")

    /// Shared singleton instance.
    public static let shared = SecretRedactor()

    // MARK: - Types

    /// Redaction level controls which pattern categories are applied.
    public enum Level: String, Sendable, CaseIterable {
        /// Redact everything: PII, crypto, API keys, tokens.
        case strict
        /// Same as strict (recommended for most use cases).
        case standard
        /// Allow API keys/tokens to pass through. PII and crypto still redacted.
        case apiPermissive = "api_permissive"
        /// Only redact PII (SSN, credit cards, phone, email). Default.
        case pii
        /// No redaction. Use with extreme caution.
        case off
    }

    private enum PatternCategory {
        case pii
        case crypto
        case apiKeys
        case tokens
    }

    // MARK: - Configuration

    /// Current redaction level.
    public var level: Level

    /// Text used to replace redacted content.
    public let redactionText: String

    /// Values that should never be redacted.
    private let whitelist: Set<String> = Set([
        "example", "test", "demo", "sample", "mock", "localhost",
        "127.0.0.1", "::1", "0.0.0.0",
        "development", "staging", "production",
        "readme", "license", "changelog", "undefined",
        "placeholder", "dummy", "foobar", "redacted",
        "true", "false", "null"
    ])

    // MARK: - Pattern Definitions

    /// PII patterns: most critical, always redacted in strict/standard/api_permissive/pii.
    private static let piiPatterns: [NSRegularExpression] = {
        let patterns: [String] = [
            // Email addresses
            #"\b[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,63}\b"#,
            // US Social Security Numbers
            #"\b\d{3}-\d{2}-\d{4}\b"#,
            // US Phone numbers (various formats)
            #"(?:\+1[-.\s]?)?(?:\(\d{3}\)|\d{3})[-.\s]?\d{3}[-.\s]?\d{4}"#,
            // Credit card numbers (16 digits, various separators)
            #"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"#,
            // UK National Insurance numbers
            #"(?i)\b[A-CEGHJ-PR-TW-Z]{2}\s?\d{2}\s?\d{2}\s?\d{2}\s?[A-D]\b"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    /// Cryptographic material and database credentials.
    private static let cryptoPatterns: [NSRegularExpression] = {
        let patterns: [String] = [
            // PEM-encoded private keys (full block, multi-line)
            #"-----BEGIN\s+(?:RSA\s+|DSA\s+|EC\s+|OPENSSH\s+|ENCRYPTED\s+)?PRIVATE\s+KEY-----[\s\S]*?-----END\s+(?:RSA\s+|DSA\s+|EC\s+|OPENSSH\s+|ENCRYPTED\s+)?PRIVATE\s+KEY-----"#,
            // PostgreSQL connection strings with password
            #"postgres(?:ql)?://[^:]+:[^@]+@[^\s/]+"#,
            // MySQL connection strings with password
            #"mysql://[^:]+:[^@]+@[^\s/]+"#,
            // MongoDB connection strings with password
            #"mongodb(?:\+srv)?://[^:]+:[^@]+@[^\s/]+"#,
            // Redis connection strings with password
            #"redis://:[^@]+@[^\s/]+"#,
            #"redis://[^:]+:[^@]+@[^\s/]+"#,
            // ODBC connection strings with password
            #"(?i)(?:Password|Pwd)\s*=\s*[^;'"\s]{8}"#,
            // Password assignments
            #"(?i)(?:password|passwd|pwd)\s*[:=]\s*["']?[^\s'"]{8}["']?"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    /// API key patterns.
    private static let apiKeyPatterns: [NSRegularExpression] = {
        let patterns: [String] = [
            // AWS Access Key ID
            #"AKIA[0-9A-Z]{16}"#,
            // AWS Secret Access Key
            #"(?i)aws[_\-]?secret[_\-]?(?:access[_\-]?)?key\s*[:=]\s*["']?[a-zA-Z0-9+/]{40}["']?"#,
            // GitHub tokens (Personal, OAuth, etc.)
            #"gh[pous]_[a-zA-Z0-9]{36}"#,
            // GitHub fine-grained tokens
            #"github_pat_[a-zA-Z0-9]{22}_[a-zA-Z0-9]{59}"#,
            // Stripe keys
            #"sk_(?:live|test)_[0-9a-zA-Z]{24}"#,
            #"pk_(?:live|test)_[0-9a-zA-Z]{24}"#,
            #"rk_(?:live|test)_[0-9a-zA-Z]{24}"#,
            // Google Cloud API keys
            #"AIza[0-9A-Za-z\-_]{35}"#,
            // OpenAI API keys
            #"sk-[a-zA-Z0-9]{48}"#,
            #"sk-proj-[a-zA-Z0-9\-_]{64}"#,
            // Anthropic API keys
            #"sk-ant-[a-zA-Z0-9\-_]{95}"#,
            // Slack tokens
            #"xox[baprs]-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24}"#,
            #"xoxe\.xox[bp]-1-[a-zA-Z0-9]{60}"#,
            // Slack webhooks
            #"https?://hooks\.slack\.com/services/T[A-Z0-9]{8}/B[A-Z0-9]{8}/[a-zA-Z0-9]{24}"#,
            // Discord tokens and webhooks
            #"[MN][A-Za-z\d]{23,27}\.[A-Za-z\d\-_]{6}\.[A-Za-z\d\-_]{27,40}"#,
            #"https?://discord(?:app)?\.com/api/webhooks/\d+/[a-zA-Z0-9_\-]+"#,
            // Twilio Account SID and Auth Token
            #"(?i)AC[a-f0-9]{32}"#,
            #"(?i)SK[a-f0-9]{32}"#,
            // Generic key=value patterns
            #"(?i)(?:api[_\-]?key|secret[_\-]?key|access[_\-]?token|auth[_\-]?token|private[_\-]?key)\s*[:=]\s*["']?[a-zA-Z0-9_\-\.]{12}["']?"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    /// Authentication token patterns.
    private static let tokenPatterns: [NSRegularExpression] = {
        let patterns: [String] = [
            // JWT tokens (3 base64 segments)
            #"eyJ[a-zA-Z0-9_\-]+\.eyJ[a-zA-Z0-9_\-]+\.[a-zA-Z0-9_\-]+"#,
            // Bearer tokens in headers
            #"(?i)Bearer\s+[a-zA-Z0-9_\-\.]{20,256}"#,
            // Authorization: Basic header
            #"(?i)Authorization:\s*Basic\s+[A-Za-z0-9+/]{20}={0,2}"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    /// Map from level to active pattern categories.
    private static let levelCategories: [Level: [PatternCategory]] = [
        .strict: [.pii, .crypto, .apiKeys, .tokens],
        .standard: [.pii, .crypto, .apiKeys, .tokens],
        .apiPermissive: [.pii, .crypto],
        .pii: [.pii],
        .off: [],
    ]

    // MARK: - Init

    /// Create a new SecretRedactor.
    /// - Parameters:
    ///   - level: Redaction level (default: .pii)
    ///   - redactionText: Replacement text (default: "[REDACTED]")
    public init(level: Level = .pii, redactionText: String = "[REDACTED]") {
        self.level = level
        self.redactionText = redactionText
    }

    // MARK: - Public API

    /// Redact secrets and PII from text.
    ///
    /// - Parameters:
    ///   - text: Input text
    ///   - level: Override redaction level (defaults to instance level)
    /// - Returns: Text with secrets replaced by redaction text
    public func redact(_ text: String, level: Level? = nil) -> String {
        let activeLevel = level ?? self.level
        guard activeLevel != .off else { return text }
        guard !text.isEmpty else { return text }

        let patterns = Self.patternsForLevel(activeLevel)
        var result = text

        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: redactionText)
        }

        return result
    }

    /// Redact secrets from a JSON-encodable data structure (for tool results).
    ///
    /// Walks the structure recursively, redacting any string values.
    ///
    /// - Parameters:
    ///   - value: Any JSON-compatible value (String, Array, Dictionary, Number, etc.)
    ///   - level: Override redaction level
    /// - Returns: Redacted copy of the value
    public func redactAny(_ value: Any, level: Level? = nil) -> Any {
        if let str = value as? String {
            return redact(str, level: level)
        } else if let dict = value as? [String: Any] {
            var result = [String: Any]()
            for (key, val) in dict {
                result[key] = redactAny(val, level: level)
            }
            return result
        } else if let array = value as? [Any] {
            return array.map { redactAny($0, level: level) }
        } else {
            return value
        }
    }

    /// Check if text contains any detectable secrets.
    ///
    /// - Parameters:
    ///   - text: Input text
    ///   - level: Override redaction level
    /// - Returns: true if secrets were detected
    public func containsSecrets(_ text: String, level: Level? = nil) -> Bool {
        let activeLevel = level ?? self.level
        guard activeLevel != .off else { return false }
        guard !text.isEmpty else { return false }

        let patterns = Self.patternsForLevel(activeLevel)
        let nsRange = NSRange(text.startIndex..., in: text)

        for pattern in patterns {
            if pattern.firstMatch(in: text, options: [], range: nsRange) != nil {
                return true
            }
        }

        return false
    }

    // MARK: - Internal

    /// Get compiled regex patterns for a given redaction level.
    private static func patternsForLevel(_ level: Level) -> [NSRegularExpression] {
        let categories = levelCategories[level] ?? []
        var patterns: [NSRegularExpression] = []

        for category in categories {
            switch category {
            case .pii: patterns.append(contentsOf: piiPatterns)
            case .crypto: patterns.append(contentsOf: cryptoPatterns)
            case .apiKeys: patterns.append(contentsOf: apiKeyPatterns)
            case .tokens: patterns.append(contentsOf: tokenPatterns)
            }
        }

        return patterns
    }
}
