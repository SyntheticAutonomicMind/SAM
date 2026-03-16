// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import AppKit
import Logging

/// Renders Mermaid diagrams to NSImage for PDF/print/export.
/// Uses MermaidWebRenderer (bundled mermaid.js) for full compatibility.
struct MermaidImageRenderer {
    private static let logger = Logger(label: "com.sam.mermaid.imagerenderer")

    /// Render mermaid code to NSImage using mermaid.js via WKWebView
    @MainActor
    static func renderDiagram(code: String, width: CGFloat = 600, isDarkMode: Bool = false) async -> NSImage? {
        logger.info("Rendering diagram to image: width=\(width), darkMode=\(isDarkMode)")
        return await MermaidWebRenderer.renderToImage(code: code, width: width, isDarkMode: isDarkMode)
    }
}
