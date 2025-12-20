// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Foundation

/// Abstract Syntax Tree node for markdown content
/// Recursive structure that supports arbitrary nesting of markdown elements
enum MarkdownASTNode {
    /// Block-level elements
    case document(children: [MarkdownASTNode])
    case heading(level: Int, children: [MarkdownASTNode])
    case paragraph(children: [MarkdownASTNode])
    case blockquote(depth: Int, children: [MarkdownASTNode])
    case codeBlock(language: String?, code: String)
    case list(type: ListType, items: [ListItemNode])
    case table(headers: [String], alignments: [TableAlignment], rows: [[String]])
    case horizontalRule
    case image(altText: String, url: String)

    /// Inline elements
    case text(String)
    case strong(children: [MarkdownASTNode])
    case emphasis(children: [MarkdownASTNode])
    case strikethrough(children: [MarkdownASTNode])
    case inlineCode(String)
    case link(text: String, url: String)
    case softBreak
    case hardBreak

    /// List-specific node
    struct ListItemNode {
        let children: [MarkdownASTNode]
        let isChecked: Bool?  // nil for regular lists, true/false for task lists
        let number: Int?      // nil for unordered lists, number for ordered lists
        let indentLevel: Int  // 0-based indentation level for nested lists
    }

    enum ListType {
        case ordered
        case unordered
        case task
    }

    enum TableAlignment {
        case left
        case center
        case right
    }
}

/// Token types for markdown parsing
enum MarkdownToken {
    /// Block tokens
    case heading(level: Int, text: String)
    case codeBlockStart(language: String?)
    case codeBlockEnd
    case blockquotePrefix(depth: Int)
    case listItemUnordered(indent: Int, text: String)
    case listItemOrdered(indent: Int, number: Int, text: String)
    case listItemTask(indent: Int, checked: Bool, text: String)
    case tableRow(cells: [String])
    case tableSeparator(alignments: [MarkdownASTNode.TableAlignment])
    case horizontalRule
    case blankLine
    case text(String)

    /// Inline tokens (processed separately)
    case inlineContent(String)
}

/// Parsing context to maintain state during recursive parsing
struct MarkdownParserContext {
    var currentIndent: Int = 0
    var insideCodeBlock: Bool = false
    var codeBlockLanguage: String?
    var codeBlockLines: [String] = []
    var blockquoteDepth: Int = 0
    var referenceLinks: [String: String] = [:]
    var footnotes: [String: String] = [:]
}

/// Result of parsing operation
struct ParseResult {
    let node: MarkdownASTNode
    let linesConsumed: Int
}

/// Configuration for markdown parser behavior
struct MarkdownParserConfig {
    var maxNestingDepth: Int = 20
    var maxContentLength: Int = 50000
    var enableTables: Bool = true
    var enableTaskLists: Bool = true
    var enableFootnotes: Bool = true
    var enableMath: Bool = true
}
