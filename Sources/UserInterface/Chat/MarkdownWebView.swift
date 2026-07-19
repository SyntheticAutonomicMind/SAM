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
    @Binding var bubbleHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        Self.appendDebug("[MERMAID_DEBUG] makeNSView called markdownLen=\(markdown.count)")
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        /// Register a custom URL scheme handler so the bubble page can fetch
        /// bundled resources (mermaid.min.js, future helpers) via
        /// "sam-bundle://". Pages loaded with loadHTMLString on macOS
        /// have a null origin, so file:// fetches from a baseURL are blocked
        /// even with allowFileAccessFromFileURLs set; a same-scheme resource
        /// load via WKURLSchemeHandler sidesteps that policy entirely.
        config.setURLSchemeHandler(MermaidResourceSchemeHandler(), forURLScheme: MermaidResourceSchemeHandler.scheme)
        config.userContentController.add(context.coordinator, name: "sizeHandler")
        config.userContentController.add(context.coordinator, name: "linkHandler")

        let webView = NonScrollingWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.maxWidth = maxBubbleWidth
        return webView
    }

        func updateNSView(_ webView: WKWebView, context: Context) {
        Self.appendDebug("[MERMAID_DEBUG] updateNSView TOP markdownLen=\(markdown.count) lastMarkdownLen=\(context.coordinator.lastMarkdown?.count ?? -1)")
        /// Track whether content actually changed BEFORE we mutate any
        /// state. The bump-then-load pattern needs the original change
        /// status available for both decisions - if we set lastMarkdown
        /// during the bump and then test lastMarkdown == markdown, the
        /// condition is always true (we just wrote that value), so the
        /// HTML load path would never run. Capturing isChanged up front
        /// preserves the distinction: changed -> bump + load HTML,
        /// unchanged -> force JS size evaluation only.
        let isChanged = context.coordinator.lastMarkdown != markdown

        /// Bump the generation counter BEFORE capturing it in the closure
        /// when content changes. The closure compares its captured value
        /// against the live currentGeneration at the time the size report
        /// fires; if the bump happened after the capture, the live value
        /// would always be one ahead and every legitimate size report
        /// from the current page would be rejected (bubbleHeight stays
        /// at its initial 28pt). Bumping first makes the closure capture
        /// the NEW generation so the page that THIS updateNSView started
        /// can fire reportSize successfully. Bumping only on changed
        /// content means the same-content recycle path keeps its
        /// capturedGeneration == currentGeneration invariant intact.
        if isChanged {
            context.coordinator.currentGeneration &+= 1
        }

        /// ALWAYS set onSizeChange before the guard, so the closure captures the
        /// current bindings even when the content hasn't changed. Without this,
        /// recycled views (LazyVStack) can end up with a stale closure that
        /// updates a dead binding, leaving bubbleHeight at its initial default.
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
        context.coordinator.onSizeChange = { [weak webView, weak coordinator = context.coordinator] _, h in
            DispatchQueue.main.async {
                /// Generation check: ignore size reports from a page that has
                /// since been superseded by a newer loadHTMLString. Without
                /// this, a stale dispatch from a cancelled page load could
                /// land after the new page has reported its size, overwriting
                /// bubbleHeight with the previous content's height and
                /// producing the "taller than content" artifact.
                guard coordinator?.currentGeneration == capturedGeneration else { return }
                webView?.frame.size = CGSize(width: intendedWidth, height: h)
                bubbleHeight = h
            }
        }

        if context.coordinator.lastMarkdown == markdown {
            /// Content unchanged, but the view may have been recycled with
            /// fresh bindings. Force a JS size evaluation so the current
            /// closures fire with the correct height.
            let width = Int(maxBubbleWidth)
            webView.evaluateJavaScript(
                "var el=document.getElementById('content');if(el){webkit.messageHandlers.sizeHandler.postMessage({width:Math.min(el.scrollWidth,\(width)),height:el.scrollHeight+8})}",
                completionHandler: nil
            )
            return
        }

        context.coordinator.lastMarkdown = markdown

        // Parse markdown AST and convert to HTML
        let parser = MarkdownASTParser()
        let ast = parser.parse(markdown)
        let bodyHTML = MarkdownASTToHTML.convert(ast)

        /// Detect mermaid code blocks before building the HTML template.
        /// The script tag for the bundled mermaid.min.js is only included
        /// when the bubble actually has mermaid blocks - the 3MB library
        /// is otherwise a noticeable cost on every chat bubble. Static
        /// <script> tags parsed from the initial HTML are allowed by
        /// WKWebView without any extra configuration; dynamic
        /// document.head.appendChild fetches from a loadHTMLString
        /// document (null origin) are blocked, which is why the previous
        /// JS-side lazy-load IIFE silently failed and diagrams showed up
        /// as raw code in chat while still rendering in print and export
        /// (which use static script tags).
        let hasMermaid = markdown.range(of: "```mermaid", options: .caseInsensitive) != nil

        logger.info("[MERMAID_DEBUG] hasMermaid=\(hasMermaid), markdownLen=\(markdown.count), hasMermaidScript=\(bodyHTML.contains("language-mermaid"))")

        /// TEMP DIAGNOSTIC: also write to /tmp so we can read the value
        /// regardless of os_log routing. The Logger call doesn't seem
        /// to be making it into server.log.
        let lastLen = context.coordinator.lastMarkdown?.count ?? -1
        Self.appendDebug("[MERMAID_DEBUG] updateNSView HAS_MERMAID hasMermaid=\(hasMermaid) markdownLen=\(markdown.count) lastLen=\(lastLen)")

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
            /// Pad the body so the line box doesn't sit flush against
            /// the WKWebView's edges. Without this, on the last (or
            /// only) line, descenders (p, g, j, q, y) extend below
            /// the line box's reported bottom edge by a hair, and the
            /// WKWebView's content view clips them when the frame is
            /// set to exactly scrollHeight. 4px top/bottom gives 8px
            /// of breathing room AND centers the visible text row
            /// within the bubble's 12pt vertical padding for content
            /// with descenders. The matching `+ 8` in the JS size
            /// callback compensates for the fact that scrollHeight
            /// (on #content) only reports content height - it does
            /// NOT include this body's padding - so without the
            /// manual addition the WKWebView ends up 8pt short and
            /// the line box bottom gets clipped.
            padding: 4px 0;
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

        /// Note the three slashes: sam-bundle:///mermaid.min.js.
        /// For "scheme://host/path" forms, "sam-bundle://mermaid.min.js"
        /// puts the file in the URL host (url.path is ""). Our handler
        /// resolves the file via url.path, so we use three slashes to
        /// put the file in url.path instead ("mermaid.min.js"). Standard
        /// same-scheme fetch, same routing - just correct path storage.
        \(hasMermaid ? "<script src=\"\(MermaidResourceSchemeHandler.scheme):///mermaid.min.js\"></script>" : "")

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
            /// scrollHeight on #content reports only the content area
            /// height - it does NOT include the body's 4px top/bottom
            /// padding set in CSS. Without this addition the Swift
            /// callback sizes the WKWebView to the content height,
            /// the body overflows by 8px at the bottom, and
            /// overflow:hidden on body clips the descenders (p, g,
            /// j, q, y) of the last (or only) line.
            var h = el.scrollHeight + 8;
            if (w > 0 && h > 0) {
                webkit.messageHandlers.sizeHandler.postMessage({width: w, height: h});
            }
        }

        // Mermaid render. The Swift template conditionally includes
        // <script src="mermaid.min.js"></script> above this script when
        // the bubble contains mermaid blocks; the static tag is parsed
        // as part of the initial HTML load so WKWebView allows the file://
        // fetch. If mermaid isn't loaded (no script tag), this falls
        // through to reportSize() so the bubble still measures itself.
        // When blocks ARE present the bubble renders the raw code first
        // and mermaid replaces each block with SVG as it renders.
        (function() {
            var blocks = document.querySelectorAll('#content pre code.language-mermaid');
            if (blocks.length === 0) {
                reportSize();
                return;
            }
            if (typeof mermaid === 'undefined') {
                reportSize();
                return;
            }
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
        })();
        </script>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)

        /// Diagnostic: query the page state 2s after load and log it.
        /// Captures whether mermaid.min.js actually fetched, how many
        /// .language-mermaid blocks exist, and the body scroll height.
        /// Will be removed once the underlying render failure is identified.
        let diagGeneration = context.coordinator.currentGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak webView, weak coordinator = context.coordinator] in
            guard let webView = webView,
                  coordinator?.currentGeneration == diagGeneration else { return }
            webView.evaluateJavaScript("""
                (function() {
                    var script = document.querySelector('script[src^="sam-bundle://"], script[src="mermaid.min.js"]');
                    return JSON.stringify({
                        mermaidLoaded: typeof mermaid,
                        blocks: document.querySelectorAll('#content pre code.language-mermaid').length,
                        hasScriptTag: !!script,
                        scriptSrc: script ? script.src : null,
                        bodyScrollHeight: document.body.scrollHeight
                    });
                })()
            """) { result, error in
                if let result = result as? String {
                    logger.info("[MERMAID_DEBUG] pageState=\(result)")
                } else if let error = error {
                    logger.error("[MERMAID_DEBUG] evalError=\(error.localizedDescription)")
                } else {
                    logger.warning("[MERMAID_DEBUG] no result")
                }
            }
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
                "var el=document.getElementById('content');webkit.messageHandlers.sizeHandler.postMessage({width:Math.min(el.scrollWidth,\(Int(maxWidth))),height:el.scrollHeight+8})",
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

    /// Append a single line to /tmp/sam_mermaid_debug.log so multiple
    /// MarkdownWebView observations accumulate in order instead of
    /// overwriting each other (Swift's write(toFile:) always overwrites).
    private static func appendDebug(_ message: String) {
        let entry = (message + "\n").data(using: .utf8) ?? Data()
        let path = "/tmp/sam_mermaid_debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? (message + "\n").write(toFile: path, atomically: true, encoding: .utf8)
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