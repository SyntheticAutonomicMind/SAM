// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import WebKit
import Logging

/// Renders Mermaid diagrams using bundled mermaid.js via WKWebView.
/// This is the primary rendering engine - all diagram types are handled by mermaid.js.
/// Supports both live display and image capture for export/print.
@MainActor
struct MermaidWebRenderer: NSViewRepresentable {
    let mermaidCode: String
    let isDarkMode: Bool
    let maxWidth: CGFloat?
    let onRendered: ((NSImage?) -> Void)?
    let captureMode: Bool

    private static let logger = Logger(label: "com.sam.mermaid.webrenderer")

    /// Standard display mode
    init(mermaidCode: String, isDarkMode: Bool, maxWidth: CGFloat? = nil) {
        self.mermaidCode = mermaidCode
        self.isDarkMode = isDarkMode
        self.maxWidth = maxWidth
        self.onRendered = nil
        self.captureMode = false
    }

    /// Capture mode - renders and captures as NSImage
    init(mermaidCode: String, isDarkMode: Bool, maxWidth: CGFloat? = nil, onRendered: @escaping (NSImage?) -> Void) {
        self.mermaidCode = mermaidCode
        self.isDarkMode = isDarkMode
        self.maxWidth = maxWidth
        self.onRendered = onRendered
        self.captureMode = true
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "mermaidReady")
        config.userContentController = contentController

        // Allow file access for bundled resources
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // Set initial frame with explicit width so mermaid.js renders at the right size
        let initialWidth = maxWidth ?? 600
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: initialWidth, height: 2000), configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        Self.logger.debug("Creating WKWebView for mermaid rendering, code length: \(mermaidCode.count), maxWidth: \(maxWidth.map { "\($0)" } ?? "600 (default)")")

        let html = Self.generateHTML(for: mermaidCode, isDarkMode: isDarkMode, maxWidth: maxWidth ?? initialWidth)

        // Try to load with file URL base for bundled mermaid.js access
        if let resourcePath = Bundle.main.resourcePath {
            let baseURL = URL(fileURLWithPath: resourcePath)
            webView.loadHTMLString(html, baseURL: baseURL)
        } else {
            webView.loadHTMLString(html, baseURL: nil)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.currentCode != mermaidCode ||
              context.coordinator.currentDarkMode != isDarkMode else {
            return
        }

        context.coordinator.currentCode = mermaidCode
        context.coordinator.currentDarkMode = isDarkMode

        let html = Self.generateHTML(for: mermaidCode, isDarkMode: isDarkMode, maxWidth: maxWidth ?? 600)

        if let resourcePath = Bundle.main.resourcePath {
            let baseURL = URL(fileURLWithPath: resourcePath)
            webView.loadHTMLString(html, baseURL: baseURL)
        } else {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            mermaidCode: mermaidCode,
            isDarkMode: isDarkMode,
            onRendered: onRendered,
            captureMode: captureMode
        )
    }

    // MARK: - HTML Generation

    /// Generate the HTML page with bundled mermaid.js and proper theming
    static func generateHTML(for code: String, isDarkMode: Bool, maxWidth: CGFloat? = nil) -> String {
        // Escape the code for safe embedding in HTML
        let escapedCode = code
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        let bgColor = isDarkMode ? "#1e1e1e" : "#ffffff"
        let textColor = isDarkMode ? "#d4d4d4" : "#333333"

        // Theme variables for consistent macOS look
        let themeVars: String
        if isDarkMode {
            themeVars = """
                        primaryColor: '#0A84FF',
                        primaryTextColor: '#E5E5EA',
                        primaryBorderColor: '#0A84FF',
                        lineColor: '#636366',
                        secondaryColor: '#30D158',
                        tertiaryColor: '#FF9F0A',
                        background: '#1e1e1e',
                        mainBkg: '#2c2c2e',
                        nodeBorder: '#0A84FF',
                        clusterBkg: '#2c2c2e',
                        clusterBorder: '#48484A',
                        titleColor: '#E5E5EA',
                        edgeLabelBackground: '#2c2c2e',
                        nodeTextColor: '#E5E5EA',
                        actorTextColor: '#E5E5EA',
                        actorBorder: '#0A84FF',
                        actorBkg: '#2c2c2e',
                        activationBorderColor: '#0A84FF',
                        activationBkgColor: '#3a3a3c',
                        sequenceNumberColor: '#E5E5EA',
                        sectionBkgColor: '#2c2c2e',
                        altSectionBkgColor: '#3a3a3c',
                        sectionBkgColor2: '#2c2c2e',
                        taskBorderColor: '#0A84FF',
                        taskBkgColor: '#0A84FF',
                        taskTextColor: '#ffffff',
                        taskTextDarkColor: '#E5E5EA',
                        taskTextClickableColor: '#0A84FF',
                        activeTaskBorderColor: '#0A84FF',
                        activeTaskBkgColor: '#0A84FF',
                        gridColor: '#48484A',
                        doneTaskBkgColor: '#30D158',
                        doneTaskBorderColor: '#30D158',
                        critBorderColor: '#FF453A',
                        critBkgColor: '#FF453A',
                        todayLineColor: '#FF9F0A',
                        labelColor: '#E5E5EA',
                        errorBkgColor: '#FF453A',
                        errorTextColor: '#ffffff',
                        classText: '#E5E5EA',
                        fillType0: '#0A84FF',
                        fillType1: '#30D158',
                        fillType2: '#FF9F0A',
                        fillType3: '#BF5AF2',
                        fillType4: '#FF453A',
                        fillType5: '#5AC8FA',
                        fillType6: '#FF375F',
                        fillType7: '#64D2FF',
                        pie1: '#0A84FF',
                        pie2: '#30D158',
                        pie3: '#FF9F0A',
                        pie4: '#BF5AF2',
                        pie5: '#FF453A',
                        pie6: '#5AC8FA',
                        pie7: '#FF375F',
                        pie8: '#64D2FF',
                        pie9: '#AC8E68',
                        pie10: '#FFD60A',
                        pie11: '#32ADE6',
                        pie12: '#FF6482',
                        pieTitleTextSize: '16px',
                        pieTitleTextColor: '#E5E5EA',
                        pieSectionTextSize: '14px',
                        pieSectionTextColor: '#ffffff',
                        pieLegendTextSize: '14px',
                        pieLegendTextColor: '#E5E5EA',
                        pieStrokeColor: '#48484A',
                        pieStrokeWidth: '1px',
                        pieOuterStrokeWidth: '1px',
                        pieOuterStrokeColor: '#48484A',
                        pieOpacity: '1',
                        quadrant1Fill: '#0A84FF33',
                        quadrant2Fill: '#30D15833',
                        quadrant3Fill: '#FF9F0A33',
                        quadrant4Fill: '#BF5AF233',
                        quadrant1TextFill: '#E5E5EA',
                        quadrant2TextFill: '#E5E5EA',
                        quadrant3TextFill: '#E5E5EA',
                        quadrant4TextFill: '#E5E5EA',
                        quadrantPointFill: '#0A84FF',
                        quadrantPointTextFill: '#E5E5EA',
                        quadrantXAxisTextFill: '#E5E5EA',
                        quadrantYAxisTextFill: '#E5E5EA',
                        quadrantTitleFill: '#E5E5EA',
                        xyChart: {
                            backgroundColor: 'transparent',
                            titleColor: '#E5E5EA',
                            xAxisTitleColor: '#E5E5EA',
                            xAxisLabelColor: '#AEAEB2',
                            xAxisTickColor: '#48484A',
                            xAxisLineColor: '#48484A',
                            yAxisTitleColor: '#E5E5EA',
                            yAxisLabelColor: '#AEAEB2',
                            yAxisTickColor: '#48484A',
                            yAxisLineColor: '#48484A',
                            plotColorPalette: '#0A84FF,#30D158,#FF9F0A,#BF5AF2,#FF453A,#5AC8FA,#FF375F,#64D2FF'
                        },
                        gitInv0: '#0A84FF',
                        gitInv1: '#30D158',
                        gitInv2: '#FF9F0A',
                        gitInv3: '#BF5AF2',
                        gitInv4: '#FF453A',
                        gitInv5: '#5AC8FA',
                        gitInv6: '#FF375F',
                        gitInv7: '#64D2FF',
                        git0: '#0A84FF',
                        git1: '#30D158',
                        git2: '#FF9F0A',
                        git3: '#BF5AF2',
                        git4: '#FF453A',
                        git5: '#5AC8FA',
                        git6: '#FF375F',
                        git7: '#64D2FF',
                        gitBranchLabel0: '#ffffff',
                        gitBranchLabel1: '#ffffff',
                        gitBranchLabel2: '#ffffff',
                        gitBranchLabel3: '#ffffff',
                        gitBranchLabel4: '#ffffff',
                        gitBranchLabel5: '#ffffff',
                        gitBranchLabel6: '#ffffff',
                        gitBranchLabel7: '#ffffff',
                        tagLabelColor: '#E5E5EA',
                        tagLabelBackground: '#2c2c2e',
                        tagLabelBorder: '#48484A',
                        tagLabelFontSize: '12px',
                        commitLabelColor: '#E5E5EA',
                        commitLabelBackground: '#2c2c2e',
                        commitLabelFontSize: '12px',
                        fontSize: '14px',
                        fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro", "Segoe UI", Roboto, sans-serif'
            """
        } else {
            themeVars = """
                        primaryColor: '#007AFF',
                        primaryTextColor: '#1c1c1e',
                        primaryBorderColor: '#007AFF',
                        lineColor: '#8E8E93',
                        secondaryColor: '#34C759',
                        tertiaryColor: '#FF9500',
                        background: '#ffffff',
                        mainBkg: '#f2f2f7',
                        nodeBorder: '#007AFF',
                        clusterBkg: '#f2f2f7',
                        clusterBorder: '#c7c7cc',
                        titleColor: '#1c1c1e',
                        edgeLabelBackground: '#ffffff',
                        nodeTextColor: '#1c1c1e',
                        actorTextColor: '#1c1c1e',
                        actorBorder: '#007AFF',
                        actorBkg: '#f2f2f7',
                        activationBorderColor: '#007AFF',
                        activationBkgColor: '#e5e5ea',
                        sequenceNumberColor: '#1c1c1e',
                        sectionBkgColor: '#f2f2f7',
                        altSectionBkgColor: '#e5e5ea',
                        sectionBkgColor2: '#f2f2f7',
                        taskBorderColor: '#007AFF',
                        taskBkgColor: '#007AFF',
                        taskTextColor: '#ffffff',
                        taskTextDarkColor: '#1c1c1e',
                        taskTextClickableColor: '#007AFF',
                        activeTaskBorderColor: '#007AFF',
                        activeTaskBkgColor: '#007AFF',
                        gridColor: '#c7c7cc',
                        doneTaskBkgColor: '#34C759',
                        doneTaskBorderColor: '#34C759',
                        critBorderColor: '#FF3B30',
                        critBkgColor: '#FF3B30',
                        todayLineColor: '#FF9500',
                        labelColor: '#1c1c1e',
                        errorBkgColor: '#FF3B30',
                        errorTextColor: '#ffffff',
                        classText: '#1c1c1e',
                        fillType0: '#007AFF',
                        fillType1: '#34C759',
                        fillType2: '#FF9500',
                        fillType3: '#AF52DE',
                        fillType4: '#FF3B30',
                        fillType5: '#5AC8FA',
                        fillType6: '#FF2D55',
                        fillType7: '#64D2FF',
                        pie1: '#007AFF',
                        pie2: '#34C759',
                        pie3: '#FF9500',
                        pie4: '#AF52DE',
                        pie5: '#FF3B30',
                        pie6: '#5AC8FA',
                        pie7: '#FF2D55',
                        pie8: '#64D2FF',
                        pie9: '#AC8E68',
                        pie10: '#FFD60A',
                        pie11: '#32ADE6',
                        pie12: '#FF6482',
                        pieTitleTextSize: '16px',
                        pieTitleTextColor: '#1c1c1e',
                        pieSectionTextSize: '14px',
                        pieSectionTextColor: '#ffffff',
                        pieLegendTextSize: '14px',
                        pieLegendTextColor: '#1c1c1e',
                        pieStrokeColor: '#c7c7cc',
                        pieStrokeWidth: '1px',
                        pieOuterStrokeWidth: '1px',
                        pieOuterStrokeColor: '#c7c7cc',
                        pieOpacity: '1',
                        quadrant1Fill: '#007AFF33',
                        quadrant2Fill: '#34C75933',
                        quadrant3Fill: '#FF950033',
                        quadrant4Fill: '#AF52DE33',
                        quadrant1TextFill: '#1c1c1e',
                        quadrant2TextFill: '#1c1c1e',
                        quadrant3TextFill: '#1c1c1e',
                        quadrant4TextFill: '#1c1c1e',
                        quadrantPointFill: '#007AFF',
                        quadrantPointTextFill: '#1c1c1e',
                        quadrantXAxisTextFill: '#1c1c1e',
                        quadrantYAxisTextFill: '#1c1c1e',
                        quadrantTitleFill: '#1c1c1e',
                        xyChart: {
                            backgroundColor: 'transparent',
                            titleColor: '#1c1c1e',
                            xAxisTitleColor: '#1c1c1e',
                            xAxisLabelColor: '#8E8E93',
                            xAxisTickColor: '#c7c7cc',
                            xAxisLineColor: '#c7c7cc',
                            yAxisTitleColor: '#1c1c1e',
                            yAxisLabelColor: '#8E8E93',
                            yAxisTickColor: '#c7c7cc',
                            yAxisLineColor: '#c7c7cc',
                            plotColorPalette: '#007AFF,#34C759,#FF9500,#AF52DE,#FF3B30,#5AC8FA,#FF2D55,#64D2FF'
                        },
                        gitInv0: '#007AFF',
                        gitInv1: '#34C759',
                        gitInv2: '#FF9500',
                        gitInv3: '#AF52DE',
                        gitInv4: '#FF3B30',
                        gitInv5: '#5AC8FA',
                        gitInv6: '#FF2D55',
                        gitInv7: '#64D2FF',
                        git0: '#007AFF',
                        git1: '#34C759',
                        git2: '#FF9500',
                        git3: '#AF52DE',
                        git4: '#FF3B30',
                        git5: '#5AC8FA',
                        git6: '#FF2D55',
                        git7: '#64D2FF',
                        gitBranchLabel0: '#ffffff',
                        gitBranchLabel1: '#ffffff',
                        gitBranchLabel2: '#ffffff',
                        gitBranchLabel3: '#ffffff',
                        gitBranchLabel4: '#ffffff',
                        gitBranchLabel5: '#ffffff',
                        gitBranchLabel6: '#ffffff',
                        gitBranchLabel7: '#ffffff',
                        tagLabelColor: '#1c1c1e',
                        tagLabelBackground: '#f2f2f7',
                        tagLabelBorder: '#c7c7cc',
                        tagLabelFontSize: '12px',
                        commitLabelColor: '#1c1c1e',
                        commitLabelBackground: '#f2f2f7',
                        commitLabelFontSize: '12px',
                        fontSize: '14px',
                        fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro", "Segoe UI", Roboto, sans-serif'
            """
        }

        // Use bundled mermaid.js (loaded via baseURL from Resources directory)
        // Falls back to CDN only if bundled file is missing
        let mermaidScript: String
        if Bundle.main.path(forResource: "mermaid.min", ofType: "js") != nil {
            // Relative path works because baseURL is set to Resources directory
            mermaidScript = "<script src=\"mermaid.min.js\"></script>"
        } else {
            // Fallback to CDN (should not normally happen in production)
            mermaidScript = "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js\"></script>"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            \(mermaidScript)
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    background: \(bgColor);
                    color: \(textColor);
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro", "Segoe UI", Roboto, sans-serif;
                    display: flex;
                    justify-content: center;
                    align-items: flex-start;
                    padding: 16px;
                    overflow: hidden;
                    \(maxWidth.map { "max-width: \(Int($0))px;" } ?? "")
                }
                #diagram-container {
                    max-width: 100%;
                    overflow: hidden;
                    \(maxWidth.map { "max-width: \(Int($0) - 32)px;" } ?? "")
                }
                #diagram-container svg {
                    max-width: 100%;
                    height: auto;
                    display: block;
                }
                .error-display {
                    color: #FF3B30;
                    font-size: 14px;
                    padding: 12px;
                    background: rgba(255, 59, 48, 0.1);
                    border-radius: 8px;
                    border: 1px solid rgba(255, 59, 48, 0.3);
                    font-family: monospace;
                    white-space: pre-wrap;
                }
            </style>
        </head>
        <body>
            <div id="diagram-container"></div>
            <script>
                (async function() {
                    try {
                        mermaid.initialize({
                            startOnLoad: false,
                            theme: 'base',
                            themeVariables: {
                                \(themeVars)
                            },
                            flowchart: {
                                htmlLabels: true,
                                useMaxWidth: true,
                                curve: 'basis',
                                padding: 15,
                                nodeSpacing: 50,
                                rankSpacing: 50,
                                diagramPadding: 8
                            },
                            sequence: {
                                diagramMarginX: 10,
                                diagramMarginY: 10,
                                actorMargin: 50,
                                width: 150,
                                height: 65,
                                boxMargin: 10,
                                boxTextMargin: 5,
                                noteMargin: 10,
                                messageMargin: 35,
                                mirrorActors: true,
                                useMaxWidth: true,
                                rightAngles: false,
                                showSequenceNumbers: false
                            },
                            gantt: {
                                titleTopMargin: 25,
                                barHeight: 20,
                                barGap: 4,
                                topPadding: 50,
                                leftPadding: 75,
                                gridLineStartPadding: 35,
                                fontSize: 11,
                                sectionFontSize: 11,
                                numberSectionStyles: 4,
                                useMaxWidth: true
                            },
                            pie: {
                                useMaxWidth: true,
                                textPosition: 0.75
                            },
                            er: {
                                useMaxWidth: true,
                                fontSize: 12,
                                diagramPadding: 20,
                                layoutDirection: 'TB',
                                minEntityWidth: 100,
                                minEntityHeight: 75,
                                entityPadding: 15
                            },
                            state: {
                                useMaxWidth: true,
                                dividerMargin: 10,
                                sizeUnit: 5,
                                padding: 8,
                                textHeight: 10,
                                titleShift: -15,
                                noteMargin: 10,
                                forkWidth: 70,
                                forkHeight: 7
                            },
                            journey: {
                                diagramMarginX: 50,
                                diagramMarginY: 10,
                                leftMargin: 150,
                                width: 150,
                                height: 50,
                                boxMargin: 10,
                                boxTextMargin: 5,
                                noteMargin: 10,
                                messageMargin: 35,
                                useMaxWidth: true
                            },
                            class: {
                                useMaxWidth: true,
                                diagramPadding: 8
                            },
                            mindmap: {
                                useMaxWidth: true,
                                padding: 10,
                                maxNodeWidth: 200
                            },
                            timeline: {
                                useMaxWidth: true,
                                diagramMarginX: 50,
                                diagramMarginY: 10
                            },
                            gitGraph: {
                                useMaxWidth: true,
                                mainBranchName: 'main',
                                showCommitLabel: true,
                                showBranches: true
                            },
                            requirement: {
                                useMaxWidth: true
                            },
                            quadrantChart: {
                                useMaxWidth: true,
                                chartWidth: 500,
                                chartHeight: 500,
                                titleFontSize: 20,
                                titlePadding: 10,
                                quadrantPadding: 5,
                                xAxisLabelFontSize: 16,
                                yAxisLabelFontSize: 16,
                                quadrantLabelFontSize: 16,
                                pointTextPadding: 5,
                                pointLabelFontSize: 12,
                                pointRadius: 5
                            },
                            sankey: {
                                useMaxWidth: true
                            },
                            block: {
                                useMaxWidth: true
                            },
                            packet: {
                                useMaxWidth: true
                            },
                            architecture: {
                                useMaxWidth: true
                            },
                            kanban: {
                                useMaxWidth: true
                            },
                            securityLevel: 'loose',
                            suppressErrors: false
                        });

                        const code = decodeHTMLEntities(`\(escapedCode)`);
                        const { svg } = await mermaid.render('mermaid-diagram', code);
                        document.getElementById('diagram-container').innerHTML = svg;

                        // Notify Swift that rendering is complete
                        const svgEl = document.querySelector('#diagram-container svg');
                        const bounds = svgEl ? svgEl.getBoundingClientRect() : document.body.getBoundingClientRect();
                        window.webkit.messageHandlers.mermaidReady.postMessage({
                            status: 'success',
                            width: Math.ceil(bounds.width),
                            height: Math.ceil(bounds.height)
                        });
                    } catch(e) {
                        // Show error inline
                        document.getElementById('diagram-container').innerHTML =
                            '<div class="error-display">' + escapeHTML(e.message || String(e)) + '</div>';
                        window.webkit.messageHandlers.mermaidReady.postMessage({
                            status: 'error',
                            message: e.message || String(e)
                        });
                    }
                })();

                function decodeHTMLEntities(text) {
                    const textarea = document.createElement('textarea');
                    textarea.innerHTML = text;
                    return textarea.value;
                }

                function escapeHTML(str) {
                    return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
                }
            </script>
        </body>
        </html>
        """
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var currentCode: String?
        var currentDarkMode: Bool
        let onRendered: ((NSImage?) -> Void)?
        let captureMode: Bool
        private let logger = Logger(label: "com.sam.mermaid.webrenderer.coordinator")
        private var captureAttempted = false

        init(mermaidCode: String, isDarkMode: Bool, onRendered: ((NSImage?) -> Void)?, captureMode: Bool) {
            self.currentCode = mermaidCode
            self.currentDarkMode = isDarkMode
            self.onRendered = onRendered
            self.captureMode = captureMode
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "mermaidReady",
                  let body = message.body as? [String: Any],
                  let status = body["status"] as? String else {
                return
            }

            if status == "success" {
                let width = body["width"] as? Int ?? 0
                let height = body["height"] as? Int ?? 0
                logger.info("Mermaid rendered: \(width)x\(height)")

                if captureMode, !captureAttempted {
                    captureAttempted = true
                    // webView is a weak property on WKScriptMessage - can be nil if deallocated
                    guard let webView = message.webView else {
                        logger.warning("WebView was deallocated before capture")
                        onRendered?(nil)
                        return
                    }
                    // Brief delay for paint to complete after SVG injection
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.captureImage(from: webView)
                    }
                }
            } else {
                let errorMsg = body["message"] as? String ?? "Unknown error"
                logger.error("Mermaid render error: \(errorMsg)")
                if captureMode {
                    onRendered?(nil)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.debug("WKWebView navigation finished")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.error("WKWebView navigation failed: \(error.localizedDescription)")
            if captureMode {
                onRendered?(nil)
            }
        }

        private func captureImage(from webView: WKWebView) {
            // Get the actual content size from the SVG
            webView.evaluateJavaScript("""
                (function() {
                    const svg = document.querySelector('#diagram-container svg');
                    if (svg) {
                        const rect = svg.getBoundingClientRect();
                        return { width: Math.ceil(rect.width + 32), height: Math.ceil(rect.height + 32) };
                    }
                    return { width: document.body.scrollWidth, height: document.body.scrollHeight };
                })()
            """) { [weak self] result, error in
                guard let self = self else { return }

                var captureWidth: CGFloat = 800
                var captureHeight: CGFloat = 600

                if let dims = result as? [String: Any] {
                    captureWidth = CGFloat(dims["width"] as? Int ?? 800)
                    captureHeight = CGFloat(dims["height"] as? Int ?? 600)
                }

                // Cap capture width to the WKWebView frame width (which is set to maxWidth)
                // This prevents capturing SVGs wider than the available space
                let frameWidth = webView.frame.width
                if frameWidth > 0 && captureWidth > frameWidth {
                    captureWidth = frameWidth
                }

                self.logger.debug("Capturing at \(captureWidth)x\(captureHeight)")

                // Resize WKWebView frame to match capture dimensions for accurate snapshot
                webView.frame = CGRect(x: 0, y: 0, width: captureWidth, height: captureHeight)

                let config = WKSnapshotConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: captureWidth, height: captureHeight)

                webView.takeSnapshot(with: config) { [weak self] image, error in
                    if let error = error {
                        self?.logger.error("Snapshot failed: \(error.localizedDescription)")
                        self?.onRendered?(nil)
                        return
                    }

                    if let image = image {
                        self?.logger.info("Captured image: \(image.size.width)x\(image.size.height)")
                        self?.onRendered?(image)
                    } else {
                        self?.onRendered?(nil)
                    }
                }
            }
        }
    }
}

// MARK: - Static Image Rendering (for Export/Print)

extension MermaidWebRenderer {

    /// Render mermaid code to NSImage synchronously (for PDF/print/export)
    /// Uses an offscreen WKWebView with async/await for reliable rendering.
    /// WKWebView callbacks require the main thread's GCD queue to process,
    /// which RunLoop.current.run() does NOT do. Using async/await yields
    /// control back to the main actor, allowing callbacks to fire.
    @MainActor
    static func renderToImage(code: String, width: CGFloat = 800, isDarkMode: Bool = false) async -> NSImage? {
        let logger = Logger(label: "com.sam.mermaid.webrenderer.static")
        logger.info("Static render: width=\(width), darkMode=\(isDarkMode)")

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        // Register mermaidReady handler so JS doesn't crash on postMessage
        // Use it to know exactly when mermaid rendering is complete
        let messageHandler = StaticRenderMessageHandler()
        contentController.add(messageHandler, name: "mermaidReady")

        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 2000), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        // Retain the message handler
        objc_setAssociatedObject(webView, "messageHandler", messageHandler, .OBJC_ASSOCIATION_RETAIN)

        let html = generateHTML(for: code, isDarkMode: isDarkMode)

        // Phase 1: Load HTML and wait for navigation to finish
        let navigationSuccess: Bool = await withCheckedContinuation { continuation in
            let navDelegate = StaticRenderNavigationDelegate { success in
                continuation.resume(returning: success)
            }
            webView.navigationDelegate = navDelegate
            // Must retain the delegate - store on webView via associated object
            objc_setAssociatedObject(webView, "navDelegate", navDelegate, .OBJC_ASSOCIATION_RETAIN)

            if let resourcePath = Bundle.main.resourcePath {
                let baseURL = URL(fileURLWithPath: resourcePath)
                webView.loadHTMLString(html, baseURL: baseURL)
            } else {
                webView.loadHTMLString(html, baseURL: nil)
            }

            // Safety timeout
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                // If continuation hasn't resumed yet, this will crash - but it shouldn't
                // because navDelegate always calls back on success or failure
            }
        }

        if !navigationSuccess {
            logger.warning("Navigation failed")
            return nil
        }

        logger.debug("Navigation finished, waiting for mermaid.js render...")

        // Phase 2: Wait for mermaid.js to signal rendering complete via messageHandler
        let renderSuccess = await messageHandler.waitForRender(timeout: 5.0)
        if !renderSuccess {
            logger.warning("Mermaid render timed out or failed, attempting snapshot anyway")
        } else {
            logger.debug("Mermaid.js render signaled complete")
        }

        // Phase 3: Get actual content dimensions from the rendered SVG
        var captureWidth = width
        var captureHeight: CGFloat = 600

        do {
            let result = try await webView.evaluateJavaScript("""
                (function() {
                    const svg = document.querySelector('#diagram-container svg');
                    if (svg) {
                        const rect = svg.getBoundingClientRect();
                        return { width: Math.ceil(rect.width + 32), height: Math.ceil(rect.height + 32), found: true };
                    }
                    return { width: document.body.scrollWidth, height: document.body.scrollHeight, found: false };
                })()
            """)
            if let dims = result as? [String: Any] {
                captureWidth = CGFloat(dims["width"] as? Int ?? Int(width))
                captureHeight = CGFloat(dims["height"] as? Int ?? 600)
                let found = dims["found"] as? Bool ?? false
                logger.debug("Content dimensions: \(captureWidth)x\(captureHeight), svg found: \(found)")

                // If no SVG found, mermaid had a parse error - return nil instead of capturing error page
                if !found {
                    let firstLine = code.components(separatedBy: .newlines).first ?? "empty"
                    let errorDetail = messageHandler.errorMessage ?? "unknown"
                    logger.warning("No SVG produced for '\(firstLine)' - \(errorDetail)")
                    return nil
                }
            }
        } catch {
            logger.warning("JS dimension query failed: \(error.localizedDescription)")
        }

        // Phase 4: Resize webview to match content and take snapshot
        webView.frame = CGRect(x: 0, y: 0, width: captureWidth, height: captureHeight)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = CGRect(x: 0, y: 0, width: captureWidth, height: captureHeight)

        do {
            let image = try await webView.takeSnapshot(configuration: snapshotConfig)
            logger.info("Static render complete: \(image.size.width)x\(image.size.height)")
            return image
        } catch {
            logger.error("Static snapshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Render mermaid code to SVG string via offscreen WKWebView.
    /// Uses mermaid.js to render the diagram, then extracts the SVG markup from the DOM.
    @MainActor
    static func renderToSVG(code: String, width: CGFloat = 800, isDarkMode: Bool = false) async -> String? {
        let logger = Logger(label: "com.sam.mermaid.webrenderer.svg")
        logger.info("SVG render: width=\(width), darkMode=\(isDarkMode)")

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        let messageHandler = StaticRenderMessageHandler()
        contentController.add(messageHandler, name: "mermaidReady")

        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 2000), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        objc_setAssociatedObject(webView, "messageHandler", messageHandler, .OBJC_ASSOCIATION_RETAIN)

        let html = generateHTML(for: code, isDarkMode: isDarkMode)

        let navigationSuccess: Bool = await withCheckedContinuation { continuation in
            let navDelegate = StaticRenderNavigationDelegate { success in
                continuation.resume(returning: success)
            }
            webView.navigationDelegate = navDelegate
            objc_setAssociatedObject(webView, "navDelegate", navDelegate, .OBJC_ASSOCIATION_RETAIN)

            if let resourcePath = Bundle.main.resourcePath {
                let baseURL = URL(fileURLWithPath: resourcePath)
                webView.loadHTMLString(html, baseURL: baseURL)
            } else {
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        guard navigationSuccess else {
            logger.warning("SVG render: navigation failed")
            return nil
        }

        let renderSuccess = await messageHandler.waitForRender(timeout: 5.0)
        if !renderSuccess {
            logger.warning("SVG render: mermaid timed out or failed")
        }

        // Extract SVG markup from the DOM
        do {
            let result = try await webView.evaluateJavaScript("""
                (function() {
                    const svg = document.querySelector('#diagram-container svg');
                    if (svg) {
                        return svg.outerHTML;
                    }
                    return null;
                })()
            """)
            if let svgString = result as? String {
                logger.info("SVG extracted: \(svgString.count) chars")
                return svgString
            }
            logger.warning("No SVG element found in DOM")
            return nil
        } catch {
            logger.error("SVG extraction failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Navigation delegate for static rendering
private class StaticRenderNavigationDelegate: NSObject, WKNavigationDelegate {
    private var onFinished: ((Bool) -> Void)?
    private let logger = Logger(label: "com.sam.mermaid.webrenderer.staticnav")

    init(onFinished: @escaping (Bool) -> Void) {
        self.onFinished = onFinished
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logger.debug("Static render: navigation finished")
        onFinished?(true)
        onFinished = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logger.error("Static render: navigation failed: \(error.localizedDescription)")
        onFinished?(false)
        onFinished = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        logger.error("Static render: provisional navigation failed: \(error.localizedDescription)")
        onFinished?(false)
        onFinished = nil
    }
}


/// Message handler for static rendering - receives mermaidReady postMessage from JS
@MainActor
private class StaticRenderMessageHandler: NSObject, WKScriptMessageHandler {
    private let logger = Logger(label: "com.sam.mermaid.webrenderer.staticmsg")
    private var continuation: CheckedContinuation<Bool, Never>?
    private var hasCompleted = false
    private(set) var errorMessage: String?

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "mermaidReady" else { return }

        MainActor.assumeIsolated {
            let body = message.body as? [String: Any]
            let status = body?["status"] as? String ?? "unknown"
            logger.debug("Static render message received: status=\(status)")

            if status == "error" {
                errorMessage = body?["message"] as? String
                if let msg = errorMessage {
                    logger.warning("Mermaid render error: \(msg)")
                }
            }

            guard !hasCompleted else { return }
            hasCompleted = true
            continuation?.resume(returning: status == "success")
            continuation = nil
        }
    }

    func waitForRender(timeout: TimeInterval) async -> Bool {
        if hasCompleted { return true }

        return await withCheckedContinuation { cont in
            self.continuation = cont

            // Safety timeout
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !self.hasCompleted else { return }
                self.hasCompleted = true
                self.continuation?.resume(returning: false)
                self.continuation = nil
            }
        }
    }
}
