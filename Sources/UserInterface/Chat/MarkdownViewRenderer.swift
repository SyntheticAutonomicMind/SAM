// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Foundation
import Logging

/// Renders markdown AST nodes to SwiftUI views
/// Handles nested structures correctly (blockquotes in lists, etc.)
@MainActor
class MarkdownViewRenderer {
    private let logger = Logger(label: "com.sam.ui.MarkdownViewRenderer")

    /// Render AST node to SwiftUI view
    func render(_ node: MarkdownASTNode) -> AnyView {
        switch node {
        case .document(let children):
            return AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(children.enumerated()), id: \.offset) { [self] _, child in
                        render(child)
                    }
                }
            )

        case .heading(let level, let children):
            return AnyView(renderHeading(level: level, children: children))

        case .paragraph(let children):
            return AnyView(renderParagraph(children: children))

        case .blockquote(let depth, let children):
            return AnyView(renderBlockquote(depth: depth, children: children))

        case .codeBlock(let language, let code):
            return AnyView(renderCodeBlock(language: language, code: code))

        case .list(let type, let items):
            return AnyView(renderList(type: type, items: items))

        case .table(let headers, let alignments, let rows):
            return AnyView(renderTable(headers: headers, alignments: alignments, rows: rows))

        case .horizontalRule:
            return AnyView(renderHorizontalRule())

        case .image(let altText, let url):
            return AnyView(renderImage(altText: altText, url: url))

        default:
            // Inline elements should not be rendered directly at this level
            return AnyView(EmptyView())
        }
    }
    
    /// Public method to render just a table view (for PDF generation)
    func renderTableView(headers: [String], alignments: [MarkdownASTNode.TableAlignment], rows: [[String]]) -> some View {
        return renderTable(headers: headers, alignments: alignments, rows: rows)
    }

    /// Render heading
    @ViewBuilder
    private func renderHeading(level: Int, children: [MarkdownASTNode]) -> some View {
        let markdown = children.map { inlineNodeToMarkdown($0) }.joined()

        // Use AttributedString with markdown options
        if let attributedText = try? AttributedString(markdown: markdown, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributedText)
                .font(fontForHeading(level: level))
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .padding(.vertical, paddingForHeading(level: level))
        } else {
            Text(markdown)
                .font(fontForHeading(level: level))
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .padding(.vertical, paddingForHeading(level: level))
        }
    }

    private func fontForHeading(level: Int) -> Font {
        switch level {
        case 1: return .largeTitle
        case 2: return .title
        case 3: return .title2
        case 4: return .title3
        case 5: return .headline
        default: return .subheadline
        }
    }

    private func paddingForHeading(level: Int) -> CGFloat {
        switch level {
        case 1: return 8
        case 2: return 6
        case 3: return 5
        default: return 4
        }
    }

    /// Render paragraph
    @ViewBuilder
    private func renderParagraph(children: [MarkdownASTNode]) -> some View {
        // Check if paragraph contains images - if so, render them separately
        let hasImages = children.contains { node in
            if case .image = node { return true }
            return false
        }

        if hasImages {
            // Render paragraph with images as separate views
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(children.enumerated()), id: \.offset) { [self] _, child in
                        if case .image(let altText, let url) = child {
                            renderImage(altText: altText, url: url)
                        } else {
                            let markdownText = inlineNodeToMarkdown(child)
                            if !markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                if let attributedText = try? AttributedString(markdown: markdownText, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                                    Text(attributedText)
                                        .lineSpacing(4)
                                } else {
                                    Text(markdownText)
                                        .lineSpacing(4)
                                }
                            }
                        }
                    }
                }
            )
        } else {
            // Convert AST nodes back to markdown string
            let markdownText = children.map { inlineNodeToMarkdown($0) }.joined()

            // Use AttributedString with markdown options for better compatibility
            if let attributedText = try? AttributedString(markdown: markdownText, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                return AnyView(
                    Text(attributedText)
                        .lineSpacing(4)
                )
            } else {
                // Fallback to plain text
                return AnyView(
                    Text(markdownText)
                        .lineSpacing(4)
                )
            }
        }
    }

    /// Render blockquote
    @ViewBuilder
    private func renderBlockquote(depth: Int, children: [MarkdownASTNode]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(Color.blue.opacity(0.7))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    self.render(child)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }

            Spacer()
        }
        .padding(.leading, CGFloat(depth * 16))
        .padding(.vertical, 4)
    }

    /// Render code block (with Mermaid diagram support)
    @ViewBuilder
    private func renderCodeBlock(language: String?, code: String) -> some View {
        // Check if this is a Mermaid diagram
        if let language = language, language.lowercased() == "mermaid" {
            // Native Mermaid rendering
            MermaidDiagramView(code: code)
        } else {
            // Regular code block
            VStack(alignment: .leading, spacing: 0) {
                if let language = language, !language.isEmpty {
                    HStack {
                        Text(language.uppercased())
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        Spacer()
                    }
                    .background(Color.secondary.opacity(0.1))
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
    }

    /// Render list
    @ViewBuilder
    private func renderList(type: MarkdownASTNode.ListType, items: [MarkdownASTNode.ListItemNode]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                self.renderListItem(item: item, index: index, type: type)
            }
        }
    }

    /// Render individual list item
    @ViewBuilder
    private func renderListItem(item: MarkdownASTNode.ListItemNode, index: Int, type: MarkdownASTNode.ListType) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Render marker
            switch type {
            case .ordered:
                let number = item.number ?? (index + 1)
                Text("\(number).")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(width: 30, alignment: .trailing)

            case .unordered:
                bulletImage(for: item.indentLevel)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .frame(width: 12, alignment: .center)

            case .task:
                Image(systemName: item.isChecked == true ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundColor(item.isChecked == true ? .blue : .secondary)
                    .frame(width: 16, alignment: .center)
            }

            // Render content
            // CRITICAL: List items are parsed as blocks, so children are usually paragraphs
            // If there's a single paragraph child, render it inline without extra spacing
            if item.children.count == 1 {
                let firstChild = item.children[0]

                if case .paragraph(let inlineChildren) = firstChild {
                    // Single paragraph - render inline
                    let markdownText = inlineChildren.map { inlineNodeToMarkdown($0) }.joined()

                    if let attributedText = try? AttributedString(markdown: markdownText, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributedText)
                    } else {
                        Text(markdownText)
                    }
                } else {
                    // Not a paragraph - render normally
                    self.render(firstChild)
                }
            } else {
                // Multiple children or complex content - render as blocks
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                        self.render(child)
                    }
                }
            }

            Spacer()
        }
        .padding(.leading, CGFloat(item.indentLevel * 20))
    }

    /// Returns appropriate bullet style based on nesting level
    private func bulletImage(for level: Int) -> Image {
        switch level % 3 {
        case 0: return Image(systemName: "circle.fill")
        case 1: return Image(systemName: "circle")
        default: return Image(systemName: "square.fill")
        }
    }

    /// Render table
    @ViewBuilder
    private func renderTable(headers: [String], alignments: [MarkdownASTNode.TableAlignment], rows: [[String]]) -> some View {
        VStack(spacing: 1) {
            // Header row
            HStack(spacing: 1) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    self.renderTableCellContent(header, isBold: true)
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: self.alignmentForTable(index: index, alignments: alignments))
                        .background(Color.secondary.opacity(0.15))
                        .overlay(
                            Rectangle()
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                }
            }

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 1) {
                    ForEach(Array(row.enumerated()), id: \.offset) { cellIndex, cell in
                        self.renderTableCellContent(cell, isBold: false)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: self.alignmentForTable(index: cellIndex, alignments: alignments))
                            .background(
                                rowIndex % 2 == 0
                                ? Color.clear
                                : Color.secondary.opacity(0.05)
                            )
                            .overlay(
                                Rectangle()
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.02))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }

    /// Render table cell content with inline markdown (bold, italic, code, links).
    @ViewBuilder
    private func renderTableCellContent(_ text: String, isBold: Bool) -> some View {
        if let attributedString = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            if isBold {
                Text(attributedString).font(.body.bold())
            } else {
                Text(attributedString).font(.body)
            }
        } else {
            /// Fallback to plain text if markdown parsing fails.
            if isBold {
                Text(text).font(.body.bold())
            } else {
                Text(text).font(.body)
            }
        }
    }

    private func alignmentForTable(index: Int, alignments: [MarkdownASTNode.TableAlignment]) -> Alignment {
        guard index < alignments.count else { return .leading }

        switch alignments[index] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    /// Render horizontal rule
    /// Render horizontal rule
    @ViewBuilder
    private func renderHorizontalRule() -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(maxWidth: .infinity, maxHeight: 1)
            .padding(.vertical, 8)
    }

    /// Render image
    @ViewBuilder
    private func renderImage(altText: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            /// Handle file:// URLs specially - AsyncImage doesn't work well with local files
            if url.hasPrefix("file://"), let imageURL = URL(string: url) {
                LocalFileImageView(url: imageURL, altText: altText)
            } else if let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.large)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)

                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 600)
                            .cornerRadius(8)
                            .shadow(color: .primary.opacity(0.1), radius: 4, x: 0, y: 2)

                    case .failure:
                        VStack(spacing: 8) {
                            Image(systemName: "photo.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)

                            Text("Failed to load image")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if !altText.isEmpty {
                                Text(altText)
                                    .font(.caption2)
                                    .foregroundColor(.secondary.opacity(0.8))
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, minHeight: 150)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)

                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)

                    Text("Invalid image URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: 100)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            if !altText.isEmpty {
                Text(altText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Inline Rendering

    /// Render inline nodes to AttributedString using SwiftUI's markdown parser
    /// This ensures proper formatting for bold, italic, links, etc.
    func renderInline(_ nodes: [MarkdownASTNode]) -> AttributedString {
        // Convert AST nodes back to markdown string
        var markdownText = ""
        for node in nodes {
            markdownText += inlineNodeToMarkdown(node)
        }

        // Use SwiftUI's built-in markdown parser
        do {
            // Sanitize emphasis trailing spaces
            let sanitized = MarkdownViewRenderer.sanitizeEmphasisTrailingSpaces(in: markdownText)
            return try AttributedString(markdown: sanitized)
        } catch {
            logger.warning("Markdown parsing failed for inline: \(markdownText.prefix(50))")
            return AttributedString(markdownText)
        }
    }

    /// Convert inline AST node back to markdown string
    /// Check if node is an inline element
    private func isInlineNode(_ node: MarkdownASTNode) -> Bool {
        switch node {
        case .text, .strong, .emphasis, .strikethrough, .inlineCode, .link, .softBreak, .hardBreak:
            return true
        default:
            return false
        }
    }

    private func inlineNodeToMarkdown(_ node: MarkdownASTNode) -> String {
        switch node {
        case .text(let text):
            return text

        case .strong(let children):
            let inner = children.map { inlineNodeToMarkdown($0) }.joined()
            return "**\(inner)**"

        case .emphasis(let children):
            let inner = children.map { inlineNodeToMarkdown($0) }.joined()
            return "*\(inner)*"

        case .strikethrough(let children):
            let inner = children.map { inlineNodeToMarkdown($0) }.joined()
            return "~~\(inner)~~"

        case .inlineCode(let code):
            return "`\(code)`"

        case .link(let text, let url):
            return "[\(text)](\(url))"

        case .softBreak:
            return " "

        case .hardBreak:
            return "  \n"

        case .image(let altText, let url):
            // Inline images render as links
            return "[\(altText.isEmpty ? "Image" : altText)](\(url))"

        default:
            logger.warning("Unexpected node type in inline context: \(node)")
            return ""
        }
    }

    /// Sanitize emphasis trailing spaces for SwiftUI compatibility
    /// Prevents SwiftUI's markdown parser from stripping emphasis
    static func sanitizeEmphasisTrailingSpaces(in text: String) -> String {
        var result = text

        // Fix **text: ** -> **text:** (remove space before closing **)
        result = result.replacingOccurrences(of: #" \*\*"#, with: "**", options: .regularExpression)

        // Fix *text: * -> *text:* (remove space before closing *)
        result = result.replacingOccurrences(of: #" \*(?!\*)"#, with: "*", options: .regularExpression)

        return result
    }
}

/// SwiftUI view that renders a markdown AST
struct MarkdownASTView: View {
    let ast: MarkdownASTNode
    private let renderer = MarkdownViewRenderer()

    var body: some View {
        renderer.render(ast)
    }
}

/// View for rendering local file:// images using NSImage
/// AsyncImage doesn't work reliably with file:// URLs on macOS
struct LocalFileImageView: View {
    let url: URL
    let altText: String
    @State private var nsImage: NSImage?
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        Group {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            } else if let nsImage = nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 600)
                    .cornerRadius(8)
                    .shadow(color: .primary.opacity(0.1), radius: 4, x: 0, y: 2)
                    .contextMenu {
                        Button("Open in Finder") {
                            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: (url.path as NSString).deletingLastPathComponent)
                        }

                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.path, forType: .string)
                        }

                        Divider()

                        Button("Copy Image") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([nsImage])
                        }

                        Button("Delete Image", role: .destructive) {
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("Failed to load image")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let error = loadError {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }

                    if !altText.isEmpty {
                        Text(altText)
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: 200)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }
        }
        .onAppear {
            loadImage()
        }
    }

    private func loadImage() {
        Task {
            do {
                /// CRITICAL: file:// URLs with percent-encoding (e.g., %20 for space, %28%29 for parentheses)
                /// need to be decoded to actual file paths before Data(contentsOf:) can use them.

                /// Get the decoded path from the URL
                /// Swift 5.9+: url.path(percentEncoded: false)
                /// Fallback: url.path then manually decode
                let decodedPath: String
                if #available(macOS 13.0, *) {
                    decodedPath = url.path(percentEncoded: false)
                } else {
                    /// Fallback for older macOS: use path property and removingPercentEncoding
                    decodedPath = url.path.removingPercentEncoding ?? url.path
                }

                /// Create a new file URL from the decoded path
                let fileURL = URL(fileURLWithPath: decodedPath)

                /// Load image data
                let imageData = try Data(contentsOf: fileURL)
                if let loadedImage = NSImage(data: imageData) {
                    await MainActor.run {
                        self.nsImage = loadedImage
                        self.isLoading = false
                    }
                } else {
                    await MainActor.run {
                        self.loadError = "Invalid image format"
                        self.isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.loadError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}
