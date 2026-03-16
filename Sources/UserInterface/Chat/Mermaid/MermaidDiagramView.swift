// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging

/// Main Mermaid diagram view - renders using bundled mermaid.js via WKWebView.
/// All diagram types (flowchart, sequence, class, state, ER, gantt, pie,
/// journey, mindmap, timeline, quadrant, requirement, gitGraph, xychart,
/// C4, sankey, block, kanban, architecture, etc.) are handled by mermaid.js.
///
/// Streaming-safe: waits for code to stabilize before attempting render.
@MainActor
struct MermaidDiagramView: View {
    let code: String
    let showBackground: Bool
    private let logger = Logger(label: "com.sam.mermaid")

    @Environment(\.colorScheme) private var colorScheme

    @State private var cachedImage: NSImage?
    @State private var renderedHeight: CGFloat = 300
    @State private var renderError: String?
    @State private var isRendering = false
    @State private var lastRenderedCode: String = ""
    @State private var renderDebounceTask: Task<Void, Never>?

    /// Standard initializer (for UI)
    init(code: String, showBackground: Bool = true) {
        self.code = code
        self.showBackground = showBackground
    }

    /// Pre-parsed initializer (kept for API compatibility - diagram param ignored,
    /// mermaid.js handles all parsing now)
    init(code: String, diagram: MermaidDiagram, showBackground: Bool = true) {
        self.code = code
        self.showBackground = showBackground
    }

    var body: some View {
        Group {
            if let image = cachedImage {
                imageView(image)
            } else if isRendering {
                renderingView
            } else if !MermaidCodeValidator.isLikelyComplete(code) {
                // Still streaming - show placeholder
                streamingPlaceholder
            } else {
                // Ready to render
                renderingView
            }
        }
        .conditionalBackground(showBackground)
        .onAppear {
            scheduleRenderIfReady()
        }
        .onChange(of: code) { _, newCode in
            handleCodeChange(newCode)
        }
        .onChange(of: colorScheme) { _, _ in
            // Force re-render on theme change
            cachedImage = nil
            renderError = nil
            lastRenderedCode = ""
            scheduleRenderIfReady()
        }
    }

    // MARK: - Render Scheduling

    private func handleCodeChange(_ newCode: String) {
        // Cancel any pending render
        renderDebounceTask?.cancel()
        renderDebounceTask = nil

        // If the code hasn't meaningfully changed, skip
        if newCode == lastRenderedCode { return }

        // Only render when code looks complete (avoids streaming errors)
        if MermaidCodeValidator.isLikelyComplete(newCode) {
            scheduleRender(delay: 0.3)
        }
        // Otherwise: show streaming placeholder, wait for more code
    }

    private func scheduleRenderIfReady() {
        if cachedImage == nil && !code.isEmpty && MermaidCodeValidator.isLikelyComplete(code) {
            scheduleRender(delay: 0.1)
        }
    }

    private func scheduleRender(delay: TimeInterval) {
        renderDebounceTask?.cancel()
        renderDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if !code.isEmpty {
                cachedImage = nil
                renderError = nil
                await performRender()
            }
        }
    }

    // MARK: - Offscreen Rendering

    private func performRender() async {
        guard !isRendering else { return }
        isRendering = true

        let isDark = colorScheme == .dark
        let image = await MermaidWebRenderer.renderToImage(
            code: code,
            width: 700,
            isDarkMode: isDark
        )

        if let image = image {
            cachedImage = image
            renderedHeight = image.size.height
            lastRenderedCode = code
        } else {
            if MermaidCodeValidator.isLikelyComplete(code) {
                renderError = "Failed to render diagram"
            }
            logger.error("Mermaid diagram render returned nil")
        }
        isRendering = false
    }

    // MARK: - Subviews

    private var renderingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Rendering diagram...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
    }

    private var streamingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Receiving diagram...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
    }

    private func imageView(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: min(image.size.width, 560))
            .padding(.vertical, 4)
    }

    private func errorView(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MERMAID")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Spacer()
            }
            .background(Color.secondary.opacity(0.1))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Mermaid Code Validator

/// Checks whether mermaid code is likely complete enough to render.
/// Used to avoid sending partial/streaming code to mermaid.js.
struct MermaidCodeValidator {

    /// Known mermaid diagram type prefixes for first-line detection
    private static let knownPrefixes = [
        "graph ", "flowchart ", "sequencediagram", "classdiagram",
        "statediagram", "erdiagram", "gantt", "pie", "journey",
        "mindmap", "timeline", "quadrantchart", "requirementdiagram",
        "gitgraph", "xychart-beta", "sankey-beta",
        "block-beta", "packet-beta", "kanban",
        "c4context", "c4container", "c4component", "c4deployment"
    ]

    /// Quick heuristic check: is this mermaid code likely complete?
    /// - Balanced brackets/parens (context-aware for certain diagram types)
    /// - Has at least one complete statement after the diagram type declaration
    /// - Doesn't end mid-token
    static func isLikelyComplete(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Must have at least 2 lines (type declaration + at least one statement)
        let lines = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard lines.count >= 2 else { return false }

        // Verify first line looks like a diagram type declaration
        let firstLine = lines[0].lowercased()
        let isKnownType = knownPrefixes.contains { firstLine.hasPrefix($0) }

        // For unknown types, still attempt render if code has multiple lines
        // and doesn't look obviously incomplete
        if !isKnownType {
            // If it has multiple non-empty lines, give mermaid.js a chance
            return lines.count >= 2
        }

        // Detect diagram type for context-aware parsing
        let isERDiagram = firstLine.hasPrefix("erdiagram")
        let isSankey = firstLine.hasPrefix("sankey-beta")
        let isPacket = firstLine.hasPrefix("packet-beta")

        // Sankey and packet diagrams use simple value lines, no brackets needed
        if isSankey || isPacket {
            return true
        }

        // Check balanced brackets
        var squareBrackets = 0
        var curlyBraces = 0
        var parens = 0

        let allLines = trimmed.components(separatedBy: .newlines)
        for line in allLines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // ER diagram relationship lines use { and } as cardinality markers
            if isERDiagram && (trimmedLine.contains("||") || trimmedLine.contains("|{") ||
                               trimmedLine.contains("}|") || trimmedLine.contains("o{") ||
                               trimmedLine.contains("}o")) {
                continue
            }

            for char in trimmedLine {
                switch char {
                case "[": squareBrackets += 1
                case "]": squareBrackets -= 1
                case "{": curlyBraces += 1
                case "}": curlyBraces -= 1
                case "(": parens += 1
                case ")": parens -= 1
                default: break
                }
            }
        }

        // If any bracket type is unbalanced, code is incomplete
        if squareBrackets != 0 || curlyBraces != 0 || parens != 0 {
            return false
        }

        // Check the last line doesn't end mid-arrow or mid-token
        if let lastLine = lines.last {
            let dangling = ["-->", "-.->", "==>", "->", "--", "-.", "==",
                            ":", "|", ">>", "<<", "->>" ]
            for suffix in dangling {
                if lastLine.hasSuffix(suffix) {
                    return false
                }
            }
        }

        return true
    }
}

// MARK: - View Modifier

extension View {
    @ViewBuilder
    func conditionalBackground(_ showBackground: Bool) -> some View {
        if showBackground {
            self
                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
        } else {
            self
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        Text("Flowchart Example")
            .font(.headline)

        MermaidDiagramView(code: """
        flowchart TD
            A[Start] --> B{Is it working?}
            B -->|Yes| C[Great!]
            B -->|No| D[Debug]
            D --> B
            C --> E[End]
        """)

        Text("Sequence Diagram")
            .font(.headline)

        MermaidDiagramView(code: """
        sequenceDiagram
            participant User
            participant SAM
            participant API
            User->>SAM: Send message
            SAM->>API: Process request
            API-->>SAM: Return response
            SAM-->>User: Display result
        """)
    }
    .padding()
    .frame(width: 700, height: 900)
}
