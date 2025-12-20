// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import WebKit
import Logging

/// Simple WebKit-based scraper for JavaScript-rendered pages.
/// Returns raw HTML after JavaScript execution - no complex extraction logic.
@MainActor
public class WebKitScraper: NSObject {
    private let logger = Logger(label: "com.sam.webkit")
    private var webView: WKWebView?
    private static var sharedWebView: WKWebView?
    private static var activeDelegate: NavigationDelegate?

    public override init() {
        super.init()
    }

    /// Scrape a URL with JavaScript rendering.
    /// Returns HTML content after page loads and JavaScript executes.
    /// Default wait time increased to 5s to handle Cloudflare/bot protection delays.
    public func scrape(url: String, waitSeconds: Double = 5.0) async throws -> String {
        guard let targetURL = URL(string: url) else {
            throw WebKitScraperError.invalidURL
        }

        logger.info("WebKit scraping: \(url)")

        /// Use shared WebView to avoid keychain prompts.
        /// Ephemeral session prevents cookie/cache persistence.
        let webView = try await getOrCreateWebView()

        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                /// Create navigation delegate that will resume continuation.
                /// Pass webView reference so timeout can cancel navigation
                let delegate = NavigationDelegate(
                    webView: webView,
                    waitSeconds: waitSeconds,
                    onComplete: { result in
                        continuation.resume(with: result)
                        /// Clear the delegate reference after completion.
                        Self.activeDelegate = nil
                    }
                )

                /// Keep delegate alive by storing it as a static property.
                Self.activeDelegate = delegate
                webView.navigationDelegate = delegate

                /// Start loading.
                let request = URLRequest(url: targetURL)
                webView.load(request)
            }
        }
    }

    /// Get or create shared WebView instance.
    /// Using a single shared instance prevents keychain prompts and reduces overhead.
    private func getOrCreateWebView() async throws -> WKWebView {
        if let existing = Self.sharedWebView {
            return existing
        }

        /// Create configuration for ephemeral (non-persistent) browsing.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        /// Enable JavaScript and other browser-like features.
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences

        /// Create WebView with realistic desktop dimensions.
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            configuration: config
        )

        /// Set standard browser User-Agent to prevent bot blocking.
        /// Many websites (Academy Sports, Yelp, Petco, etc.) return 403 or Access Denied
        /// when they detect automated browsers or missing User-Agent.
        /// Using Chrome User-Agent is standard practice for web scraping tools.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        Self.sharedWebView = webView
        logger.debug("Created shared WebView with browser simulation: 1920x1080, JS enabled, Chrome UA")

        return webView
    }
}

/// Navigation delegate that extracts HTML after page load + delay.
@MainActor
private class NavigationDelegate: NSObject, WKNavigationDelegate {
    private let logger = Logger(label: "com.sam.webkit.delegate")
    private weak var webView: WKWebView?
    private let waitSeconds: Double
    private let onComplete: (Result<String, Error>) -> Void
    private var hasCompleted = false
    private var timeoutTask: Task<Void, Never>?

    init(webView: WKWebView, waitSeconds: Double, onComplete: @escaping (Result<String, Error>) -> Void) {
        self.webView = webView
        self.waitSeconds = waitSeconds
        self.onComplete = onComplete
        super.init()

        /// Start absolute timeout that will forcefully stop navigation
        /// This ensures WebView doesn't hang indefinitely on non-responsive sites
        self.timeoutTask = Task { @MainActor in
            /// Wait for max timeout period (add 2s buffer for cleanup)
            try? await Task.sleep(nanoseconds: UInt64((waitSeconds + 2.0) * 1_000_000_000))

            guard !self.hasCompleted else { return }

            self.logger.warning("Absolute timeout reached (\(waitSeconds + 2.0)s) - forcefully stopping navigation")
            self.webView?.stopLoading()
            self.complete(with: .failure(WebKitScraperError.timeout))
        }
    }

    deinit {
        timeoutTask?.cancel()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !hasCompleted else { return }

        logger.debug("Page loaded, monitoring for content readiness...")

        /// Smart wait strategy: Poll for content instead of fixed delay.
        /// Check every 500ms up to maxWaitSeconds for real content to appear.
        Task { @MainActor in
            await self.waitForContentReady(webView)

            guard !self.hasCompleted else { return }

            do {
                let html = try await self.extractHTML(from: webView)
                self.complete(with: .success(html))
            } catch {
                self.complete(with: .failure(error))
            }
        }
    }

    /// Poll the page to detect when bot protection challenge completes.
    /// Checks for indicators that real content has loaded.
    private func waitForContentReady(_ webView: WKWebView) async {
        let maxWaitSeconds = waitSeconds
        let pollIntervalMs: UInt64 = 500 // Check every 500ms
        let maxAttempts = Int(maxWaitSeconds * 1000 / Double(pollIntervalMs))

        for attempt in 1...maxAttempts {
            // Check if page has meaningful content (not just challenge page)
            do {
                let hasContent = try await checkForRealContent(webView)
                if hasContent {
                    logger.debug("Content ready after \(attempt * 500)ms")
                    return // Content detected, proceed immediately
                }
            } catch {
                logger.debug("Content check failed: \(error)")
            }

            // Wait before next check
            try? await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
        }

        logger.debug("Max wait time reached (\(maxWaitSeconds)s), proceeding with extraction")
    }

    /// Check if page has actual content (not bot protection challenge).
    /// Returns true if page appears to have real content loaded.
    private func checkForRealContent(_ webView: WKWebView) async throws -> Bool {
        // JavaScript to detect if page has moved past challenge/loading screens
        let jsCheck = """
        (function() {
            // Check for common bot protection indicators (still loading)
            if (document.body.innerText.includes('Checking your browser') ||
                document.body.innerText.includes('Just a moment') ||
                document.body.innerText.includes('Please wait')) {
                return false;
            }

            // Check for minimal content (challenge page usually has very little)
            var bodyText = document.body.innerText.trim();
            if (bodyText.length < 100) {
                return false;
            }

            // Check for common e-commerce product indicators
            if (document.querySelectorAll('[class*="product"]').length > 0 ||
                document.querySelectorAll('[class*="item"]').length > 3 ||
                document.querySelectorAll('[data-product]').length > 0) {
                return true;
            }

            // If we have substantial text content, probably good
            if (bodyText.length > 500) {
                return true;
            }

            return false;
        })();
        """

        guard let result = try await webView.evaluateJavaScript(jsCheck) as? Bool else {
            return false
        }

        return result
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete(with: .failure(error))
    }

    private func extractHTML(from webView: WKWebView) async throws -> String {
        logger.debug("Extracting HTML via JavaScript")

        /// Get full HTML including dynamically generated content.
        let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String

        guard let html = html else {
            throw WebKitScraperError.extractionFailed
        }

        logger.info("Extracted \(html.count) characters of HTML")
        return html
    }

    private func complete(with result: Result<String, Error>) {
        guard !hasCompleted else { return }
        hasCompleted = true

        /// Cancel timeout task
        timeoutTask?.cancel()

        onComplete(result)
    }
}

// MARK: - Error Types

public enum WebKitScraperError: LocalizedError {
    case invalidURL
    case extractionFailed
    case timeout

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL provided to WebKit scraper"
        case .extractionFailed:
            return "Failed to extract HTML content"
        case .timeout:
            return "WebKit scraping timed out"
        }
    }
}
