// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// Converts MarkdownAST to clean HTML for WKWebView rendering.
enum MarkdownASTToHTML {
    
    /// Convert an AST node tree to an HTML string.
    static func convert(_ node: MarkdownASTNode) -> String {
        switch node {
        case .document(let children):
            return children.map(convert).joined(separator: "\n")
            
        case .heading(let level, let children):
            let content = children.map(convertInline).joined()
            return "<h\(level)>\(content)</h\(level)>"
            
        case .paragraph(let children):
            let content = children.map(convertInline).joined()
            if content.isEmpty { return "" }
            return "<p>\(content)</p>"
            
        case .blockquote(let depth, let children):
            let content = children.map(convert).joined(separator: "\n")
            return "<blockquote>\(content)</blockquote>"
            
        case .codeBlock(let language, let code):
            let lang = language.map { " class=\"language-\(esc($0))\"" } ?? ""
            return "<pre><code\(lang)>\(esc(code))</code></pre>"
            
        case .list(let type, let items):
            let tag = type == .ordered ? "ol" : "ul"
            let itemsHTML = items.map { item in
                let content = item.children.map(convert).joined(separator: "\n")
                let indent = item.indentLevel > 0 ? " style=\"margin-left:\(item.indentLevel * 20)px\"" : ""
                if type == .task {
                    let checked = (item.isChecked ?? false) ? " checked" : ""
                    return "<li class=\"task-item\"\(indent)><input type=\"checkbox\" disabled\(checked)>\(content)</li>"
                }
                return "<li\(indent)>\(content)</li>"
            }.joined(separator: "\n")
            return "<\(tag) class=\"\(type == .task ? "task-list" : "")\">\(itemsHTML)</\(tag)>"
            
        case .table(let headers, let alignments, let rows):
            var html = "<table>"
            html += "<thead><tr>"
            for (i, h) in headers.enumerated() {
                let align = i < alignments.count ? tableAlign(alignments[i]) : ""
                html += "<th\(align)>\(parseInlineHTML(h))</th>"
            }
            html += "</tr></thead><tbody>"
            for row in rows {
                html += "<tr>"
                for (i, cell) in row.enumerated() {
                    let align = i < alignments.count ? tableAlign(alignments[i]) : ""
                    html += "<td\(align)>\(parseInlineHTML(cell))</td>"
                }
                html += "</tr>"
            }
            html += "</tbody></table>"
            return html
            
        case .horizontalRule:
            return "<hr>"
            
        case .image(let altText, let url):
            let alt = esc(altText)
            let src = esc(url)
            return "<p><img src=\"\(src)\" alt=\"\(alt)\" style=\"max-width:100%\"></p>"
            
        case .text(let string):
            return esc(string)
            
        case .strong(let children):
            return "<strong>\(children.map(convertInline).joined())</strong>"
            
        case .emphasis(let children):
            return "<em>\(children.map(convertInline).joined())</em>"
            
        case .strikethrough(let children):
            return "<del>\(children.map(convertInline).joined())</del>"
            
        case .inlineCode(let code):
            return "<code>\(esc(code))</code>"
            
        case .link(let text, let url):
            return "<a href=\"\(esc(url))\">\(esc(text))</a>"
            
        case .softBreak:
            return "\n"
            
        case .hardBreak:
            return "<br>"
        }
    }
    
    /// Convert inline-only nodes (for use inside paragraphs/headings).
    private static func convertInline(_ node: MarkdownASTNode) -> String {
        switch node {
        case .text(let s): return esc(s)
        case .strong(let c): return "<strong>\(c.map(convertInline).joined())</strong>"
        case .emphasis(let c): return "<em>\(c.map(convertInline).joined())</em>"
        case .strikethrough(let c): return "<del>\(c.map(convertInline).joined())</del>"
        case .inlineCode(let code): return "<code>\(esc(code))</code>"
        case .link(let text, let url): return "<a href=\"\(esc(url))\">\(esc(text))</a>"
        case .softBreak: return "\n"
        case .hardBreak: return "<br>"
        case .image(let alt, let url): 
            return "<img src=\"\(esc(url))\" alt=\"\(esc(alt))\" style=\"max-width:100%\">"
        default: return convert(node)
        }
    }
    
    /// Parse inline markdown in plain text strings (for table cells).
    private static func parseInlineHTML(_ text: String) -> String {
        var result = esc(text)
        // Code: `text`
        result = regexReplace(text: result, pattern: "`([^`]+)`") { groups in
            "<code>\(esc(groups[1]))</code>"
        }
        // Bold: **text**
        result = regexReplace(text: result, pattern: "\\*\\*(.+?)\\*\\*") { groups in
            "<strong>\(groups[1])</strong>"
        }
        // Italic: *text* (not preceded or followed by *)
        result = regexReplace(text: result, pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)") { groups in
            "<em>\(groups[1])</em>"
        }
        // Links: [text](url)
        result = regexReplace(text: result, pattern: "\\[([^\\]]*)\\]\\(([^)]+)\\)") { groups in
            "<a href=\"\(esc(groups[2]))\">\(groups[1])</a>"
        }
        return result
    }
    
    /// Replace regex pattern matches using NSRegularExpression.
    private static func regexReplace(text: String, pattern: String, replacer: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        var result = text
        for match in matches.reversed() {
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                if let r = Range(match.range(at: i), in: text) {
                    groups.append(String(text[r]))
                }
            }
            let replacement = replacer(groups)
            if let nsRange = Range(match.range, in: result) {
                result.replaceSubrange(nsRange, with: replacement)
            }
        }
        return result
    }
    
    private static func tableAlign(_ a: MarkdownASTNode.TableAlignment) -> String {
        switch a {
        case .left: return ""
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        }
    }
    
    /// HTML-escape special characters.
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
