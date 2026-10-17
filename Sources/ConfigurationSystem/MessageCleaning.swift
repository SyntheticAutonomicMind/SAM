// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// Precompiled, stateless message-content cleaning.
///
/// All regexes are compiled once at first use and cached in static let
/// properties. This eliminates the per-call NSRegularExpression compilation
/// that was happening 30-60 times/sec during streaming.
///
/// The cleaning pipeline is applied in a single pass — the UI layer
/// (MessageView / MessageBubble) receives already-clean content from
/// the MessageBus, so it never needs to run these regexes at render time.
public struct MessageCleaner {
    // MARK: - Precompiled Patterns

    /// ````...```` thinking blocks and orphaned ```` tags.
    /// Pattern uses [\s\S] instead of . because NSRegularExpression
    /// doesn't match newlines without dotMatchesLineSeparators.
    private static let thinkBlockRegex: NSRegularExpression = {
        // swift-format: off
        try! NSRegularExpression(
            pattern: "(?s)```.*?```\\n*",
            options: []
        )
        // swift-format: on
    }()

    /// Remove bare ````opening``` and ````closing tag remnants.
    private static let thinkTagsRegex: NSRegularExpression = {
        // swift-format: off
        try! NSRegularExpression(
            pattern: "</?thinking/?>?",
            options: []
        )
        // swift-format: on
    }()

    /// Fragmented special-token patterns: standalone ```` markers.
    private static let fragmentedTokenRegex: NSRegularExpression = {
        // swift-format: off
        try! NSRegularExpression(
            pattern: "\\s*<\\|[^>]*\\|?>\\s*",
            options: []
        )
        // swift-format: on
    }()

    /// Raw JSON tool requests: `{"name": "...", "arguments": {...}}`.
    private static let toolJSONRegex: NSRegularExpression = {
        // swift-format: off
        try! NSRegularExpression(
            pattern: "\\{\\s*\"name\"\\s*:\\s*\"[^\"]+\"\\s*,\\s*\"arguments\"\\s*:\\s*\\{[^}]*\\}\\s*\\}",
            options: [.dotMatchesLineSeparators]
        )
        // swift-format: on
    }()

    /// `SUCCESS: Thinking: ...` content (echoed tool thinking) up to paragraph boundary.
    private static let thinkingEchoRegex: NSRegularExpression = {
        // swift-format: off
        try! NSRegularExpression(
            pattern: "SUCCESS:\\s+Thinking:.*?(?=\\n\\n|$)",
            options: [.dotMatchesLineSeparators]
        )
        // swift-format: on
    }()

    /// Other tool progress messages: `SUCCESS: Researching: ...` etc.
    private static let toolProgressRegex: NSRegularExpression = {
        // swift-format: off
        try! NSRegularExpression(
            pattern: "SUCCESS:\\s+[A-Za-z][^:]+:.*?(?=\\n|$)",
            options: []
        )
        // swift-format: on
    }()

    /// Excessive whitespace (3+ consecutive newlines -> 2).
    private static let excessiveNewlinesRegex: NSRegularExpression = {
        // swift-format: off
        try! NSRegularExpression(
            pattern: "\\n{3,}",
            options: []
        )
        // swift-format: on
    }()

    /// HTML comments emitted as session-naming markers (e.g. ``<!-- chunkId=...`
    /// These render as invisible in HTML viewers but should never reach the
    /// UI as the sole content of a message. Strip them so the message is
    /// treated as empty (and filtered by the render pipeline) rather than
    /// appearing as a blank bubble.
    private static let htmlCommentRegex: NSRegularExpression = {
        // swift-format: off
        try! NSRegularExpression(
            pattern: "<!--.*?-->",
            options: [.dotMatchesLineSeparators]
        )
        // swift-format: on
    }()

    // MARK: - Public API

    /// Clean special tokens, tool XML, and thinking-tag remnants from
    /// accumulated message content. Applied at write time by MessageBus,
    /// not at render time.
    ///
    /// - Parameter content: Raw streamed/accumulated message content.
    /// - Parameter isToolMessage: If true, skips aggressive stripping of
    ///   `SUCCESS: ...` content (tool messages legitimately contain this).
    /// - Returns: Cleaned content safe for display.
    public static func cleanSpecialTokens(from content: String, isToolMessage: Bool = false) -> String {
        var cleaned = content

        // Remove EOS / conversation-end tokens.
        cleaned = cleaned
            .replacingOccurrences(of: "", with: "", options: .literal)
            .replacingOccurrences(of: "", with: "", options: .literal)
            .replacingOccurrences(of: "</s>", with: "", options: .literal)

        // Remove conversation role markers.
        cleaned = cleaned
            .replacingOccurrences(of: "", with: "", options: .literal)
            .replacingOccurrences(of: "", with: "", options: .literal)
            .replacingOccurrences(of: "", with: "", options: .literal)
            .replacingOccurrences(of: "", with: "", options: .literal)

        // Remove tool-call XML framing.
        cleaned = cleaned
            .replacingOccurrences(of: "", with: "", options: .literal)
            .replacingOccurrences(of: "", with: "", options: .literal)

        // Strip thinking blocks and orphaned tags.
        cleaned = thinkBlockRegex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
        cleaned = thinkTagsRegex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")

        // Strip HTML comments (session-naming markers, etc.).
        cleaned = htmlCommentRegex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")

        // Strip fragmented special tokens.
        cleaned = fragmentedTokenRegex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")

        // Strip raw JSON tool requests.
        cleaned = toolJSONRegex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")

        // Aggressive stripping only on assistant messages.
        if !isToolMessage {
            cleaned = thinkingEchoRegex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
            cleaned = toolProgressRegex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
        }

        // Collapse excessive newlines.
        cleaned = excessiveNewlinesRegex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "\n\n")

        return cleaned
    }

    /// Filter internal status/marker lines without trimming surrounding whitespace.
    /// Preserves paragraph structure so filtered content doesn't collapse.
    public static func filterInternalMarkersNoTrim(from input: String) -> String {
        let lines = input.components(separatedBy: CharacterSet.newlines)
        var outputLines: [String] = []
        var skipIntentExtraction = false

        let bracketMarkers: Set<String> = [
            "[WORKFLOW_COMPLETE]", "[TASK_COMPLETE]", "[CONTINUE]",
            "[PLANNING_COMPLETE]", "[STEP_COMPLETE]", "[PLANNING_DONE]",
            "[STEP_DONE]"
        ]

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            if skipIntentExtraction {
                if trimmed.hasSuffix("}") {
                    skipIntentExtraction = false
                }
                continue
            }

            if trimmed.isEmpty {
                outputLines.append("")
                continue
            }

            if bracketMarkers.contains(trimmed) {
                if outputLines.last != "" { outputLines.append("") }
                continue
            }

            if trimmed.uppercased().hasPrefix("INTENT EXTRACTION:") {
                if !trimmed.hasSuffix("}") {
                    skipIntentExtraction = true
                }
                if outputLines.last != "" { outputLines.append("") }
                continue
            }

            // Standalone status JSON: {"status":"continue"}
            if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") && trimmed.contains("\"status\"") {
                if outputLines.last != "" { outputLines.append("") }
                continue
            }

            // Session naming markers.
            if trimmed.contains("<!--session:") && trimmed.contains("-->") {
                continue
            }

            // Bare thinking tags.
            if trimmed == "<thinking>" || trimmed == "</thinking>" ||
               trimmed == "<thinking/>" ||
               (trimmed.hasPrefix("<thinking") && trimmed.hasSuffix(">")) ||
               (trimmed.hasPrefix("</thinking") && trimmed.hasSuffix(">")) {
                if outputLines.last != "" { outputLines.append("") }
                continue
            }

            outputLines.append(raw)
        }

        return outputLines.joined(separator: "\n")
    }
}
