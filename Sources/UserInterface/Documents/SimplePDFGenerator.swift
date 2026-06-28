// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import PDFKit
import AppKit
import ConversationEngine
import ConfigurationSystem
import Logging

/// Simple, reliable PDF generation using NSTextView's built-in PDF data export.
///
/// Previous approach built complex NSView hierarchies with manual y-coordinate
/// math. NSTextView.dataWithPDF(inside:) is simpler and more reliable - it
/// handles text layout, pagination, and font rendering natively.
@MainActor
public enum SimplePDFGenerator {
    private static let logger = Logger(label: "com.sam.documents.SimplePDFGenerator")
    
    private static let pageWidth: CGFloat = 612   // US Letter
    private static let pageHeight: CGFloat = 792  // US Letter
    private static let margin: CGFloat = 54
    
    // MARK: - Public API
    
    /// Generate PDF from an array of enhanced messages.
    /// Uses NSPrintOperation with the NSTextView for proper multi-page output.
    public static func generatePDF(
        messages: [EnhancedMessage],
        conversationTitle: String,
        modelName: String? = nil
    ) async throws -> URL {
        let textView = await buildPrintTextView(
            messages: messages,
            conversationTitle: conversationTitle,
            modelName: modelName
        )

        // Use NSPrintOperation to render to a paginated PDF
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin

        let pdfData = generatePaginatedPDF(view: textView, printInfo: printInfo)

        let tempDir = FileManager.default.temporaryDirectory
        let sanitizedTitle = conversationTitle.replacingOccurrences(of: "/", with: "_")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "SAM_\(sanitizedTitle)_\(dateFormatter.string(from: Date())).pdf"
        let fileURL = tempDir.appendingPathComponent(filename)
        try pdfData.write(to: fileURL)

        logger.info("PDF generated: \(fileURL.path) (\(pdfData.count) bytes)")
        return fileURL
    }

    /// Render a view as a properly paginated PDF using CGPDFContext.
    private static func generatePaginatedPDF(view: NSView, printInfo: NSPrintInfo) -> Data {
        let paperSize = printInfo.paperSize
        let printableRect = NSRect(
            x: printInfo.leftMargin,
            y: printInfo.bottomMargin,
            width: paperSize.width - printInfo.leftMargin - printInfo.rightMargin,
            height: paperSize.height - printInfo.topMargin - printInfo.bottomMargin
        )

        let totalContentHeight = view.bounds.height
        let pageContentHeight = printableRect.height
        let pageCount = max(1, Int(ceil(totalContentHeight / pageContentHeight)))

        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: paperSize)
        guard let pdfConsumer = CGDataConsumer(data: pdfData as CFMutableData),
              let pdfContext = CGContext(consumer: pdfConsumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        for page in 0..<pageCount {
            let pageRect = NSRect(
                x: 0, y: CGFloat(page) * pageContentHeight,
                width: paperSize.width, height: pageContentHeight
            )

            pdfContext.beginPDFPage(nil)

            // Flip coordinate system: PDF origin is bottom-left, AppKit is top-left
            let nsContext = NSGraphicsContext(cgContext: pdfContext, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext

            // Translate to position this page's content within the view
            pdfContext.translateBy(x: 0, y: printableRect.minY)
            pdfContext.scaleBy(x: 1.0, y: 1.0)

            // Draw the relevant portion of the view
            view.displayIgnoringOpacity(pageRect, in: nsContext)

            NSGraphicsContext.restoreGraphicsState()
            pdfContext.endPDFPage()
        }

        pdfContext.closePDF()
        return pdfData as Data
    }
    
    // MARK: - Print
    
    public static func printMessages(
        messages: [EnhancedMessage],
        conversationTitle: String,
        modelName: String? = nil
    ) async {
        // Build an NSTextView and print it directly - NSTextView's
        // printOperation handles real pagination.
        let textView = await buildPrintTextView(
            messages: messages,
            conversationTitle: conversationTitle,
            modelName: modelName
        )
        
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        
        let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        printOp.run()
    }
    
    /// Build an NSTextView suitable for printing (async markdown conversion).
    private static func buildPrintTextView(
        messages: [EnhancedMessage],
        conversationTitle: String,
        modelName: String?
    ) async -> NSTextView {
        let contentWidth = pageWidth - (margin * 2)
        let fullContent = NSMutableAttributedString()
        
        // Title
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        titleStyle.paragraphSpacing = 20
        fullContent.append(NSAttributedString(
            string: "\(conversationTitle)\n",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 18),
                .foregroundColor: NSColor.black,
                .paragraphStyle: titleStyle
            ]
        ))
        
        // Metadata
        let metaStyle = NSMutableParagraphStyle()
        metaStyle.alignment = .center
        metaStyle.paragraphSpacing = 24
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short)
        var metaStr = dateStr
        if let model = modelName { metaStr += "  ·  \(model)" }
        metaStr += "\n"
        fullContent.append(NSAttributedString(
            string: metaStr,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.darkGray,
                .paragraphStyle: metaStyle
            ]
        ))
        
        // Messages
        for (i, message) in messages.enumerated() {
            if message.isToolMessage { continue }
            
            if i > 0 {
                fullContent.append(NSAttributedString(
                    string: "\n\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 8),
                        .foregroundColor: NSColor.lightGray
                    ]
                ))
            }
            
            let role = message.isFromUser ? "You" : "SAM"
            let roleColor = message.isFromUser ? NSColor.systemBlue : NSColor.systemGreen
            fullContent.append(NSAttributedString(
                string: "\(role):\n",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: roleColor
                ]
            ))
            
            let cleanContent = stripUserContext(message.content)
            
            if message.isFromUser {
                let ps = NSMutableParagraphStyle()
                ps.lineSpacing = 3
                ps.paragraphSpacing = 8
                fullContent.append(NSAttributedString(
                    string: cleanContent + "\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12),
                        .foregroundColor: NSColor.black,
                        .paragraphStyle: ps
                    ]
                ))
            } else {
                let parser = MarkdownASTParser()
                let node = parser.parse(cleanContent)
                let converter = MarkdownASTToNSAttributedString()
                let markdownAttr = await converter.convert(node)
                let mutable = NSMutableAttributedString(attributedString: markdownAttr)
                mutable.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: mutable.length)) { _, range, _ in
                    mutable.addAttribute(.foregroundColor, value: NSColor.black, range: range)
                }
                fullContent.append(mutable)
                fullContent.append(NSAttributedString(string: "\n"))
            }
        }
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 100))
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textStorage?.setAttributedString(fullContent)
        textView.sizeToFit()
        
        return textView
    }
    
    // MARK: - Helpers
    
    private static func stripUserContext(_ content: String) -> String {
        var cleaned = content
        let pattern = "<userContext>.*?</userContext>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "PDF Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}
