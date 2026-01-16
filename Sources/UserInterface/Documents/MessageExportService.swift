// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import PDFKit
import AppKit
import ConfigurationSystem
import Logging

/// Service for exporting and printing individual messages Provides PDF generation and print functionality for single chat messages.
public class MessageExportService {
    private let logger = Logger(label: "com.sam.documents.MessageExportService")

    /// Export a single message to PDF - Parameters: - message: The message to export - conversationTitle: Title of the conversation (for metadata) - modelName: Model that generated the message (optional) - Returns: URL to the generated PDF file.
    @MainActor
    public static func exportMessageToPDF(
        message: EnhancedMessage,
        conversationTitle: String,
        modelName: String? = nil
    ) async throws -> URL {
        let logger = Logger(label: "com.sam.documents.MessageExportService")
        logger.debug("Exporting message to PDF: \(message.id)")
        
        // Use UnifiedPDFGenerator for reliable PDF generation
        return try await UnifiedPDFGenerator.generatePDF(
            messages: [message],
            conversationTitle: conversationTitle,
            modelName: modelName,
            includeHeaders: false  // No headers for single message export
        )
    }

    /// Async variant of export that offloads heavy markdown parsing off the main thread.
    public static func exportMessageToPDFAsync(
        message: EnhancedMessage,
        conversationTitle: String,
        modelName: String? = nil
    ) async throws -> URL {
        // Just call the main export which is already async
        return try await exportMessageToPDF(
            message: message,
            conversationTitle: conversationTitle,
            modelName: modelName
        )
    }

    /// Print a single message by generating PDF and printing it
    public static func printMessage(
        message: EnhancedMessage,
        conversationTitle: String,
        modelName: String? = nil
    ) {
        let logger = Logger(label: "com.sam.documents.MessageExportService")
        logger.info("Printing message: \(message.id)")

        Task {
            await UnifiedPDFGenerator.printMessages(
                messages: [message],
                conversationTitle: conversationTitle,
                modelName: modelName
            )
        }
    }

    /// Show print error alert
    private static func showPrintError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Print Failed"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    // MARK: - Helper Methods

    /// Strip user context tags (mini-prompts, location, file attachments) from message content
    /// These are injected at send time wrapped in <userContext>...</userContext> XML tags
    /// and should be removed for cleaner PDF/print output.
    /// - Parameter content: Raw message content possibly containing <userContext> tags
    /// - Returns: Clean content with all <userContext> blocks removed
    public static func stripUserContext(_ content: String) -> String {
        var cleaned = content
        
        // Remove all <userContext>...</userContext> blocks
        // Use regex to handle multiline content
        let pattern = "<userContext>.*?</userContext>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        // Clean up excessive whitespace left after removal
        // Replace multiple newlines with maximum of 2 newlines
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        
        // Trim leading/trailing whitespace
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse markdown content into attributed string for PDF Manual parser handles headers, bold, italic, code blocks, inline code.
    @MainActor
    public static func parseMarkdownForPDF(_ markdown: String) -> NSAttributedString {
        /// Strip user context tags before parsing
        let cleanedMarkdown = stripUserContext(markdown)
        
        /// Use new AST-based parser for accurate rendering with all latest fixes.
        let astParser = MarkdownASTParser()
        let astNodes = astParser.parse(cleanedMarkdown)

        let converter = MarkdownASTToNSAttributedString()
        return converter.convert(astNodes)
    }

    /// Parse markdown and extract images separately (for continuous PDF rendering)
    /// This is needed because NSTextAttachment images don't render correctly in some PDF contexts
    /// - Returns: Tuple of (text content as attributed string, array of extracted images)
    @MainActor
    public static func parseMarkdownForPDFWithImages(_ markdown: String) -> (NSAttributedString, [NSImage]) {
        /// Strip user context tags before parsing
        let cleanedMarkdown = stripUserContext(markdown)
        
        let astParser = MarkdownASTParser()
        let astNodes = astParser.parse(cleanedMarkdown)

        var extractedImages: [NSImage] = []

        // Convert to attributed string but extract mermaid images separately
        let converter = MarkdownASTToNSAttributedStringWithImageExtraction(imageHandler: { image in
            extractedImages.append(image)
        })
        let textContent = converter.convert(astNodes)

        return (textContent, extractedImages)
    }

    /// Convert MarkdownElements from MarkdownSemanticParser to NSAttributedString for PDF/print.
    @MainActor
    private static func convertMarkdownElementsToNSAttributedString(_ elements: [MarkdownElement]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        /// Define fonts and styles.
        let bodyFont = NSFont.systemFont(ofSize: 12)
        let bodyColor = NSColor.black
        let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let codeBackgroundColor = NSColor.lightGray.withAlphaComponent(0.15)

        for element in elements {
            let elementString = convertMarkdownElement(
                element,
                bodyFont: bodyFont,
                bodyColor: bodyColor,
                codeFont: codeFont,
                codeBackgroundColor: codeBackgroundColor
            )
            result.append(elementString)
        }

        return result
    }

    /// Convert a single MarkdownElement to NSAttributedString.
    @MainActor
    private static func convertMarkdownElement(
        _ element: MarkdownElement,
        bodyFont: NSFont,
        bodyColor: NSColor,
        codeFont: NSFont,
        codeBackgroundColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        switch element {
        case .header(let level, let text):
            let fontSize: CGFloat = {
                switch level {
                case 1: return 24
                case 2: return 20
                case 3: return 16
                case 4: return 14
                case 5: return 12
                default: return 11
                }
            }()
            let headerFont = NSFont.boldSystemFont(ofSize: fontSize)
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: headerFont,
                .foregroundColor: bodyColor
            ]
            /// Convert AttributedString to NSAttributedString and apply header font.
            let nsHeaderText = convertAttributedStringToNSAttributedString(text, defaultFont: headerFont, defaultColor: bodyColor)
            result.append(nsHeaderText)
            result.append(NSAttributedString(string: "\n\n", attributes: headerAttributes))

        case .paragraph(let text):
            let paragraphAttributes: [NSAttributedString.Key: Any] = [
                .font: bodyFont,
                .foregroundColor: bodyColor
            ]
            let nsText = convertAttributedStringToNSAttributedString(text, defaultFont: bodyFont, defaultColor: bodyColor)
            result.append(nsText)
            result.append(NSAttributedString(string: "\n\n", attributes: paragraphAttributes))

        case .codeBlock(let language, let code):
            // Special handling for Mermaid diagrams - render as images
            if let lang = language, lang.lowercased() == "mermaid" {
                // INCREASED: Use 800px width for PDF export (was 550px)
                // Complex diagrams need more width for proper layout
                if let diagramImage = MermaidImageRenderer.renderDiagram(code: code, width: 800) {
                    // Create attachment for image
                    let imageAttachment = NSTextAttachment()
                    imageAttachment.image = diagramImage

                    // Scale image to fit page width if needed
                    let maxWidth: CGFloat = 800
                    let imageSize = diagramImage.size
                    if imageSize.width > maxWidth {
                        let scale = maxWidth / imageSize.width
                        imageAttachment.bounds = CGRect(
                            x: 0,
                            y: 0,
                            width: imageSize.width * scale,
                            height: imageSize.height * scale
                        )
                    } else {
                        imageAttachment.bounds = CGRect(
                            x: 0,
                            y: 0,
                            width: imageSize.width,
                            height: imageSize.height
                        )
                    }

                    // Add small label above diagram
                    let labelAttributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                    let label = NSAttributedString(string: "[Mermaid Diagram]\n", attributes: labelAttributes)
                    result.append(label)

                    // Add image
                    let imageString = NSAttributedString(attachment: imageAttachment)
                    result.append(imageString)
                    result.append(NSAttributedString(string: "\n\n"))
                } else {
                    // Fallback to code text if rendering fails
                    let codeAttributes: [NSAttributedString.Key: Any] = [
                        .font: codeFont,
                        .foregroundColor: NSColor.darkGray,
                        .backgroundColor: codeBackgroundColor
                    ]
                    let codeString = NSAttributedString(string: "[mermaid]\n" + code + "\n\n", attributes: codeAttributes)
                    result.append(codeString)
                }
            } else {
                // Regular code block
                let codeAttributes: [NSAttributedString.Key: Any] = [
                    .font: codeFont,
                    .foregroundColor: NSColor.darkGray,
                    .backgroundColor: codeBackgroundColor
                ]
                let languagePrefix = (language ?? "").isEmpty ? "" : "[\(language!)]\n"
                let codeString = NSAttributedString(string: languagePrefix + code + "\n\n", attributes: codeAttributes)
                result.append(codeString)
            }

        case .orderedList(let items):
            /// Render ordered lists while preserving original starting numbers and nested lists.
            result.append(renderListItems(items, bodyFont: bodyFont, bodyColor: bodyColor))
            result.append(NSAttributedString(string: "\n"))

        case .unorderedList(let items):
            result.append(renderListItems(items, bodyFont: bodyFont, bodyColor: bodyColor))
            result.append(NSAttributedString(string: "\n"))

        case .taskList(let items):
            for item in items {
                let checkbox = item.isCompleted ? "" : ""
                let itemText = convertAttributedStringToNSAttributedString(item.text, defaultFont: bodyFont, defaultColor: bodyColor)
                let indentedItem = createListItem(bullet: checkbox, text: itemText, indentLevel: item.indentLevel, bodyFont: bodyFont, bodyColor: bodyColor)
                result.append(indentedItem)
            }
            result.append(NSAttributedString(string: "\n"))

        case .table(let headers, _, let rows):
            result.append(renderTableAsNSAttributedString(headers: headers, rows: rows, bodyFont: bodyFont, bodyColor: bodyColor))
            result.append(NSAttributedString(string: "\n"))

        case .blockquote(let text, _):
            let quoteAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask),
                .foregroundColor: NSColor.darkGray
            ]
            let quoteString = NSAttributedString(string: "  " + text + "\n\n", attributes: quoteAttributes)
            result.append(quoteString)

        case .horizontalRule:
            let ruleAttributes: [NSAttributedString.Key: Any] = [
                .font: bodyFont,
                .foregroundColor: NSColor.gray
            ]
            let ruleString = NSAttributedString(string: String(repeating: "─", count: 39) + "\n\n", attributes: ruleAttributes)
            result.append(ruleString)

        case .inlineCode(let text):
            /// This shouldn't appear at top level, but handle it anyway.
            let codeAttributes: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .foregroundColor: NSColor.darkGray,
                .backgroundColor: codeBackgroundColor
            ]
            result.append(NSAttributedString(string: text + "\n", attributes: codeAttributes))

        case .image(let altText, let url):
            /// Load and embed actual image in PDF
            if let imageURL = URL(string: url),
               let image = NSImage(contentsOf: imageURL) {
                /// Create attachment for image
                let imageAttachment = NSTextAttachment()
                imageAttachment.image = image

                /// Scale image down to fit page width if needed (never scale up)
                let maxWidth: CGFloat = 550
                let imageSize = image.size
                if imageSize.width > maxWidth {
                    /// Fixed geometry scaling - maintain aspect ratio
                    let scale = maxWidth / imageSize.width
                    imageAttachment.bounds = CGRect(
                        x: 0,
                        y: 0,
                        width: imageSize.width * scale,
                        height: imageSize.height * scale
                    )
                } else {
                    /// Use original size if within max width
                    imageAttachment.bounds = CGRect(
                        x: 0,
                        y: 0,
                        width: imageSize.width,
                        height: imageSize.height
                    )
                }

                /// Add small label above image if alt text provided
                if !altText.isEmpty {
                    let labelAttributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                    let label = NSAttributedString(string: "[\(altText)]\n", attributes: labelAttributes)
                    result.append(label)
                }

                /// Add image
                let imageString = NSAttributedString(attachment: imageAttachment)
                result.append(imageString)
                result.append(NSAttributedString(string: "\n\n"))
            } else {
                /// Fallback to text representation if image loading fails
                let imageAttributes: [NSAttributedString.Key: Any] = [
                    .font: bodyFont,
                    .foregroundColor: NSColor.blue
                ]
                let imageText = altText.isEmpty ? "[Image]" : "[Image: \(altText)]"
                let imageString = NSMutableAttributedString(string: imageText + "\n", attributes: imageAttributes)

                /// Add URL as link
                let urlAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.gray
                ]
                imageString.append(NSAttributedString(string: url + "\n\n", attributes: urlAttributes))
                result.append(imageString)
            }
        }

        return result
    }

    /// Create a formatted list item with bullet and indentation.
    private static func createListItem(
        bullet: String,
        text: NSAttributedString,
        indentLevel: Int,
        bodyFont: NSFont,
        bodyColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        /// Build the raw paragraph: bullet + text.
        let indentPrefix = String(repeating: "  ", count: indentLevel)
        let bulletPrefix = indentPrefix + bullet

        /// Append bullet prefix (plain attributes - actual paragraph styling applied to whole paragraph below).
        let bulletAttr: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: bodyColor
        ]
        result.append(NSAttributedString(string: bulletPrefix, attributes: bulletAttr))

        /// Append the rich item text (preserves inline formatting).
        result.append(text)

        /// Append newline to terminate paragraph.
        result.append(NSAttributedString(string: "\n", attributes: bulletAttr))

        /// Apply paragraph style so wrapped lines align under the text (not the bullet).
        let paragraphStyle = NSMutableParagraphStyle()
        /// Indent amount for wrapped lines (increase with nesting).
        let indentStep: CGFloat = 18.0
        paragraphStyle.headIndent = indentStep * CGFloat(indentLevel + 1)
        /// First line keeps the bullet at the start, so set firstLineHeadIndent slightly smaller.
        paragraphStyle.firstLineHeadIndent = paragraphStyle.headIndent -  (bulletPrefix.count > 0 ?  (bodyFont.pointSize * 0.85) : 0)
        paragraphStyle.paragraphSpacing = 4

        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))

        return result
    }

    /// Render list items (ordered or unordered) recursively, preserving original numbering for ordered lists.
    private static func renderListItems(_ items: [MarkdownListItem], bodyFont: NSFont, bodyColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()

        /// Running number used when items don't specify originalNumber.
        var runningNumber = items.first?.originalNumber ?? 1

        for item in items {
            var bullet: String
            switch item.listType {
            case .ordered:
                if let orig = item.originalNumber {
                    bullet = "\(orig). "
                    /// Ensure subsequent unspecified items continue from this number.
                    runningNumber = orig + 1
                } else {
                    bullet = "\(runningNumber). "
                    runningNumber += 1
                }
            case .unordered:
                bullet = "• "
            }

            let itemText = convertAttributedStringToNSAttributedString(item.text, defaultFont: bodyFont, defaultColor: bodyColor)
            let indentedItem = createListItem(bullet: bullet, text: itemText, indentLevel: item.indentLevel, bodyFont: bodyFont, bodyColor: bodyColor)
            result.append(indentedItem)

            /// Render nested sub-items (they use their own numbering context).
            if !item.subItems.isEmpty {
                let subRendered = renderListItems(item.subItems, bodyFont: bodyFont, bodyColor: bodyColor)
                result.append(subRendered)
            }
        }

        return result
    }

    /// Render table as NSAttributedString with box-drawing characters (visual table).
    private static func renderTableAsNSAttributedString(
        headers: [String],
        rows: [[String]],
        bodyFont: NSFont,
        bodyColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        /// Use monospaced font for proper alignment.
        let tableFont = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 1, weight: .regular)
        let boldTableFont = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 1, weight: .bold)

        /// Calculate column widths.
        var columnWidths = headers.map { $0.count }
        for row in rows {
            for (index, cell) in row.enumerated() where index < columnWidths.count {
                columnWidths[index] = max(columnWidths[index], cell.count)
            }
        }

        /// Add padding.
        let cellPadding = 2
        columnWidths = columnWidths.map { $0 + cellPadding * 2 }

        /// Top border: ┌───┬───┬───┐.
        var topBorder = "┌"
        for (index, width) in columnWidths.enumerated() {
            topBorder += String(repeating: "─", count: width)
            topBorder += index < columnWidths.count - 1 ? "┬" : "┐"
        }
        result.append(NSAttributedString(string: topBorder + "\n", attributes: [.font: tableFont, .foregroundColor: NSColor.gray]))

        /// Header row: │ Header 1 │ Header 2 │ Header 3 │.
        var headerLine = "│"
        for (index, header) in headers.enumerated() {
            let paddedHeader = header.padding(toLength: columnWidths[index] - cellPadding, withPad: " ", startingAt: 0)
            headerLine += " " + paddedHeader + " │"
        }
        result.append(NSAttributedString(string: headerLine + "\n", attributes: [.font: boldTableFont, .foregroundColor: bodyColor]))

        /// Header separator: ├───┼───┼───┤.
        var headerSeparator = "├"
        for (index, width) in columnWidths.enumerated() {
            headerSeparator += String(repeating: "─", count: width)
            headerSeparator += index < columnWidths.count - 1 ? "┼" : "┤"
        }
        result.append(NSAttributedString(string: headerSeparator + "\n", attributes: [.font: tableFont, .foregroundColor: NSColor.gray]))

        /// Data rows: │ Cell 1 │ Cell 2 │ Cell 3 │.
        for (rowIndex, row) in rows.enumerated() {
            var rowLine = "│"
            for (colIndex, cell) in row.enumerated() {
                guard colIndex < columnWidths.count else { continue }
                let paddedCell = cell.padding(toLength: columnWidths[colIndex] - cellPadding, withPad: " ", startingAt: 0)
                rowLine += " " + paddedCell + " │"
            }
            result.append(NSAttributedString(string: rowLine + "\n", attributes: [.font: tableFont, .foregroundColor: bodyColor]))

            /// Row separator (except after last row): ├───┼───┼───┤.
            if rowIndex < rows.count - 1 {
                var rowSeparator = "├"
                for (index, width) in columnWidths.enumerated() {
                    rowSeparator += String(repeating: "─", count: width)
                    rowSeparator += index < columnWidths.count - 1 ? "┼" : "┤"
                }
                result.append(NSAttributedString(string: rowSeparator + "\n", attributes: [.font: tableFont, .foregroundColor: NSColor.gray]))
            }
        }

        /// Bottom border: └───┴───┴───┘.
        var bottomBorder = "└"
        for (index, width) in columnWidths.enumerated() {
            bottomBorder += String(repeating: "─", count: width)
            bottomBorder += index < columnWidths.count - 1 ? "┴" : "┘"
        }
        result.append(NSAttributedString(string: bottomBorder + "\n\n", attributes: [.font: tableFont, .foregroundColor: NSColor.gray]))

        return result
    }

    /// Convert SwiftUI AttributedString to NSAttributedString with formatting.
    private static func convertAttributedStringToNSAttributedString(
        _ attrString: AttributedString,
        defaultFont: NSFont,
        defaultColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for run in attrString.runs {
            let text = String(attrString[run.range].characters)
            var font = defaultFont
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: defaultColor
            ]

            /// Apply formatting based on presentation intent.
            if let intent = run.inlinePresentationIntent {
                /// Handle bold and italic (can be combined).
                var traits: NSFontDescriptor.SymbolicTraits = []

                if intent.contains(.stronglyEmphasized) {
                    traits.insert(.bold)
                }
                if intent.contains(.emphasized) {
                    traits.insert(.italic)
                }

                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                    font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }

                if intent.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: defaultFont.pointSize - 1, weight: .regular)
                    attributes[.backgroundColor] = NSColor.lightGray.withAlphaComponent(0.15)
                }

                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }

            attributes[.font] = font

            /// Handle links.
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.blue
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }

            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        return result
    }

    /// Extract plain text from AttributedString.
    private static func convertAttributedStringToPlainText(_ attrString: AttributedString) -> String {
        return String(attrString.characters)
    }

    /// Old manual parser - DEPRECATED, kept for reference only Use parseMarkdownForPDF() instead which uses MarkdownSemanticParser.
    private static func parseMarkdownManually(_ markdown: String) -> NSAttributedString {
        let attributedString = NSMutableAttributedString()

        let bodyFont = NSFont.systemFont(ofSize: 12)
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.black
        ]

        let boldFont = NSFont.boldSystemFont(ofSize: 12)
        let italicFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        let lines = markdown.components(separatedBy: .newlines)

        for line in lines {
            var processedLine = line
            var lineAttributes = bodyAttributes

            /// Handle horizontal rules.
            if line.trimmingCharacters(in: .whitespaces) == "---" ||
               line.trimmingCharacters(in: .whitespaces) == "***" ||
               line.trimmingCharacters(in: .whitespaces) == "___" {
                /// Add a horizontal line using underline.
                let rule = NSMutableAttributedString(string: "\n" + String(repeating: "─", count: 39) + "\n\n")
                rule.addAttribute(.foregroundColor, value: NSColor.gray, range: NSRange(location: 0, length: rule.length))
                attributedString.append(rule)
                continue
            }

            /// Handle headers.
            if processedLine.hasPrefix("### ") {
                processedLine = String(processedLine.dropFirst(4))
                lineAttributes = [
                    .font: NSFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: NSColor.black
                ]
                attributedString.append(NSAttributedString(string: processedLine + "\n\n", attributes: lineAttributes))
                continue
            } else if processedLine.hasPrefix("## ") {
                processedLine = String(processedLine.dropFirst(3))
                lineAttributes = [
                    .font: NSFont.boldSystemFont(ofSize: 16),
                    .foregroundColor: NSColor.black
                ]
                attributedString.append(NSAttributedString(string: processedLine + "\n\n", attributes: lineAttributes))
                continue
            } else if processedLine.hasPrefix("# ") {
                processedLine = String(processedLine.dropFirst(2))
                lineAttributes = [
                    .font: NSFont.boldSystemFont(ofSize: 18),
                    .foregroundColor: NSColor.black
                ]
                attributedString.append(NSAttributedString(string: processedLine + "\n\n", attributes: lineAttributes))
                continue
            }

            /// Handle code blocks.
            if processedLine.hasPrefix("```") {
                attributedString.append(NSAttributedString(string: processedLine + "\n", attributes: [
                    .font: codeFont,
                    .foregroundColor: NSColor.darkGray,
                    .backgroundColor: NSColor.lightGray.withAlphaComponent(0.2)
                ]))
                continue
            }

            /// Handle inline formatting.
            let lineString = parseInlineMarkdown(processedLine, bodyFont: bodyFont, boldFont: boldFont, italicFont: italicFont, codeFont: codeFont)
            attributedString.append(lineString)
            attributedString.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        }

        return attributedString
    }

    /// Parse inline markdown: **bold**, *italic*, `code`.
    private static func parseInlineMarkdown(
        _ text: String,
        bodyFont: NSFont,
        boldFont: NSFont,
        italicFont: NSFont,
        codeFont: NSFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var currentText = text
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.black
        ]

        while !currentText.isEmpty {
            /// Check for **bold**.
            if let boldRange = currentText.range(of: "**") {
                let beforeBold = String(currentText[..<boldRange.lowerBound])
                result.append(NSAttributedString(string: beforeBold, attributes: bodyAttributes))

                let afterFirstBold = currentText[boldRange.upperBound...]
                if let closeBoldRange = afterFirstBold.range(of: "**") {
                    let boldText = String(afterFirstBold[..<closeBoldRange.lowerBound])
                    result.append(NSAttributedString(string: boldText, attributes: [
                        .font: boldFont,
                        .foregroundColor: NSColor.black
                    ]))
                    currentText = String(afterFirstBold[closeBoldRange.upperBound...])
                    continue
                } else {
                    result.append(NSAttributedString(string: "**", attributes: bodyAttributes))
                    currentText = String(afterFirstBold)
                    continue
                }
            }

            /// Check for *italic*.
            else if let italicRange = currentText.range(of: "*"),
                    !currentText[italicRange.lowerBound...].hasPrefix("**") {
                let beforeItalic = String(currentText[..<italicRange.lowerBound])
                result.append(NSAttributedString(string: beforeItalic, attributes: bodyAttributes))

                let afterFirstItalic = currentText[italicRange.upperBound...]
                if let closeItalicRange = afterFirstItalic.range(of: "*") {
                    let italicText = String(afterFirstItalic[..<closeItalicRange.lowerBound])
                    result.append(NSAttributedString(string: italicText, attributes: [
                        .font: italicFont,
                        .foregroundColor: NSColor.black
                    ]))
                    currentText = String(afterFirstItalic[closeItalicRange.upperBound...])
                    continue
                } else {
                    result.append(NSAttributedString(string: "*", attributes: bodyAttributes))
                    currentText = String(afterFirstItalic)
                    continue
                }
            }

            /// Check for `code`.
            else if let codeRange = currentText.range(of: "`") {
                let beforeCode = String(currentText[..<codeRange.lowerBound])
                result.append(NSAttributedString(string: beforeCode, attributes: bodyAttributes))

                let afterFirstCode = currentText[codeRange.upperBound...]
                if let closeCodeRange = afterFirstCode.range(of: "`") {
                    let codeText = String(afterFirstCode[..<closeCodeRange.lowerBound])
                    result.append(NSAttributedString(string: codeText, attributes: [
                        .font: codeFont,
                        .foregroundColor: NSColor.darkGray,
                        .backgroundColor: NSColor.lightGray.withAlphaComponent(0.2)
                    ]))
                    currentText = String(afterFirstCode[closeCodeRange.upperBound...])
                    continue
                } else {
                    result.append(NSAttributedString(string: "`", attributes: bodyAttributes))
                    currentText = String(afterFirstCode)
                    continue
                }
            }

            /// No special formatting, append rest.
            else {
                result.append(NSAttributedString(string: currentText, attributes: bodyAttributes))
                break
            }
        }

        return result
    }
}

// MARK: - UI Setup

/// NSView for printing a message with multi-page support.
private class MessagePrintView: NSView {
    let message: EnhancedMessage
    let conversationTitle: String
    let modelName: String?

    init(message: EnhancedMessage, conversationTitle: String, modelName: String?) {
        self.message = message
        self.conversationTitle = conversationTitle
        self.modelName = modelName

        /// Calculate the full height needed for content only (no header/footer).
        let pageWidth: CGFloat = 612
        let margin: CGFloat = 27
        let contentWidth = pageWidth - (margin * 2)

        /// Calculate content height.
        let content = MessageExportService.parseMarkdownForPDF(message.content)
        let textContainer = NSTextContainer(containerSize: CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let layoutManager = NSLayoutManager()
        let textStorage = NSTextStorage(attributedString: content)
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.glyphRange(for: textContainer)
        let contentHeight = layoutManager.usedRect(for: textContainer).height

        /// Calculate total height needed (margins + content only).
        let totalHeight = margin + contentHeight + margin

        let frame = CGRect(x: 0, y: 0, width: pageWidth, height: totalHeight)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let margin: CGFloat = 27
        let contentWidth = bounds.width - (margin * 2)
        let currentY = margin

        /// Draw content only - no header or footer.
        let contentAttributedString = MessageExportService.parseMarkdownForPDF(message.content)
        let contentRect = CGRect(
            x: margin,
            y: currentY,
            width: contentWidth,
            height: bounds.height - currentY - margin
        )
        contentAttributedString.draw(with: contentRect, options: .usesLineFragmentOrigin)
    }
}

// MARK: - Error Types

public enum MessageExportError: Error, LocalizedError {
    case pdfCreationFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .pdfCreationFailed(let message):
            return "PDF creation failed: \(message)"
        case .writeFailed(let message):
            return "Write failed: \(message)"
        }
    }
}

// MARK: - UI Setup

/// NSView subclass for rendering a message to PDF with proper multi-page support.
