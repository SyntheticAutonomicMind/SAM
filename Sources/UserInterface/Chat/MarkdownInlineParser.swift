// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Foundation
import Logging

/// Parses inline markdown elements into AST nodes
/// Handles: **bold**, *italic*, `code`, [links](url), ![images](url), etc.
class MarkdownInlineParser {
    private let logger = Logger(label: "com.sam.ui.MarkdownInlineParser")
    private static let staticLogger = Logger(label: "com.sam.ui.MarkdownInlineParser")

    /// Regex patterns for inline elements (ordered by precedence)
    private static let patterns: [(name: String, regex: NSRegularExpression)] = {
        let regexes: [(String, String)] = [
            // Images must be before links
            // CRITICAL: URL can contain parentheses (e.g., file:///path/folder%20(name)/file.png)
            // Use greedy match .* to capture everything including parens, then match last )
            ("image", #"!\[([^\]]*)\]\((.*)\)"#),
            // Links - same issue, URLs can have parens
            ("link", #"\[([^\]]+)\]\((.*)\)"#),
            // Reference links
            ("refLink", #"\[([^\]]+)\]\[([^\]]+)\]"#),
            // Bold + italic ***text***
            ("boldItalic", #"\*\*\*(.+?)\*\*\*"#),
            // Bold **text**
            ("bold", #"\*\*(.+?)\*\*"#),
            // Bold __text__ (must be at word boundaries - not within words like var__name)
            ("boldUnderscore", #"(?<=^|[\s\p{P}])__(.+?)__(?=$|[\s\p{P}])"#),
            // Italic *text* (non-greedy, not preceded or followed by *)
            ("italic", #"(?<!\*)\*(.+?)\*(?!\*)"#),
            // Italic _text_ (must be at word boundaries - not within words like file_name)
            ("italicUnderscore", #"(?<=^|[\s\p{P}])_([^_]+?)_(?=$|[\s\p{P}])"#),
            // Strikethrough ~~text~~
            ("strikethrough", #"~~(.+?)~~"#),
            // Inline code `text`
            ("code", #"`([^`]+)`"#),
            // Hard break (two spaces + newline)
            ("hardBreak", #"  \n"#),
            // Soft break (single newline)
            ("softBreak", #"\n"#)
        ]

        return regexes.compactMap { name, pattern in
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                return (name, regex)
            } else {
                return nil
            }
        }
    }()

    /// Instance method wrapper for parsing inline markdown
    func parse(_ text: String, referenceLinks: [String: String] = [:]) -> [MarkdownASTNode] {
        return Self.parseInlineMarkdown(text, referenceLinks: referenceLinks)
    }

    /// Parse inline markdown into AST nodes
    static func parseInlineMarkdown(_ text: String, referenceLinks: [String: String] = [:]) -> [MarkdownASTNode] {
        guard !text.isEmpty else { return [] }

        // Safety check
        guard text.count <= 5000 else {
            staticLogger.warning("Inline text too long (\(text.count) chars), truncating")
            return [.text(String(text.prefix(5000)) + "...")]
        }

        var nodes: [MarkdownASTNode] = []
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            // Find the next inline element - use substring to preserve indices
            let remainingSubstring = text[currentIndex...]
            let remainingText = String(remainingSubstring)
            let nsRange = NSRange(remainingText.startIndex..., in: remainingText)

            var foundMatch = false
            var earliestMatch: (range: NSRange, type: String, match: NSTextCheckingResult)?

            // Find earliest match among all patterns
            for (name, regex) in Self.patterns {
                if let match = regex.firstMatch(in: remainingText, range: nsRange) {
                    if let earliest = earliestMatch {
                        if match.range.location < earliest.range.location {
                            earliestMatch = (match.range, name, match)
                        }
                    } else {
                        earliestMatch = (match.range, name, match)
                    }
                }
            }

            if let (range, type, match) = earliestMatch {
                // Convert NSRange (UTF-16) to Range<String.Index>
                guard let stringRange = Range(range, in: remainingText) else {
                    // Failed to convert - add remaining text and break
                    staticLogger.warning("Failed to convert NSRange to String.Index - skipping remaining text")
                    if !remainingText.isEmpty {
                        nodes.append(.text(remainingText))
                    }
                    break
                }

                // Add text before match
                if stringRange.lowerBound > remainingText.startIndex {
                    let textBefore = String(remainingText[remainingText.startIndex..<stringRange.lowerBound])
                    if !textBefore.isEmpty {
                        nodes.append(.text(textBefore))
                    }
                }

                // Process the match (with error handling)
                do {
                    let matchedNode = try processMatch(type: type, match: match, in: remainingText, referenceLinks: referenceLinks)
                    nodes.append(matchedNode)
                } catch {
                    staticLogger.error("ERROR: Processing match failed: \(error)")
                    // Add as plain text if processing fails
                    if let matchText = Range(match.range, in: remainingText).map({ String(remainingText[$0]) }) {
                        nodes.append(.text(matchText))
                    }
                }

                // Advance current index past the match (with safety check)
                let distance = remainingText.distance(from: remainingText.startIndex, to: stringRange.upperBound)
                guard let advancedIndex = text.index(currentIndex, offsetBy: distance, limitedBy: text.endIndex) else {
                    staticLogger.warning("Failed to advance index - stopping parse")
                    break
                }

                currentIndex = advancedIndex
                foundMatch = true
            } else {
                // No more matches, add remaining text
                let remainingText = String(text[currentIndex...])
                if !remainingText.isEmpty {
                    nodes.append(.text(remainingText))
                }
                break
            }
        }

        // If no nodes were created, return plain text
        if nodes.isEmpty && !text.isEmpty {
            nodes.append(.text(text))
        }

        return nodes
    }

    /// Process a regex match into an AST node
    private static func processMatch(type: String, match: NSTextCheckingResult, in text: String, referenceLinks: [String: String]) throws -> MarkdownASTNode {
        switch type {
        case "image":
            let altText = extractGroup(1, from: match, in: text)
            let url = extractGroup(2, from: match, in: text)
            return .image(altText: altText, url: url)

        case "link":
            let linkText = extractGroup(1, from: match, in: text)
            let url = extractGroup(2, from: match, in: text)
            return .link(text: linkText, url: url)

        case "refLink":
            let linkText = extractGroup(1, from: match, in: text)
            let refId = extractGroup(2, from: match, in: text).lowercased()
            if let url = referenceLinks[refId] {
                return .link(text: linkText, url: url)
            } else {
                // Reference not found, return as plain text
                return .text("[\(linkText)][\(refId)]")
            }

        case "boldItalic":
            let content = extractGroup(1, from: match, in: text)
            let children = parseInlineMarkdown(content, referenceLinks: referenceLinks)
            return .strong(children: [.emphasis(children: children)])

        case "bold", "boldUnderscore":
            let content = extractGroup(1, from: match, in: text)
            let children = parseInlineMarkdown(content, referenceLinks: referenceLinks)
            return .strong(children: children)

        case "italic", "italicUnderscore":
            let content = extractGroup(1, from: match, in: text)
            let children = parseInlineMarkdown(content, referenceLinks: referenceLinks)
            return .emphasis(children: children)

        case "strikethrough":
            let content = extractGroup(1, from: match, in: text)
            let children = parseInlineMarkdown(content, referenceLinks: referenceLinks)
            return .strikethrough(children: children)

        case "code":
            let code = extractGroup(1, from: match, in: text)
            return .inlineCode(code)

        case "hardBreak":
            return .hardBreak

        case "softBreak":
            return .softBreak

        default:
            // Unknown type, return as text
            let fullMatch = (text as NSString).substring(with: match.range)
            return .text(fullMatch)
        }
    }

    /// Extract a capture group from a regex match
    private static func extractGroup(_ group: Int, from match: NSTextCheckingResult, in text: String) -> String {
        if match.range(at: group).location != NSNotFound,
           let range = Range(match.range(at: group), in: text) {
            return String(text[range])
        }
        return ""
    }
}
