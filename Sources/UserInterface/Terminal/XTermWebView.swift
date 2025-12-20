// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import WebKit
import MCPFramework
import Logging

/// WKWebView-based terminal using xterm.js Provides a production-grade terminal emulator with: - Complete VT100/ANSI support via xterm.js - PTY integration via Swift <-> JavaScript bridge - AI agent accessibility via buffer query - User interaction via standard terminal.
class XTermWebView: WKWebView {
    internal var sessionId: String?
    nonisolated(unsafe) private var updateTimer: Timer?
    private var lastOutputIndex = 0
    private let logger = Logger(label: "com.sam.ui.XTermWebView")
    private var isReady = false
    private var isPolling = false
    private var pollCount = 0

    init() {
        /// Configure WKWebView.
        let config = WKWebViewConfiguration()
        /// JavaScript is enabled by default in modern WKWebView.

        /// Enable developer extras for debugging.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        super.init(frame: .zero, configuration: config)

        /// Set up message handlers for JS -> Swift communication.
        configuration.userContentController.add(MessageHandler(webView: self), name: "terminalInput")
        configuration.userContentController.add(MessageHandler(webView: self), name: "terminalResize")
        configuration.userContentController.add(MessageHandler(webView: self), name: "terminalReady")

        /// Load terminal HTML - try multiple locations.
        var htmlURL: URL?

        logger.debug("Terminal init: Looking for terminal.html...")
        logger.debug("Terminal init: Bundle.main.bundlePath = \(Bundle.main.bundlePath)")
        logger.debug("Terminal init: Bundle.main.resourcePath = \(Bundle.main.resourcePath ?? "nil")")
        logger.debug("Terminal init: Current directory = \(FileManager.default.currentDirectoryPath)")

        /// Try 1: Bundle resources (when running as .app).
        if let path = Bundle.main.path(forResource: "terminal", ofType: "html") {
            htmlURL = URL(fileURLWithPath: path)
            logger.debug("Terminal init: Found via Bundle.main.path: \(path)")
        }

        /// Try 2: In SAM.app/Contents/Resources (when running executable directly).
        if htmlURL == nil {
            let executablePath = Bundle.main.bundlePath
            let appResourcesPath = URL(fileURLWithPath: executablePath)
                .appendingPathComponent("SAM.app/Contents/Resources/terminal.html")
            if FileManager.default.fileExists(atPath: appResourcesPath.path) {
                htmlURL = appResourcesPath
                logger.debug("Terminal init: Found via .app/Contents/Resources: \(appResourcesPath.path)")
            }
        }

        /// Try 3: Relative to executable in debug builds.
        if htmlURL == nil {
            let debugPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/terminal.html")
            if FileManager.default.fileExists(atPath: debugPath.path) {
                htmlURL = debugPath
                logger.debug("Terminal init: Found via ./Resources: \(debugPath.path)")
            }
        }

        if let htmlURL = htmlURL,
           let htmlString = try? String(contentsOf: htmlURL, encoding: .utf8) {
            let resourcesDir = htmlURL.deletingLastPathComponent()
            logger.debug("Terminal init: Loading terminal.html from: \(htmlURL.path)")
            logger.debug("Terminal init: Resources directory: \(resourcesDir.path)")

            /// Check if CSS/JS files exist.
            let cssPath = resourcesDir.appendingPathComponent("xterm.css").path
            let jsPath = resourcesDir.appendingPathComponent("xterm.js").path
            let fitPath = resourcesDir.appendingPathComponent("xterm-addon-fit.js").path
            logger.debug("Terminal init: xterm.css exists = \(FileManager.default.fileExists(atPath: cssPath))")
            logger.debug("Terminal init: xterm.js exists = \(FileManager.default.fileExists(atPath: jsPath))")
            logger.debug("Terminal init: xterm-addon-fit.js exists = \(FileManager.default.fileExists(atPath: fitPath))")

            /// Inject absolute file:// URLs for xterm.js and addon WKWebView blocks relative paths even with baseURL, so we need absolute URLs.
            let xtermURL = resourcesDir.appendingPathComponent("xterm.js").absoluteString
            let fitURL = resourcesDir.appendingPathComponent("xterm-addon-fit.js").absoluteString

            let modifiedHTML = htmlString
                .replacingOccurrences(of: "<script src=\"xterm.js\"></script>",
                                      with: "<script src=\"\(xtermURL)\"></script>")
                .replacingOccurrences(of: "<script src=\"xterm-addon-fit.js\"></script>",
                                      with: "<script src=\"\(fitURL)\"></script>")

            loadHTMLString(modifiedHTML, baseURL: htmlURL)
            logger.debug("Terminal init: Loaded HTML with injected file:// URLs for scripts")
        } else {
            logger.error("Terminal init: Failed to find terminal.html in any location")
            logger.error("Terminal init: Tried: Bundle resources, .app/Contents/Resources, ./Resources/")
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Connect to PTY session.
    func connectToSession(_ sessionId: String) {
        /// Only reset if this is a DIFFERENT session.
        let isNewSession = (self.sessionId != sessionId)

        self.sessionId = sessionId

        /// Only clear terminal and reset index for NEW sessions.
        if isNewSession {
            self.lastOutputIndex = 0

            /// Clear terminal display when connecting to new session (for reset button) Only try to clear if terminal JavaScript is ready.
            if isReady {
                evaluateJavaScript("clearTerminal();") { _, error in
                    if let error = error {
                        self.logger.error("Terminal connectToSession: Failed to clear terminal: \(error)")
                    }
                }
            }
        }

        /// Start polling when ready.
        if isReady && isNewSession {
            /// Skip any output that accumulated while terminal was loading.
            Task {
                do {
                    let (_, currentIndex) = try await PTYSessionManager.shared.getOutput(sessionId: sessionId, fromIndex: 0)
                    self.lastOutputIndex = currentIndex
                } catch {
                    logger.error("Terminal connectToSession: Failed to get initial PTY buffer size: \(error)")
                }
            }

            startPolling()
        }
    }

    // MARK: - terminal as ready (called from JS)
    func markReady() {
        isReady = true

        /// Start polling if session already connected.
        if let sessionId = sessionId {
            /// Write any output that accumulated while terminal was loading This shows the initial bash prompt.
            Task {
                do {
                    let (initialOutput, currentIndex) = try await PTYSessionManager.shared.getOutput(sessionId: sessionId, fromIndex: 0)
                    if !initialOutput.isEmpty {
                        writeToTerminal(initialOutput)
                    }
                    self.lastOutputIndex = currentIndex
                } catch {
                    logger.error("Terminal markReady: Failed to get initial PTY output: \(error)")
                }
            }

            /// Only start polling if not already polling.
            if !isPolling {
                startPolling()
            }
        }
    }

    private func startPolling() {
        guard !isPolling else {
            return
        }

        isPolling = true

        /// Stop existing timer.
        updateTimer?.invalidate()

        /// Poll PTY output every 50ms.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollPTYOutput()
        }

        RunLoop.main.add(updateTimer!, forMode: .common)
    }

    private func pollPTYOutput() {
        guard let sessionId = sessionId else {
            return
        }

        pollCount += 1

        Task {
            do {
                /// Get new output since last read.
                let (output, endIndex) = try await PTYSessionManager.shared.getOutput(
                    sessionId: sessionId,
                    fromIndex: lastOutputIndex
                )

                if !output.isEmpty {
                    /// Write output to xterm.js.
                    writeToTerminal(output)
                    lastOutputIndex = endIndex
                }
            } catch {
                logger.error("pollPTYOutput: Failed to get PTY output: \(error)")
            }
        }
    }

    /// Write data to terminal (Swift -> JavaScript).
    private func writeToTerminal(_ data: String) {
        /// Use Base64 encoding to safely pass data to JavaScript without escaping issues Then use TextDecoder to properly decode UTF-8 (handles ANSI codes correctly).
        guard let dataBytes = data.data(using: .utf8) else {
            logger.error("writeToTerminal: Failed to encode terminal data as UTF-8")
            return
        }

        let base64 = dataBytes.base64EncodedString()

        let js = """
            (function() {
                try {
                    /// Decode base64 to Uint8Array.
                    const binaryString = atob('\(base64)');
                    const bytes = new Uint8Array(binaryString.length);
                    for (let i = 0; i < binaryString.length; i++) {
                        bytes[i] = binaryString.charCodeAt(i);
                    }
                    /// Properly decode UTF-8.
                    const decoded = new TextDecoder('utf-8').decode(bytes);
                    writeOutput(decoded);
                } catch(e) {
                    console.error('Failed to decode terminal data:', e);
                }
            })();
            """

        evaluateJavaScript(js) { [weak self] _, error in
            if let error = error {
                self?.logger.error("writeToTerminal: Failed to write to terminal: \(error)")
            }
        }
    }

    /// Handle input from terminal (JavaScript -> Swift -> PTY).
    func handleTerminalInput(_ data: String) {
        guard let sessionId = sessionId else {
            logger.warning("Terminal input received but no session connected")
            return
        }

        do {
            try PTYSessionManager.shared.sendInput(sessionId: sessionId, input: data)
        } catch {
            logger.error("Failed to send input to PTY: \(error)")
        }
    }

    /// Handle terminal resize (JavaScript -> Swift -> PTY).
    func handleTerminalResize(rows: Int, cols: Int) {
        guard let sessionId = sessionId else { return }

        /// Send SIGWINCH to PTY to update terminal size.
        do {
            try PTYSessionManager.shared.resizeSession(sessionId: sessionId, rows: rows, cols: cols)
        } catch {
            logger.error("Failed to resize PTY: \(error)")
        }
    }

    /// Get terminal buffer for AI agents.
    func getTerminalBuffer(completion: @escaping (String) -> Void) {
        evaluateJavaScript("getTerminalBuffer();") { result, error in
            if let error = error {
                self.logger.error("Failed to get terminal buffer: \(error)")
                completion("")
            } else if let buffer = result as? String {
                completion(buffer)
            } else {
                completion("")
            }
        }
    }

    /// Send command to terminal for AI agents.
    func sendCommand(_ command: String) {
        guard let sessionId = sessionId else {
            logger.warning("Cannot send command - no session connected")
            return
        }

        do {
            /// Send command + Enter.
            try PTYSessionManager.shared.sendInput(sessionId: sessionId, input: command + "\r")
            logger.debug("AI agent sent command: \(command)")
        } catch {
            logger.error("Failed to send command to PTY: \(error)")
        }
    }

    deinit {
        /// Swift 6: deinit cannot be @MainActor
        /// Timer is nonisolated(unsafe) so we can access it here
        updateTimer?.invalidate()
        updateTimer = nil
        logger.debug("XTermWebView deallocated")
    }
}

/// Message handler for JavaScript -> Swift communication.
private class MessageHandler: NSObject, WKScriptMessageHandler {
    weak var webView: XTermWebView?

    init(webView: XTermWebView) {
        self.webView = webView
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = webView else { return }

        switch message.name {
        case "terminalInput":
            if let data = message.body as? String {
                webView.handleTerminalInput(data)
            }

        case "terminalResize":
            if let dict = message.body as? [String: Int],
               let rows = dict["rows"],
               let cols = dict["cols"] {
                webView.handleTerminalResize(rows: rows, cols: cols)
            }

        case "terminalReady":
            webView.markReady()

        default:
            break
        }
    }
}

/// SwiftUI wrapper for XTermWebView.
struct XTermTerminalView: NSViewRepresentable {
    let sessionId: String?
    let terminalManager: TerminalManager?

    func makeNSView(context: Context) -> XTermWebView {
        let webView = XTermWebView()

        /// Set reference in TerminalManager for AI agent access.
        terminalManager?.terminalView = webView

        /// Connect to session if provided.
        if let sessionId = sessionId {
            /// Delay connection until terminal is ready - reduced delay for faster reset.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                webView.connectToSession(sessionId)
            }
        }

        return webView
    }

    func updateNSView(_ nsView: XTermWebView, context: Context) {
        /// Update session if changed.
        if let sessionId = sessionId, nsView.sessionId != sessionId {
            nsView.connectToSession(sessionId)
        }
    }

    typealias NSViewType = XTermWebView
}
