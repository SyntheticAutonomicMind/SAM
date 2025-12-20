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
        
        // Pre-render all messages
        var renderedMessages: [RenderedMessage] = []
        for message in visibleMessages {
            let cleanContent = MessageExportService.stripUserContext(message.content)
            
            // Use regular parseMarkdownForPDF which embeds images as NSTextAttachment in correct positions
            let textContent = MessageExportService.parseMarkdownForPDF(cleanContent)
            
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
            
            renderedMessages.append(RenderedMessage(
                message: message,
                textContent: textContent,
                contentPartsImages: contentPartsImages
            ))
        }
        
        // Calculate total content height
        let marginHorizontal: CGFloat = 54
        let marginVertical: CGFloat = 20   // Minimal (printInfo provides per-page margins)
        let contentWidth = pageWidth - (marginHorizontal * 2)
        
        // Build combined attributed string (same as in draw method)
        let combined = NSMutableAttributedString()
        
        for (index, rendered) in renderedMessages.enumerated() {
            // Add separator (except before first message)
            if index > 0 {
                let separator = NSAttributedString(string: "\n\n" + String(repeating: "─", count: 40) + "\n\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.lightGray
                ])
                combined.append(separator)
            }
            
            // Role header (if requested)
            if includeHeaders {
                let roleText = rendered.message.isFromUser ? "You:" : "SAM:"
                let roleColor = rendered.message.isFromUser ? NSColor.systemBlue : NSColor.systemGreen
                let roleAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: roleColor
                ]
                let roleString = NSAttributedString(string: roleText + "\n", attributes: roleAttributes)
                combined.append(roleString)
            }
            
            // Text content
            combined.append(rendered.textContent)
            combined.append(NSAttributedString(string: "\n"))
        }
        
        // Calculate total height from combined string (includes embedded images) + contentParts images
        let textHeight = calculateTextHeight(combined, width: contentWidth)
        var contentPartsImagesHeight: CGFloat = 0
        
        for rendered in renderedMessages {
            for image in rendered.contentPartsImages {
                let maxWidth = contentWidth * 0.9
                let imageSize = image.size
                if imageSize.width > maxWidth {
                    let scale = maxWidth / imageSize.width
                    contentPartsImagesHeight += imageSize.height * scale + 20  // Image + spacing
                } else {
                    contentPartsImagesHeight += imageSize.height + 20
                }
            }
        }
        
        let totalHeight = marginVertical + textHeight + contentPartsImagesHeight + marginVertical  // Top + text + contentParts images + bottom
        
        // Create NSTextView for rendering (handles pagination automatically)
        let viewFrame = CGRect(x: 0, y: 0, width: pageWidth, height: totalHeight)
        logger.debug("Total content height: \(totalHeight), frame: width=\(viewFrame.width) height=\(viewFrame.height)")
        
        let textView = NSTextView(frame: viewFrame)
        textView.isEditable = false
        textView.isSelectable = false
        textView.textContainerInset = NSSize(width: marginHorizontal, height: marginVertical)
        
        // Append contentParts images to the combined attributed string
        for rendered in renderedMessages {
            for image in rendered.contentPartsImages {
                // Add content parts images as NSTextAttachment
                let attachment = NSTextAttachment()
                attachment.image = image
                
                // Scale if needed
                let maxWidth = contentWidth * 0.9
                if image.size.width > maxWidth {
                    let scale = maxWidth / image.size.width
                    attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
                } else {
                    attachment.bounds = CGRect(origin: .zero, size: image.size)
                }
                
                // Use default left alignment (matches text)
                let imageAttrString = NSAttributedString(attachment: attachment)
                combined.append(imageAttrString)
                combined.append(NSAttributedString(string: "\n"))
            }
        }
        
        // Set the complete attributed string on the text view
        textView.textStorage?.setAttributedString(combined)
        
        // Debug: Check for attachments in the combined string
        var attachmentCount = 0
        combined.enumerateAttribute(.attachment, in: NSRange(location: 0, length: combined.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment {
                attachmentCount += 1
                let imageSize = attachment.image?.size ?? .zero
                logger.debug("Found NSTextAttachment #\(attachmentCount) at range \(range), image size: \(imageSize)")
            }
        }
        logger.info("Total NSTextAttachments in combined string: \(attachmentCount)")
        
        logger.debug("Created NSTextView with \(renderedMessages.count) rendered messages")
        
        // Use NSPrintOperation for proper pagination (NSTextView handles pagination automatically)
        let pdfView = textView  // NSTextView is the view to print
        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: pageWidth, height: pageHeight)
        // Add margins to each page - 54pt = 0.75 inch (standard macOS margins)
        printInfo.topMargin = 54      // 0.75 inch top margin per page
        printInfo.bottomMargin = 54   // 0.75 inch bottom margin per page
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        printInfo.horizontalPagination = .clip
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        
        // Create temporary file for output
        let tempDir = FileManager.default.temporaryDirectory
        let sanitizedTitle = conversationTitle.replacingOccurrences(of: "/", with: "_")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateString = dateFormatter.string(from: Date())
        let filename = "SAM_\(sanitizedTitle)_\(dateString).pdf"
        let fileURL = tempDir.appendingPathComponent(filename)
        
        // Configure to save to file
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey(rawValue: NSPrintInfo.AttributeKey.jobSavingURL.rawValue)] = fileURL
        
        // Create and run print operation
        let printOperation = NSPrintOperation(view: pdfView, printInfo: printInfo)
        printOperation.showsPrintPanel = false
        printOperation.showsProgressPanel = false
        
        guard printOperation.run() else {
            throw PDFGenerationError.renderingFailed("NSPrintOperation failed")
        }
        
        // Load the generated PDF to set metadata
        guard let pdfDocument = PDFDocument(url: fileURL) else {
            throw PDFGenerationError.renderingFailed("Failed to load generated PDF")
        }
        
        // Set metadata
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
    let textContent: NSAttributedString  // Contains NSTextAttachment for Mermaid/markdown images
    let contentPartsImages: [NSImage]     // Separate images from message.contentParts
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
