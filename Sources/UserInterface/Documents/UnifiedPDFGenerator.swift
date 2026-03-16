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
        // NSPrintOperation drops NSTextAttachment images, so we draw manually
        let marginH: CGFloat = 54
        let marginV: CGFloat = 54
        let contentWidth = pageWidth - (marginH * 2)
        let usableHeight = pageHeight - (marginV * 2)
        
        // Create temporary file for output
        let tempDir = FileManager.default.temporaryDirectory
        let sanitizedTitle = conversationTitle.replacingOccurrences(of: "/", with: "_")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateString = dateFormatter.string(from: Date())
        let filename = "SAM_\(sanitizedTitle)_\(dateString).pdf"
        let fileURL = tempDir.appendingPathComponent(filename)
        
        // Build content segments: each segment is either text or an image
        var segments: [PDFSegment] = []
        
        for (index, rendered) in renderedMessages.enumerated() {
            // Separator between messages
            if index > 0 {
                let separator = NSAttributedString(string: "\n" + String(repeating: "─", count: 40) + "\n\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.lightGray
                ])
                segments.append(.text(separator))
            }
            
            // Role header
            if includeHeaders {
                let roleText = rendered.message.isFromUser ? "You:" : "SAM:"
                let roleColor = rendered.message.isFromUser ? NSColor.systemBlue : NSColor.systemGreen
                let roleAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: roleColor
                ]
                segments.append(.text(NSAttributedString(string: roleText + "\n", attributes: roleAttributes)))
            }
            
            // Text content (may contain NSTextAttachment for tables, etc.)
            segments.append(.text(rendered.textContent))
            
            // Extracted images (mermaid diagrams + contentParts)
            for image in rendered.allImages {
                segments.append(.image(image))
            }
            
            // Trailing newline
            segments.append(.text(NSAttributedString(string: "\n")))
        }
        
        // Draw PDF pages using CGContext
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let context = CGContext(fileURL as CFURL, mediaBox: &mediaBox, nil) else {
            throw PDFGenerationError.renderingFailed("Failed to create CGContext for PDF")
        }
        
        var currentY: CGFloat = marginV  // Y position from top of current page
        var pageCount = 0
        
        func startNewPage() {
            if pageCount > 0 {
                context.endPage()
            }
            context.beginPage(mediaBox: &mediaBox)
            pageCount += 1
            currentY = marginV
        }
        
        // Start first page
        startNewPage()
        
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        
        for segment in segments {
            switch segment {
            case .text(let attrString):
                guard attrString.length > 0 else { continue }
                
                // Use text container to lay out text in chunks that fit pages
                let textStorage = NSTextStorage(attributedString: attrString)
                let layoutManager = NSLayoutManager()
                textStorage.addLayoutManager(layoutManager)
                
                let textContainer = NSTextContainer(containerSize: CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
                textContainer.lineFragmentPadding = 0
                layoutManager.addTextContainer(textContainer)
                layoutManager.ensureLayout(for: textContainer)
                
                let totalTextHeight = layoutManager.usedRect(for: textContainer).height
                var textOffset: CGFloat = 0  // How much text we've drawn
                
                while textOffset < totalTextHeight {
                    let remainingOnPage = usableHeight - currentY
                    
                    if remainingOnPage < 20 {
                        // Not enough space, start new page
                        startNewPage()
                        continue
                    }
                    
                    // Determine glyph range that fits in remaining space
                    let drawHeight = min(remainingOnPage, totalTextHeight - textOffset)
                    
                    // Draw text chunk
                    let savedState = NSGraphicsContext.current
                    NSGraphicsContext.current = nsContext
                    
                    // CGContext origin is bottom-left, flipped
                    let drawOriginY = pageHeight - marginV - currentY - drawHeight
                    
                    context.saveGState()
                    // Clip to the area we want to draw in
                    context.clip(to: CGRect(x: marginH, y: drawOriginY, width: contentWidth, height: drawHeight))
                    
                    // Draw text at the correct offset
                    let textOrigin = NSPoint(
                        x: marginH,
                        y: drawOriginY + drawHeight - totalTextHeight + textOffset
                    )
                    layoutManager.drawBackground(forGlyphRange: layoutManager.glyphRange(for: textContainer), at: textOrigin)
                    layoutManager.drawGlyphs(forGlyphRange: layoutManager.glyphRange(for: textContainer), at: textOrigin)
                    
                    context.restoreGState()
                    NSGraphicsContext.current = savedState
                    
                    textOffset += drawHeight
                    currentY += drawHeight
                    
                    if textOffset < totalTextHeight {
                        startNewPage()
                    }
                }
                
            case .image(let nsImage):
                // Scale image to fit content width
                let maxWidth = contentWidth * 0.9
                var drawWidth = nsImage.size.width
                var drawHeight = nsImage.size.height
                
                if drawWidth > maxWidth {
                    let scale = maxWidth / drawWidth
                    drawWidth = drawWidth * scale
                    drawHeight = drawHeight * scale
                }
                
                // Cap height to usable page height
                if drawHeight > usableHeight {
                    let scale = usableHeight / drawHeight
                    drawWidth = drawWidth * scale
                    drawHeight = drawHeight * scale
                }
                
                let remainingOnPage = usableHeight - currentY
                if drawHeight + 10 > remainingOnPage {
                    startNewPage()
                }
                
                // Draw image (CGContext y is from bottom)
                let imageY = pageHeight - marginV - currentY - drawHeight
                let imageRect = CGRect(x: marginH, y: imageY, width: drawWidth, height: drawHeight)
                
                if let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    context.draw(cgImage, in: imageRect)
                    logger.debug("Drew image at y=\(imageY), size=\(drawWidth)x\(drawHeight)")
                } else {
                    logger.warning("Failed to get CGImage from NSImage")
                }
                
                currentY += drawHeight + 10  // Image + spacing
            }
        }
        
        // End last page
        context.endPage()
        context.closePDF()
        
        // Load to set metadata
        guard let pdfDocument = PDFDocument(url: fileURL) else {
            throw PDFGenerationError.renderingFailed("Failed to load generated PDF")
        }
        
        setMetadata(on: pdfDocument, title: conversationTitle, modelName: modelName, messageCount: visibleMessages.count)
        pdfDocument.write(to: fileURL)
        
        logger.info("PDF generated: \(pdfDocument.pageCount) page(s), \(visibleMessages.count) message(s)")
        return fileURL
    }
    
    /// Print messages directly
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
