// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import PDFKit
import Markdown
import Logging

/// AST-based markdown to PDF renderer Inspired by md2pdf's architecture: https://github.com/solworktech/md2pdf Uses Apple's swift-markdown for AST parsing, implements visitor pattern with state stack for nested formatting (same approach as md2pdf).
public class MarkdownASTRenderer {
    private let logger = Logger(label: "com.sam.documents.MarkdownASTRenderer")

    /// PDF context and configuration.
    private var pdfContext: CGContext!
    private var currentY: CGFloat = 0
    private let pageSize: CGSize
    private let margin: CGFloat
    private let contentWidth: CGFloat
    private let contentHeight: CGFloat

    /// State stack for nested formatting (like md2pdf's containerState).
    private var styleStack: [TextStyle] = []

    /// List state tracking.
    private var listStack: [ListContext] = []

    /// Accumulated attributed string for current paragraph.
    private var currentParagraph = NSMutableAttributedString()

    public init(pageSize: CGSize = CGSize(width: 612, height: 792), margin: CGFloat = 72) {
        self.pageSize = pageSize
        self.margin = margin
        self.contentWidth = pageSize.width - (margin * 2)
        self.contentHeight = pageSize.height - (margin * 2)
    }

    // MARK: - Public API

    /// Render markdown content to PDF data.
    public func renderToPDF(
        markdown: String,
        metadata: DocumentMetadata?,
        formattingMetadata: FormattingMetadata?
    ) -> Data? {
        /// Apply custom formatting if provided.
        if let formatting = formattingMetadata {
            applyCustomFormatting(formatting)
        }

        /// Parse markdown to AST.
        // Sanitize common user input patterns where trailing spaces before
        // a closing emphasis/strong delimiter prevent rendering under
        // strict CommonMark rules (e.g. "**header: **"). We conservatively
        // remove a single run of whitespace immediately before a closing
        // `**` or `*` when the inner content ends with punctuation. This
        // makes the renderer more forgiving without changing valid markup.
        let sanitizedMarkdown = Self.sanitizeEmphasisTrailingSpaces(in: markdown)
        let document = Document(parsing: sanitizedMarkdown)

        /// Create PDF context.
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            logger.error("Failed to create PDF consumer")
            return nil
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            logger.error("Failed to create PDF context")
            return nil
        }

        self.pdfContext = context
        self.currentY = margin

        /// Begin first page.
        context.beginPage(mediaBox: &mediaBox)

        /// Initialize style stack with default body style.
        styleStack = [TextStyle.body]

        /// Render metadata if present.
        if let metadata = metadata {
            renderMetadata(metadata)
        }

        /// Walk AST and render content.
        walkDocument(document)

        /// Flush any remaining paragraph content.
        flushParagraph()

        /// End page and close PDF.
        context.endPage()
        context.closePDF()

        return pdfData as Data
    }

    // MARK: - Metadata Rendering

    private func renderMetadata(_ metadata: DocumentMetadata) {
        /// Title.
        let titleString = NSAttributedString(
            string: "\(metadata.title)\n\n",
            attributes: TextStyle.title.attributes
        )
        drawAttributedString(titleString)

        /// Author and date.
        var metadataText = ""
        if let author = metadata.author {
            metadataText += "Author: \(author)\n"
        }
        metadataText += "Created: \(metadata.createdDate.formatted(date: .long, time: .shortened))\n"
        if let description = metadata.description {
            metadataText += "\(description)\n"
        }
        metadataText += "\n"

        let metadataString = NSAttributedString(
            string: metadataText,
            attributes: TextStyle.metadata.attributes
        )
        drawAttributedString(metadataString)
    }

    // MARK: - AST Walking (like md2pdf's RenderNode)

    private func walkDocument(_ document: Document) {
        for child in document.children {
            walk(markup: child)
        }
    }

    /// Main AST walker - dispatches to specific processors This is equivalent to md2pdf's RenderNode() function.
    private func walk(markup: Markup) {
        /// Process "entering" event first.
        switch markup {
        case let paragraph as Paragraph:
            processParagraph(paragraph, entering: true)

        case let heading as Heading:
            processHeading(heading, entering: true)

        case let emphasis as Emphasis:
            processEmphasis(emphasis, entering: true)

        case let strong as Strong:
            processStrong(strong, entering: true)

        case let inlineCode as InlineCode:
            processInlineCode(inlineCode)

        case let text as Text:
            processText(text)

        case let softBreak as SoftBreak:
            processSoftBreak(softBreak)

        case let lineBreak as LineBreak:
            processLineBreak(lineBreak)

        case let list as UnorderedList:
            processList(list, entering: true)

        case let list as OrderedList:
            processList(list, entering: true)

        case let listItem as ListItem:
            processListItem(listItem, entering: true)

        case let codeBlock as CodeBlock:
            processCodeBlock(codeBlock)

        case let blockQuote as BlockQuote:
            processBlockQuote(blockQuote, entering: true)

        case let table as Table:
            processTable(table, entering: true)

        default:
            /// Unknown node type - log and continue.
            logger.debug("Unknown markup type: \(String(describing: type(of: markup)))")
        }

        /// Recursively walk children CRITICAL: Skip walking children for nodes that process their own children internally - Table: Extracts and renders its own rows/cells in processTable() - CodeBlock: Renders its own content in processCodeBlock().
        let shouldWalkChildren = !(markup is Table || markup is CodeBlock)

        if shouldWalkChildren {
            if let container = markup as? BlockMarkup {
                for child in container.children {
                    walk(markup: child)
                }
            } else if let container = markup as? InlineMarkup {
                for child in container.children {
                    walk(markup: child)
                }
            }
        }

        /// Process "leaving" event after children.
        switch markup {
        case let paragraph as Paragraph:
            processParagraph(paragraph, entering: false)

        case let heading as Heading:
            processHeading(heading, entering: false)

        case let emphasis as Emphasis:
            processEmphasis(emphasis, entering: false)

        case let strong as Strong:
            processStrong(strong, entering: false)

        case is UnorderedList, is OrderedList:
            processList(markup, entering: false)

        case let listItem as ListItem:
            processListItem(listItem, entering: false)

        case let blockQuote as BlockQuote:
            processBlockQuote(blockQuote, entering: false)

        case let table as Table:
            processTable(table, entering: false)

        default:
            break
        }
    }

    // MARK: - Node Processors (like md2pdf's process* functions)

    private func processParagraph(_ paragraph: Paragraph, entering: Bool) {
        if entering {
            /// Start new paragraph.
            currentParagraph = NSMutableAttributedString()
        } else {
            /// End paragraph - flush content and add spacing.
            currentParagraph.append(NSAttributedString(string: "\n", attributes: currentStyle.attributes))
            flushParagraph()
        }
    }

    private func processHeading(_ heading: Heading, entering: Bool) {
        if entering {
            /// Push heading style onto stack.
            let headingStyle: TextStyle
            switch heading.level {
            case 1: headingStyle = .heading1
            case 2: headingStyle = .heading2
            case 3: headingStyle = .heading3
            case 4: headingStyle = .heading4
            case 5: headingStyle = .heading5
            case 6: headingStyle = .heading6
            default: headingStyle = .heading1
            }
            styleStack.append(headingStyle)
        } else {
            /// Pop heading style and flush.
            styleStack.removeLast()
            currentParagraph.append(NSAttributedString(string: "\n\n", attributes: currentStyle.attributes))
            flushParagraph()
        }
    }

    /// Process emphasis (italic) - add/remove italic trait This is exactly how md2pdf does it: modify style on enter/leave.
    private func processEmphasis(_ emphasis: Emphasis, entering: Bool) {
        if entering {
            /// Add italic trait to current style.
            var newStyle = currentStyle
            newStyle.addItalic()
            styleStack.append(newStyle)
        } else {
            /// Remove italic trait.
            styleStack.removeLast()
        }
    }

    /// Process strong (bold) - add/remove bold trait This is exactly how md2pdf does it: modify style on enter/leave.
    private func processStrong(_ strong: Strong, entering: Bool) {
        if entering {
            /// Add bold trait to current style.
            var newStyle = currentStyle
            newStyle.addBold()
            styleStack.append(newStyle)
        } else {
            /// Remove bold trait.
            styleStack.removeLast()
        }
    }

    private func processInlineCode(_ code: InlineCode) {
        /// Apply code style and append text.
        let codeString = NSAttributedString(
            string: code.code,
            attributes: TextStyle.code.attributes
        )
        currentParagraph.append(codeString)
    }

    private func processText(_ text: Text) {
        /// Apply current style and append text.
        let textString = NSAttributedString(
            string: text.string,
            attributes: currentStyle.attributes
        )
        currentParagraph.append(textString)
    }

    private func processSoftBreak(_ softBreak: SoftBreak) {
        /// Soft break = space.
        currentParagraph.append(NSAttributedString(string: " ", attributes: currentStyle.attributes))
    }

    private func processLineBreak(_ lineBreak: LineBreak) {
        /// Hard break = newline.
        currentParagraph.append(NSAttributedString(string: "\n", attributes: currentStyle.attributes))
    }

    private func processList(_ list: Markup, entering: Bool) {
        if entering {
            /// Determine list type (ordered or unordered).
            let isOrdered = list is OrderedList
            let listContext = ListContext(
                isOrdered: isOrdered,
                currentItem: 0,
                indentLevel: listStack.count
            )
            listStack.append(listContext)
            logger.debug("Entering list: type=\(isOrdered ? "ordered" : "unordered"), level=\(listContext.indentLevel)")
        } else {
            /// Leaving list - pop context.
            if !listStack.isEmpty {
                listStack.removeLast()
            }
            /// Add spacing after list.
            currentParagraph.append(NSAttributedString(string: "\n", attributes: currentStyle.attributes))
            flushParagraph()
        }
    }

    private func processListItem(_ listItem: ListItem, entering: Bool) {
        if entering {
            guard !listStack.isEmpty else {
                logger.warning("List item encountered outside of list context")
                currentParagraph.append(NSAttributedString(string: "• ", attributes: currentStyle.attributes))
                return
            }

            var listContext = listStack[listStack.count - 1]
            listContext.currentItem += 1
            listStack[listStack.count - 1] = listContext

            /// Calculate indentation.
            let indentSpaces = String(repeating: "    ", count: listContext.indentLevel)

            /// Add list marker.
            let marker: String
            if listContext.isOrdered {
                marker = "\(listContext.currentItem). "
            } else {
                /// Use different bullet styles for nested lists.
                switch listContext.indentLevel {
                case 0: marker = "• "
                case 1: marker = "◦ "
                default: marker = "▪ "
                }
            }

            let markerString = NSAttributedString(
                string: indentSpaces + marker,
                attributes: currentStyle.attributes
            )
            currentParagraph.append(markerString)
        } else {
            /// End of list item - add newline.
            currentParagraph.append(NSAttributedString(string: "\n", attributes: currentStyle.attributes))
        }
    }

    private func processCodeBlock(_ codeBlock: CodeBlock) {
        /// Log that we're processing a code block.
        logger.critical("DEBUG_CODEBLOCK: Processing code block, code length: \(codeBlock.code.count)")
        logger.critical("DEBUG_CODEBLOCK: Code content: \(codeBlock.code.prefix(100))")

        /// Add background rectangle for code block.
        let codeStyle = TextStyle.codeBlock
        var codeString = codeBlock.code

        /// Render code block with gray background.
        let formattedCode = NSAttributedString(
            string: "\n\(codeString)\n\n",
            attributes: codeStyle.attributes
        )
        drawAttributedString(formattedCode)

        logger.critical("DEBUG_CODEBLOCK: Finished rendering code block")
    }

    private func processBlockQuote(_ blockQuote: BlockQuote, entering: Bool) {
        if entering {
            /// Add blockquote indicator and indentation.
            let quoteMarker = NSAttributedString(
                string: "│ ",
                attributes: [
                    .font: currentStyle.font,
                    .foregroundColor: NSColor.gray
                ]
            )
            currentParagraph.append(quoteMarker)

            /// Push modified style with indentation for nested content.
            var quoteStyle = currentStyle
            quoteStyle.textColor = NSColor.darkGray
            styleStack.append(quoteStyle)
        } else {
            /// Pop quote style.
            if styleStack.count > 1 {
                styleStack.removeLast()
            }
            currentParagraph.append(NSAttributedString(string: "\n", attributes: currentStyle.attributes))
        }
    }

    private func processTable(_ table: Table, entering: Bool) {
        if entering {
            /// Log that we're processing a table.
            logger.critical("DEBUG_TABLE: Processing table - START")

            /// Flush any pending paragraph before table.
            flushParagraph()

            /// Extract table data from AST (attributed text for rendering, plain text for width).
            var tableData: [[(attributed: NSAttributedString, plain: String)]] = []
            var rowCount = 0

            /// Base style for table cells (using body style).
            let cellBaseStyle = TextStyle.body

            /// Process table structure: Table -> TableHead/TableBody -> TableRow -> TableCell.
            for child in table.children {
                /// Check if child is TableHead or TableBody.
                if let tableHead = child as? Table.Head {
                    /// Process header rows.
                    for row in tableHead.children {
                        if let tableRow = row as? Table.Row {
                            var rowData: [(attributed: NSAttributedString, plain: String)] = []
                            for cell in tableRow.children {
                                if let tableCell = cell as? Table.Cell {
                                    let plainText = extractPlainText(from: tableCell)
                                    let attributedText = extractAttributedText(from: tableCell, baseStyle: cellBaseStyle)
                                    rowData.append((attributed: attributedText, plain: plainText))
                                }
                            }
                            tableData.append(rowData)
                            rowCount += 1
                        }
                    }
                } else if let tableBody = child as? Table.Body {
                    /// Process body rows.
                    for row in tableBody.children {
                        if let tableRow = row as? Table.Row {
                            var rowData: [(attributed: NSAttributedString, plain: String)] = []
                            for cell in tableRow.children {
                                if let tableCell = cell as? Table.Cell {
                                    let plainText = extractPlainText(from: tableCell)
                                    let attributedText = extractAttributedText(from: tableCell, baseStyle: cellBaseStyle)
                                    rowData.append((attributed: attributedText, plain: plainText))
                                }
                            }
                            tableData.append(rowData)
                            rowCount += 1
                        }
                    }
                }
            }

            logger.critical("DEBUG_TABLE: Extracted \(rowCount) rows, calling renderTableAsText")

            /// Render table as formatted text.
            renderTableAsText(tableData)

            logger.critical("DEBUG_TABLE: Finished rendering table")

            /// Add spacing after table.
            currentParagraph.append(NSAttributedString(string: "\n\n", attributes: currentStyle.attributes))
        }
    }

    /// Extract plain text from markup node (for column width calculation).
    private func extractPlainText(from markup: Markup) -> String {
        var text = ""
        if let textNode = markup as? Text {
            text = textNode.string
        } else {
            for child in markup.children {
                text += extractPlainText(from: child)
            }
        }
        return text
    }

    /// Extract attributed text from markup node (for table cells with formatting).
    /// Supports bold, italic, inline code, and nested formatting.
    private func extractAttributedText(from markup: Markup, baseStyle: TextStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()

        func walk(_ node: Markup, style: TextStyle) {
            switch node {
            case let text as Text:
                result.append(NSAttributedString(string: text.string, attributes: style.attributes))

            case let strong as Strong:
                var boldStyle = style
                boldStyle.addBold()
                for child in strong.children {
                    walk(child, style: boldStyle)
                }

            case let emphasis as Emphasis:
                var italicStyle = style
                italicStyle.addItalic()
                for child in emphasis.children {
                    walk(child, style: italicStyle)
                }

            case let inlineCode as InlineCode:
                result.append(NSAttributedString(string: inlineCode.code, attributes: TextStyle.code.attributes))

            case let softBreak as SoftBreak:
                result.append(NSAttributedString(string: " ", attributes: style.attributes))

            case let lineBreak as LineBreak:
                result.append(NSAttributedString(string: "\n", attributes: style.attributes))

            default:
                /// For other inline markup, walk children.
                for child in node.children {
                    walk(child, style: style)
                }
            }
        }

        walk(markup, style: baseStyle)
        return result
    }

    /// Render table as formatted text with inline formatting support.
    private func renderTableAsText(_ tableData: [[(attributed: NSAttributedString, plain: String)]]) {
        guard !tableData.isEmpty else { return }

        /// Calculate column widths using plain text.
        var columnWidths: [Int] = []
        for row in tableData {
            for (index, cell) in row.enumerated() {
                if columnWidths.count <= index {
                    columnWidths.append(cell.plain.count)
                } else {
                    columnWidths[index] = max(columnWidths[index], cell.plain.count)
                }
            }
        }

        /// Add padding.
        columnWidths = columnWidths.map { $0 + 2 }

        /// Helper to create padded attributed string.
        func paddedCellString(_ cell: NSAttributedString, plainText: String, width: Int, isBold: Bool) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let paddingNeeded = width - plainText.count
            let leftPad = " "
            let rightPad = String(repeating: " ", count: max(0, paddingNeeded + 1))

            /// Add left padding.
            let padStyle: [NSAttributedString.Key: Any] = isBold
                ? [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.black]
                : currentStyle.attributes
            result.append(NSAttributedString(string: leftPad, attributes: padStyle))

            /// Add cell content (with its formatting).
            if isBold {
                /// For header cells, apply bold to the entire content.
                let boldCell = NSMutableAttributedString(attributedString: cell)
                boldCell.enumerateAttribute(.font, in: NSRange(location: 0, length: boldCell.length)) { value, range, _ in
                    if let font = value as? NSFont {
                        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                        boldCell.addAttribute(.font, value: boldFont, range: range)
                    }
                }
                result.append(boldCell)
            } else {
                result.append(cell)
            }

            /// Add right padding.
            result.append(NSAttributedString(string: rightPad, attributes: padStyle))
            return result
        }

        /// Render header (first row).
        if let header = tableData.first {
            let headerLine = NSMutableAttributedString()
            let headerStyle: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.black]
            headerLine.append(NSAttributedString(string: "|", attributes: headerStyle))

            for (index, cell) in header.enumerated() {
                let width = columnWidths[safe: index] ?? (cell.plain.count + 2)
                let paddedCell = paddedCellString(cell.attributed, plainText: cell.plain, width: width, isBold: true)
                headerLine.append(paddedCell)
                headerLine.append(NSAttributedString(string: "|", attributes: headerStyle))
            }

            headerLine.append(NSAttributedString(string: "\n", attributes: headerStyle))
            drawAttributedString(headerLine)

            /// Render separator.
            var separator = "|"
            for width in columnWidths {
                separator += String(repeating: "-", count: width + 2) + "|"
            }
            let separatorString = NSAttributedString(
                string: separator + "\n",
                attributes: currentStyle.attributes
            )
            drawAttributedString(separatorString)
        }

        /// Render body rows.
        for row in tableData.dropFirst() {
            let rowLine = NSMutableAttributedString()
            rowLine.append(NSAttributedString(string: "|", attributes: currentStyle.attributes))

            for (index, cell) in row.enumerated() {
                let width = columnWidths[safe: index] ?? (cell.plain.count + 2)
                let paddedCell = paddedCellString(cell.attributed, plainText: cell.plain, width: width, isBold: false)
                rowLine.append(paddedCell)
                rowLine.append(NSAttributedString(string: "|", attributes: currentStyle.attributes))
            }

            rowLine.append(NSAttributedString(string: "\n", attributes: currentStyle.attributes))
            drawAttributedString(rowLine)
        }
    }

    // MARK: - Helper Methods

    private func flushParagraph() {
        guard currentParagraph.length > 0 else { return }

        drawAttributedString(currentParagraph)
        currentParagraph = NSMutableAttributedString()
    }

    private func drawAttributedString(_ attributedString: NSAttributedString) {
        /// Create NSGraphicsContext from CGContext.
        let nsContext = NSGraphicsContext(cgContext: pdfContext, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        /// Calculate text height.
        let textContainer = NSTextContainer(containerSize: CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let layoutManager = NSLayoutManager()
        let textStorage = NSTextStorage(attributedString: attributedString)

        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.glyphRange(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height

        /// Check if we need a new page.
        if currentY + textHeight > pageSize.height - margin {
            /// End current page and start new one.
            NSGraphicsContext.restoreGraphicsState()
            pdfContext.endPage()

            var mediaBox = CGRect(origin: .zero, size: pageSize)
            pdfContext.beginPage(mediaBox: &mediaBox)

            /// Reset y position.
            currentY = margin

            /// Re-establish graphics context.
            let newNSContext = NSGraphicsContext(cgContext: pdfContext, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = newNSContext
        }

        /// Draw text at current position NOTE: PDF coordinates are bottom-left origin, so we need to flip Y.
        let drawY = pageSize.height - currentY - textHeight
        let drawRect = CGRect(x: margin, y: drawY, width: contentWidth, height: textHeight)

        attributedString.draw(in: drawRect)

        /// Update Y position.
        currentY += textHeight

        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Style Management

    private var currentStyle: TextStyle {
        return styleStack.last ?? .body
    }
}

// MARK: - Text Style (like md2pdf's Styler)

struct TextStyle: @unchecked Sendable {
    var font: NSFont
    var size: CGFloat
    var textColor: NSColor
    var backgroundColor: NSColor?
    var traits: NSFontTraitMask

    var attributes: [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        if let bgColor = backgroundColor {
            attrs[.backgroundColor] = bgColor
        }
        return attrs
    }

    mutating func addBold() {
        traits.insert(.boldFontMask)
        updateFont()
    }

    mutating func addItalic() {
        traits.insert(.italicFontMask)
        updateFont()
    }

    private mutating func updateFont() {
        /// Start with Helvetica which has proper bold/italic variants.
        var newFont = NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)

        /// Apply bold and/or italic traits.
        if traits.contains(.boldFontMask) && traits.contains(.italicFontMask) {
            /// Both bold and italic - apply both traits.
            newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .boldFontMask)
            newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .italicFontMask)
        } else if traits.contains(.boldFontMask) {
            /// Just bold.
            newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .boldFontMask)
        } else if traits.contains(.italicFontMask) {
            /// Just italic.
            newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .italicFontMask)
        }

        self.font = newFont
    }

    /// Predefined styles.
    nonisolated(unsafe) static let body = TextStyle(
        font: NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12),
        size: 12,
        textColor: .black,
        backgroundColor: nil,
        traits: []
    )

    nonisolated(unsafe) static let title = TextStyle(
        font: NSFont(name: "Helvetica-Bold", size: 24) ?? .boldSystemFont(ofSize: 24),
        size: 24,
        textColor: .black,
        backgroundColor: nil,
        traits: [.boldFontMask]
    )

    nonisolated(unsafe) static let metadata = TextStyle(
        font: NSFont(name: "Helvetica", size: 11) ?? .systemFont(ofSize: 11),
        size: 11,
        textColor: .darkGray,
        backgroundColor: nil,
        traits: []
    )

    nonisolated(unsafe) static let heading1 = TextStyle(
        font: NSFont(name: "Helvetica-Bold", size: 24) ?? .boldSystemFont(ofSize: 24),
        size: 24,
        textColor: .black,
        backgroundColor: nil,
        traits: [.boldFontMask]
    )

    nonisolated(unsafe) static let heading2 = TextStyle(
        font: NSFont(name: "Helvetica-Bold", size: 18) ?? .boldSystemFont(ofSize: 18),
        size: 18,
        textColor: .black,
        backgroundColor: nil,
        traits: [.boldFontMask]
    )

    nonisolated(unsafe) static let heading3 = TextStyle(
        font: .boldSystemFont(ofSize: 14),
        size: 14,
        textColor: .black,
        backgroundColor: nil,
        traits: [.boldFontMask]
    )

    nonisolated(unsafe) static let heading4 = TextStyle(
        font: .boldSystemFont(ofSize: 12),
        size: 12,
        textColor: .black,
        backgroundColor: nil,
        traits: [.boldFontMask]
    )

    nonisolated(unsafe) static let heading5 = TextStyle(
        font: .boldSystemFont(ofSize: 11),
        size: 11,
        textColor: .black,
        backgroundColor: nil,
        traits: [.boldFontMask]
    )

    nonisolated(unsafe) static let heading6 = TextStyle(
        font: .boldSystemFont(ofSize: 10),
        size: 10,
        textColor: .black,
        backgroundColor: nil,
        traits: [.boldFontMask]
    )

    nonisolated(unsafe) static let code = TextStyle(
        font: .monospacedSystemFont(ofSize: 11, weight: .regular),
        size: 11,
        textColor: .darkGray,
        backgroundColor: NSColor.lightGray.withAlphaComponent(0.2),
        traits: []
    )

    nonisolated(unsafe) static let codeBlock = TextStyle(
        font: .monospacedSystemFont(ofSize: 10, weight: .regular),
        size: 10,
        textColor: .black,
        backgroundColor: NSColor.lightGray.withAlphaComponent(0.1),
        traits: []
    )
}

// MARK: - Custom Formatting

extension MarkdownASTRenderer {
    /// Apply custom formatting from FormattingMetadata.
    private func applyCustomFormatting(_ formatting: FormattingMetadata) {
        /// Note: The current MarkdownASTRenderer uses immutable properties (let constants) and static TextStyle definitions, which makes dynamic formatting difficult. A future refactoring could: 1. Make pageSize and margin mutable (var instead of let) 2. Pass FormattingMetadata through the rendering pipeline 3. Create dynamic TextStyle instances instead of using static constants For now, documents will use the default PDF styling. The FormattingMetadata parameters are still valuable for future enhancements.
    }

    /// Make markdown parsing slightly more forgiving for common human-entered
    /// cases where a user leaves a space before a closing emphasis/strong
    /// delimiter (for example: "**header: **"). Strict CommonMark treats
    /// a space immediately before a closing delimiter as breaking the
    /// emphasis; this helper removes that single run of whitespace when the
    /// inner content ends with punctuation so the intent (bolding the
    /// punctuation-inclusive text) is preserved.
    static func sanitizeEmphasisTrailingSpaces(in markdown: String) -> String {
        var result = markdown

        // Patterns: strong (**text: **) and emphasis (*text: *)
        let patterns = [
            "(\\*\\*)([^*]+?\\p{Punct})(\\s+)\\*\\*",
            "(\\*)([^*]+?\\p{Punct})(\\s+)\\*"
        ]

        for pattern in patterns {
            do {
                let re = try NSRegularExpression(pattern: pattern, options: [.useUnicodeWordBoundaries])
                let range = NSRange(result.startIndex..., in: result)
                // Replace matches by removing whitespace group and leaving delimiters intact
                result = re.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1$2$1")
            } catch {
                // If regex compilation fails, log and continue with original markdown
                // Logging unavailable in static helper; caller's logger may capture issues.
                break
            }
        }

        return result
    }
}

// MARK: - Helper Methods

extension Array {
    /// Safe array access - returns nil if index out of bounds.
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
