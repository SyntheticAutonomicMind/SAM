// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import PDFKit
import AppKit
import ConfigurationSystem
import Logging

/// Unified PDF generation system for SAM messages
/// Uses NSView.dataWithPDF() for reliable, simple PDF generation with automatic pagination
public class UnifiedPDFGenerator {
    private static let logger = Logger(label: "com.sam.documents.UnifiedPDFGenerator")
    
    // MARK: - Constants
    
    private static let pageWidth: CGFloat = 612   // US Letter
    private static let pageHeight: CGFloat = 792  // US Letter
    private static let margin: CGFloat = 54       // Increased margins
    
    // MARK: - Public API
    
    /// Generate a PDF from one or more messages
    @MainActor
    public static func generatePDF(
        messages: [EnhancedMessage],
        conversationTitle: String,
        modelName: String? = nil,
        includeHeaders: Bool = true
    ) async throws -> URL {
        logger.info("Generating PDF for \(messages.count) message(s)")
        
        // Filter out tool messages
        let visibleMessages = messages.filter { !$0.isToolMessage }
        
        logger.debug("Visible messages after filtering: \(visibleMessages.count)")
        
        guard !visibleMessages.isEmpty else {
            throw PDFGenerationError.noContent("No visible messages to export")
        }
        
        // Pre-render all messages with image extraction
        var renderedMessages: [RenderedMessage] = []
        for message in visibleMessages {
            let cleanContent = MessageExportService.stripUserContext(message.content)
            
            // Use WithImages variant to extract mermaid diagrams separately
            let (textContent, mermaidImages) = await MessageExportService.parseMarkdownForPDFWithImages(cleanContent)
            
            // Collect contentParts images (these are separate from markdown content)
            var contentPartsImages: [NSImage] = []
            if let contentParts = message.contentParts {
                for part in contentParts {
                    if case .imageUrl(let imageURL) = part {
                        if let url = URL(string: imageURL.url),
                           let image = NSImage(contentsOf: url) {
                            contentPartsImages.append(image)
                        }
                    }
                }
            }
            
            // Merge all images (mermaid + contentParts) for drawing
            let allImages = mermaidImages + contentPartsImages
            
            renderedMessages.append(RenderedMessage(
                message: message,
                textContent: textContent,
                allImages: allImages
            ))
        }
        
        // Generate PDF using CGContext for reliable image rendering
        // Use NSView-based PDF generation (NSView.dataWithPDF is the most reliable
        // macOS approach - no CGContext coordinate math, no fragile clipping tricks)
        let fileURL = try generatePDFUsingNSView(
            renderedMessages: renderedMessages,
            conversationTitle: conversationTitle,
            modelName: modelName,
            visibleMessageCount: visibleMessages.count,
            includeHeaders: includeHeaders
        )
        return fileURL
    }
    
    /// Generate PDF using NSView.dataWithPDF() - the most reliable macOS PDF generation
    @MainActor
    private static func generatePDFUsingNSView(
        renderedMessages: [RenderedMessage],
        conversationTitle: String,
        modelName: String?,
        visibleMessageCount: Int,
        includeHeaders: Bool
    ) throws -> URL {
        let contentWidth = pageWidth - (margin * 2)
        
        // Build the content view hierarchy
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: 100))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.white.cgColor
        
        var yOffset: CGFloat = 0  // Distance from top (y increases downward in NSView)
        
        for (index, rendered) in renderedMessages.enumerated() {
            // Separator between messages
            if index > 0 {
                let sep = makeSeparatorView(yOffset: &yOffset, contentWidth: contentWidth)
                contentView.addSubview(sep)
            }
            
            // Role header
            if includeHeaders {
                let roleText = rendered.message.isFromUser ? "You:" : "SAM:"
                let roleColor = rendered.message.isFromUser ? NSColor.systemBlue : NSColor.systemGreen
                let header = makeLabel(roleText, fontSize: 14, color: roleColor, bold: true,
                                       yOffset: &yOffset, contentWidth: contentWidth)
                contentView.addSubview(header)
            }
            
            // Text content
            if rendered.textContent.length > 0 {
                let textViews = makeTextViews(from: rendered.textContent,
                                              yOffset: &yOffset, contentWidth: contentWidth)
                for tv in textViews {
                    contentView.addSubview(tv)
                }
            }
            
            // Images (mermaid + contentParts)
            for image in rendered.allImages {
                let imgView = makeImageView(image, yOffset: &yOffset, contentWidth: contentWidth)
                contentView.addSubview(imgView)
            }
            
            // Trailing spacing
            yOffset += 12
        }
        
        // Finalize content view size
        contentView.frame.size.height = yOffset + margin
        
        // Generate PDF using NSView's built-in method
        let pdfData = contentView.dataWithPDF(inside: contentView.bounds)
        
        // Write to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let sanitizedTitle = conversationTitle.replacingOccurrences(of: "/", with: "_")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateString = dateFormatter.string(from: Date())
        let filename = "SAM_\(sanitizedTitle)_\(dateString).pdf"
        let fileURL = tempDir.appendingPathComponent(filename)
        
        try pdfData.write(to: fileURL)
        
        // Set metadata
        guard let pdfDocument = PDFDocument(url: fileURL) else {
            throw PDFGenerationError.renderingFailed("Failed to load generated PDF")
        }
        setMetadata(on: pdfDocument, title: conversationTitle, modelName: modelName, messageCount: visibleMessageCount)
        pdfDocument.write(to: fileURL)
        
        logger.info("NSView PDF generated: \(pdfDocument.pageCount) page(s), \(visibleMessageCount) message(s)")
        return fileURL
    }
    
    @MainActor
    private static func makeSeparatorView(yOffset: inout CGFloat, contentWidth: CGFloat) -> NSTextField {
        let separator = NSTextField(labelWithString: String(repeating: "\u{2500}", count: 50))
        separator.frame = NSRect(x: margin, y: 0, width: contentWidth, height: 20)
        separator.textColor = NSColor.lightGray
        separator.font = NSFont.systemFont(ofSize: 10)
        separator.sizeToFit()
        let h = separator.frame.height
        separator.frame = NSRect(x: margin, y: yOffset, width: contentWidth, height: h)
        yOffset += h + 8
        return separator
    }
    
    @MainActor
    private static func makeLabel(_ text: String, fontSize: CGFloat, color: NSColor, bold: Bool,
                                  yOffset: inout CGFloat, contentWidth: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
        label.textColor = color
        label.preferredMaxLayoutWidth = contentWidth
        label.sizeToFit()
        let h = label.frame.height
        label.frame = NSRect(x: margin, y: yOffset, width: contentWidth, height: h)
        yOffset += h + 8
        return label
    }
    
    @MainActor
    private static func makeTextViews(from attrString: NSAttributedString,
                                       yOffset: inout CGFloat, contentWidth: CGFloat) -> [NSTextField] {
        // Break long attributed strings into page-sized chunks
        let textStorage = NSTextStorage(attributedString: attrString)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        
        let textContainer = NSTextContainer(containerSize: CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)
        
        let usedRect = layoutManager.usedRect(for: textContainer)
        
        // Render as a single NSTextField with the full attributed string
        // NSTextField handles line wrapping automatically
        let textField = NSTextField(labelWithAttributedString: attrString)
        textField.preferredMaxLayoutWidth = contentWidth
        textField.sizeToFit()
        
        let height = min(textField.frame.height, usedRect.height)
        textField.frame = NSRect(x: margin, y: yOffset, width: contentWidth, height: max(height, 16))
        yOffset += textField.frame.height + 4
        
        return [textField]
    }
    
    @MainActor
    private static func makeImageView(_ image: NSImage, yOffset: inout CGFloat, contentWidth: CGFloat) -> NSImageView {
        // Scale to fit content width
        let maxWidth = contentWidth * 0.9
        var w = image.size.width
        var h = image.size.height
        
        if w > maxWidth {
            let scale = maxWidth / w
            w *= scale
            h *= scale
        }
        
        let view = NSImageView(frame: NSRect(x: margin, y: yOffset, width: w, height: h))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        yOffset += h + 10
        return view
    }
    @MainActor
    public static func printMessages(
        messages: [EnhancedMessage],
        conversationTitle: String,
        modelName: String? = nil
    ) async {
        logger.info("Printing \(messages.count) message(s)")
        
        do {
            let pdfURL = try await generatePDF(
                messages: messages,
                conversationTitle: conversationTitle,
                modelName: modelName,
                includeHeaders: messages.count > 1
            )
            
            guard let pdfDoc = PDFDocument(url: pdfURL) else {
                logger.error("Failed to load generated PDF for printing")
                showPrintError("Failed to load PDF")
                return
            }
            
            let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
            printInfo.horizontalPagination = .automatic
            printInfo.verticalPagination = .automatic
            printInfo.orientation = .portrait
            
            guard let printOp = pdfDoc.printOperation(for: printInfo, scalingMode: .pageScaleNone, autoRotate: false) else {
                logger.error("Failed to create print operation")
                showPrintError("Failed to create print operation")
                return
            }
            
            printOp.showsPrintPanel = true
            printOp.showsProgressPanel = true
            printOp.run()
            
            // Clean up after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                try? FileManager.default.removeItem(at: pdfURL)
                logger.debug("Cleaned up temp PDF file")
            }
            
        } catch {
            logger.error("Print failed: \(error.localizedDescription)")
            showPrintError(error.localizedDescription)
        }
    }
    
    // MARK: - Helper Methods
    
    @MainActor
    private static func calculateTextHeight(_ attributedString: NSAttributedString, width: CGFloat) -> CGFloat {
        let textContainer = NSTextContainer(containerSize: CGSize(width: width, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        
        let textStorage = NSTextStorage(attributedString: attributedString)
        textStorage.addLayoutManager(layoutManager)
        
        layoutManager.glyphRange(for: textContainer)
        return layoutManager.usedRect(for: textContainer).height
    }
    
    private static func setMetadata(
        on pdfDocument: PDFDocument,
        title: String,
        modelName: String?,
        messageCount: Int
    ) {
        var attributes: [PDFDocumentAttribute: Any] = [:]
        attributes[.titleAttribute] = title
        attributes[.creationDateAttribute] = Date()
        attributes[.creatorAttribute] = "SAM"
        
        if let model = modelName {
            attributes[.subjectAttribute] = "Generated by \(model) - \(messageCount) message(s)"
        } else {
            attributes[.subjectAttribute] = "\(messageCount) message(s)"
        }
        
        pdfDocument.documentAttributes = attributes
    }
    
    private static func saveToFile(_ pdfDocument: PDFDocument, conversationTitle: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let sanitizedTitle = conversationTitle.replacingOccurrences(of: "/", with: "_")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateString = dateFormatter.string(from: Date())
        let filename = "SAM_\(sanitizedTitle)_\(dateString).pdf"
        let fileURL = tempDir.appendingPathComponent(filename)
        
        guard pdfDocument.write(to: fileURL) else {
            throw PDFGenerationError.writeFailed("Failed to write PDF to \(fileURL.path)")
        }
        
        return fileURL
    }
    
    private static func showPrintError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Print Failed"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}

// MARK: - Supporting Types

private struct RenderedMessage {
    let message: EnhancedMessage
    let textContent: NSAttributedString
    let allImages: [NSImage]  // Mermaid diagrams + contentParts images
}

private enum PDFSegment {
    case text(NSAttributedString)
    case image(NSImage)
}

// MARK: - Error Types

public enum PDFGenerationError: Error, LocalizedError {
    case noContent(String)
    case writeFailed(String)
    case renderingFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .noContent(let message):
            return "No content to export: \(message)"
        case .writeFailed(let message):
            return "Write failed: \(message)"
        case .renderingFailed(let message):
            return "Rendering failed: \(message)"
        }
    }
}
