// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import WebKit
import OSLog

/// Prints markdown content via WKWebView for native WebKit pagination.
///
/// Renders markdown as HTML in WKWebView, renders mermaid diagrams,
/// then prints via WebKit's native print engine which handles multi-page
/// pagination. Uses the same HTML/CSS pipeline as MarkdownWebView display.
@MainActor
public enum WKWebViewPrintService {
    private static let logger = Logger(subsystem: "com.sam.ui.WebViewPrint", category: "UserInterface")

    /// Print a single message's markdown content.
    public static func printMessage(markdown: String, isFromUser: Bool, title: String) {
        let html = buildPrintHTML(markdown: markdown, isFromUser: isFromUser, title: title)
        renderAndPrint(html: html)
    }

    /// Print a full conversation (multiple messages).
    public static func printConversation(messages: [(content: String, isFromUser: Bool)], title: String) {
        var body = ""
        for (i, msg) in messages.enumerated() {
            let role = msg.isFromUser ? "You" : "SAM"
            let parser = MarkdownASTParser()
            let ast = parser.parse(msg.content)
            let msgHTML = MarkdownASTToHTML.convert(ast)
            body += """
            <div class="message \(msg.isFromUser ? "user" : "assistant")">
            <div class="role">\(role)</div>
            \(msgHTML)
            </div>
            """
            if i < messages.count - 1 {
                body += "<hr class=\"msg-sep\">"
            }
        }

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        \(mermaidScript())
        \(printBaseCSS())
        .title { font-size: 18pt; font-weight: bold; text-align: center; margin-bottom: 20pt; }
        .role { font-weight: 600; color: #555; font-size: 0.85em; margin-bottom: 2pt; }
        .user .role { color: #2563eb; }
        .message { margin-bottom: 6pt; }
        .msg-sep { border: none; border-top: 1px solid #ddd; margin: 10pt 0; }
        .mermaid-diagram { text-align: center; margin: 1em 0; }
        .mermaid-diagram svg { max-width: 100%; height: auto; }
        @media print {
            body { margin: 0.5in; }
            .message { page-break-inside: avoid; }
            .mermaid-diagram { page-break-inside: avoid; }
        }
        </style>
        </head>
        <body>
        <div class="title">\(title)</div>
        \(body)
        \(mermaidRenderJS())
        </body>
        </html>
        """

        renderAndPrint(html: html)
    }

    // MARK: - Private

    private static func buildPrintHTML(markdown: String, isFromUser: Bool, title: String) -> String {
        let parser = MarkdownASTParser()
        let ast = parser.parse(markdown)
        let bodyHTML = MarkdownASTToHTML.convert(ast)

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        \(mermaidScript())
        \(printBaseCSS())
        .print-title { font-size: 14pt; font-weight: bold; margin-bottom: 12pt; }
        .print-meta { font-size: 0.85em; color: #999; margin-bottom: 20pt; }
        .mermaid-diagram { text-align: center; margin: 1em 0; }
        .mermaid-diagram svg { max-width: 100%; height: auto; }
        @media print {
            body { margin: 0.5in; }
            .mermaid-diagram { page-break-inside: avoid; }
        }
        </style>
        </head>
        <body>
        <div class="print-title">\(title)</div>
        <div class="print-meta">\(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))</div>
        \(bodyHTML)
        \(mermaidRenderJS())
        </body>
        </html>
        """
    }

    /// Shared print-optimized base CSS (white bg, black text, proper sizing).
    private static func printBaseCSS() -> String {
        return """
        <style>
        * { box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            font-size: 12pt; line-height: 1.6; color: #000;
            margin: 0.5in; max-width: 100%; background: #fff;
        }
        h1 { font-size: 1.5em; margin: 0.6em 0 0.3em; }
        h2 { font-size: 1.3em; margin: 0.5em 0 0.3em; }
        h3 { font-size: 1.15em; margin: 0.4em 0 0.2em; }
        p { margin: 0.3em 0; }
        blockquote {
            margin: 0.4em 0; padding: 0.2em 0.8em;
            border-left: 3px solid #ccc; color: #555;
        }
        pre {
            background: #f5f5f5; border: 1px solid #ddd;
            border-radius: 4px; padding: 8pt; overflow-x: visible;
            font-family: 'SF Mono', 'Monaco', monospace; font-size: 0.85em;
            white-space: pre-wrap; word-wrap: break-word;
        }
        code { font-family: 'SF Mono', 'Monaco', monospace; font-size: 0.9em; }
        :not(pre) > code { background: #f0f0f0; padding: 1px 4px; border-radius: 2px; }
        table { border-collapse: collapse; margin: 0.4em 0; width: auto; }
        th, td { border: 1px solid #ccc; padding: 4pt 8pt; text-align: left; }
        th { background: #f0f0f0; font-weight: 600; }
        img { max-width: 100%; height: auto; }
        """
    }

    /// Mermaid CDN + initialization (light theme for print).
    /// Uses bundled mermaid.min.js from app Resources.
    private static func mermaidScript() -> String {
        return """
        <script src="mermaid.min.js"></script>
        <script>
        mermaid.initialize({startOnLoad: false, theme: 'default'});
        </script>
        """
    }

    /// JavaScript to render mermaid code blocks as SVG, then signal completion.
    /// Uses mermaid@11 async API (bundled mermaid.min.js).
    private static func mermaidRenderJS() -> String {
        return """
        <script>
        (function() {
            if (typeof mermaid === 'undefined') { window.__printReady__ = true; return; }
            var blocks = document.querySelectorAll('pre code.language-mermaid');
            if (blocks.length === 0) { window.__printReady__ = true; return; }

            var promises = [];
            var idx = 0;
            blocks.forEach(function(block) {
                try {
                    var code = block.textContent;
                    var pre = block.parentElement;
                    var i = idx++;
                    promises.push(
                        mermaid.render('mermaid-print-' + i, code).then(function(result) {
                            var div = document.createElement('div');
                            div.className = 'mermaid-diagram';
                            div.innerHTML = result.svg;
                            pre.replaceWith(div);
                        })
                    );
                } catch(e) {}
            });
            Promise.all(promises).finally(function() { window.__printReady__ = true; });
        })();
        </script>
        """
    }

    /// Render HTML in WKWebView, wait for mermaid, then print.
    private static func renderAndPrint(html: String) {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 10000))

        let delegate = PrintNavigationDelegate {
            // Wait for mermaid rendering to complete, then print
            waitForPrintReady(webView: webView)
        }

        objc_setAssociatedObject(webView, "printDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
    }

    /// Poll for window.__printReady__, then resize and print.
    private static func waitForPrintReady(webView: WKWebView, attempts: Int = 0) {
        guard attempts < 30 else {
            // Timeout - print anyway without mermaid
            logger.warning("Mermaid render timeout, printing without diagrams")
            resizeAndPrint(webView: webView)
            return
        }

        webView.evaluateJavaScript("window.__printReady__") { result, _ in
            if (result as? Bool) == true {
                resizeAndPrint(webView: webView)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    waitForPrintReady(webView: webView, attempts: attempts + 1)
                }
            }
        }
    }

    /// Measure content, resize webview, then print.
    private static func resizeAndPrint(webView: WKWebView) {
        webView.evaluateJavaScript("document.body.scrollHeight") { result, _ in
            let contentHeight = (result as? CGFloat) ?? 10000
            webView.frame.size.height = max(contentHeight + 72, 792)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
                printInfo.horizontalPagination = .fit
                printInfo.verticalPagination = .automatic
                printInfo.orientation = .portrait
                printInfo.topMargin = 36
                printInfo.bottomMargin = 36
                printInfo.leftMargin = 36
                printInfo.rightMargin = 36

                let printOp = webView.printOperation(with: printInfo)
                printOp.showsPrintPanel = true
                printOp.showsProgressPanel = true
                printOp.run()
            }
        }
    }

    /// Show error alert
    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Print Failed"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}

/// Navigation delegate that fires callback when page finishes loading.
private class PrintNavigationDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void
    private var fired = false

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !fired else { return }
        fired = true
        // Delay to allow mermaid CDN to load and initialize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.onFinish()
        }
    }
}
