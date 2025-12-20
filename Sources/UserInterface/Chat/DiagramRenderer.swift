// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import WebKit
import Logging

/// Renders Mermaid diagrams using WKWebView and mermaid.js
@MainActor
struct DiagramRenderer: NSViewRepresentable {
    let mermaidCode: String
    private let logger = Logger(label: "com.sam.ui.DiagramRenderer")

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // JavaScript is enabled by default in WKWebView
        // Just use the default configuration

        // Create web view
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Log what we're rendering
        logger.debug("Creating WKWebView for Mermaid diagram, code length: \(mermaidCode.count)")
        logger.debug("Mermaid code preview: \(String(mermaidCode.prefix(100)))")

        // Load the HTML
        let html = generateHTML(for: mermaidCode)
        webView.loadHTMLString(html, baseURL: nil)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        /// PERFORMANCE: Equatable prevents this from being called unnecessarily
        /// This method only runs when mermaidCode changes
        /// Skip reload if coordinator confirms code matches current render
        guard context.coordinator.currentCode != mermaidCode else {
            return
        }

        context.coordinator.currentCode = mermaidCode
        let html = generateHTML(for: mermaidCode)
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(logger: logger)
    }

    /// Generate HTML with embedded Mermaid.js and diagram code
    private func generateHTML(for code: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
            <style>
                body {
                    margin: 0;
                    padding: 16px;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                    background: transparent;
                    overflow: auto;
                    display: flex;
                    justify-content: center;
                    align-items: flex-start;
                }
                .mermaid {
                    max-width: 100%;
                    overflow: visible;
                }
                .mermaid svg {
                    max-width: 100%;
                    height: auto;
                    display: block;
                }
                .error {
                    color: #ff3b30;
                    font-size: 14px;
                    padding: 12px;
                    background: rgba(255, 59, 48, 0.1);
                    border-radius: 8px;
                    border: 1px solid rgba(255, 59, 48, 0.3);
                }
            </style>
        </head>
        <body>
            <div class="mermaid">
            \(code)
            </div>
            <script>
                try {
                    mermaid.initialize({
                        startOnLoad: true,
                        theme: 'base',
                        themeVariables: {
                            primaryColor: '#007AFF',
                            primaryTextColor: '#000',
                            primaryBorderColor: '#007AFF',
                            lineColor: '#8E8E93',
                            secondaryColor: '#5AC8FA',
                            tertiaryColor: '#FFCC00',
                            fontSize: '14px',
                            fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
                        },
                        flowchart: {
                            htmlLabels: true,
                            useMaxWidth: true,
                            curve: 'basis'
                        },
                        securityLevel: 'loose'
                    });
                } catch(e) {
                    document.body.innerHTML = '<div class="error">Failed to initialize: ' + e.message + '</div>';
                }
            </script>
        </body>
        </html>
        """
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let logger: Logger
        var currentCode: String?

        init(logger: Logger) {
            self.logger = logger
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.info("Diagram rendered successfully")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.error("Diagram rendering failed: \(error.localizedDescription)")
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
