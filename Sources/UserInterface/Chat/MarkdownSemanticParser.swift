// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Foundation
import Logging

/// Wrapper for MarkdownElement with pre-computed stable ID for efficient ForEach rendering.
struct IdentifiableMarkdownElement: Identifiable {
    let id: UUID
    let element: MarkdownElement

    init(_ element: MarkdownElement) {
        self.id = UUID()
        self.element = element
    }
}

/// Semantic markdown element types for proper SwiftUI rendering.
enum MarkdownElement {
    case header(level: Int, text: AttributedString)
    case paragraph(text: AttributedString)
    case codeBlock(language: String?, code: String)
    case inlineCode(text: String)
    case table(headers: [String], alignments: [TextAlignment], rows: [[String]])
    case orderedList(items: [MarkdownListItem])
    case unorderedList(items: [MarkdownListItem])
    case blockquote(text: String, depth: Int)
    case horizontalRule
    case taskList(items: [MarkdownTaskItem])
    case image(altText: String, url: String)
}

/// List item with potential nesting.
struct MarkdownListItem {
    let text: AttributedString
    let rawText: String
    let indentLevel: Int
    var subItems: [MarkdownListItem]
    let listType: ListType
    /// If the original markdown ordered list specified a starting number (e.g.
    let originalNumber: Int?
}

/// Task list item with completion status.
struct MarkdownTaskItem {
    let text: AttributedString
    let isCompleted: Bool
    let indentLevel: Int
}

/// Text alignment for table columns.
enum TextAlignment {
    case left, center, right
}

/// Type of a list (ordered or unordered) used to render nested lists correctly.
enum ListType {
    case ordered
    case unordered
}

/// Comprehensive markdown parser that creates semantic elements Performance-optimized with caching and intelligent chunking for streaming content.
class MarkdownSemanticParser {
    /// Logging.
    private let logger = Logger(label: "com.sam.ui.MarkdownSemanticParser")

    /// PERFORMANCE: Add caching with size limits and TTL.
    private var cache: [String: CachedResult] = [:]
    private let maxCacheSize = 50
    private let cacheTimeToLive: TimeInterval = 300

    /// SAFETY: Following Ink reference implementation - no timeouts for text processing Markdown parsing is simple text processing and should complete naturally.
    private let maxContentLength = 50000

    /// Cache entry with timestamp.
    private struct CachedResult {
        let elements: [MarkdownElement]
        let timestamp: Date

        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > 300
        }
    }

    /// PERFORMANCE: Pre-compile regex patterns with increased length limits.
    private static let headerRegex = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.{1,1000})$")
    private static let fenceRegex = try! NSRegularExpression(pattern: "^```([a-zA-Z0-9_+-]{0,20})$")
    private static let separatorRegex = try! NSRegularExpression(pattern: "^\\s*[|]?\\s*:?-+:?\\s*(?:[|]\\s*:?-+:?\\s*)*[|]?\\s*$")

    /// Increased length limits from 200 to 1000 to handle real-world markdown content.
    private static let orderedListRegex = try! NSRegularExpression(pattern: "^(\\s{0,10})(\\d{1,3})\\. (.{1,1000})$")
    private static let unorderedListRegex = try! NSRegularExpression(pattern: "^(\\s{0,10})[-*+] (.{1,1000})$")
    private static let taskListRegex = try! NSRegularExpression(pattern: "^(\\s{0,10})- \\[([xX ]?)\\] (.{1,1000})$")

    private static let horizontalRuleRegex = try! NSRegularExpression(pattern: "^\\s{0,20}([-*_]\\s*){3,10}\\s*$")
    private static let blockquoteRegex = try! NSRegularExpression(pattern: "^(>{1,5})\\s*(.{0,1000})$")

    /// Increased length limits for inline formatting from 200 to 500.
    private static let boldItalicRegex = try! NSRegularExpression(pattern: "\\*\\*\\*([^*]{1,500})\\*\\*\\*")
    private static let boldRegex = try! NSRegularExpression(pattern: "\\*\\*([^*]{1,500})\\*\\*")
    /// Word boundary patterns: underscores must NOT be surrounded by alphanumeric characters
    /// This prevents false matches in words like "file_name" or "final_report_v2_really_final"
    private static let boldUnderscoreRegex = try! NSRegularExpression(pattern: "(?<![a-zA-Z0-9])__([^_]{1,500})__(?![a-zA-Z0-9])")
    private static let italicRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*([^*]{1,500})\\*(?!\\*)")
    private static let italicUnderscoreRegex = try! NSRegularExpression(pattern: "(?<![a-zA-Z0-9])_([^_]{1,500})_(?![a-zA-Z0-9])")
    private static let strikethroughRegex = try! NSRegularExpression(pattern: "~~([^~]{1,500})~~")
    private static let codeRegex = try! NSRegularExpression(pattern: "`([^`]{1,500})`")
    private static let linkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^\\)]+)\\)")
    private static let referenceLinkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\[([^\\]]+)\\]")
    private static let referenceDefRegex = try! NSRegularExpression(pattern: "^\\[([^\\]]+)\\]:\\s*(.+)$")
    private static let footnoteRefRegex = try! NSRegularExpression(pattern: "\\[\\^([^\\]]+)\\]")
    private static let footnoteDefRegex = try! NSRegularExpression(pattern: "^\\[\\^([^\\]]+)\\]:\\s*(.+)$")
    private static let imageRegex = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(([^\\)]+)\\)")
    private static let escapeRegex = try! NSRegularExpression(pattern: "\\\\([\\\\`*_{}\\[\\]()#+\\-.!|~])")
    private static let htmlBoldRegex = try! NSRegularExpression(pattern: "<(b|strong)>([^<]+)</\\1>")
    private static let htmlItalicRegex = try! NSRegularExpression(pattern: "<(i|em)>([^<]+)</\\1>")
    private static let htmlCodeRegex = try! NSRegularExpression(pattern: "<code>([^<]+)</code>")

    /// Math regex patterns (inline: $math$ and block: $$math$$).
    private static let blockMathRegex = try! NSRegularExpression(pattern: "\\$\\$([^$]+)\\$\\$")
    private static let inlineMathRegex = try! NSRegularExpression(pattern: "(?<!\\$)\\$([^$\\n]+)\\$(?!\\$)")

    /// Parse markdown text into semantic elements for proper SwiftUI rendering.
    func parseMarkdown(_ markdown: String) -> [MarkdownElement] {
        do {
            return try parseMarkdownInternal(markdown)
        } catch {
            logger.error("[PARSE_ERROR] Parser threw error: \(error.localizedDescription)")
            return [.paragraph(text: AttributedString("Error parsing markdown: \(error.localizedDescription)"))]
        }
    }

    private func parseMarkdownInternal(_ markdown: String) throws -> [MarkdownElement] {
        /// SAFETY: Reject oversized content immediately.
        guard markdown.count <= maxContentLength else {
            return [.paragraph(text: AttributedString("Content too large to parse safely"))]
        }

        /// PERFORMANCE: Check cache first with expiration.
        if let cached = cache[markdown], !cached.isExpired {
            return cached.elements
        }

        var elements: [MarkdownElement] = []

        /// FIRST PASS: Extract reference definitions and footnotes.
        var referenceLinks: [String: String] = [:]
        var footnotes: [String: String] = [:]
        var contentLines: [String] = []

        let lines = markdown.components(separatedBy: .newlines)

        for line in lines {
            /// Check for reference link definition.
            if let match = Self.referenceDefRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let refId = String(line[Range(match.range(at: 1), in: line)!]).lowercased()
                let url = String(line[Range(match.range(at: 2), in: line)!])
                referenceLinks[refId] = url
                continue
            }

            /// Check for footnote definition.
            if let match = Self.footnoteDefRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let footnoteId = String(line[Range(match.range(at: 1), in: line)!])
                let footnoteText = String(line[Range(match.range(at: 2), in: line)!])
                footnotes[footnoteId] = footnoteText
                continue
            }

            contentLines.append(line)
        }

        /// SECOND PASS: Parse content with references available.
        var currentIndex = 0
        var iterationCount = 0
        let maxIterations = contentLines.count * 2

        while currentIndex < contentLines.count && iterationCount < maxIterations {
            iterationCount += 1

            let line = contentLines[currentIndex]

            /// Skip empty lines.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                currentIndex += 1
                continue
            }

            /// SAFETY: Skip extremely long lines that could cause regex issues.
            if line.count > 1000 {
                let truncated = String(line.prefix(500)) + "..."
                elements.append(.paragraph(text: AttributedString(truncated)))
                currentIndex += 1
                continue
            }

            /// Parse different element types.
            if let element = parseHeader(line) {
                elements.append(element)
                currentIndex += 1
            } else if let (element, consumedLines) = parseIndentedCodeBlock(contentLines, startIndex: currentIndex) {
                elements.append(element)
                currentIndex += consumedLines
            } else if let (element, consumedLines) = parseCodeBlock(contentLines, startIndex: currentIndex) {
                elements.append(element)
                currentIndex += consumedLines
            } else if let (element, consumedLines) = parseTable(contentLines, startIndex: currentIndex) {
                elements.append(element)
                currentIndex += consumedLines
            } else if let (element, consumedLines) = parseList(contentLines, startIndex: currentIndex, referenceLinks: referenceLinks, footnotes: footnotes) {
                elements.append(element)
                currentIndex += consumedLines
            } else if let element = parseHorizontalRule(line) {
                elements.append(element)
                currentIndex += 1
            } else if let element = parseBlockquote(line) {
                elements.append(element)
                currentIndex += 1
            } else if let element = parseImage(line) {
                elements.append(element)
                currentIndex += 1
            } else {
                /// Regular paragraph.
                let (paragraphLines, consumedLines) = collectParagraphLines(contentLines, startIndex: currentIndex)

                /// SAFETY: Ensure we always consume at least one line to prevent infinite loops.
                let safeLinesConsumed = max(consumedLines, 1)

                /// Preserve original paragraph line breaks so generator-intended line breaks (e.g., title line then description on next line) are not collapsed into a single line.
                let paragraphText = paragraphLines.joined(separator: "\n")
                let attributedText = processInlineFormatting(paragraphText, referenceLinks: referenceLinks, footnotes: footnotes)
                elements.append(.paragraph(text: attributedText))
                currentIndex += safeLinesConsumed
            }
        }

        /// PERFORMANCE: Cache the result before returning.
        cache[markdown] = CachedResult(elements: elements, timestamp: Date())

        /// PERFORMANCE: Limit cache size to prevent memory issues.
        cleanupCache()

        return elements
    }

    /// PERFORMANCE: Clean up expired cache entries.
    private func cleanupCache() {
        /// Remove expired entries.
        cache = cache.filter { !$0.value.isExpired }

        /// If still too large, remove oldest entries.
        if cache.count > maxCacheSize {
            let sortedEntries = cache.sorted { $0.value.timestamp < $1.value.timestamp }
            let entriesToRemove = sortedEntries.prefix(cache.count - maxCacheSize)
            for (key, _) in entriesToRemove {
                cache.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Element Parsing Methods

    private func parseIndentedCodeBlock(_ lines: [String], startIndex: Int) -> (MarkdownElement, Int)? {
        let line = lines[startIndex]

        /// Check if line starts with 4 spaces or 1 tab.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("    ") || line.hasPrefix("\t"), !trimmed.isEmpty else {
            return nil
        }

        var codeLines: [String] = []
        var currentIndex = startIndex
        var safetyCounter = 0
        let maxCodeLines = 1000

        /// Collect indented lines.
        while currentIndex < lines.count && safetyCounter < maxCodeLines {
            safetyCounter += 1
            let codeLine = lines[currentIndex]

            /// Empty lines are allowed in code blocks.
            if codeLine.trimmingCharacters(in: .whitespaces).isEmpty {
                codeLines.append("")
                currentIndex += 1
                continue
            }

            /// Must be indented to continue.
            guard codeLine.hasPrefix("    ") || codeLine.hasPrefix("\t") else {
                break
            }

            /// Remove the indentation.
            var unindented = codeLine
            if unindented.hasPrefix("    ") {
                unindented = String(unindented.dropFirst(4))
            } else if unindented.hasPrefix("\t") {
                unindented = String(unindented.dropFirst())
            }
            codeLines.append(unindented)
            currentIndex += 1
        }

        guard !codeLines.isEmpty else { return nil }

        let code = codeLines.joined(separator: "\n")
        return (.codeBlock(language: nil, code: code), currentIndex - startIndex)
    }

    private func parseHeader(_ line: String) -> MarkdownElement? {
        /// PERFORMANCE: Use pre-compiled regex.
        guard let match = Self.headerRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        let headerLevel = line[Range(match.range(at: 1), in: line)!].count
        let headerText = String(line[Range(match.range(at: 2), in: line)!])

        /// Parse inline markdown in headers (bold, italic, code, etc.) Headers like "## **Weather Updates**" need bold formatting rendered.
        let formattedText = processInlineFormatting(headerText)

        return .header(level: headerLevel, text: formattedText)
    }

    private func parseCodeBlock(_ lines: [String], startIndex: Int) -> (MarkdownElement, Int)? {
        let line = lines[startIndex]

        /// Check for fenced code block - PERFORMANCE: Use pre-compiled regex.
        guard let match = Self.fenceRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        let language = match.range(at: 1).length > 0 ? String(line[Range(match.range(at: 1), in: line)!]) : nil
        var codeLines: [String] = []
        var currentIndex = startIndex + 1
        var safetyCounter = 0
        let maxCodeLines = 1000

        /// Collect code lines until closing fence.
        while currentIndex < lines.count && safetyCounter < maxCodeLines {
            safetyCounter += 1
            let codeLine = lines[currentIndex]
            if codeLine.trimmingCharacters(in: .whitespaces) == "```" {
                break
            }
            codeLines.append(codeLine)
            currentIndex += 1
        }

        let code = codeLines.joined(separator: "\n")
        return (.codeBlock(language: language, code: code), currentIndex - startIndex + 1)
    }

    private func parseTable(_ lines: [String], startIndex: Int) -> (MarkdownElement, Int)? {
        guard startIndex + 1 < lines.count else {
            return nil
        }

        let headerLine = lines[startIndex]
        let separatorLine = lines[startIndex + 1]

        /// SAFETY: Skip table parsing for JSON-like content.
        if headerLine.count > 1000 || headerLine.contains("[{") || headerLine.contains("}]") {
            return nil
        }

        /// Check if it's a valid table format - PERFORMANCE: Use pre-compiled regex.
        guard Self.separatorRegex.firstMatch(in: separatorLine, range: NSRange(separatorLine.startIndex..., in: separatorLine)) != nil else {
            return nil
        }

        /// Parse headers.
        let headers = parseTableRow(headerLine)
        let alignments = parseTableAlignment(separatorLine)

        /// Parse data rows.
        var dataRows: [[String]] = []
        var currentIndex = startIndex + 2
        var safetyCounter = 0
        let maxRows = 100

        while currentIndex < lines.count && safetyCounter < maxRows {
            safetyCounter += 1
            let line = lines[currentIndex]
            if line.trimmingCharacters(in: .whitespaces).isEmpty || !line.contains("|") {
                break
            }
            let parsedRow = parseTableRow(line)
            dataRows.append(parsedRow)
            currentIndex += 1
        }

        return (.table(headers: headers, alignments: alignments, rows: dataRows), currentIndex - startIndex)
    }

    private func parseList(_ lines: [String], startIndex: Int, referenceLinks: [String: String], footnotes: [String: String]) -> (MarkdownElement, Int)? {
        let line = lines[startIndex]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        /// SAFETY: Add length limit and fast rejection to prevent infinite loops.
        guard trimmed.count <= 500, !trimmed.isEmpty else {
            return nil
        }

        /// SAFETY: Fast rejection - only check strings that could be lists.
        guard trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("+") ||
              (trimmed.count < 100 && trimmed.range(of: ". ", options: [.literal, .caseInsensitive]) != nil) else {
            return nil
        }

        /// Check for task list BEFORE unordered list (since task lists start with "- [").
        if Self.taskListRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            let (items, consumedLines) = parseTaskListItems(lines, startIndex: startIndex, referenceLinks: referenceLinks, footnotes: footnotes)
            /// If no items were parsed (e.g., line too long), return nil instead of empty list
            guard !items.isEmpty else {
                return nil
            }
            return (.taskList(items: items), consumedLines)
        }

        /// Check for ordered list - PERFORMANCE: Use pre-compiled regex.
        if Self.orderedListRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            let (items, consumedLines) = parseOrderedListItems(lines, startIndex: startIndex, referenceLinks: referenceLinks, footnotes: footnotes)
            /// If no items were parsed (e.g., line too long), return nil instead of empty list
            guard !items.isEmpty else {
                return nil
            }
            return (.orderedList(items: items), consumedLines)
        }

        /// Check for unordered list - PERFORMANCE: Use pre-compiled regex.
        if Self.unorderedListRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            let (items, consumedLines) = parseUnorderedListItems(lines, startIndex: startIndex, referenceLinks: referenceLinks, footnotes: footnotes)
            /// If no items were parsed (e.g., line too long), return nil instead of empty list
            guard !items.isEmpty else {
                return nil
            }
            return (.unorderedList(items: items), consumedLines)
        }

        return nil
    }

    private func parseHorizontalRule(_ line: String) -> MarkdownElement? {
        /// PERFORMANCE: Use pre-compiled regex.
        guard Self.horizontalRuleRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else {
            return nil
        }
        return .horizontalRule
    }

    private func parseBlockquote(_ line: String) -> MarkdownElement? {
        /// PERFORMANCE: Use pre-compiled regex.
        guard let match = Self.blockquoteRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        let depth = line[Range(match.range(at: 1), in: line)!].count
        let text = String(line[Range(match.range(at: 2), in: line)!])

        return .blockquote(text: text, depth: depth)
    }

    private func parseImage(_ line: String) -> MarkdownElement? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        /// Only parse as standalone image if line STARTS with ![ This prevents interfering with lists like "1.
        guard trimmed.hasPrefix("![") else {
            return nil
        }

        /// Match ![alt](url) pattern
        /// Regex: !\[([^\]]*)\]\((.+?)\)\s*$
        /// This pattern handles parentheses in URLs (e.g., "file:///path/dir (1)/file.png")
        /// by using non-greedy matching (.+?) and requiring end of string after the closing )
        let pattern = #"!\[([^\]]*)\]\((.+?)\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else {
            return nil
        }

        let altText = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
        let url = String(trimmed[Range(match.range(at: 2), in: trimmed)!])

        return .image(altText: altText, url: url)
    }

    // MARK: - Helper Methods

    private func parseTableRow(_ row: String) -> [String] {
        /// SAFETY: Skip parsing extremely long lines that contain JSON data.
        if row.count > 2000 {
            return ["Content too large to parse as table"]
        }

        let trimmed = row.trimmingCharacters(in: .whitespaces)
        let withoutOuterPipes = trimmed.hasPrefix("|") && trimmed.hasSuffix("|") ?
            String(trimmed.dropFirst().dropLast()) : trimmed
        return withoutOuterPipes.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func parseTableAlignment(_ separatorLine: String) -> [TextAlignment] {
        let cells = parseTableRow(separatorLine)
        return cells.map { cell in
            if cell.hasPrefix(":") && cell.hasSuffix(":") {
                return .center
            } else if cell.hasSuffix(":") {
                return .right
            } else {
                return .left
            }
        }
    }

    private func parseOrderedListItems(_ lines: [String], startIndex: Int, referenceLinks: [String: String], footnotes: [String: String]) -> ([MarkdownListItem], Int) {
        var items: [MarkdownListItem] = []
        var currentIndex = startIndex
        var safetyCounter = 0
        let maxListItems = 200

        while currentIndex < lines.count && safetyCounter < maxListItems {
            safetyCounter += 1
            let line = lines[currentIndex]

            /// SAFETY: Reject problematic content immediately before regex.
            guard line.count <= 200 else {
                break
            }

            /// SAFETY: Use range(of:) with literal options for better performance.
            guard line.range(of: ". ", options: .literal) != nil else {
                break
            }

            /// PERFORMANCE: Use pre-compiled regex.
            guard let match = Self.orderedListRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                break
            }

            let indent = line[Range(match.range(at: 1), in: line)!].count
            let text = String(line[Range(match.range(at: 3), in: line)!])
            var fullItemText = text

            /// ATTACH FOLLOWING PARAGRAPHS: Some generators emit the list marker on one line and the full paragraph on the following line(s) without indentation.
            if currentIndex < lines.count {
                let nextIndex = currentIndex + 1
                if nextIndex < lines.count {
                    var peekIndex = nextIndex
                    var peek = lines[peekIndex]
                    var peekTrimmed = peek.trimmingCharacters(in: .whitespaces)

                    /// Allow a single blank line between the list marker and the paragraph.
                    if peekTrimmed.isEmpty {
                        let nextNext = peekIndex + 1
                        if nextNext < lines.count {
                            peekIndex = nextNext
                            peek = lines[peekIndex]
                            peekTrimmed = peek.trimmingCharacters(in: .whitespaces)
                        }
                    }

                    /// If the inspected line is non-empty and not a block starter or list marker, treat it as continuation paragraph for this list item.
                    if !peekTrimmed.isEmpty &&
                        !peekTrimmed.hasPrefix("#") &&
                        !peekTrimmed.hasPrefix("```") &&
                        peekTrimmed.range(of: "^\\s*[-*+]\\s+", options: .regularExpression) == nil &&
                        peekTrimmed.range(of: "^\\s*\\d+\\.\\s+", options: .regularExpression) == nil {

                        let (paraLines, consumed) = collectParagraphLines(lines, startIndex: peekIndex)
                        if !paraLines.isEmpty {
                            /// Preserve paragraph separation.
                            let trimmedTitle = fullItemText.trimmingCharacters(in: .whitespaces)
                            /// Use an explicit hard line break (two spaces + newline) when attaching a following paragraph to a list item so the generator-intended single-line break is preserved in SwiftUI's markdown rendering.
                            if trimmedTitle.hasSuffix(":") {
                                fullItemText += "  \n" + paraLines.joined(separator: "\n")
                            } else {
                                fullItemText += "  \n" + paraLines.joined(separator: "\n")
                            }

                            currentIndex = peekIndex + consumed
                        }
                    }
                }
            }

            /// Normalize label spacing for items like "Fantasy:In..." → "Fantasy: In...".
            fullItemText = normalizeLeadingLabelSpacing(fullItemText)

            let attributedText = processInlineFormatting(fullItemText, referenceLinks: referenceLinks, footnotes: footnotes)

            /// Capture the original number so renderers can preserve starting numbers.
            let numberString = String(line[Range(match.range(at: 2), in: line)!])
            let originalNumber = Int(numberString)
            /// Create the list item as ordered by default.
            items.append(MarkdownListItem(text: attributedText, rawText: fullItemText, indentLevel: indent / 2, subItems: [], listType: .ordered, originalNumber: originalNumber))
            currentIndex += 1

            /// Handle nested lists that belong to this item (e.g., indented bullets) If next lines are nested lists with greater indent, parse them and attach as subItems.
            while currentIndex < lines.count {
                let nextLine = lines[currentIndex]

                /// If next line is blank, stop nesting.
                if nextLine.trimmingCharacters(in: .whitespaces).isEmpty { break }

                /// Check for nested unordered list.
                if let umatch = Self.unorderedListRegex.firstMatch(in: nextLine, range: NSRange(nextLine.startIndex..., in: nextLine)) {
                    let nextIndent = nextLine[Range(umatch.range(at: 1), in: nextLine)!].count
                    /// Attach only if nested (indent > parent indent).
                    if nextIndent > indent {
                        let (nestedItems, consumed) = parseUnorderedListItems(lines, startIndex: currentIndex, referenceLinks: referenceLinks, footnotes: footnotes)
                        /// Append nested items as subItems to last item.
                        if var last = items.popLast() {
                            last.subItems.append(contentsOf: nestedItems)
                            items.append(last)
                        }
                        currentIndex += consumed
                        continue
                    }
                }

                /// Check for nested ordered list.
                if let omatch = Self.orderedListRegex.firstMatch(in: nextLine, range: NSRange(nextLine.startIndex..., in: nextLine)) {
                    let nextIndent = nextLine[Range(omatch.range(at: 1), in: nextLine)!].count
                    if nextIndent > indent {
                        let (nestedItems, consumed) = parseOrderedListItems(lines, startIndex: currentIndex, referenceLinks: referenceLinks, footnotes: footnotes)
                        if var last = items.popLast() {
                            last.subItems.append(contentsOf: nestedItems)
                            items.append(last)
                        }
                        currentIndex += consumed
                        continue
                    }
                }

                /// Not a nested list, break to continue parsing sibling list items.
                break
            }
        }

        /// POST-PROCESS: If the original numbering is non-sequential (common when generators emit "1." for every item), normalize to a sequential series starting at the first original number.
        if items.count > 1 {
            let originals = items.compactMap { $0.originalNumber }
            if originals.count == items.count {
                /// Check if already sequential.
                var isSequential = true
                for i in 1..<originals.count {
                    if originals[i] != originals[i - 1] + 1 {
                        isSequential = false
                        break
                    }
                }

                if !isSequential {
                    /// Renumber starting from the first original value.
                    let start = originals.first ?? 1
                    var renumbered: [MarkdownListItem] = []
                    for (idx, item) in items.enumerated() {
                        let newNumber = start + idx
                        let newItem = MarkdownListItem(text: item.text, rawText: item.rawText, indentLevel: item.indentLevel, subItems: item.subItems, listType: item.listType, originalNumber: newNumber)
                        renumbered.append(newItem)
                    }
                    items = renumbered
                }
            }
        }

        return (items, currentIndex - startIndex)
    }

    private func parseUnorderedListItems(_ lines: [String], startIndex: Int, referenceLinks: [String: String], footnotes: [String: String]) -> ([MarkdownListItem], Int) {
        var items: [MarkdownListItem] = []
        var currentIndex = startIndex
        var safetyCounter = 0
        let maxListItems = 200

        while currentIndex < lines.count && safetyCounter < maxListItems {
            safetyCounter += 1
            let line = lines[currentIndex]

            /// SAFETY: Reject problematic content immediately before regex.
            guard line.count <= 200 else {
                break
            }

            /// SAFETY: Skip non-list lines quickly.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("+") else {
                break
            }

            /// PERFORMANCE: Use pre-compiled regex.
            guard let match = Self.unorderedListRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                break
            }

            let indent = line[Range(match.range(at: 1), in: line)!].count
            var fullItemText = String(line[Range(match.range(at: 2), in: line)!])

            /// ATTACH FOLLOWING PARAGRAPHS: mirror ordered-list behavior and allow a single blank line between the marker and the paragraph.
            if currentIndex < lines.count {
                let nextIndex = currentIndex + 1
                if nextIndex < lines.count {
                    var peekIndex = nextIndex
                    var peek = lines[peekIndex]
                    var peekTrimmed = peek.trimmingCharacters(in: .whitespaces)

                    /// Allow one blank line between label and paragraph.
                    if peekTrimmed.isEmpty {
                        let nextNext = peekIndex + 1
                        if nextNext < lines.count {
                            peekIndex = nextNext
                            peek = lines[peekIndex]
                            peekTrimmed = peek.trimmingCharacters(in: .whitespaces)
                        }
                    }

                    if !peekTrimmed.isEmpty &&
                        !peekTrimmed.hasPrefix("#") &&
                        !peekTrimmed.hasPrefix("```") &&
                        peekTrimmed.range(of: "^\\s*[-*+]\\s+", options: .regularExpression) == nil &&
                        peekTrimmed.range(of: "^\\s*\\d+\\.\\s+", options: .regularExpression) == nil {

                        let (paraLines, consumed) = collectParagraphLines(lines, startIndex: peekIndex)
                        if !paraLines.isEmpty {
                            let trimmedTitle = fullItemText.trimmingCharacters(in: .whitespaces)
                            /// Same behavior for unordered lists: prefer a hard break when attaching a continuation paragraph so titles and descriptions remain on separate lines in the UI.
                            if trimmedTitle.hasSuffix(":") {
                                fullItemText += "  \n" + paraLines.joined(separator: "\n")
                            } else {
                                fullItemText += "  \n" + paraLines.joined(separator: "\n")
                            }
                            currentIndex = peekIndex + consumed
                        }
                    }
                }
            }

            /// Normalize label spacing for unordered list items too.
            fullItemText = normalizeLeadingLabelSpacing(fullItemText)
            let attributedText = processInlineFormatting(fullItemText, referenceLinks: referenceLinks, footnotes: footnotes)

            /// Create the list item as unordered by default.
            items.append(MarkdownListItem(text: attributedText, rawText: fullItemText, indentLevel: indent / 2, subItems: [], listType: .unordered, originalNumber: nil))
            currentIndex += 1

            /// Handle nested lists that belong to this item.
            while currentIndex < lines.count {
                let nextLine = lines[currentIndex]

                if nextLine.trimmingCharacters(in: .whitespaces).isEmpty { break }

                /// Nested unordered.
                if let umatch = Self.unorderedListRegex.firstMatch(in: nextLine, range: NSRange(nextLine.startIndex..., in: nextLine)) {
                    let nextIndent = nextLine[Range(umatch.range(at: 1), in: nextLine)!].count
                    if nextIndent > indent {
                        let (nestedItems, consumed) = parseUnorderedListItems(lines, startIndex: currentIndex, referenceLinks: referenceLinks, footnotes: footnotes)
                        if var last = items.popLast() {
                            last.subItems.append(contentsOf: nestedItems)
                            items.append(last)
                        }
                        currentIndex += consumed
                        continue
                    }
                }

                /// Nested ordered.
                if let omatch = Self.orderedListRegex.firstMatch(in: nextLine, range: NSRange(nextLine.startIndex..., in: nextLine)) {
                    let nextIndent = nextLine[Range(omatch.range(at: 1), in: nextLine)!].count
                    if nextIndent > indent {
                        let (nestedItems, consumed) = parseOrderedListItems(lines, startIndex: currentIndex, referenceLinks: referenceLinks, footnotes: footnotes)
                        if var last = items.popLast() {
                            last.subItems.append(contentsOf: nestedItems)
                            items.append(last)
                        }
                        currentIndex += consumed
                        continue
                    }
                }

                break
            }
        }

        return (items, currentIndex - startIndex)
    }

    /// If the first token of the item looks like a short label followed immediately by a colon with no space (e.g.
    private func normalizeLeadingLabelSpacing(_ text: String) -> String {
        /// Quick checks.
        guard text.count > 1 else { return text }
        let maxScan = min(30, text.count)
        let prefix = String(text.prefix(maxScan))
        guard let colonIndex = prefix.firstIndex(of: ":") else { return text }

        /// Ensure prefix before colon contains no spaces (single-word label).
        let beforeColon = prefix[..<colonIndex]
        if beforeColon.contains(" ") { return text }

        /// Ensure character after colon exists and is not whitespace.
        let afterIndex = text.index(after: colonIndex)
        if afterIndex < text.endIndex {
            let afterChar = text[afterIndex]
            if afterChar != " " && afterChar != "\n" && afterChar != "\t" {
                /// Insert a space after colon.
                var s = text
                s.insert(" ", at: afterIndex)
                return s
            }
        }

        return text
    }

    private func parseTaskListItems(_ lines: [String], startIndex: Int, referenceLinks: [String: String], footnotes: [String: String]) -> ([MarkdownTaskItem], Int) {
        var items: [MarkdownTaskItem] = []
        var currentIndex = startIndex
        var safetyCounter = 0
        let maxTaskItems = 200

        while currentIndex < lines.count && safetyCounter < maxTaskItems {
            safetyCounter += 1
            let line = lines[currentIndex]

            /// SAFETY: Reject problematic content immediately before regex.
            guard line.count <= 200 else {
                break
            }

            /// SAFETY: Use range(of:) with literal options for better performance.
            guard line.range(of: "- [", options: .literal) != nil else {
                break
            }

            /// PERFORMANCE: Use pre-compiled regex.
            guard let match = Self.taskListRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                break
            }

            let indent = line[Range(match.range(at: 1), in: line)!].count
            let checkbox = String(line[Range(match.range(at: 2), in: line)!])
            let text = String(line[Range(match.range(at: 3), in: line)!])
            let attributedText = processInlineFormatting(text, referenceLinks: referenceLinks, footnotes: footnotes)
            let isCompleted = checkbox.lowercased() == "x"

            items.append(MarkdownTaskItem(text: attributedText, isCompleted: isCompleted, indentLevel: indent / 2))
            currentIndex += 1
        }

        return (items, currentIndex - startIndex)
    }

    private func collectParagraphLines(_ lines: [String], startIndex: Int) -> ([String], Int) {
        var paragraphLines: [String] = []
        var currentIndex = startIndex
        var safetyCounter = 0
        let maxParagraphLines = 100

        while currentIndex < lines.count && safetyCounter < maxParagraphLines {
            safetyCounter += 1
            let line = lines[currentIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            /// Stop at empty line or markdown block elements.
            if trimmed.isEmpty ||
               trimmed.hasPrefix("#") ||
               trimmed.hasPrefix("```") ||
               trimmed.hasPrefix(">") ||
               trimmed.contains("|") ||
               trimmed.range(of: "^\\s*([-*_]\\s*){3,}\\s*$", options: .regularExpression) != nil {
                break
            }

            /// Check for actual list items (not just bold text starting with *).
            if trimmed.range(of: "^\\s*[-*+]\\s+", options: .regularExpression) != nil ||
               trimmed.range(of: "^\\s*\\d+\\.\\s+", options: .regularExpression) != nil {
                break
            }

            paragraphLines.append(line)
            currentIndex += 1
        }

        /// SAFETY: Ensure we always consume at least one line to prevent infinite loops.
        let consumedLines = currentIndex - startIndex
        if consumedLines == 0 && startIndex < lines.count {
            return ([lines[startIndex]], 1)
        }

        return (paragraphLines, consumedLines)
    }

    /// Process inline formatting (bold, italic, links, inline code) within text.
    private func processInlineFormatting(_ text: String, referenceLinks: [String: String] = [:], footnotes: [String: String] = [:]) -> AttributedString {
        /// SAFETY: Reject oversized text immediately.
        guard text.count <= 2000 else {
            return AttributedString(text)
        }

        /// FIRST: Resolve math expressions (convert to styled code).
        var resolvedText = text

        /// Replace block math $$...$$ with code blocks (process first as they can contain single $).
        let blockMathNSText = resolvedText as NSString
        let blockMathRange = NSRange(location: 0, length: blockMathNSText.length)
        if let blockMatches = Self.blockMathRegex.matches(in: resolvedText, range: blockMathRange) as? [NSTextCheckingResult] {
            for match in blockMatches.reversed() {
                let mathExpr = blockMathNSText.substring(with: match.range(at: 1))
                let replacement = "`\(mathExpr)`"
                resolvedText = (resolvedText as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }

        /// Replace inline math $...$ with styled code.
        let inlineMathNSText = resolvedText as NSString
        let inlineMathRange = NSRange(location: 0, length: inlineMathNSText.length)
        if let inlineMatches = Self.inlineMathRegex.matches(in: resolvedText, range: inlineMathRange) as? [NSTextCheckingResult] {
            for match in inlineMatches.reversed() {
                let mathExpr = inlineMathNSText.substring(with: match.range(at: 1))
                let replacement = "`\(mathExpr)`"
                resolvedText = (resolvedText as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }

        /// SECOND: Resolve reference links and footnotes Replace reference links: [text][ref] -> [text](url).
        if !referenceLinks.isEmpty {
            let nsText = resolvedText as NSString
            let range = NSRange(location: 0, length: nsText.length)

            if let matches = Self.referenceLinkRegex.matches(in: resolvedText, range: range) as? [NSTextCheckingResult] {
                /// Process matches in reverse order to preserve ranges.
                for match in matches.reversed() {
                    let linkText = nsText.substring(with: match.range(at: 1))
                    let refId = nsText.substring(with: match.range(at: 2)).lowercased()

                    if let url = referenceLinks[refId] {
                        let replacement = "[\(linkText)](\(url))"
                        resolvedText = (resolvedText as NSString).replacingCharacters(in: match.range, with: replacement)
                    }
                }
            }
        }

        /// Replace footnote references: [^1] -> superscript with footnote text.
        if !footnotes.isEmpty {
            let nsText = resolvedText as NSString
            let range = NSRange(location: 0, length: nsText.length)

            if let matches = Self.footnoteRefRegex.matches(in: resolvedText, range: range) as? [NSTextCheckingResult] {
                /// Process matches in reverse order to preserve ranges.
                for match in matches.reversed() {
                    let footnoteId = nsText.substring(with: match.range(at: 1))

                    if let footnoteText = footnotes[footnoteId] {
                        /// Convert to superscript notation with footnote text.
                        let replacement = "^[\(footnoteId): \(footnoteText)]"
                        resolvedText = (resolvedText as NSString).replacingCharacters(in: match.range, with: replacement)
                    }
                }
            }
        }

        /// Protect special characters from SwiftUI's markdown parser SwiftUI's AttributedString(markdown:) can incorrectly remove or modify certain characters Escape dashes in compound words (e.g., "users-no" → "users\\-no") Escape apostrophes in contractions to prevent italics misinterpretation.
        var protectedText = resolvedText

        /// Protect dashes between alphanumeric characters (compound words, hyphenated terms) Pattern: word-word (e.g., "users-no", "open-source", "COVID-19").
        let dashPattern = "([a-zA-Z0-9])\\-([a-zA-Z0-9])"
        if let dashRegex = try? NSRegularExpression(pattern: dashPattern) {
            let matches = dashRegex.matches(in: protectedText, range: NSRange(protectedText.startIndex..., in: protectedText))
            /// Process in reverse to maintain ranges.
            for match in matches.reversed() {
                let fullRange = match.range
                if let range = Range(fullRange, in: protectedText) {
                    let original = String(protectedText[range])
                    /// Escape the dash: "a-b" → "a\\-b".
                    let escaped = original.replacingOccurrences(of: "-", with: "\\-")
                    protectedText.replaceSubrange(range, with: escaped)
                }
            }
        }

        /// USE SWIFTUI'S BUILT-IN MARKDOWN PARSER This is more reliable than manual AttributedString manipulation.
        do {
            /// Convert single newlines (soft breaks) into Markdown hard line breaks (two spaces + newline) so that generator-intended line breaks (title on one line, description on next) are honored by SwiftUI's AttributedString(markdown:).
            let ns = protectedText as NSString
            let singleBreakPattern = "(?<!\\n)\\n(?!\\n)"
            if let singleBreakRegex = try? NSRegularExpression(pattern: singleBreakPattern, options: []) {
                let range = NSRange(location: 0, length: ns.length)
                /// Replace single newline with two spaces + newline.
                let modified = singleBreakRegex.stringByReplacingMatches(in: protectedText, options: [], range: range, withTemplate: "  \n")
                // Sanitize common emphasis trailing-space patterns so SwiftUI's
                // Markdown parser preserves intended emphasis (e.g., "**header: **").
                let sanitized = MarkdownASTRenderer.sanitizeEmphasisTrailingSpaces(in: modified)
                /// Try full markdown parsing on modified text.
                let result = try AttributedString(markdown: sanitized)
                return result
            } else {
                let sanitized = MarkdownASTRenderer.sanitizeEmphasisTrailingSpaces(in: protectedText)
                let result = try AttributedString(markdown: sanitized)
                return result
            }
        } catch {
            /// Fallback to plain text if markdown parsing fails.
            logger.warning("Markdown parsing failed for '\(text.prefix(50))...': \(error)")
            return AttributedString(text)
        }
    }
}
