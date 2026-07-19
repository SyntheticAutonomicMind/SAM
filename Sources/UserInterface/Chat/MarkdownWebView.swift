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

private let logger = Logger(subsystem: "com.sam.ui.MarkdownWebView", category: "UserInterface")

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let isFromUser: Bool
    let maxBubbleWidth: CGFloat
    @Binding var bubbleWidth: CGFloat
    @Binding var bubbleHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        config.userContentController.add(context.coordinator, name: "sizeHandler")
        config.userContentController.add(context.coordinator, name: "linkHandler")

        let webView = NonScrollingWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        /// Disable the internal scroll bars and zero out the content
        /// insets. Without this, WKWebView reserves ~15pt for the
        /// vertical scroller and the body's content area is narrower
        /// than the bubble's intended width, which then forces #content
        /// to wrap before reaching the bubble edge.
        if let scroll = webView.internalScrollView {
            scroll.hasHorizontalScroller = false
            scroll.hasVerticalScroller = false
            scroll.contentInsets = NSEdgeInsetsZero
        }
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.maxWidth = maxBubbleWidth
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        /// ALWAYS set onSizeChange before the guard, so the closure captures the
        /// current bindings even when the content hasn't changed. Without this,
        /// recycled views (LazyVStack) can end up with a stale closure that
        /// updates a dead binding, leaving bubbleHeight at its initial default.
        /// The closure also captures the current generation so stale size
        /// reports from a cancelled page load are rejected below.
        let capturedGeneration = context.coordinator.currentGeneration
        /// Capture the bubble's intended width so the manual frame set
        /// below uses the same width SwiftUI's .frame() will apply. If we
        /// set the WKWebView to the JS-reported w instead, SwiftUI may
        /// not always re-apply its frame on subsequent layout passes
        /// (when the height binding hasn't changed), leaving the
        /// WKWebView narrower than the bubble. Body then fills a smaller
        /// container and #content wraps early, before reaching the
        /// bubble edge.
        let intendedWidth = maxBubbleWidth
        context.coordinator.onSizeChange = { [weak webView, weak coordinator = context.coordinator] w, h in
            DispatchQueue.main.async {
                /// Generation check: ignore size reports from a page that has
                /// since been superseded by a newer loadHTMLString. Without
                /// this, a stale DispatchQueue.main.async from a cancelled
                /// page load could land after the new page has reported its
                /// size, overwriting bubbleHeight with the previous
                /// content's height and producing the "taller than content"
                /// artifact.
                guard coordinator?.currentGeneration == capturedGeneration else { return }
                webView?.frame.size = CGSize(width: intendedWidth, height: h)
                bubbleWidth = w
                bubbleHeight = h
            }
        }

        if context.coordinator.lastMarkdown == markdown {
            /// Content unchanged, but the view may have been recycled with
            /// fresh bindings. Force a JS size evaluation so the current
            /// closures fire with the correct height.
            let width = Int(maxBubbleWidth)
            webView.evaluateJavaScript(
                "var el=document.getElementById('content');if(el){webkit.messageHandlers.sizeHandler.postMessage({width:Math.min(el.scrollWidth,\(width)),height:el.scrollHeight})}",
                completionHandler: nil
            )
            return
        }
        /// Bump the generation BEFORE kicking off the new page load. Any
        /// in-flight DispatchQueue.main.async blocks captured by the
        /// previous updateNSView's closure carry the OLD generation and
        /// are rejected by the closure's generation check above. Without
        /// this, a stale size report from a cancelled page load could
        /// overwrite bubbleHeight with a value from content that's no
        /// longer rendered.
        context.coordinator.currentGeneration &+= 1
        context.coordinator.lastMarkdown = markdown

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
            display: block;
            width: 100%;
            max-width: \(Int(maxBubbleWidth))px;
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
        /// Nested lists indent properly with consistent spacing.
        li > ul, li > ol { margin: 0.15em 0; padding-left: 1.4em; }
        a { color: \(linkColor); text-decoration: underline; }
        hr { border: none; border-top: 1px solid \(borderColor); margin: 1em 0; }
        img { max-width: 100%; height: auto; border-radius: 4px; display: block; margin: 0.4em 0; }
        .task-list { list-style: none; padding-left: 0.5em; }
        .task-item { margin: 0.2em 0; }
        .task-item label.task-label { display: inline-flex; align-items: baseline; gap: 0.4em; cursor: default; }
        .task-item input[type="checkbox"] { margin: 0; vertical-align: middle; flex-shrink: 0; }
        .task-item .task-text { display: inline; }
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

        <script>
        // Intercept link clicks - open external URLs in the system browser
        // instead of navigating the WKWebView (which would replace the
        // bubble content with the link target).
        document.addEventListener('click', function(e) {
            var a = e.target;
            while (a && a.tagName !== 'A') { a = a.parentElement; }
            if (a && a.tagName === 'A' && a.href) {
                e.preventDefault();
                e.stopPropagation();
                webkit.messageHandlers.linkHandler.postMessage(a.href);
            }
        }, true);

        // reportSize: send the rendered content's dimensions back to
        // Swift so MessageBubble can size itself correctly. Called
        // immediately for non-mermaid content and from the mermaid
        // onload after diagram rendering completes.
        function reportSize() {
            var el = document.getElementById('content');
            var w = Math.min(el.scrollWidth, \(Int(maxBubbleWidth)));
            var h = el.scrollHeight;
            if (w > 0 && h > 0) {
                webkit.messageHandlers.sizeHandler.postMessage({width: w, height: h});
            }
        }

        // Mermaid library (~3MB minified) loads lazily only when the page
        // actually contains mermaid code blocks. Previously the template
        // included <script src="mermaid.min.js"></script> unconditionally,
        // which made the WebContent process fetch + parse 3MB of JS on
        // every bubble render - even for messages with no mermaid (the
        // vast majority). Combined with the 30 FPS delta sync throttle
        // during streaming, this compounded to ~20 second delays before
        // a code-block-heavy bubble finished rendering. Now we check the
        // DOM for mermaid blocks first and skip the script load entirely
        // when none exist; reportSize fires immediately so the bubble
        // appears at full size. When blocks ARE present the bubble still
        // renders the raw code right away (so the user sees content
        // immediately) and mermaid replaces it with SVG once the script
        // finishes loading.
        (function() {
            var blocks = document.querySelectorAll('#content pre code.language-mermaid');
            if (blocks.length === 0) {
                reportSize();
                return;
            }
            var s = document.createElement('script');
            s.src = 'mermaid.min.js';
            s.onload = function() {
                mermaid.initialize({startOnLoad: false, theme: '\(isDark ? "dark" : "default")'});
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
            };
            s.onerror = function() {
                reportSize();
            };
            document.head.appendChild(s);
        })();
        </script>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
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
            switch message.name {
            case "sizeHandler":
                guard let dict = message.body as? [String: Any],
                      let w = dict["width"] as? CGFloat,
                      let h = dict["height"] as? CGFloat,
                      w > 0, h > 0 else { return }
                onSizeChange?(w, h)
            case "linkHandler":
                guard let urlString = message.body as? String,
                      let url = URL(string: urlString) else { return }
                logger.info("[link-handler] opening: \(url.absoluteString)")
                NSWorkspace.shared.open(url)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(
                "var el=document.getElementById('content');webkit.messageHandlers.sizeHandler.postMessage({width:Math.min(el.scrollWidth,\(Int(maxWidth))),height:el.scrollHeight})",
                completionHandler: nil
            )
        }

        /// Intercept link taps. External http/https links open in the system
        /// browser instead of navigating the WKWebView (which would replace
        /// the bubble content with the link target). Same-page anchors and
        /// other non-http schemes fall through to default behavior.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            logger.debug("[link-tap] url=\(navigationAction.request.url?.absoluteString ?? "nil") navType=\(navigationAction.navigationType.rawValue)")
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""
            /// http/https links always open in the system browser, regardless
            /// of navigationType. Tap, long-press menu, back/forward, and any
            /// other path into an external URL all funnel through here. We
            /// cancel the WKWebView navigation so the bubble content isn't
            /// replaced. Anchor links and other schemes fall through.
            let isExternal = (scheme == "http" || scheme == "https")

            if isExternal {
                logger.info("[link-tap] opening external: \(url.absoluteString)")
                let opened = NSWorkspace.shared.open(url)
                logger.info("[link-tap] NSWorkspace.open returned: \(opened)")
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
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

    /// Expose the underlying scroll view so callers can disable the
    /// scrollers and zero the content insets. WKWebView's scrollView
    /// isn't part of the public Swift API yet, so we reach for it via
    /// the Obj-C selector.
    var internalScrollView: NSScrollView? {
        value(forKey: "scrollView") as? NSScrollView
    }
}