// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import AppKit
import Foundation
import Logging
import SwiftUI

/// Converts markdown AST nodes to NSAttributedString for PDF/print rendering
@MainActor
class MarkdownASTToNSAttributedString {
    private let logger = Logger(label: "com.sam.ui.MarkdownASTToNSAttributedString")

    private let baseFontSize: CGFloat = 12
    private let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let baseFont = NSFont.systemFont(ofSize: 12)
    private let boldFont = NSFont.boldSystemFont(ofSize: 12)

    /// Convert AST to NSAttributedString (accepts single node or array)
    func convert(_ node: MarkdownASTNode) -> NSAttributedString {
        return convertNode(node)
    }

    func convert(_ nodes: [MarkdownASTNode]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for node in nodes {
            result.append(convertNode(node))
        }

        return result
    }

    // MARK: - Node Conversion

    private func convertNode(_ node: MarkdownASTNode) -> NSAttributedString {
        switch node {
        case .document(let children):
            let result = NSMutableAttributedString()
            for child in children {
                result.append(convertNode(child))
            }
            return result

        case .heading(let level, let children):
            return convertHeading(level: level, children: children)

        case .paragraph(let children):
            return convertParagraph(children: children)

        case .blockquote(let depth, let children):
            return convertBlockquote(depth: depth, children: children)

        case .codeBlock(let language, let code):
            return convertCodeBlock(language: language, code: code)

        case .list(let type, let items):
            return convertList(type: type, items: items)

        case .table(let headers, let alignments, let rows):
            return convertTable(headers: headers, alignments: alignments, rows: rows)

        case .horizontalRule:
            return convertHorizontalRule()

        case .image(let altText, let url):
            return convertImage(altText: altText, url: url)

        case .text(let string):
            return NSAttributedString(string: string, attributes: baseAttributes())

        case .strong(let children):
            return convertStrong(children: children)

        case .emphasis(let children):
            return convertEmphasis(children: children)

        case .strikethrough(let children):
            return convertStrikethrough(children: children)

        case .inlineCode(let text):
            return convertInlineCode(text: text)

        case .link(let text, let url):
            return convertLink(text: text, url: url)

        case .softBreak:
            return NSAttributedString(string: " ")

        case .hardBreak:
            return NSAttributedString(string: "\n")
        }
    }

    // MARK: - Block Elements

    private func convertHeading(level: Int, children: [MarkdownASTNode]) -> NSAttributedString {
        let fontSize: CGFloat = {
            switch level {
            case 1: return 24
            case 2: return 20
            case 3: return 16
            case 4: return 14
            case 5: return 13
            default: return 12
            }
        }()

        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]

        let result = NSMutableAttributedString()
        for child in children {
            result.append(convertInlineNode(child, baseAttributes: attributes))
        }
        result.append(NSAttributedString(string: "\n\n"))

        return result
    }

    private func convertParagraph(children: [MarkdownASTNode]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for child in children {
            result.append(convertInlineNode(child, baseAttributes: baseAttributes()))
        }

        result.append(NSAttributedString(string: "\n"))
        return result
    }

    private func convertBlockquote(depth: Int, children: [MarkdownASTNode]) -> NSAttributedString {
        let indent = CGFloat(depth * 20)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = indent
        paragraphStyle.headIndent = indent
        paragraphStyle.tailIndent = -20

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: baseFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]

        let result = NSMutableAttributedString()

        // Add vertical bar indicator
        let barString = String(repeating: "│ ", count: depth)
        result.append(NSAttributedString(string: barString, attributes: attributes))

        for child in children {
            result.append(convertNode(child))
        }

        result.append(NSAttributedString(string: "\n"))
        return result
    }

    @MainActor
    private func convertCodeBlock(language: String?, code: String) -> NSAttributedString {
        // Special handling for mermaid diagrams
        if language?.lowercased() == "mermaid" {
            return convertMermaidDiagram(code: code)
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 10
        paragraphStyle.headIndent = 10
        paragraphStyle.tailIndent = -10

        let attributes: [NSAttributedString.Key: Any] = [
            .font: codeFont,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.controlBackgroundColor,
            .paragraphStyle: paragraphStyle
        ]

        let result = NSMutableAttributedString()

        // Language label if present
        if let language = language {
            let langAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            result.append(NSAttributedString(string: language + "\n", attributes: langAttributes))
        }

        result.append(NSAttributedString(string: code, attributes: attributes))
        result.append(NSAttributedString(string: "\n\n"))

        return result
    }

    /// Convert Mermaid diagram to image for PDF/print using bitmapImageRepForCachingDisplay
    @MainActor
    private func convertMermaidDiagram(code: String) -> NSAttributedString {
        logger.info("Converting mermaid diagram for PDF/print, code length: \(code.count)")
        let result = NSMutableAttributedString()

        // PRE-PARSE diagram BEFORE creating view (critical for synchronous rendering)
        let parser = MermaidParser()
        let parsedDiagram = parser.parse(code)
        logger.info("Pre-parsed mermaid diagram type: \(parsedDiagram)")

        // Skip unsupported diagrams
        if case .unsupported = parsedDiagram {
            logger.warning("Unsupported mermaid diagram type, showing code block")
            return createFallbackCodeBlock(code: code)
        }

        // Render at higher resolution (700px) for better quality
        // Then scale down to PDF page width (550px) for proper fitting
        let renderWidth: CGFloat = 700
        let targetWidth: CGFloat = 550  // PDF page usable width
        
        // Create SwiftUI diagram view WITH pre-parsed diagram
        let diagramView = MermaidDiagramView(code: code, diagram: parsedDiagram, showBackground: false)
            .frame(width: renderWidth, alignment: .leading)

        // Use bitmapImageRepForCachingDisplay - most reliable for offscreen rendering
        var capturedImage: NSImage?

        let renderWithBitmap: () -> NSImage? = { [self] in
            let hostingView = NSHostingView(rootView: diagramView)
            // INCREASED: Use 3000px initial height (was 1000px) for complex diagrams
            hostingView.frame = NSRect(x: 0, y: 0, width: renderWidth, height: 3000)

            // Force layout multiple times for SwiftUI to properly render
            // INCREASED: 5 cycles with longer delays (was 3 cycles × 0.05s)
            var lastHeight: CGFloat = 0
            for cycle in 0..<5 {
                hostingView.layout()
                hostingView.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
                
                // Check for stabilization
                let currentSize = hostingView.fittingSize
                self.logger.debug("PDF render cycle \(cycle): fittingSize=\(currentSize.width)×\(currentSize.height)")
                
                if cycle > 2 && currentSize.height > 100 {
                    let heightChange = abs(currentSize.height - lastHeight)
                    let changePercent = heightChange / max(currentSize.height, 1) * 100
                    if changePercent < 5 {
                        self.logger.info("PDF render stabilized at cycle \(cycle): height=\(currentSize.height)")
                        break
                    }
                }
                lastHeight = currentSize.height
            }

            // Get actual size after layout
            let actualSize = hostingView.fittingSize
            self.logger.info("PDF render fittingSize: \(actualSize.width)×\(actualSize.height)")
            
            // INCREASED: Allow up to 4000px height (was 2000px) for very complex diagrams
            let finalHeight = max(min(actualSize.height, 4000), 100)
            let finalWidth = max(actualSize.width, renderWidth)
            
            hostingView.frame = NSRect(x: 0, y: 0, width: finalWidth, height: finalHeight)
            self.logger.info("PDF render final frame: \(finalWidth)×\(finalHeight)")
            
            hostingView.layout()
            hostingView.layoutSubtreeIfNeeded()

            // Render using bitmapImageRepForCachingDisplay (reliable for offscreen)
            guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                self.logger.error("Failed to create bitmap representation for PDF")
                return nil
            }
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

            let image = NSImage(size: hostingView.bounds.size)
            image.addRepresentation(bitmapRep)
            return image
        }

        if Thread.isMainThread {
            capturedImage = MainActor.assumeIsolated { renderWithBitmap() }
        } else {
            DispatchQueue.main.sync {
                capturedImage = MainActor.assumeIsolated { renderWithBitmap() }
            }
        }

        if let nsImage = capturedImage {
            logger.info("Captured mermaid diagram: \(nsImage.size.width)x\(nsImage.size.height)")
            
            // Debug: Log representation details
            if let bitmapRep = nsImage.representations.first as? NSBitmapImageRep {
                logger.info("Mermaid BitmapRep - size: \(bitmapRep.size), pixelsWide: \(bitmapRep.pixelsWide), pixelsHigh: \(bitmapRep.pixelsHigh)")
                logger.info("Mermaid BitmapRep - bitsPerPixel: \(bitmapRep.bitsPerPixel), colorSpace: \(String(describing: bitmapRep.colorSpaceName))")
            }

            // Create attachment with the rendered image
            let attachment = NSTextAttachment()
            attachment.image = nsImage

            // Scale image to fit PDF page width
            // Render at 700px for quality, scale to 550px for page fit
            let scale = targetWidth / nsImage.size.width
            attachment.bounds = CGRect(
                x: 0,
                y: 0,
                width: nsImage.size.width * scale,
                height: nsImage.size.height * scale
            )
            
            logger.debug("Mermaid NSTextAttachment created - hasImage: \(attachment.image != nil), bounds: \(attachment.bounds)")

            // Use default left alignment (matches text)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "\n\n"))
        } else {
            // Fallback: show code block if rendering fails
            logger.warning("Failed to render mermaid diagram with ImageRenderer, showing code instead")
            result.append(createFallbackCodeBlock(code: code))
        }

        return result
    }

    /// Create fallback code block for when diagram rendering fails
    private func createFallbackCodeBlock(code: String) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: codeFont,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.controlBackgroundColor
        ]
        return NSAttributedString(string: "mermaid\n" + code + "\n\n", attributes: attributes)
    }

    /// Capture NSView as NSImage
    private func captureViewAsImage(_ view: NSView) -> NSImage? {
        guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmapRep)

        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }

    private func convertList(type: MarkdownASTNode.ListType, items: [MarkdownASTNode.ListItemNode]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for (index, item) in items.enumerated() {
            // Bullet or number
            let bullet: String
            switch type {
            case .unordered:
                bullet = "• "
            case .ordered:
                bullet = "\(item.number ?? (index + 1)). "
            case .task:
                bullet = (item.isChecked ?? false) ? "☑ " : "☐ "
            }

            // Calculate indent based on nesting level (20pt per level)
            let indent = CGFloat(item.indentLevel * 20)
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent = indent
            paragraphStyle.headIndent = indent + 20  // Indent content more than bullet

            let bulletAttributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]

            result.append(NSAttributedString(string: bullet, attributes: bulletAttributes))

            // Item content
            for child in item.children {
                result.append(convertNode(child))
            }
        }

        result.append(NSAttributedString(string: "\n"))
        return result
    }

    private func convertTable(headers: [String], alignments: [MarkdownASTNode.TableAlignment], rows: [[String]]) -> NSAttributedString {
        logger.info("convertTable: START - rendering table with \(headers.count) columns, \(rows.count) rows")
        logger.debug("convertTable: Thread.isMainThread = \(Thread.isMainThread)")
        
        // Create the exact same SwiftUI view used in message bubbles
        let renderer = MarkdownViewRenderer()
        // Use same width as diagrams (700pt with frame, 550pt max for bounds)
        let tableWidth: CGFloat = 700
        let tableView = renderer.renderTableView(headers: headers, alignments: alignments, rows: rows)
            .frame(width: tableWidth, alignment: .leading)
            .environment(\.colorScheme, .light)  // Force light mode for PDF rendering to avoid transparent colors
        
        logger.debug("convertTable: Created tableView SwiftUI component with forced light mode")
        
        // Render using the SAME method as Mermaid diagrams (bitmapImageRepForCachingDisplay)
        var capturedImage: NSImage?
        
        let renderWithBitmap: () -> NSImage? = {
            self.logger.debug("convertTable: Creating NSHostingView")
            let hostingView = NSHostingView(rootView: tableView)
            hostingView.frame = NSRect(x: 0, y: 0, width: tableWidth, height: 500)  // Initial size
            
            self.logger.debug("convertTable: Forcing layout cycles")
            // Force layout multiple times for SwiftUI to properly render (same as diagrams)
            for i in 0..<3 {
                hostingView.layout()
                hostingView.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                self.logger.debug("convertTable: Layout cycle \(i + 1) complete")
            }
            
            // Get actual size after layout
            let actualSize = hostingView.fittingSize
            self.logger.info("convertTable: Fitting size = \(actualSize.width)x\(actualSize.height)")
            let finalHeight = max(min(actualSize.height, 1000), 50)  // Min 50, max 1000
            hostingView.frame = NSRect(x: 0, y: 0, width: tableWidth, height: finalHeight)
            hostingView.layout()
            hostingView.layoutSubtreeIfNeeded()
            
            self.logger.debug("convertTable: Final frame = \(hostingView.frame)")
            
            // Render using bitmapImageRepForCachingDisplay (reliable for offscreen)
            guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                self.logger.error("convertTable: FAILED to create bitmap rep")
                return nil
            }
            
            self.logger.debug("convertTable: Created bitmap rep, size = \(bitmapRep.size)")
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)
            self.logger.debug("convertTable: Cached display to bitmap")
            
            let image = NSImage(size: hostingView.bounds.size)
            image.addRepresentation(bitmapRep)
            self.logger.info("convertTable: Created NSImage, size = \(image.size)")
            return image
        }
        
        // Handle threading exactly like Mermaid diagrams
        if Thread.isMainThread {
            capturedImage = MainActor.assumeIsolated { renderWithBitmap() }
        } else {
            DispatchQueue.main.sync {
                capturedImage = MainActor.assumeIsolated { renderWithBitmap() }
            }
        }
        
        guard let image = capturedImage else {
            logger.error("convertTable: renderWithBitmap returned nil")
            return NSAttributedString(string: "[Table rendering failed]\n\n")
        }
        
        logger.info("convertTable: Successfully rendered table as image: \(image.size.width)x\(image.size.height)")
        logger.info("convertTable: Image representations: \(image.representations.count)")
        
        // Debug: Log representation details
        if let bitmapRep = image.representations.first as? NSBitmapImageRep {
            logger.info("convertTable: BitmapRep - size: \(bitmapRep.size), pixelsWide: \(bitmapRep.pixelsWide), pixelsHigh: \(bitmapRep.pixelsHigh)")
            logger.info("convertTable: BitmapRep - bitsPerPixel: \(bitmapRep.bitsPerPixel), colorSpace: \(String(describing: bitmapRep.colorSpaceName))")
        }
        
        // Create text attachment with the image
        let attachment = NSTextAttachment()
        attachment.image = image
        
        // Scale to fit page width (same as diagrams - max 550 to account for margins)
        let maxWidth: CGFloat = 550
        if image.size.width > maxWidth {
            let scale = maxWidth / image.size.width
            attachment.bounds = CGRect(
                x: 0,
                y: 0,
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            logger.debug("convertTable: Scaled attachment bounds = \(attachment.bounds)")
        } else {
            attachment.bounds = CGRect(origin: .zero, size: image.size)
            logger.debug("convertTable: Unscaled attachment bounds = \(attachment.bounds)")
        }
        
        logger.debug("convertTable: NSTextAttachment created - hasImage: \(attachment.image != nil), bounds: \(attachment.bounds)")
        
        logger.debug("convertTable: NSTextAttachment created - hasImage: \(attachment.image != nil), bounds: \(attachment.bounds)")
        
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(attachment: attachment))
        result.append(NSAttributedString(string: "\n\n"))
        
        logger.info("convertTable: COMPLETE - returning attributed string with attachment")
        return result
    }
    
    /// Render a SwiftUI view to an NSImage
    private func renderSwiftUIViewToImage<V: View>(_ view: V, width: CGFloat) -> NSImage? {
        // Create hosting view with proper constraints
        let hostingView = NSHostingView(rootView: view.frame(width: width))
        
        // Force initial layout with a reasonable minimum height
        hostingView.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        
        // Get actual required size
        let fittingSize = hostingView.fittingSize
        let actualHeight = max(fittingSize.height, 50)  // Minimum 50pt height
        let actualSize = CGSize(width: width, height: actualHeight)
        
        // Set final frame and force layout again
        hostingView.frame = CGRect(origin: .zero, size: actualSize)
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        
        // Ensure layer-backed rendering
        hostingView.wantsLayer = true
        if hostingView.layer == nil {
            hostingView.layer = CALayer()
        }
        
        // Create bitmap with proper size
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(actualSize.width * 2),  // 2x for retina
            pixelsHigh: Int(actualSize.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            logger.error("Failed to create bitmap representation")
            return nil
        }
        
        bitmap.size = actualSize  // Set logical size for retina
        
        // Draw into bitmap context
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            logger.error("Failed to create graphics context")
            return nil
        }
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        
        // Scale for retina
        context.cgContext.scaleBy(x: 2.0, y: 2.0)
        
        // Render the view
        if let layer = hostingView.layer {
            layer.render(in: context.cgContext)
        } else {
            // Fallback: draw view directly
            hostingView.draw(hostingView.bounds)
        }
        
        NSGraphicsContext.restoreGraphicsState()
        
        // Create final image
        let image = NSImage(size: actualSize)
        image.addRepresentation(bitmap)
        
        logger.debug("Rendered SwiftUI view to image: \(actualSize.width)x\(actualSize.height)")
        return image
    }

    private func convertHorizontalRule() -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.separatorColor
        ]
        return NSAttributedString(string: "────────────────────────────────\n\n", attributes: attributes)
    }

    private func convertImage(altText: String, url: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Try to load and embed the actual image
        if let imageURL = URL(string: url),
           let image = NSImage(contentsOf: imageURL) {

            // Create attachment with the image
            let attachment = NSTextAttachment()
            attachment.image = image

            // Scale image down to fit page width if needed (never scale up)
            let maxWidth: CGFloat = 550
            let imageSize = image.size
            let scaledWidth: CGFloat
            let scaledHeight: CGFloat
            
            if imageSize.width > maxWidth {
                let scale = maxWidth / imageSize.width
                scaledWidth = imageSize.width * scale
                scaledHeight = imageSize.height * scale
                attachment.bounds = CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight)
            } else {
                scaledWidth = imageSize.width
                scaledHeight = imageSize.height
                attachment.bounds = CGRect(origin: .zero, size: imageSize)
            }

            // Center the image by calculating indent
            // Assuming content width is ~550, center by indenting
            let contentWidth: CGFloat = 550
            let indent = max(0, (contentWidth - scaledWidth) / 2)
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent = indent
            paragraphStyle.lineSpacing = 0
            paragraphStyle.paragraphSpacing = 12
            
            let centeredAttrs: [NSAttributedString.Key: Any] = [
                .paragraphStyle: paragraphStyle
            ]
            
            let imageString = NSAttributedString(attachment: attachment)
            let attributedImage = NSMutableAttributedString(attributedString: imageString)
            attributedImage.addAttributes(centeredAttrs, range: NSRange(location: 0, length: attributedImage.length))
            
            result.append(attributedImage)
            result.append(NSAttributedString(string: "\n"))
        } else {
            // Fallback: show alt text and URL if image loading fails
            let imageText = altText.isEmpty ? "[Image: \(url)]" : "[\(altText)](\(url))"
            result.append(NSAttributedString(string: imageText + "\n\n", attributes: baseAttributes()))
        }

        return result
    }

    // MARK: - Inline Elements

    private func convertInlineNode(_ node: MarkdownASTNode, baseAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch node {
        case .text(let string):
            return NSAttributedString(string: string, attributes: baseAttributes)

        case .strong(let children):
            var attrs = baseAttributes
            attrs[.font] = NSFont.boldSystemFont(ofSize: baseFontSize)
            let result = NSMutableAttributedString()
            for child in children {
                result.append(convertInlineNode(child, baseAttributes: attrs))
            }
            return result

        case .emphasis(let children):
            var attrs = baseAttributes
            let italicFont = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic), size: baseFontSize) ?? baseFont
            attrs[.font] = italicFont
            let result = NSMutableAttributedString()
            for child in children {
                result.append(convertInlineNode(child, baseAttributes: attrs))
            }
            return result

        case .inlineCode(let text):
            return convertInlineCode(text: text)

        case .link(let text, let url):
            var attrs = baseAttributes
            attrs[.foregroundColor] = NSColor.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return NSAttributedString(string: text, attributes: attrs)

        default:
            // For block elements called as inline, just convert normally
            return convertNode(node)
        }
    }

    private func convertStrong(children: [MarkdownASTNode]) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: boldFont,
            .foregroundColor: NSColor.labelColor
        ]

        let result = NSMutableAttributedString()
        for child in children {
            result.append(convertInlineNode(child, baseAttributes: attributes))
        }
        return result
    }

    private func convertEmphasis(children: [MarkdownASTNode]) -> NSAttributedString {
        let italicFont = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic), size: baseFontSize) ?? baseFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: italicFont,
            .foregroundColor: NSColor.labelColor
        ]

        let result = NSMutableAttributedString()
        for child in children {
            result.append(convertInlineNode(child, baseAttributes: attributes))
        }
        return result
    }

    private func convertInlineCode(text: String) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: codeFont,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.controlBackgroundColor
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func convertLink(text: String, url: String) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        return NSAttributedString(string: text, attributes: attributes)
    }

    private func convertStrikethrough(children: [MarkdownASTNode]) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue
        ]

        let result = NSMutableAttributedString()
        for child in children {
            result.append(convertInlineNode(child, baseAttributes: attributes))
        }
        return result
    }

    // MARK: - Helpers

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        return [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor
        ]
    }
}

// MARK: - Image Extraction Variant

/// Variant of MarkdownASTToNSAttributedString that extracts images separately instead of embedding them
/// This is useful for PDF rendering where NSTextAttachment doesn't always work correctly
@MainActor
class MarkdownASTToNSAttributedStringWithImageExtraction {
    private let logger = Logger(label: "com.sam.ui.MarkdownASTToNSAttributedStringWithImageExtraction")

    private let baseFontSize: CGFloat = 12
    private let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let baseFont = NSFont.systemFont(ofSize: 12)
    private let boldFont = NSFont.boldSystemFont(ofSize: 12)
    
    private let imageHandler: (NSImage) -> Void
    
    init(imageHandler: @escaping (NSImage) -> Void) {
        self.imageHandler = imageHandler
    }

    /// Convert single AST node to NSAttributedString, extracting images via handler
    func convert(_ node: MarkdownASTNode) -> NSAttributedString {
        return convertNode(node)
    }

    /// Convert AST nodes array to NSAttributedString, extracting images via handler
    func convert(_ nodes: [MarkdownASTNode]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for node in nodes {
            result.append(convertNode(node))
        }

        return result
    }

    private func convertNode(_ node: MarkdownASTNode) -> NSAttributedString {
        switch node {
        case .document(let children):
            let result = NSMutableAttributedString()
            for child in children {
                result.append(convertNode(child))
            }
            return result

        case .heading(let level, let children):
            let fontSize: CGFloat = {
                switch level {
                case 1: return 24
                case 2: return 20
                case 3: return 16
                case 4: return 14
                case 5: return 13
                default: return 12
                }
            }()

            let font = NSFont.boldSystemFont(ofSize: fontSize)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]

            let result = NSMutableAttributedString()
            for child in children {
                result.append(convertInlineNode(child, baseAttributes: attributes))
            }
            result.append(NSAttributedString(string: "\n\n"))
            return result

        case .paragraph(let children):
            let result = NSMutableAttributedString()
            for child in children {
                result.append(convertInlineNode(child, baseAttributes: baseAttributes()))
            }
            result.append(NSAttributedString(string: "\n\n"))
            return result

        case .blockquote(let depth, let children):
            let indent = CGFloat(depth * 20)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent = indent
            paragraphStyle.headIndent = indent

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: baseFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]

            let result = NSMutableAttributedString()
            let barString = String(repeating: "│ ", count: depth)
            result.append(NSAttributedString(string: barString, attributes: attributes))

            for child in children {
                result.append(convertNode(child))
            }
            result.append(NSAttributedString(string: "\n"))
            return result

        case .codeBlock(let language, let code):
            // Special handling for mermaid - extract as image
            if language?.lowercased() == "mermaid" {
                return convertMermaidDiagram(code: code)
            }

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent = 10
            paragraphStyle.headIndent = 10

            let attributes: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.controlBackgroundColor,
                .paragraphStyle: paragraphStyle
            ]

            let result = NSMutableAttributedString()
            if let language = language {
                let langAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                result.append(NSAttributedString(string: language + "\n", attributes: langAttributes))
            }
            result.append(NSAttributedString(string: code, attributes: attributes))
            result.append(NSAttributedString(string: "\n\n"))
            return result

        case .list(let type, let items):
            let result = NSMutableAttributedString()
            for (index, item) in items.enumerated() {
                let bullet: String
                switch type {
                case .unordered: bullet = "• "
                case .ordered: bullet = "\(item.number ?? (index + 1)). "
                case .task: bullet = (item.isChecked ?? false) ? "☑ " : "☐ "
                }

                // Calculate indent based on nesting level (20pt per level)
                let indent = CGFloat(item.indentLevel * 20)
                
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.firstLineHeadIndent = indent
                paragraphStyle.headIndent = indent + 20  // Indent content more than bullet

                let bulletAttributes: [NSAttributedString.Key: Any] = [
                    .font: baseFont,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraphStyle
                ]

                result.append(NSAttributedString(string: bullet, attributes: bulletAttributes))
                for child in item.children {
                    result.append(convertNode(child))
                }
            }
            result.append(NSAttributedString(string: "\n"))
            return result

        case .table(let headers, let alignments, let rows):
            // Render table as image using SwiftUI view (same method as diagrams)
            let renderer = MarkdownViewRenderer()
            let tableWidth: CGFloat = 700  // Match diagram width (not 550!)
            let tableView = renderer.renderTableView(headers: headers, alignments: alignments, rows: rows)
                .frame(width: tableWidth, alignment: .leading)
            
            var capturedImage: NSImage?
            
            let renderWithBitmap: () -> NSImage? = {
                let hostingView = NSHostingView(rootView: tableView)
                hostingView.frame = NSRect(x: 0, y: 0, width: tableWidth, height: 500)
                
                for _ in 0..<3 {
                    hostingView.layout()
                    hostingView.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                }
                
                let actualSize = hostingView.fittingSize
                let finalHeight = max(min(actualSize.height, 1000), 50)
                hostingView.frame = NSRect(x: 0, y: 0, width: tableWidth, height: finalHeight)
                hostingView.layout()
                hostingView.layoutSubtreeIfNeeded()
                
                guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                    return nil
                }
                hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)
                
                let image = NSImage(size: hostingView.bounds.size)
                image.addRepresentation(bitmapRep)
                return image
            }
            
            // Handle threading exactly like Mermaid diagrams
            if Thread.isMainThread {
                capturedImage = MainActor.assumeIsolated { renderWithBitmap() }
            } else {
                DispatchQueue.main.sync {
                    capturedImage = MainActor.assumeIsolated { renderWithBitmap() }
                }
            }
            
            guard let image = capturedImage else {
                return NSAttributedString(string: "[Table rendering failed]\n\n")
            }
            
            // Extract image for manual positioning
            imageHandler(image)
            
            // Return placeholder
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            return NSAttributedString(string: "[Table]\n", attributes: labelAttributes)

        case .horizontalRule:
            let attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.separatorColor
            ]
            return NSAttributedString(string: "────────────────────────────────\n\n", attributes: attributes)

        case .image(let altText, let url):
            // Load image and pass to handler for separate rendering
            if let imageURL = URL(string: url),
               let image = NSImage(contentsOf: imageURL) {
                logger.info("Extracted markdown image: \(image.size.width)x\(image.size.height)")
                imageHandler(image)
                // Add alt text placeholder
                if !altText.isEmpty {
                    let labelAttributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                    return NSAttributedString(string: "[\(altText)]\n", attributes: labelAttributes)
                }
                return NSAttributedString(string: "\n", attributes: baseAttributes())
            } else {
                // Fallback: show alt text and URL if image loading fails
                let imageText = altText.isEmpty ? "[Image: \(url)]" : "[\(altText)](\(url))"
                return NSAttributedString(string: imageText + "\n\n", attributes: baseAttributes())
            }

        case .text(let string):
            return NSAttributedString(string: string, attributes: baseAttributes())

        case .strong(let children):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: boldFont,
                .foregroundColor: NSColor.labelColor
            ]
            let result = NSMutableAttributedString()
            for child in children {
                result.append(convertInlineNode(child, baseAttributes: attributes))
            }
            return result

        case .emphasis(let children):
            let italicFont = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic), size: baseFontSize) ?? baseFont
            let attributes: [NSAttributedString.Key: Any] = [
                .font: italicFont,
                .foregroundColor: NSColor.labelColor
            ]
            let result = NSMutableAttributedString()
            for child in children {
                result.append(convertInlineNode(child, baseAttributes: attributes))
            }
            return result

        case .strikethrough(let children):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue
            ]
            let result = NSMutableAttributedString()
            for child in children {
                result.append(convertInlineNode(child, baseAttributes: attributes))
            }
            return result

        case .inlineCode(let text):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.controlBackgroundColor
            ]
            return NSAttributedString(string: text, attributes: attributes)

        case .link(let text, _):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            return NSAttributedString(string: text, attributes: attributes)

        case .softBreak:
            return NSAttributedString(string: " ")

        case .hardBreak:
            return NSAttributedString(string: "\n")
        }
    }

    /// Convert Mermaid diagram - renders to image and passes to handler instead of embedding
    @MainActor
    private func convertMermaidDiagram(code: String) -> NSAttributedString {
        logger.info("Extracting mermaid diagram as separate image")
        let result = NSMutableAttributedString()

        // Pre-parse diagram
        let parser = MermaidParser()
        let parsedDiagram = parser.parse(code)

        // Skip unsupported diagrams
        if case .unsupported = parsedDiagram {
            logger.warning("Unsupported mermaid diagram type, showing code block")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.controlBackgroundColor
            ]
            return NSAttributedString(string: "mermaid\n" + code + "\n\n", attributes: attributes)
        }

        let diagramView = MermaidDiagramView(code: code, diagram: parsedDiagram, showBackground: false)
            .frame(width: 700, alignment: .leading)

        var capturedImage: NSImage?

        // Use bitmapImageRepForCachingDisplay - most reliable for offscreen rendering
        let renderWithBitmap: () -> NSImage? = {
            let hostingView = NSHostingView(rootView: diagramView)
            hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 1000)

            // Force layout multiple times for SwiftUI to properly render
            for _ in 0..<3 {
                hostingView.layout()
                hostingView.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }

            let actualSize = hostingView.fittingSize
            let finalHeight = max(min(actualSize.height, 2000), 100)
            hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: finalHeight)
            hostingView.layout()
            hostingView.layoutSubtreeIfNeeded()

            // Render using bitmapImageRepForCachingDisplay (reliable for offscreen)
            guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                return nil
            }
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

            let image = NSImage(size: hostingView.bounds.size)
            image.addRepresentation(bitmapRep)
            return image
        }

        if Thread.isMainThread {
            capturedImage = MainActor.assumeIsolated { renderWithBitmap() }
        } else {
            DispatchQueue.main.sync {
                capturedImage = MainActor.assumeIsolated { renderWithBitmap() }
            }
        }

        if let image = capturedImage {
            logger.info("Extracted mermaid image: \(image.size.width)x\(image.size.height)")
            // Pass image to handler instead of embedding
            imageHandler(image)
            // Add placeholder text indicating where image goes
            result.append(NSAttributedString(string: "\n", attributes: baseAttributes()))
        } else {
            // Fallback: show code
            let attributes: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.controlBackgroundColor
            ]
            result.append(NSAttributedString(string: "mermaid\n" + code + "\n\n", attributes: attributes))
        }

        return result
    }

    private func convertInlineNode(_ node: MarkdownASTNode, baseAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch node {
        case .text(let string):
            return NSAttributedString(string: string, attributes: baseAttributes)

        case .strong(let children):
            var attrs = baseAttributes
            attrs[.font] = NSFont.boldSystemFont(ofSize: baseFontSize)
            let result = NSMutableAttributedString()
            for child in children {
                result.append(convertInlineNode(child, baseAttributes: attrs))
            }
            return result

        case .emphasis(let children):
            var attrs = baseAttributes
            let italicFont = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic), size: baseFontSize) ?? baseFont
            attrs[.font] = italicFont
            let result = NSMutableAttributedString()
            for child in children {
                result.append(convertInlineNode(child, baseAttributes: attrs))
            }
            return result

        case .inlineCode(let text):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: codeFont,
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.controlBackgroundColor
            ]
            return NSAttributedString(string: text, attributes: attrs)

        case .link(let text, _):
            var attrs = baseAttributes
            attrs[.foregroundColor] = NSColor.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return NSAttributedString(string: text, attributes: attrs)

        default:
            return convertNode(node)
        }
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        return [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor
        ]
    }
    
    private func alignmentForNSTextImageExtraction(_ alignment: MarkdownASTNode.TableAlignment?) -> NSTextAlignment {
        guard let alignment = alignment else { return .left }
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
    
    /// Render a SwiftUI view to an NSImage (ImageExtraction variant)
    private func renderSwiftUIViewToImageImageExtraction<V: View>(_ view: V, width: CGFloat) -> NSImage? {
        let hostingView = NSHostingView(rootView: view.frame(width: width))
        
        hostingView.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        
        let fittingSize = hostingView.fittingSize
        let actualHeight = max(fittingSize.height, 50)
        let actualSize = CGSize(width: width, height: actualHeight)
        
        hostingView.frame = CGRect(origin: .zero, size: actualSize)
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        
        hostingView.wantsLayer = true
        if hostingView.layer == nil {
            hostingView.layer = CALayer()
        }
        
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(actualSize.width * 2),
            pixelsHigh: Int(actualSize.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        
        bitmap.size = actualSize
        
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        
        context.cgContext.scaleBy(x: 2.0, y: 2.0)
        
        if let layer = hostingView.layer {
            layer.render(in: context.cgContext)
        } else {
            hostingView.draw(hostingView.bounds)
        }
        
        NSGraphicsContext.restoreGraphicsState()
        
        let image = NSImage(size: actualSize)
        image.addRepresentation(bitmap)
        
        return image
    }
}
