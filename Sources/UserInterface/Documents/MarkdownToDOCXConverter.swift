// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Markdown
import Logging
import AppKit

/// Image data for embedding in DOCX
public struct DOCXImageData {
    let imageData: Data
    let filename: String
    let width: CGFloat
    let height: CGFloat
    let relationshipId: String
    let contentType: String  // "image/png" or "image/jpeg"
}

/// Result of DOCX conversion with paragraphs and embedded images
public struct DOCXConversionResult {
    let paragraphsXML: String
    let images: [DOCXImageData]
}

/// Converts Markdown AST to Microsoft Word Open XML format
/// Properly translates markdown formatting to Word XML styles
/// Supports:
/// - Headings (H1-H6) with proper Word styles
/// - Bold, italic, strikethrough, code inline formatting
/// - Ordered and unordered lists with proper numbering/nesting
/// - Code blocks with monospace formatting
/// - Blockquotes with indentation
/// - Tables with proper XML structure
/// - Links and emphasis
/// - Mermaid diagrams (embedded as PNG images)
/// - Markdown images from URLs (embedded in document)
public class MarkdownToDOCXConverter {
    private let logger = Logging.Logger(label: "com.sam.documents.MarkdownToDOCXConverter")

    private var paragraphs: [String] = []
    private var currentRuns: [String] = []
    private var listStack: [ListContext] = []

    /// Mermaid diagram exporter for converting diagrams to images
    private let mermaidExporter = MermaidDiagramExporter()

    /// Track images to embed in DOCX
    private var embeddedImages: [DOCXImageData] = []
    private var imageCounter: Int = 0

    public init() {}

    // MARK: - Public API

    /// Convert markdown text to DOCX XML paragraphs (legacy method for compatibility)
    /// - Parameter markdown: Markdown-formatted text
    /// - Returns: Word XML paragraphs ready for document.xml
    public func convert(markdown: String) -> String {
        let result = convertWithImages(markdown: markdown)
        return result.paragraphsXML
    }

    /// Convert markdown text to DOCX XML with embedded images
    /// - Parameter markdown: Markdown-formatted text
    /// - Returns: DOCXConversionResult containing XML paragraphs and image data for embedding
    public func convertWithImages(markdown: String) -> DOCXConversionResult {
        logger.info("MARKDOWN_CONVERT: Input length=\(markdown.count)")
        logger.info("MARKDOWN_CONVERT: First 200 chars=\(String(markdown.prefix(200)))")

        paragraphs = []
        currentRuns = []
        listStack = []
        embeddedImages = []
        imageCounter = 0

        /// Parse markdown to AST.
        let document = Document(parsing: markdown)

        logger.info("MARKDOWN_CONVERT: Parsed document successfully")

        /// Walk AST and generate XML.
        walkDocument(document)

        /// Flush any remaining runs.
        flushParagraph()

        /// Join all paragraphs.
        let xml = paragraphs.joined(separator: "\n")

        logger.info("MARKDOWN_CONVERT: Generated \(paragraphs.count) paragraphs, \(embeddedImages.count) images")

        return DOCXConversionResult(paragraphsXML: xml, images: embeddedImages)
    }

    // MARK: - AST Walking

    private func walkDocument(_ document: Document) {
        for child in document.children {
            walk(markup: child)
        }
    }

    private func walk(markup: Markup) {
        /// Process entering event.
        switch markup {
        case let paragraph as Paragraph:
            processParagraph(paragraph, entering: true)

        case let heading as Heading:
            processHeading(heading, entering: true)

        case let text as Text:
            processText(text)

        case let emphasis as Emphasis:
            processEmphasis(emphasis, entering: true)

        case let strong as Strong:
            processStrong(strong, entering: true)

        case let inlineCode as InlineCode:
            processInlineCode(inlineCode)

        case let codeBlock as Markdown.CodeBlock:
            processCodeBlock(codeBlock)

        case let list as UnorderedList:
            processList(list, entering: true, isOrdered: false)

        case let list as OrderedList:
            processList(list, entering: true, isOrdered: true)

        case let listItem as ListItem:
            processListItem(listItem, entering: true)

        case let blockQuote as BlockQuote:
            processBlockQuote(blockQuote, entering: true)

        case let table as Table:
            processTable(table)

        case let softBreak as SoftBreak:
            currentRuns.append(" ")

        case let lineBreak as LineBreak:
            flushParagraph()

        case let image as Markdown.Image:
            processImage(image)

        default:
            logger.debug("Unknown markup type: \(String(describing: type(of: markup)))")
        }

        /// Recursively walk children
        /// CRITICAL: Skip walking children for nodes that process their own children internally
        /// - Table: Extracts and renders its own rows/cells in processTable()
        /// - CodeBlock: Renders its own content in processCodeBlock()
        /// - Image: Self-contained inline element
        let shouldWalkChildren = !(markup is Table || markup is Markdown.CodeBlock || markup is Markdown.Image)

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

        /// Process leaving event.
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
            processList(markup, entering: false, isOrdered: markup is OrderedList)

        case let listItem as ListItem:
            processListItem(listItem, entering: false)

        case let blockQuote as BlockQuote:
            processBlockQuote(blockQuote, entering: false)

        default:
            break
        }
    }

    // MARK: - Node Processors

    private func processParagraph(_ paragraph: Paragraph, entering: Bool) {
        if !entering {
            flushParagraph()
        }
    }

    private func processHeading(_ heading: Heading, entering: Bool) {
        if entering {
            logger.info("MARKDOWN_HEADING: level=\(heading.level), entering=\(entering)")
            /// Add heading style based on level.
            let styleName = "Heading\(heading.level)"
            currentRuns.insert("<w:pPr><w:pStyle w:val=\"\(styleName)\"/></w:pPr>", at: 0)
            logger.info("MARKDOWN_HEADING: Inserted style=\(styleName), currentRuns count=\(currentRuns.count)")
        } else {
            logger.info("MARKDOWN_HEADING: Flushing paragraph for heading level=\(heading.level)")
            flushParagraph()
        }
    }

    private func processText(_ text: Text) {
        let escaped = xmlEscape(text.string)
        currentRuns.append("<w:r><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r>")
    }

    private func processEmphasis(_ emphasis: Emphasis, entering: Bool) {
        if entering {
            currentRuns.append("<w:r><w:rPr><w:i/></w:rPr><w:t xml:space=\"preserve\">")
        } else {
            currentRuns.append("</w:t></w:r>")
        }
    }

    private func processStrong(_ strong: Strong, entering: Bool) {
        if entering {
            currentRuns.append("<w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">")
        } else {
            currentRuns.append("</w:t></w:r>")
        }
    }

    private func processInlineCode(_ code: InlineCode) {
        let escaped = xmlEscape(code.code)
        let codeRun = """
        <w:r>
            <w:rPr>
                <w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/>
                <w:shd w:val="clear" w:color="auto" w:fill="F0F0F0"/>
            </w:rPr>
            <w:t xml:space="preserve">\(escaped)</w:t>
        </w:r>
        """
        currentRuns.append(codeRun)
    }

    private func processCodeBlock(_ codeBlock: Markdown.CodeBlock) {
        flushParagraph()

        // Check if this is a Mermaid diagram
        if let language = codeBlock.language, language.lowercased() == "mermaid" {
            processMermaidDiagram(code: codeBlock.code)
            return
        }

        let escaped = xmlEscape(codeBlock.code)
        let lines = escaped.components(separatedBy: .newlines)

        for line in lines {
            let codeParagraph = """
            <w:p>
                <w:pPr>
                    <w:spacing w:before="60" w:after="60"/>
                    <w:ind w:left="720"/>
                </w:pPr>
                <w:r>
                    <w:rPr>
                        <w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/>
                        <w:sz w:val="20"/>
                        <w:shd w:val="clear" w:color="auto" w:fill="F0F0F0"/>
                    </w:rPr>
                    <w:t xml:space="preserve">\(line)</w:t>
                </w:r>
            </w:p>
            """
            paragraphs.append(codeParagraph)
        }
    }

    /// Process Mermaid diagram code block by embedding as image
    private func processMermaidDiagram(code: String) {
        logger.debug("Processing Mermaid diagram in DOCX conversion")

        do {
            // Export Mermaid diagram to PNG
            let imageURL = try mermaidExporter.exportDiagramToTemp(
                code,
                format: .png,
                size: CGSize(width: 800, height: 600)
            )

            // Load image data
            guard let imageData = try? Data(contentsOf: imageURL),
                  let nsImage = NSImage(data: imageData) else {
                throw NSError(domain: "MarkdownToDOCXConverter", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: "Failed to load mermaid image"])
            }

            // Clean up temp file
            try? FileManager.default.removeItem(at: imageURL)

            // Embed the image
            embedImage(imageData: imageData, image: nsImage, altText: "Mermaid Diagram")

            logger.info("Mermaid diagram embedded in DOCX")

        } catch {
            logger.error("Failed to export Mermaid diagram: \(error.localizedDescription)")

            // Fallback: show as code block
            let escaped = xmlEscape(code)
            let fallbackParagraph = """
            <w:p>
                <w:pPr>
                    <w:spacing w:before="60" w:after="60"/>
                </w:pPr>
                <w:r>
                    <w:rPr>
                        <w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/>
                    </w:rPr>
                    <w:t xml:space="preserve">[Mermaid diagram - export failed]\n\(escaped)</w:t>
                </w:r>
            </w:p>
            """
            paragraphs.append(fallbackParagraph)
        }
    }

    /// Process markdown image by embedding in document
    private func processImage(_ image: Markdown.Image) {
        guard let urlString = image.source,
              let url = URL(string: urlString) else {
            // No source URL, show placeholder
            let altText = image.plainText.isEmpty ? "Image" : image.plainText
            currentRuns.append("<w:r><w:t>[\(xmlEscape(altText))]</w:t></w:r>")
            return
        }

        logger.debug("Processing markdown image: \(urlString)")

        // Load image from URL
        do {
            let imageData = try Data(contentsOf: url)
            guard let nsImage = NSImage(data: imageData) else {
                throw NSError(domain: "MarkdownToDOCXConverter", code: 2,
                             userInfo: [NSLocalizedDescriptionKey: "Invalid image data"])
            }

            // Flush any current runs before the image
            flushParagraph()

            // Embed the image
            let altText = image.plainText.isEmpty ? "Image" : image.plainText
            embedImage(imageData: imageData, image: nsImage, altText: altText)

        } catch {
            logger.warning("Failed to load image from \(urlString): \(error.localizedDescription)")
            // Fallback: show link
            let altText = image.plainText.isEmpty ? "Image" : image.plainText
            currentRuns.append("<w:r><w:t>[\(xmlEscape(altText)): \(xmlEscape(urlString))]</w:t></w:r>")
        }
    }

    /// Embed an image in the document
    private func embedImage(imageData: Data, image: NSImage, altText: String) {
        imageCounter += 1
        let relationshipId = "rIdImage\(imageCounter)"
        let filename = "image\(imageCounter).png"

        // Get image dimensions (in EMUs - English Metric Units, 914400 EMUs = 1 inch)
        let size = image.size
        let maxWidthInches: CGFloat = 6.0  // Max 6 inches wide
        let pixelsPerInch: CGFloat = 96.0

        var widthInches = size.width / pixelsPerInch
        var heightInches = size.height / pixelsPerInch

        // Scale down if too wide
        if widthInches > maxWidthInches {
            let scale = maxWidthInches / widthInches
            widthInches = maxWidthInches
            heightInches *= scale
        }

        let widthEMU = Int(widthInches * 914400)
        let heightEMU = Int(heightInches * 914400)

        // Determine content type based on data
        let contentType: String
        if let firstByte = imageData.first {
            if firstByte == 0x89 {  // PNG
                contentType = "image/png"
            } else if firstByte == 0xFF {  // JPEG
                contentType = "image/jpeg"
            } else {
                contentType = "image/png"  // Default to PNG
            }
        } else {
            contentType = "image/png"
        }

        // Store image data for embedding
        embeddedImages.append(DOCXImageData(
            imageData: imageData,
            filename: filename,
            width: CGFloat(widthEMU),
            height: CGFloat(heightEMU),
            relationshipId: relationshipId,
            contentType: contentType
        ))

        // Generate Word drawing XML
        // Note: This uses DrawingML which is the standard way to embed images in DOCX
        let imageXML = """
        <w:p>
            <w:pPr>
                <w:jc w:val="center"/>
                <w:spacing w:before="120" w:after="120"/>
            </w:pPr>
            <w:r>
                <w:drawing>
                    <wp:inline distT="0" distB="0" distL="0" distR="0"
                        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
                        <wp:extent cx="\(widthEMU)" cy="\(heightEMU)"/>
                        <wp:docPr id="\(imageCounter)" name="\(xmlEscape(altText))" descr="\(xmlEscape(altText))"/>
                        <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
                            <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                                <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
                                    <pic:nvPicPr>
                                        <pic:cNvPr id="\(imageCounter)" name="\(xmlEscape(filename))"/>
                                        <pic:cNvPicPr/>
                                    </pic:nvPicPr>
                                    <pic:blipFill>
                                        <a:blip r:embed="\(relationshipId)"
                                            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>
                                        <a:stretch>
                                            <a:fillRect/>
                                        </a:stretch>
                                    </pic:blipFill>
                                    <pic:spPr>
                                        <a:xfrm>
                                            <a:off x="0" y="0"/>
                                            <a:ext cx="\(widthEMU)" cy="\(heightEMU)"/>
                                        </a:xfrm>
                                        <a:prstGeom prst="rect">
                                            <a:avLst/>
                                        </a:prstGeom>
                                    </pic:spPr>
                                </pic:pic>
                            </a:graphicData>
                        </a:graphic>
                    </wp:inline>
                </w:drawing>
            </w:r>
        </w:p>
        """

        paragraphs.append(imageXML)
        logger.debug("Embedded image \(filename) with relationship \(relationshipId)")
    }

    private func processList(_ list: Markup, entering: Bool, isOrdered: Bool) {
        if entering {
            let context = ListContext(isOrdered: isOrdered, currentItem: 0, indentLevel: listStack.count)
            listStack.append(context)
        } else {
            if !listStack.isEmpty {
                listStack.removeLast()
            }
        }
    }

    private func processListItem(_ listItem: ListItem, entering: Bool) {
        if entering {
            guard !listStack.isEmpty else { return }

            var context = listStack[listStack.count - 1]
            context.currentItem += 1
            listStack[listStack.count - 1] = context

            /// Add list item marker.
            let marker: String
            if context.isOrdered {
                marker = "\(context.currentItem). "
            } else {
                /// Use bullet symbol.
                marker = "• "
            }

            /// Add list formatting to current runs.
            let indentPoints = 720 * (context.indentLevel + 1)
            let hangingIndent = 360

            currentRuns.insert("""
            <w:pPr>
                <w:pStyle w:val="ListParagraph"/>
                <w:ind w:left="\(indentPoints)" w:hanging="\(hangingIndent)"/>
            </w:pPr>
            """, at: 0)

            /// Add marker as first run.
            currentRuns.append("<w:r><w:t xml:space=\"preserve\">\(marker)</w:t></w:r>")
        } else {
            flushParagraph()
        }
    }

    private func processBlockQuote(_ blockQuote: BlockQuote, entering: Bool) {
        if entering {
            /// Add blockquote styling.
            currentRuns.insert("""
            <w:pPr>
                <w:pStyle w:val="Quote"/>
                <w:ind w:left="720"/>
            </w:pPr>
            """, at: 0)
        } else {
            flushParagraph()
        }
    }

    private func processTable(_ table: Table) {
        flushParagraph()

        /// Extract table cells from Table.Head and Table.Body elements.
        /// Store Table.Cell objects to preserve formatting information.
        var tableRows: [[Table.Cell]] = []
        var isHeaderRow: [Bool] = []

        for child in table.children {
            if let tableHead = child as? Table.Head {
                /// Process header rows.
                for row in tableHead.children {
                    if let tableRow = row as? Table.Row {
                        var rowCells: [Table.Cell] = []
                        for cell in tableRow.children {
                            if let tableCell = cell as? Table.Cell {
                                rowCells.append(tableCell)
                            }
                        }
                        tableRows.append(rowCells)
                        isHeaderRow.append(true)
                    }
                }
            } else if let tableBody = child as? Table.Body {
                /// Process body rows.
                for row in tableBody.children {
                    if let tableRow = row as? Table.Row {
                        var rowCells: [Table.Cell] = []
                        for cell in tableRow.children {
                            if let tableCell = cell as? Table.Cell {
                                rowCells.append(tableCell)
                            }
                        }
                        tableRows.append(rowCells)
                        isHeaderRow.append(false)
                    }
                }
            }
        }

        /// Generate Word table XML.
        var tableXML = """
        <w:tbl>
            <w:tblPr>
                <w:tblStyle w:val="TableGrid"/>
                <w:tblW w:w="5000" w:type="pct"/>
                <w:tblBorders>
                    <w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>
                    <w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>
                    <w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>
                    <w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>
                    <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>
                    <w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>
                </w:tblBorders>
            </w:tblPr>
        """

        /// Add table rows.
        for (rowIndex, row) in tableRows.enumerated() {
            tableXML += "<w:tr>"
            let isHeader = isHeaderRow[safe: rowIndex] ?? false

            for cell in row {
                /// Extract formatted runs from cell content (supports bold, italic, etc.).
                let cellRuns = extractFormattedRuns(from: cell, isBold: isHeader, isItalic: false)

                tableXML += """
                <w:tc>
                    <w:tcPr>
                        <w:shd w:val="clear" w:color="auto" w:fill="\(isHeader ? "DDDDDD" : "FFFFFF")"/>
                    </w:tcPr>
                    <w:p>
                        \(cellRuns)
                    </w:p>
                </w:tc>
                """
            }

            tableXML += "</w:tr>"
        }

        tableXML += "</w:tbl>"
        paragraphs.append(tableXML)
    }

    // MARK: - Helper Methods

    private func flushParagraph() {
        guard !currentRuns.isEmpty else { return }

        let paragraph = "<w:p>\(currentRuns.joined())</w:p>"
        paragraphs.append(paragraph)
        currentRuns = []
    }

    /// Extract plain text from markup (for tables - used for debugging/logging).
    private func extractPlainText(from markup: Markup) -> String {
        if let text = markup as? Text {
            return text.string
        }

        var result = ""
        for child in markup.children {
            result += extractPlainText(from: child)
        }
        return result
    }

    /// Extract formatted Word XML runs from markup (for table cells with formatting).
    /// Supports bold, italic, inline code, and nested formatting.
    private func extractFormattedRuns(from markup: Markup, isBold: Bool = false, isItalic: Bool = false) -> String {
        var runs = ""

        func walk(_ node: Markup, bold: Bool, italic: Bool) {
            switch node {
            case let text as Text:
                let escaped = xmlEscape(text.string)
                var rPr = ""
                if bold { rPr += "<w:b/>" }
                if italic { rPr += "<w:i/>" }
                if !rPr.isEmpty {
                    runs += "<w:r><w:rPr>\(rPr)</w:rPr><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r>"
                } else {
                    runs += "<w:r><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r>"
                }

            case _ as Strong:
                for child in node.children {
                    walk(child, bold: true, italic: italic)
                }

            case _ as Emphasis:
                for child in node.children {
                    walk(child, bold: bold, italic: true)
                }

            case let inlineCode as InlineCode:
                let escaped = xmlEscape(inlineCode.code)
                var rPr = "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F0F0F0\"/>"
                if bold { rPr += "<w:b/>" }
                if italic { rPr += "<w:i/>" }
                runs += "<w:r><w:rPr>\(rPr)</w:rPr><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r>"

            case _ as SoftBreak:
                runs += "<w:r><w:t xml:space=\"preserve\"> </w:t></w:r>"

            case _ as LineBreak:
                runs += "<w:r><w:br/></w:r>"

            default:
                /// For other inline markup, walk children.
                for child in node.children {
                    walk(child, bold: bold, italic: italic)
                }
            }
        }

        walk(markup, bold: isBold, italic: isItalic)
        return runs
    }

    /// Escape special XML characters.
    private func xmlEscape(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - List Context

struct ListContext {
    var isOrdered: Bool
    var currentItem: Int
    var indentLevel: Int
}
