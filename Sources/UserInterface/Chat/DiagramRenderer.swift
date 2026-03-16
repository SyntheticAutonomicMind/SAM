// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import WebKit
import Logging

/// Live WKWebView renderer for Mermaid diagrams.
/// Uses bundled mermaid.js - no CDN dependency.
/// Primarily used by CachedDiagramView for initial rendering before image capture.
@MainActor
struct DiagramRenderer: NSViewRepresentable {
    let mermaidCode: String
    @Environment(\.colorScheme) private var colorScheme
    private let logger = Logger(label: "com.sam.ui.DiagramRenderer")

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        logger.debug("Creating WKWebView for diagram, code length: \(mermaidCode.count)")

        let html = MermaidWebRenderer.generateHTML(
            for: mermaidCode,
            isDarkMode: colorScheme == .dark
        )

        if let resourcePath = Bundle.main.resourcePath {
            let baseURL = URL(fileURLWithPath: resourcePath)
            webView.loadHTMLString(html, baseURL: baseURL)
        } else {
            webView.loadHTMLString(html, baseURL: nil)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.currentCode != mermaidCode else {
            return
        }

        context.coordinator.currentCode = mermaidCode

        let html = MermaidWebRenderer.generateHTML(
            for: mermaidCode,
            isDarkMode: colorScheme == .dark
        )

        if let resourcePath = Bundle.main.resourcePath {
            let baseURL = URL(fileURLWithPath: resourcePath)
            webView.loadHTMLString(html, baseURL: baseURL)
        } else {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(logger: logger)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let logger: Logger
        var currentCode: String?

        init(logger: Logger) {
            self.logger = logger
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.debug("Diagram rendered")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.error("Diagram render failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            logger.error("Diagram provisional navigation failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("Flowchart Example")
                .font(.headline)

            DiagramRenderer(mermaidCode: """
            graph TD;
                A[Start] --> B{Is it working?};
                B -->|Yes| C[Great!];
                B -->|No| D[Debug];
                D --> B;
                C --> E[End];
            """)
            .frame(height: 300)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            Text("Sequence Diagram Example")
                .font(.headline)

            DiagramRenderer(mermaidCode: """
            sequenceDiagram
                participant User
                participant SAM
                participant API
                User->>SAM: Send message
                SAM->>API: Process request
                API-->>SAM: Return response
                SAM-->>User: Display result
            """)
            .frame(height: 300)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .padding()
    }
    .frame(width: 600, height: 800)
}
