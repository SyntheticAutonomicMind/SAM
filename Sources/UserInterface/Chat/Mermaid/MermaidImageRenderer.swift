// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import AppKit

/// Utility to render SwiftUI views as NSImages for PDF/print export
struct MermaidImageRenderer {
    /// Render a MermaidDiagramView to an NSImage
    /// - Parameters:
    ///   - code: The mermaid code to render
    ///   - width: Desired width of the rendered image
    /// - Returns: Rendered NSImage, or nil if rendering fails
    @MainActor
    static func renderDiagram(code: String, width: CGFloat = 600) -> NSImage? {
        // Parse the diagram first to verify it's valid
        let parser = MermaidParser()
        let diagram = parser.parse(code)

        // Skip rendering if it's unsupported
        if case .unsupported = diagram {
            return nil
        }

        // CRITICAL: Use pre-parsed initializer so diagram renders immediately
        // The standard init waits for .onAppear which doesn't fire for offscreen rendering
        let diagramView = MermaidDiagramView(code: code, diagram: diagram, showBackground: false)

        // Wrap in a container with fixed width to ensure proper layout
        let containerView = diagramView
            .frame(width: width)
            .padding()

        // Create NSHostingView to convert SwiftUI to NSView
        let hostingView = NSHostingView(rootView: containerView)
        hostingView.frame = CGRect(x: 0, y: 0, width: width + 40, height: 1500)  // Generous initial height

        // Force layout with longer delays for complex diagrams
        // Complex flowcharts need time for edge routing and obstacle avoidance calculations
        for cycle in 0..<5 {
            hostingView.layout()
            hostingView.layoutSubtreeIfNeeded()
            
            // Longer delay for complex layouts (0.15s vs 0.1s)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            
            // Check if rendering is stabilizing (fittingSize not changing much)
            let currentSize = hostingView.fittingSize
            if cycle > 2 && currentSize.height > 100 {
                // If we have a reasonable height after 3 cycles, we're probably done
                // One more cycle to be sure
                hostingView.layout()
                hostingView.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
                break
            }
        }

        // Calculate actual needed height after layout
        let fittingSize = hostingView.fittingSize
        let finalHeight = max(min(fittingSize.height, 2000), 400) // Cap between 400-2000
        hostingView.frame = CGRect(x: 0, y: 0, width: width + 40, height: finalHeight)

        // Final layout pass
        hostingView.layout()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        // Render to bitmap
        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return nil
        }

        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        // Create NSImage from bitmap
        let image = NSImage(size: hostingView.bounds.size)
        image.addRepresentation(bitmapRep)

        return image
    }
}
