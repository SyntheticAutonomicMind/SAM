// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import WebKit
import OSLog

/// Serves files from Bundle.main.resourcePath under a custom URL scheme
/// (sam-bundle://<path>). Registered on MarkdownWebView's WKWebViewConfiguration
/// so chat-bubble scripts and other static resources can be loaded without
/// relying on file:// fetches - which WKWebView on macOS restricts in subtle
/// ways for pages loaded via loadHTMLString (null-origin documents cannot
/// freely fetch file:// resources even when a baseURL is provided).
///
/// Paths are resolved against Bundle.main.resourcePath, which is also where
/// Makefile copies bundled JS resources (mermaid.min.js, xterm.js, etc.).
/// Unknown paths return 404 via WKURLSchemeTask.didFailWithError so the
/// page sees a normal script-load failure rather than silently hanging.
private let schemeLogger = Logger(subsystem: "com.sam.ui.MermaidScheme", category: "UserInterface")

final class MermaidResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "sam-bundle"

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "MermaidResourceScheme", code: 0))
            return
        }

        /// Resolve the resource path. Form is either:
        ///   sam-bundle:///mermaid.min.js  ->  url.host="", url.path="/mermaid.min.js"
        ///   sam-bundle://mermaid.min.js   ->  url.host="mermaid.min.js", url.path=""
        /// We support both by combining host and path. The MarkdownWebView
        /// template uses the three-slash form so the file lands in url.path;
        /// the two-slash form is accepted for callers that prefer it.
        guard let resourcePath = Bundle.main.resourcePath else {
            urlSchemeTask.didFailWithError(NSError(domain: "MermaidResourceScheme", code: 1))
            return
        }

        let host = url.host ?? ""
        let path = url.path
        let combined = host + path
        let relativePath = combined.hasPrefix("/") ? String(combined.dropFirst()) : combined
        let fileURL = URL(fileURLWithPath: resourcePath).appendingPathComponent(relativePath)

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            schemeLogger.warning("[scheme] 404 for \(url.absoluteString) -> \(fileURL.path)")
            urlSchemeTask.didFailWithError(NSError(domain: "MermaidResourceScheme", code: 404))
            return
        }

        let mimeType = Self.mimeType(for: fileURL.pathExtension)
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No long-running work to cancel - file reads complete in microseconds.
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "js": return "application/javascript"
        case "mjs": return "application/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "html": return "text/html"
        default: return "application/octet-stream"
        }
    }

}
