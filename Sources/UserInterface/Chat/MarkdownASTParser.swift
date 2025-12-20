// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Foundation
import Logging

/// AST-based markdown parser with full support for nested structures
/// Parses markdown into an Abstract Syntax Tree for reliable rendering
class MarkdownASTParser {
    private let logger = Logger(label: "com.sam.ui.MarkdownASTParser")
    private let inlineParser = MarkdownInlineParser()
    private let config: MarkdownParserConfig

    init(config: MarkdownParserConfig = MarkdownParserConfig()) {
        self.config = config
    }

    /// Parse markdown text into an AST
    func parse(_ markdown: String) -> MarkdownASTNode {
        // Safety check
        guard markdown.count <= config.maxContentLength else {
            logger.warning("Content too large (\(markdown.count) chars), truncating")
            let truncated = String(markdown.prefix(config.maxContentLength))
            return parse(truncated)
        }

        let lines = markdown.components(separatedBy: .newlines)

        // First pass: extract reference links and footnotes
        let (referenceLinks, footnotes, contentLines) = extractReferences(from: lines)

        // Second pass: parse block elements
        var context = MarkdownParserContext()
        context.referenceLinks = referenceLinks
        context.footnotes = footnotes

        let children = parseBlocks(contentLines, context: context, depth: 0)

        return .document(children: children)
    }

    /// Extract reference links and footnotes from lines
    private func extractReferences(from lines: [String]) -> ([String: String], [String: String], [String]) {
        var referenceLinks: [String: String] = [:]
        var footnotes: [String: String] = [:]
        var contentLines: [String] = []

        let refLinkPattern = #"^\[([^\]]+)\]:\s*(.+)$"#
        let footnotePattern = #"^\[\^([^\]]+)\]:\s*(.+)$"#

        guard let refLinkRegex = try? NSRegularExpression(pattern: refLinkPattern),
              let footnoteRegex = try? NSRegularExpression(pattern: footnotePattern) else {
            return (referenceLinks, footnotes, lines)
        }

        for line in lines {
            let nsRange = NSRange(line.startIndex..., in: line)

            // Check for reference link
            if let match = refLinkRegex.firstMatch(in: line, range: nsRange) {
                if let idRange = Range(match.range(at: 1), in: line),
                   let urlRange = Range(match.range(at: 2), in: line) {
                    let id = String(line[idRange]).lowercased()
                    let url = String(line[urlRange])
                    referenceLinks[id] = url
                    continue
                }
            }

            // Check for footnote
            if let match = footnoteRegex.firstMatch(in: line, range: nsRange) {
                if let idRange = Range(match.range(at: 1), in: line),
                   let textRange = Range(match.range(at: 2), in: line) {
                    let id = String(line[idRange])
                    let text = String(line[textRange])
                    footnotes[id] = text
                    continue
                }
            }

            // Regular content line
            contentLines.append(line)
        }

        return (referenceLinks, footnotes, contentLines)
    }

    /// Parse block-level elements recursively
    private func parseBlocks(_ lines: [String], context: MarkdownParserContext, depth: Int) -> [MarkdownASTNode] {
        guard depth < config.maxNestingDepth else {
            logger.error("Max nesting depth exceeded at \(depth)")
            return [.text("Error: Content too deeply nested")]
        }

        var nodes: [MarkdownASTNode] = []
        var currentIndex = 0
        var iterationCount = 0
        let maxIterations = lines.count * 2

        while currentIndex < lines.count && iterationCount < maxIterations {
            iterationCount += 1
            let line = lines[currentIndex]

            // Skip blank lines
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                currentIndex += 1
                continue
            }

            // Safety check for extremely long lines (raised to 100K to support long LLM responses)
            // Claude/GPT often generate 5K-20K character paragraphs for detailed prompts
            if line.count > 100_000 {
                logger.warning("Line too long (\(line.count) chars), truncating to 50K")
                let truncated = String(line.prefix(50_000)) + "..."
                nodes.append(.paragraph(children: [.text(truncated)]))
                currentIndex += 1
                continue
            }

            // Try to parse as different block types
            if let result = parseHeading(line) {
                nodes.append(result)
                currentIndex += 1
            } else if let result = parseCodeBlock(lines, startIndex: currentIndex) {
                nodes.append(result.node)
                currentIndex += result.linesConsumed
            } else if let result = parseBlockquote(lines, startIndex: currentIndex, context: context, depth: depth) {
                nodes.append(result.node)
                currentIndex += result.linesConsumed
            } else if let result = parseList(lines, startIndex: currentIndex, context: context, depth: depth) {
                nodes.append(result.node)
                currentIndex += result.linesConsumed
            } else if let result = parseTable(lines, startIndex: currentIndex) {
                nodes.append(result.node)
                currentIndex += result.linesConsumed
            } else if parseHorizontalRule(line) {
                nodes.append(.horizontalRule)
                currentIndex += 1
            } else if let result = parseImage(line) {
                nodes.append(result)
                currentIndex += 1
            } else {
                // Parse as paragraph
                let result = parseParagraph(lines, startIndex: currentIndex, context: context)
                nodes.append(result.node)
                currentIndex += max(result.linesConsumed, 1)  // Always advance at least 1
            }
        }

        return nodes
    }

    /// Parse heading (# through ######)
    private func parseHeading(_ line: String) -> MarkdownASTNode? {
        let pattern = #"^(#{1,6})\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let hashRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        let level = line[hashRange].count
        let text = String(line[textRange])
        let children = inlineParser.parse(text)

        return .heading(level: level, children: children)
    }

    /// Parse code block (``` or indented)
    private func parseCodeBlock(_ lines: [String], startIndex: Int) -> ParseResult? {
        let line = lines[startIndex]

        // Fenced code block
        if line.hasPrefix("```") {
            let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            var currentIndex = startIndex + 1

            while currentIndex < lines.count {
                let codeLine = lines[currentIndex]
                if codeLine.trimmingCharacters(in: .whitespaces) == "```" {
                    let code = codeLines.joined(separator: "\n")
                    let node = MarkdownASTNode.codeBlock(
                        language: language.isEmpty ? nil : language,
                        code: code
                    )
                    return ParseResult(node: node, linesConsumed: currentIndex - startIndex + 1)
                }
                codeLines.append(codeLine)
                currentIndex += 1
            }

            // No closing fence found
            let code = codeLines.joined(separator: "\n")
            return ParseResult(
                node: .codeBlock(language: language.isEmpty ? nil : language, code: code),
                linesConsumed: currentIndex - startIndex
            )
        }

        // Indented code block (4 spaces or 1 tab)
        if line.hasPrefix("    ") || line.hasPrefix("\t") {
            var codeLines: [String] = []
            var currentIndex = startIndex

            while currentIndex < lines.count {
                let codeLine = lines[currentIndex]

                // Blank lines are part of code block
                if codeLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    codeLines.append("")
                    currentIndex += 1
                    continue
                }

                // Must be indented
                guard codeLine.hasPrefix("    ") || codeLine.hasPrefix("\t") else {
                    break
                }

                // Remove indentation
                let unindented = codeLine.hasPrefix("    ")
                    ? String(codeLine.dropFirst(4))
                    : String(codeLine.dropFirst())
                codeLines.append(unindented)
                currentIndex += 1
            }

            guard !codeLines.isEmpty else { return nil }

            let code = codeLines.joined(separator: "\n")
            return ParseResult(node: .codeBlock(language: nil, code: code), linesConsumed: currentIndex - startIndex)
        }

        return nil
    }

    /// Parse blockquote with nested content support
    private func parseBlockquote(_ lines: [String], startIndex: Int, context: MarkdownParserContext, depth: Int) -> ParseResult? {
        let line = lines[startIndex]

        // Check if line starts with >
        guard line.trimmingCharacters(in: .whitespaces).hasPrefix(">") else {
            return nil
        }

        // Collect all consecutive blockquote lines
        var blockquoteLines: [String] = []
        var currentIndex = startIndex
        var blockquoteDepth = 0

        while currentIndex < lines.count {
            let bqLine = lines[currentIndex]
            let trimmed = bqLine.trimmingCharacters(in: .whitespaces)

            // Stop at non-blockquote line
            guard trimmed.hasPrefix(">") else {
                break
            }

            // Count > prefixes
            var depth = 0
            var remaining = trimmed
            while remaining.hasPrefix(">") {
                depth += 1
                remaining = String(remaining.dropFirst()).trimmingCharacters(in: .whitespaces)
            }

            blockquoteDepth = max(blockquoteDepth, depth)

            // Remove > prefix and add to content
            blockquoteLines.append(remaining)
            currentIndex += 1
        }

        guard !blockquoteLines.isEmpty else { return nil }

        // Recursively parse blockquote content
        let children = parseBlocks(blockquoteLines, context: context, depth: depth + 1)

        return ParseResult(
            node: .blockquote(depth: blockquoteDepth, children: children),
            linesConsumed: currentIndex - startIndex
        )
    }

    /// Parse list (ordered, unordered, or task)
    private func parseList(_ lines: [String], startIndex: Int, context: MarkdownParserContext, depth: Int) -> ParseResult? {
        let line = lines[startIndex]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Detect list type
        let listType: MarkdownASTNode.ListType
        let pattern: String

        if let taskMatch = try? NSRegularExpression(pattern: #"^(\s*)- \[([xX ])\] (.+)$"#).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            listType = .task
            pattern = #"^(\s*)- \[([xX ])\] (.+)$"#
        } else if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("+") {
            listType = .unordered
            pattern = #"^(\s*)[-*+] (.+)$"#
        } else if let _ = try? NSRegularExpression(pattern: #"^(\s*)(\d+)\. (.+)$"#).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            listType = .ordered
            pattern = #"^(\s*)(\d+)\. (.+)$"#
        } else {
            return nil
        }

        // Parse list items
        var items: [MarkdownASTNode.ListItemNode] = []
        var currentIndex = startIndex

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        while currentIndex < lines.count {
            let itemLine = lines[currentIndex]

            guard let match = regex.firstMatch(in: itemLine, range: NSRange(itemLine.startIndex..., in: itemLine)) else {
                break
            }

            // Parse list item content
            let result = parseListItem(lines, startIndex: currentIndex, listType: listType, context: context, depth: depth)
            items.append(result.item)
            currentIndex += result.linesConsumed
        }

        guard !items.isEmpty else { return nil }

        return ParseResult(
            node: .list(type: listType, items: items),
            linesConsumed: currentIndex - startIndex
        )
    }

    /// Parse a single list item with nested content
    private func parseListItem(_ lines: [String], startIndex: Int, listType: MarkdownASTNode.ListType, context: MarkdownParserContext, depth: Int) -> (item: MarkdownASTNode.ListItemNode, linesConsumed: Int) {
        let line = lines[startIndex]

        var isChecked: Bool?
        var number: Int?
        var text = ""
        var indent = 0

        switch listType {
        case .task:
            if let match = try? NSRegularExpression(pattern: #"^(\s*)- \[([xX ])\] (.+)$"#).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let indentRange = Range(match.range(at: 1), in: line),
               let checkRange = Range(match.range(at: 2), in: line),
               let textRange = Range(match.range(at: 3), in: line) {
                indent = String(line[indentRange]).count
                let checkChar = String(line[checkRange]).lowercased()
                isChecked = (checkChar == "x")
                text = String(line[textRange])
            }

        case .unordered:
            if let match = try? NSRegularExpression(pattern: #"^(\s*)[-*+] (.+)$"#).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let indentRange = Range(match.range(at: 1), in: line),
               let textRange = Range(match.range(at: 2), in: line) {
                indent = String(line[indentRange]).count
                text = String(line[textRange])
            }

        case .ordered:
            if let match = try? NSRegularExpression(pattern: #"^(\s*)(\d+)\. (.+)$"#).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let indentRange = Range(match.range(at: 1), in: line),
               let numRange = Range(match.range(at: 2), in: line),
               let textRange = Range(match.range(at: 3), in: line) {
                indent = String(line[indentRange]).count
                number = Int(String(line[numRange]))
                text = String(line[textRange])
            }
        }

        // Calculate indent level (0-based, each 2 spaces = 1 level)
        let indentLevel = indent / 2

        // Collect continuation lines (lines that belong to this list item)
        var contentLines = [text]
        var currentIndex = startIndex + 1

        while currentIndex < lines.count {
            let nextLine = lines[currentIndex]
            let trimmed = nextLine.trimmingCharacters(in: .whitespaces)

            // Stop at blank line
            if trimmed.isEmpty {
                break
            }

            // Stop at next list marker at same or higher level
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("+") ||
               trimmed.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                break
            }

            // CRITICAL: Include block elements as part of list item content
            // They will be parsed recursively as nested markdown
            // Only stop at headers (they should start new sections)
            if trimmed.hasPrefix("#") {
                break
            }

            contentLines.append(trimmed)
            currentIndex += 1
        }

        // Parse item content as blocks (supports nested markdown including blockquotes!)
        let children = parseBlocks(contentLines, context: context, depth: depth + 1)

        let item = MarkdownASTNode.ListItemNode(
            children: children,
            isChecked: isChecked,
            number: number,
            indentLevel: indentLevel
        )

        return (item, currentIndex - startIndex)
    }

    /// Parse table
    private func parseTable(_ lines: [String], startIndex: Int) -> ParseResult? {
        guard startIndex + 1 < lines.count else {
            logger.trace("parseTable: not enough lines at index \(startIndex)")
            return nil
        }

        let headerLine = lines[startIndex]
        let separatorLine = lines[startIndex + 1]
        
        logger.trace("parseTable: checking header='\(headerLine)' separator='\(separatorLine)'")

        // Check for table separator (allows pipes throughout: |---|---|---|)
        guard separatorLine.trimmingCharacters(in: .whitespaces).range(of: #"^\|?[\s:|\-]+\|?$"#, options: .regularExpression) != nil else {
            logger.trace("parseTable: separator line doesn't match table pattern")
            return nil
        }
        
        logger.info("parseTable: MATCHED table at line \(startIndex)")

        // Parse headers
        let headers = parseTableRow(headerLine)
        let alignments = parseTableAlignments(separatorLine)

        // Parse data rows
        var rows: [[String]] = []
        var currentIndex = startIndex + 2

        while currentIndex < lines.count {
            let rowLine = lines[currentIndex]
            let trimmed = rowLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || !trimmed.contains("|") {
                break
            }

            let cells = parseTableRow(rowLine)
            rows.append(cells)
            currentIndex += 1
        }

        return ParseResult(
            node: .table(headers: headers, alignments: alignments, rows: rows),
            linesConsumed: currentIndex - startIndex
        )
    }

    private func parseTableRow(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var working = trimmed

        // Remove outer pipes
        if working.hasPrefix("|") { working = String(working.dropFirst()) }
        if working.hasSuffix("|") { working = String(working.dropLast()) }

        return working.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func parseTableAlignments(_ line: String) -> [MarkdownASTNode.TableAlignment] {
        let cells = parseTableRow(line)
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

    /// Parse horizontal rule
    private func parseHorizontalRule(_ line: String) -> Bool {
        let pattern = #"^\s*[-*_]{3,}\s*$"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    /// Parse standalone image
    private func parseImage(_ line: String) -> MarkdownASTNode? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard trimmed.hasPrefix("![") else { return nil }

        let pattern = #"^!\[([^\]]*)\]\(([^)]+)\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let altRange = Range(match.range(at: 1), in: trimmed),
              let urlRange = Range(match.range(at: 2), in: trimmed) else {
            return nil
        }

        let altText = String(trimmed[altRange])
        let url = String(trimmed[urlRange])

        return .image(altText: altText, url: url)
    }

    /// Parse paragraph with inline content
    private func parseParagraph(_ lines: [String], startIndex: Int, context: MarkdownParserContext) -> ParseResult {
        var paragraphLines: [String] = []
        var currentIndex = startIndex

        while currentIndex < lines.count {
            let line = lines[currentIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Stop at blank line or block elements
            if trimmed.isEmpty ||
               trimmed.hasPrefix("#") ||
               trimmed.hasPrefix("```") ||
               trimmed.hasPrefix(">") ||
               trimmed.range(of: #"^[-*+] "#, options: .regularExpression) != nil ||
               trimmed.range(of: #"^\d+\. "#, options: .regularExpression) != nil ||
               trimmed.range(of: #"^- \[[xX ]\] "#, options: .regularExpression) != nil ||
               trimmed.range(of: #"^\|"#, options: .regularExpression) != nil {
                break
            }

            paragraphLines.append(line)
            currentIndex += 1
        }

        let text = paragraphLines.joined(separator: "\n")
        let children = inlineParser.parse(text, referenceLinks: context.referenceLinks)

        return ParseResult(
            node: .paragraph(children: children),
            linesConsumed: max(paragraphLines.count, 1)
        )
    }
}
