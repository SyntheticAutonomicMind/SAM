// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import WebKit
import Logging

/// Cached diagram view that renders once to image, then displays cached result
/// Solves jerkiness caused by WKWebView recreation during LazyVStack scroll
struct CachedDiagramView: View {
    let mermaidCode: String
    @Binding var cache: [String: NSImage]

    private let logger = Logger(label: "com.sam.ui.CachedDiagramView")

    @State private var isRendering = false
    @State private var renderError: String?

    var body: some View {
        Group {
            if let cachedImage = cache[mermaidCode] {
                /// Use cached image - instant display, no WKWebView
                Image(nsImage: cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else if let error = renderError {
                /// Render failed - show error
                errorView(error)
            } else {
                /// First render - use WKWebView and capture
                renderingView
            }
        }
    }

    private var renderingView: some View {
        ZStack {
            /// Actual WKWebView (hidden while rendering)
            DiagramRendererWithCapture(
                mermaidCode: mermaidCode,
                onImageCaptured: { image in
                    cache[mermaidCode] = image
                    logger.info("Cached diagram image: \(image.size.width)x\(image.size.height)")
                },
                onError: { error in
                    renderError = error
                    logger.error("Diagram render failed: \(error)")
                }
            )
            .frame(height: 400)
            .opacity(0.01) /// Nearly invisible while rendering

            /// Loading indicator
            if !isRendering {
                ProgressView("Rendering diagram...")
                    .frame(height: 400)
                    .onAppear {
                        isRendering = true
                    }
            }
        }
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

/// DiagramRenderer variant that captures rendered output as image
private struct DiagramRendererWithCapture: NSViewRepresentable {
    let mermaidCode: String
    let onImageCaptured: (NSImage) -> Void
    let onError: (String) -> Void

    private let logger = Logger(label: "com.sam.ui.DiagramRendererWithCapture")

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        logger.debug("Creating WKWebView for capture, code length: \(mermaidCode.count)")

        let html = generateHTML(for: mermaidCode)
        webView.loadHTMLString(html, baseURL: nil)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        /// No updates needed - render once and capture
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            mermaidCode: mermaidCode,
            onImageCaptured: onImageCaptured,
            onError: onError,
            logger: logger
        )
    }

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
                    background: white;
                    overflow: visible;
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

                    /// Notify parent when render complete
                    window.webkit.messageHandlers.renderComplete.postMessage('success');
                } catch(e) {
                    window.webkit.messageHandlers.renderComplete.postMessage('error: ' + e.message);
                }
            </script>
        </body>
        </html>
        """
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let mermaidCode: String
        let onImageCaptured: (NSImage) -> Void
        let onError: (String) -> Void
        let logger: Logger

        private var captureAttempted = false

        init(
            mermaidCode: String,
            onImageCaptured: @escaping (NSImage) -> Void,
            onError: @escaping (String) -> Void,
            logger: Logger
        ) {
            self.mermaidCode = mermaidCode
            self.onImageCaptured = onImageCaptured
            self.onError = onError
            self.logger = logger
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.debug("WKWebView finished loading, waiting for mermaid.js render...")

            /// Wait for mermaid.js to render, then capture
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.captureImage(from: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.error("WKWebView navigation failed: \(error.localizedDescription)")
            onError(error.localizedDescription)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "renderComplete" {
                if let body = message.body as? String {
                    if body.starts(with: "error") {
                        logger.error("Mermaid render failed: \(body)")
                        onError(body)
                    } else {
                        logger.info("Mermaid render complete")
                    }
                }
            }
        }

        private func captureImage(from webView: WKWebView) {
            guard !captureAttempted else { return }
            captureAttempted = true

            /// Get actual content size
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] (result, error) in
                guard let self = self else { return }

                let height = (result as? CGFloat) ?? 400
                let width = webView.bounds.width

                logger.debug("Capturing diagram: \(width)x\(height)")

                /// Create bitmap representation
                let config = WKSnapshotConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: width, height: height)

                webView.takeSnapshot(with: config) { [weak self] image, error in
                    guard let self = self else { return }

                    if let error = error {
                        logger.error("Snapshot failed: \(error.localizedDescription)")
                        onError(error.localizedDescription)
                        return
                    }

                    if let image = image {
                        logger.info("Captured diagram successfully")
                        onImageCaptured(image)
                    } else {
                        logger.error("Snapshot returned nil image")
                        onError("Failed to capture diagram")
                    }
                }
            }
        }
    }
}
