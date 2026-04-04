// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Defense against invisible Unicode character injection in AI pipelines.
///
/// Detects and removes invisible and dangerous Unicode characters that can be used for
/// prompt injection attacks. Invisible characters can:
/// - Hide malicious instructions inside otherwise-visible text
/// - Use BiDi overrides to reverse displayed text, making dangerous instructions appear benign
/// - Encode entirely hidden text via Unicode Tag block characters (U+E0000-U+E007F)
/// - Break token boundaries to defeat other security filters
///
/// Apply to: system prompts, custom instructions, AI response content, file content read by tools.
public struct InvisibleCharFilter: Sendable {

    private static let logger = Logger(label: "com.sam.security.InvisibleCharFilter")

    // MARK: - Character Definitions

    /// Zero-width and invisible formatting characters.
    /// These render as nothing but are present in the string.
    private static let zeroWidthChars: Set<Unicode.Scalar> = [
        "\u{200B}",   // ZERO WIDTH SPACE
        "\u{200C}",   // ZERO WIDTH NON-JOINER
        "\u{200D}",   // ZERO WIDTH JOINER
        "\u{2060}",   // WORD JOINER
        "\u{2061}",   // FUNCTION APPLICATION (math)
        "\u{2062}",   // INVISIBLE TIMES (math)
        "\u{2063}",   // INVISIBLE SEPARATOR (math)
        "\u{2064}",   // INVISIBLE PLUS (math)
        "\u{FEFF}",   // BOM / ZERO WIDTH NO-BREAK SPACE (mid-string use is suspicious)
    ]

    /// BiDi (Bidirectional) control characters.
    /// Can reverse display order of text, making malicious content appear harmless.
    private static let bidiControls: Set<Unicode.Scalar> = [
        "\u{202A}",   // LEFT-TO-RIGHT EMBEDDING
        "\u{202B}",   // RIGHT-TO-LEFT EMBEDDING
        "\u{202C}",   // POP DIRECTIONAL FORMATTING
        "\u{202D}",   // LEFT-TO-RIGHT OVERRIDE
        "\u{202E}",   // RIGHT-TO-LEFT OVERRIDE (most commonly abused)
        "\u{2066}",   // LEFT-TO-RIGHT ISOLATE
        "\u{2067}",   // RIGHT-TO-LEFT ISOLATE
        "\u{2068}",   // FIRST STRONG ISOLATE
        "\u{2069}",   // POP DIRECTIONAL ISOLATE
        "\u{200E}",   // LEFT-TO-RIGHT MARK
        "\u{200F}",   // RIGHT-TO-LEFT MARK
    ]

    /// Interlinear annotation characters (hidden annotation anchors).
    private static let interlinearChars: Set<Unicode.Scalar> = [
        "\u{FFF9}",   // INTERLINEAR ANNOTATION ANCHOR
        "\u{FFFA}",   // INTERLINEAR ANNOTATION SEPARATOR
        "\u{FFFB}",   // INTERLINEAR ANNOTATION TERMINATOR
    ]

    /// Object replacement character (invisible placeholder).
    private static let objectChars: Set<Unicode.Scalar> = [
        "\u{FFFC}",   // OBJECT REPLACEMENT CHARACTER
        // U+FFFD (REPLACEMENT CHARACTER) is kept - it's a legitimate UTF-8 error marker
    ]

    /// Whitespace variants that should be normalized (not stripped).
    /// Key: unusual whitespace, Value: replacement character.
    private static let normalizeWhitespace: [Unicode.Scalar: Character] = [
        "\u{00A0}": " ",    // NO-BREAK SPACE
        "\u{1680}": " ",    // OGHAM SPACE MARK
        "\u{2000}": " ",    // EN QUAD
        "\u{2001}": " ",    // EM QUAD
        "\u{2002}": " ",    // EN SPACE
        "\u{2003}": " ",    // EM SPACE
        "\u{2004}": " ",    // THREE-PER-EM SPACE
        "\u{2005}": " ",    // FOUR-PER-EM SPACE
        "\u{2006}": " ",    // SIX-PER-EM SPACE
        "\u{2007}": " ",    // FIGURE SPACE
        "\u{2008}": " ",    // PUNCTUATION SPACE
        "\u{2009}": " ",    // THIN SPACE
        "\u{200A}": " ",    // HAIR SPACE
        "\u{202F}": " ",    // NARROW NO-BREAK SPACE
        "\u{205F}": " ",    // MEDIUM MATHEMATICAL SPACE
        "\u{3000}": " ",    // IDEOGRAPHIC SPACE
        "\u{2028}": "\n",   // LINE SEPARATOR -> real newline
        "\u{2029}": "\n",   // PARAGRAPH SEPARATOR -> real newline
    ]

    // MARK: - Scalar Classification

    /// Check if a Unicode scalar should be stripped outright.
    private static func shouldStrip(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value

        // Zero-width characters
        if zeroWidthChars.contains(scalar) { return true }

        // BiDi controls
        if bidiControls.contains(scalar) { return true }

        // Interlinear annotation
        if interlinearChars.contains(scalar) { return true }

        // Object replacement
        if objectChars.contains(scalar) { return true }

        // Unicode Tag block: U+E0000-U+E007F
        if value >= 0xE0000 && value <= 0xE007F { return true }

        // Variation selectors: U+FE00-U+FE0F, U+E0100-U+E01EF
        if (value >= 0xFE00 && value <= 0xFE0F) ||
           (value >= 0xE0100 && value <= 0xE01EF) { return true }

        // Soft hyphen
        if value == 0x00AD { return true }

        // Null byte
        if value == 0x0000 { return true }

        // C0 control characters (except TAB 0x09, LF 0x0A, CR 0x0D)
        if (value >= 0x0001 && value <= 0x0008) ||
           value == 0x000B || value == 0x000C ||
           (value >= 0x000E && value <= 0x001F) { return true }

        // C1 control characters: U+0080-U+009F
        if value >= 0x0080 && value <= 0x009F { return true }

        return false
    }

    // MARK: - Public API

    /// Strip all invisible and potentially dangerous Unicode characters from text.
    ///
    /// This is the primary defense function. Call it on any untrusted text before
    /// passing it to an AI model.
    ///
    /// Behavior:
    /// - Strips: zero-width chars, BiDi controls, Tag block chars, variation selectors,
    ///   interlinear annotations, soft hyphen, null bytes, C0/C1 control chars
    /// - Normalizes: unusual whitespace variants to regular ASCII space or newline
    ///
    /// - Parameter text: Input text (may be nil)
    /// - Returns: Sanitized text with dangerous characters removed
    public static func filter(_ text: String?) -> String? {
        guard let text = text, !text.isEmpty else { return text }

        // Fast path: ASCII-only strings need minimal processing
        // (just check for null and C0 controls)
        if text.allSatisfy({ $0.asciiValue != nil || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            return filterASCII(text)
        }

        var result = String()
        result.reserveCapacity(text.unicodeScalars.count)

        for scalar in text.unicodeScalars {
            // Check for normalizable whitespace first (replace, don't strip)
            if let replacement = normalizeWhitespace[scalar] {
                result.append(replacement)
                continue
            }

            // Check if scalar should be stripped
            if shouldStrip(scalar) {
                continue
            }

            result.unicodeScalars.append(scalar)
        }

        return result
    }

    /// Fast path for ASCII-only text: strip null and dangerous C0 controls.
    private static func filterASCII(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            // Strip null and dangerous C0 controls
            if value == 0x0000 { continue }
            if (value >= 0x0001 && value <= 0x0008) ||
               value == 0x000B || value == 0x000C ||
               (value >= 0x000E && value <= 0x001F) { continue }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// Check if text contains any invisible or dangerous Unicode characters.
    ///
    /// Use for logging/alerting before calling `filter()`.
    ///
    /// - Parameter text: Input text
    /// - Returns: true if suspicious characters found
    public static func hasInvisibleChars(_ text: String?) -> Bool {
        guard let text = text, !text.isEmpty else { return false }

        for scalar in text.unicodeScalars {
            if shouldStrip(scalar) { return true }
            if normalizeWhitespace[scalar] != nil { return true }
        }
        return false
    }

    /// Severity level for detected invisible characters.
    public enum Severity: String, Sendable {
        case high = "HIGH"
        case medium = "MEDIUM"
        case low = "LOW"
    }

    /// A detection of invisible characters in text.
    public struct Detection: Sendable {
        public let name: String
        public let severity: Severity
        public let description: String
        public let count: Int
    }

    /// Result of describing invisible characters found in text.
    public struct DescribeResult: Sendable {
        public let found: Bool
        public let detections: [Detection]
        public let summary: String
    }

    /// Detection rules for classifying invisible characters.
    private struct DetectionRule: Sendable {
        let name: String
        let check: @Sendable (Unicode.Scalar) -> Bool
        let severity: Severity
        let description: String
    }

    nonisolated(unsafe) private static let detectionRules: [DetectionRule] = [
        DetectionRule(
            name: "BiDi override/embedding characters",
            check: { s in
                let v = s.value
                return (v >= 0x202A && v <= 0x202E) ||
                       (v >= 0x2066 && v <= 0x2069) ||
                       v == 0x200E || v == 0x200F
            },
            severity: .high,
            description: "Can reverse display order of text to disguise malicious instructions"
        ),
        DetectionRule(
            name: "Unicode Tag block characters",
            check: { s in s.value >= 0xE0000 && s.value <= 0xE007F },
            severity: .high,
            description: "Completely invisible - can encode entire hidden prompts"
        ),
        DetectionRule(
            name: "Zero-width characters",
            check: { s in
                let v = s.value
                return (v >= 0x200B && v <= 0x200D) ||
                       (v >= 0x2060 && v <= 0x2064) ||
                       v == 0xFEFF
            },
            severity: .medium,
            description: "Invisible characters used to hide text between visible characters"
        ),
        DetectionRule(
            name: "Variation selectors",
            check: { s in
                let v = s.value
                return (v >= 0xFE00 && v <= 0xFE0F) ||
                       (v >= 0xE0100 && v <= 0xE01EF)
            },
            severity: .medium,
            description: "Alter glyph rendering; can encode hidden data in sequences"
        ),
        DetectionRule(
            name: "Interlinear annotation characters",
            check: { s in s.value >= 0xFFF9 && s.value <= 0xFFFB },
            severity: .medium,
            description: "Hidden annotation anchors"
        ),
        DetectionRule(
            name: "Soft hyphen",
            check: { s in s.value == 0x00AD },
            severity: .low,
            description: "Invisible in rendered text, can break token matching in filters"
        ),
        DetectionRule(
            name: "Null byte",
            check: { s in s.value == 0x0000 },
            severity: .high,
            description: "Can terminate strings early in some parsers"
        ),
        DetectionRule(
            name: "C0/C1 control characters",
            check: { s in
                let v = s.value
                return (v >= 0x0001 && v <= 0x0008) ||
                       v == 0x000B || v == 0x000C ||
                       (v >= 0x000E && v <= 0x001F) ||
                       (v >= 0x0080 && v <= 0x009F)
            },
            severity: .medium,
            description: "Non-printable control characters that may affect parsing"
        ),
        DetectionRule(
            name: "Unicode line/paragraph separators",
            check: { s in s.value == 0x2028 || s.value == 0x2029 },
            severity: .low,
            description: "Invisible newlines in contexts that expect single-line text"
        ),
        DetectionRule(
            name: "Unusual whitespace variants",
            check: { s in
                let v = s.value
                return v == 0x00A0 || v == 0x1680 ||
                       (v >= 0x2000 && v <= 0x200A) ||
                       v == 0x202F || v == 0x205F || v == 0x3000
            },
            severity: .low,
            description: "Non-standard whitespace that may disguise word boundaries"
        ),
    ]

    /// Return a description of all invisible/dangerous characters found in text.
    ///
    /// Use for security logging, debugging, and audit trails.
    ///
    /// - Parameter text: Input text
    /// - Returns: Description result with detections and summary
    public static func describe(_ text: String?) -> DescribeResult {
        guard let text = text, !text.isEmpty else {
            return DescribeResult(found: false, detections: [], summary: "No invisible characters detected")
        }

        var ruleCounts = Array(repeating: 0, count: detectionRules.count)

        for scalar in text.unicodeScalars {
            for (index, rule) in detectionRules.enumerated() {
                if rule.check(scalar) {
                    ruleCounts[index] += 1
                    break // Each scalar counted once under first matching rule
                }
            }
        }

        var detections: [Detection] = []
        for (index, rule) in detectionRules.enumerated() {
            if ruleCounts[index] > 0 {
                detections.append(Detection(
                    name: rule.name,
                    severity: rule.severity,
                    description: rule.description,
                    count: ruleCounts[index]
                ))
            }
        }

        guard !detections.isEmpty else {
            return DescribeResult(found: false, detections: [], summary: "No invisible characters detected")
        }

        let highCount = detections.filter { $0.severity == .high }.count
        let mediumCount = detections.filter { $0.severity == .medium }.count
        let lowCount = detections.filter { $0.severity == .low }.count

        var parts: [String] = []
        if highCount > 0 { parts.append("\(highCount) HIGH-severity") }
        if mediumCount > 0 { parts.append("\(mediumCount) MEDIUM-severity") }
        if lowCount > 0 { parts.append("\(lowCount) LOW-severity") }

        let details = detections.map { "\($0.name) (x\($0.count))" }.joined(separator: "; ")
        let summary = "Invisible character injection detected: \(parts.joined(separator: ", ")) issue(s): \(details)"

        return DescribeResult(found: true, detections: detections, summary: summary)
    }
}
