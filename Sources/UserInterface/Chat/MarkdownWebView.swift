// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import WebKit
import OSLog

/// Renders markdown as styled HTML in a WKWebView.
///
/// Uses MarkdownASTToHTML for reliable parsing (Swift-side AST),
/// then feeds clean HTML to WKWebView for native text selection,
/// copy, and print support. Reports content width and height via
/// JS for shrink-wrap bubble sizing.
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let isFromUser: Bool
    let maxBubbleWidth: CGFloat
    /// Optional width from the JS size callback. nil means no measurement
    /// has arrived yet - the MessageBubble falls back to filling the chat
    /// column in that case. Once JS reports, the bubble shrinks to fit.
    @Binding var bubbleWidth: CGFloat?
    @Binding var bubbleHeight: CGFloat

    private static let logger = Logger(subsystem: "com.sam.ui.MarkdownWebView", category: "UserInterface")

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        config.userContentController.add(context.coordinator, name: "sizeHandler")

        let webView = NonScrollingWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.maxWidth = maxBubbleWidth
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        /// Bump the generation counter BEFORE kicking off any new page load.
        /// Any in-flight DispatchQueue.main.async blocks captured by the
        /// previous updateNSView's closure carry the OLD generation and
        /// will be rejected by the closure's generation check below. This
        /// prevents a stale size report from a cancelled page load from
        /// overwriting bubbleHeight with a value from content that's no
        /// longer rendered.
        if context.coordinator.lastMarkdown != markdown {
            context.coordinator.currentGeneration &+= 1
            context.coordinator.lastMarkdown = markdown
        }

        /// ALWAYS update onSizeChange (whether new content or same-content
        /// recycle). Captures the current bindings AND the current generation
        /// so the closure can reject size reports from cancelled page loads
        /// while still firing immediately on same-content recycling.
        let capturedGeneration = context.coordinator.currentGeneration
        context.coordinator.onSizeChange = { [weak webView, weak coordinator = context.coordinator] w, h in
            DispatchQueue.main.async {
                /// Generation check: ignore size reports from a page that has
                /// since been superseded by a newer loadHTMLString. Without
                /// this, a stale dispatch from a cancelled page load could
                /// land after the new page has reported its size, overwriting
                /// bubbleHeight with the previous content's height and
                /// producing the "taller than content" artifact.
                guard coordinator?.currentGeneration == capturedGeneration else { return }
                webView?.frame.size = CGSize(width: w, height: h)
                bubbleWidth = w
                bubbleHeight = h
            }
        }

        if context.coordinator.lastMarkdown != markdown {
            // Parse markdown AST and convert to HTML
            let parser = MarkdownASTParser()
            let ast = parser.parse(markdown)
            let bodyHTML = MarkdownASTToHTML.convert(ast)

            let isDark = NSApp.effectiveAppearance.name == .darkAqua
            let fgColor = isFromUser ? "#ffffff" : (isDark ? "#e0e0e0" : "#1a1a1a")
            let codeBg = isDark ? "#2d2d2d" : "#f5f5f5"
            let borderColor = isDark ? "#555" : "#ddd"
            let linkColor = isFromUser ? "#ffffff" : (isDark ? "#7eb8ff" : "#007acc")
            let thBgColor = isDark ? "#333" : "#f0f0f0"
            let stripedBg = isDark ? "#2a2a2a" : "#fafafa"
            let bqColor = isDark ? "#aaa" : "#666"

            let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        * { box-sizing: border-box; }
        html, body {
            overflow: hidden !important;
            margin: 0; padding: 0;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            font-size: 14px; line-height: 1.6;
            color: \(fgColor); background: transparent;
            -webkit-user-select: text; user-select: text;
            word-wrap: break-word; overflow-wrap: break-word;
        }
        #content {
            display: inline-block;
            max-width: \(Int(maxBubbleWidth))px;
            min-width: 1px;
        }
        h1 { font-size: 1.6em; margin: 0.8em 0 0.4em; }
        h2 { font-size: 1.4em; margin: 0.7em 0 0.3em; }
        h3 { font-size: 1.2em; margin: 0.6em 0 0.3em; }
        h4, h5, h6 { font-size: 1.05em; margin: 0.5em 0 0.2em; }
        p { margin: 0.4em 0; }
        blockquote {
            margin: 0.5em 0; padding: 0.3em 1em;
            border-left: 3px solid \(borderColor);
            color: \(bqColor);
        }
        pre {
            background: \(codeBg); border: 1px solid \(borderColor);
            border-radius: 6px; padding: 12px; overflow-x: auto;
            font-family: 'SF Mono', 'Monaco', 'Menlo', monospace;
            font-size: 0.9em; line-height: 1.4;
            white-space: pre-wrap;
            word-break: break-word;
        }
        code {
            font-family: 'SF Mono', 'Monaco', 'Menlo', monospace;
            font-size: 0.9em;
        }
        :not(pre) > code {
            background: \(codeBg); padding: 1px 5px;
            border-radius: 3px;
        }
        table {
            border-collapse: collapse; margin: 0.5em 0;
            width: 100%;
        }
        th, td {
            border: 1px solid \(borderColor);
            padding: 6px 12px; text-align: left;
        }
        th {
            background: \(thBgColor);
            font-weight: 600;
        }
        tr:nth-child(even) { background: \(stripedBg); }
        ul, ol { margin: 0.3em 0; padding-left: 1.8em; }
        li { margin: 0.15em 0; }
        a { color: \(linkColor); text-decoration: underline; }
        hr { border: none; border-top: 1px solid \(borderColor); margin: 1em 0; }
        img { max-width: 100%; height: auto; border-radius: 4px; }
        .task-list { list-style: none; padding-left: 0.5em; }
        .task-item { margin: 0.2em 0; }
        .task-item input { margin-right: 0.5em; }
        @media print {
            body { background: #fff !important; color: #000 !important; font-size: 12pt; }
            #content { display: block !important; }
            pre, code { background: #f5f5f5 !important; color: #000 !important; }
            table, th, td { border-color: #ccc; }
            a { color: #000; }
            blockquote { color: #555; }
        }
        </style>
        </head>
        <body>
        <div id="content">
        \(bodyHTML)
        </div>

        <script src="mermaid.min.js"></script>
        <script>
        // Initialize mermaid
        mermaid.initialize({startOnLoad: false, theme: '\(isDark ? "dark" : "default")'});

        function reportSize() {
            var el = document.getElementById('content');
            var w = Math.min(el.scrollWidth, \(Int(maxBubbleWidth)));
            var h = el.scrollHeight;
            if (w > 0 && h > 0) {
                webkit.messageHandlers.sizeHandler.postMessage({width: w, height: h});
            }
        }

        // Render mermaid diagrams then report size
        (function() {
            if (typeof mermaid === 'undefined') { reportSize(); return; }
            var blocks = document.querySelectorAll('#content pre code.language-mermaid');
            if (blocks.length === 0) { reportSize(); return; }

            var promises = [];
            var idx = 0;
            blocks.forEach(function(block) {
                try {
                    var code = block.textContent;
                    var pre = block.parentElement;
                    var i = idx++;
                    promises.push(
                        mermaid.render('mermaid-' + i, code).then(function(result) {
                            var div = document.createElement('div');
                            div.className = 'mermaid-diagram';
                            div.innerHTML = result.svg;
                            div.style.textAlign = 'center';
                            pre.parentElement.replaceChild(div, pre);
                        })
                    );
                } catch(e) {}
            });
            Promise.all(promises).finally(function() { reportSize(); });
        })();
        </script>
        </body>
        </html>
        """

            webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastMarkdown: String?
        weak var webView: WKWebView?
        /// Monotonic counter incremented before every loadHTMLString. The
        /// onSizeChange closure captures the value at the time it was set,
        /// and ignores any size report whose captured generation no longer
        /// matches. Prevents stale DispatchQueue.main.async blocks from a
        /// cancelled page load overwriting the new page's bubbleHeight.
        var currentGeneration: UInt64 = 0
        var onSizeChange: ((CGFloat, CGFloat) -> Void)?
        var maxWidth: CGFloat = 400

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "sizeHandler",
                  let dict = message.body as? [String: Any],
                  let w = dict["width"] as? CGFloat,
                  let h = dict["height"] as? CGFloat,
                  w > 0, h > 0 else { return }
            onSizeChange?(w, h)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(
                "var el=document.getElementById('content');webkit.messageHandlers.sizeHandler.postMessage({width:Math.min(el.scrollWidth,\(Int(maxWidth))),height:el.scrollHeight})",
                completionHandler: nil
            )
        }
    }
}

/// WKWebView that passes scroll events to the responder chain instead of
/// handling them internally. This allows the parent chat ScrollView to
/// scroll when the mouse is over a message bubble.
private class NonScrollingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
