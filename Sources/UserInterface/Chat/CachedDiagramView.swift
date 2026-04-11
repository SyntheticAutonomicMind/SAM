// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import WebKit
import Logging

/// Cached diagram view that renders once to image, then displays cached result.
/// Uses MermaidWebRenderer (bundled mermaid.js) for rendering.
/// Solves jerkiness caused by WKWebView recreation during LazyVStack scroll.
struct CachedDiagramView: View {
    let mermaidCode: String
    @Binding var cache: [String: NSImage]
    @Environment(\.colorScheme) private var colorScheme

    private let logger = Logger(label: "com.sam.ui.CachedDiagramView")

    @State private var isRendering = false
    @State private var renderError: String?
    @State private var showingZoomOverlay = false

    var body: some View {
        Group {
            if let cachedImage = cache[mermaidCode] {
                // Use cached image - instant display
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: cachedImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(cachedImage.size.width, 560))
                        .padding(.vertical, 4)

                    // Zoom hint icon
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(5)
                        .background(.ultraThinMaterial)
                        .cornerRadius(4)
                        .padding(8)
                        .opacity(0.7)
                }
                .onTapGesture {
                    showingZoomOverlay = true
                }
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .sheet(isPresented: $showingZoomOverlay) {
                    DiagramZoomOverlay(
                        mermaidCode: mermaidCode,
                        initialImage: cachedImage,
                        isPresented: $showingZoomOverlay
                    )
                    .frame(minWidth: 800, minHeight: 600)
                }
            } else if let error = renderError {
                errorView(error)
            } else {
                renderingView
            }
        }
    }

    private var renderingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Rendering diagram...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .task {
            await renderOffscreen()
        }
    }

    private func renderOffscreen() async {
        guard !isRendering else { return }
        isRendering = true

        let isDark = colorScheme == .dark
        let image = await MermaidWebRenderer.renderToImage(
            code: mermaidCode,
            width: 700,
            isDarkMode: isDark
        )

        if let image = image {
            cache[mermaidCode] = image
            logger.info("Cached diagram: \(image.size.width)x\(image.size.height)")
        } else {
            renderError = "Failed to render diagram"
            logger.error("Diagram render returned nil")
        }
        isRendering = false
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
                .font(.system(size: 32))
            Text("Diagram Render Failed")
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}
