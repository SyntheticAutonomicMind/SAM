// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import AppKit
import Logging

/// Utility to render SwiftUI views as NSImages for PDF/print export
struct MermaidImageRenderer {
    private static let logger = Logger(label: "com.sam.mermaid.imagerenderer")
    
    /// Render a MermaidDiagramView to an NSImage
    /// - Parameters:
    ///   - code: The mermaid code to render
    ///   - width: Desired width of the rendered image
    /// - Returns: Rendered NSImage, or nil if rendering fails
    @MainActor
    static func renderDiagram(code: String, width: CGFloat = 600) -> NSImage? {
        logger.info("Starting PDF render: width=\(width)")
        
        // Parse the diagram first to verify it's valid
        let parser = MermaidParser()
        let diagram = parser.parse(code)

        // Skip rendering if it's unsupported
        if case .unsupported = diagram {
            logger.warning("Skipping unsupported diagram type")
            return nil
        }

        // CRITICAL: Use pre-parsed initializer so diagram renders immediately
        // The standard init waits for .onAppear which doesn't fire for offscreen rendering
        let diagramView = MermaidDiagramView(code: code, diagram: diagram, showBackground: false)

        // Wrap in a container with fixed width to ensure proper layout
        let containerView = diagramView
            .frame(width: width)
            .padding()

        // INCREASED: Use much larger initial dimensions for complex diagrams
        // Old: 550px wide × 1500px tall → insufficient for complex flowcharts
        // New: 800px wide × 3000px tall → more room for layout calculations
        let initialWidth = width + 40
        let initialHeight: CGFloat = 3000
        
        // Create NSHostingView to convert SwiftUI to NSView
        let hostingView = NSHostingView(rootView: containerView)
        hostingView.frame = CGRect(x: 0, y: 0, width: initialWidth, height: initialHeight)
        logger.debug("Initial frame: width=\(initialWidth), height=\(initialHeight)")

        // Force layout with longer delays for complex diagrams
        // Complex flowcharts need time for edge routing and obstacle avoidance calculations
        var lastHeight: CGFloat = 0
        for cycle in 0..<5 {
            hostingView.layout()
            hostingView.layoutSubtreeIfNeeded()
            
            // Longer delay for complex layouts (0.15s vs 0.1s)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            
            // Check if rendering is stabilizing (fittingSize not changing much)
            let currentSize = hostingView.fittingSize
            logger.debug("Layout cycle \(cycle): fittingSize=\(currentSize.width)×\(currentSize.height)")
            
            if cycle > 2 && currentSize.height > 100 {
                // Check if height stabilized (changed less than 5%)
                let heightChange = abs(currentSize.height - lastHeight)
                let changePercent = heightChange / max(currentSize.height, 1) * 100
                
                if changePercent < 5 {
                    logger.info("Layout stabilized at cycle \(cycle): height=\(currentSize.height), change=\(changePercent)%")
                    // One more cycle to be sure
                    hostingView.layout()
                    hostingView.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
                    break
                }
            }
            lastHeight = currentSize.height
        }

        // Calculate actual needed height after layout
        let fittingSize = hostingView.fittingSize
        logger.info("Final fittingSize after layout: \(fittingSize.width)×\(fittingSize.height)")
        
        // INCREASED: Allow up to 4000px height for very complex diagrams
        // Old cap: 2000px → clipped large diagrams
        // New cap: 4000px → accommodate complex flowcharts
        let finalHeight = max(min(fittingSize.height, 4000), 400)
        let finalWidth = max(fittingSize.width, initialWidth)
        
        hostingView.frame = CGRect(x: 0, y: 0, width: finalWidth, height: finalHeight)
        logger.info("Final frame before render: \(finalWidth)×\(finalHeight)")

        // Final layout pass
        hostingView.layout()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        // Render to bitmap
        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            logger.error("Failed to create bitmap representation")
            return nil
        }
        
        logger.debug("Bitmap representation created: \(bitmapRep.pixelsWide)×\(bitmapRep.pixelsHigh)")

        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        // Create NSImage from bitmap
        let image = NSImage(size: hostingView.bounds.size)
        image.addRepresentation(bitmapRep)
        
        logger.info("Successfully rendered image: \(image.size.width)×\(image.size.height)")

        return image
    }
}
