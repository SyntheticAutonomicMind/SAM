// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import AppKit
import ConfigurationSystem
import ConversationEngine
import os

private let logger = Logger(subsystem: "com.sam.chat", category: "messagebubble")

/// Unified message bubble rendering for both user and assistant messages.
///
/// Single source of truth for bubble layout. Both directions share the
/// same MarkdownWebView, padding, background, metadata row, and context
/// menu - only the alignment (left vs right) and visual styling (accent
/// fill vs neutral fill) differ.
///
/// Bubble width is set by GeometryReader to the chat column width (capped).
/// MarkdownWebView is laid out as a block-level element that fills the
/// bubble's inner width, so text wraps at the bubble edge instead of
/// shrinking to its intrinsic width. Long unbreakable strings (URLs,
/// hashes) still wrap via CSS word-wrap on the body, capped at the
/// bubble width.
/// Layout:
///   HStack { bubble; Spacer(minLength: 60) }   // assistant (left)
///   HStack { Spacer(minLength: 60); bubble }   // user     (right)
struct MessageBubble: View {
    let message: EnhancedMessage
    let isFromUser: Bool
    let enableAnimations: Bool
    @Binding var messageToExport: EnhancedMessage?
    /// Pre-filtered markdown to render. Wrappers are responsible for
    /// stripping anything that shouldn't be displayed.
    let displayContent: String

    @State private var showCopyConfirmation = false
    @State private var showCopyMenu = false
    /// Start at a single-line height (28pt ≈ one line of 14px text at 1.6 line-height).
    /// The JS size callback in MarkdownWebView corrects this to the actual content
    /// height within a few milliseconds. A lower default avoids the oversized-bubble
    /// artifact when the callback is delayed or when the view is recycled by LazyVStack
    /// without re-loading the web content.
    @State private var bubbleHeight: CGFloat = 28
    @State private var reloadTrigger = UUID()

    /// Bubble width bounds. Min keeps short content from looking weirdly
    /// narrow. No upper cap - the bubble fills the chat column and the
    /// inner MarkdownWebView is laid out as block-level content so text
    /// wraps at the bubble edge. Long unbreakable strings (URLs, hashes)
    /// wrap via CSS word-wrap inside the WKWebView, not by capping.
    private static let minBubbleWidth: CGFloat = 200

    private var bubbleAlignment: HorizontalAlignment {
        isFromUser ? .trailing : .leading
    }

    private var backgroundFill: Color {
        if isFromUser {
            return Color.accentColor
        }
        /// Adaptive assistant bubble background. Using Color.primary.opacity(0.05)
        /// produced a near-white background in dark mode that made light-gray
        /// text invisible. Use platform-adaptive control background so the
        /// bubble stays subtle but legible in both light and dark mode.
        return Color(NSColor.controlBackgroundColor)
    }

    var body: some View {
        HStack(alignment: .top) {
            if isFromUser {
                Spacer(minLength: 60)
            }

            VStack(alignment: bubbleAlignment, spacing: 4) {
                if shouldShowBubble {
                    bubble
                }

                if let contentParts = message.contentParts {
                    ForEach(Array(contentParts.enumerated()), id: \.offset) { _, part in
                        if case .imageUrl(let imageURL) = part {
                            MarkdownText("![\(imageURL.url)](\(imageURL.url))")
                                .padding(.top, 4)
                        }
                    }
                }

                if shouldShowMetadata {
                    metadataRow
                }
            }

            if !isFromUser {
                Spacer(minLength: 60)
            }
        }
        .contextMenu {
            Menu("Copy") {
                Button("Copy Source") { copySource() }
                Button("Copy Formatted") { copyFormatted() }
            }
            Button("Reload Message") { reloadMessage() }
            Divider()
            Button("Export...") { messageToExport = message }
            Button("Print Message...") { printMessage() }
        }
        .animation(enableAnimations ? .easeInOut(duration: 0.2) : nil, value: showCopyConfirmation)
        /// When isStreaming flips from true -> false, force-rebuild the
        /// MarkdownWebView so its HTML is reloaded with __samIsStreaming
        /// = false and the IIFE actually runs mermaid.render. Without
        /// this, a streaming-then-complete transition that doesn't change
        /// message.content (final delta == last streamed delta) leaves
        /// the bubble's HTML showing the streaming-deferred variant.
        .onChange(of: message.isStreaming) { _, streaming in
            if !streaming { reloadMessage() }
        }
    }

    /// Bubble wrapped in GeometryReader so the dynamic cap reflects actual
    /// chat width. Without this, content with no breakable characters
    /// (URLs, hashes) overflowed the chat frame.
    private var bubble: some View {
        GeometryReader { geo in
            /// Cap the bubble to the chat column width. Long unbreakable
            /// strings (URLs, hashes) wrap via CSS word-wrap, so no upper
            /// cap is needed. minBubbleWidth prevents awkwardly narrow
            /// bubbles on tiny windows.
            let width = max(geo.size.width - 32, Self.minBubbleWidth)

            MarkdownWebView(
                markdown: displayContent,
                isFromUser: isFromUser,
                maxBubbleWidth: width,
                isStreaming: message.isStreaming,
                bubbleHeight: $bubbleHeight
            )
            .frame(width: width, height: bubbleHeight)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(backgroundFill)
                    .shadow(color: .primary.opacity(0.1), radius: 2, x: 0, y: 1)
            )
            .clipped()
            /// Reload trigger: changes the view identity so SwiftUI tears down
            /// the WKWebView and creates a fresh one. Without this, writing
            /// to reloadTrigger alone wouldn't cause a rebuild because
            /// @State values that aren't read by the view body are ignored
            /// by the diffing engine.
            .id(reloadTrigger)
        }
        .frame(height: bubbleHeight + 24)  /// bubble height + vertical padding (12 + 12)
    }

    /// Always render the bubble while content exists or streaming is
    /// active so the container doesn't collapse and reappear (flicker).
    private var shouldShowBubble: Bool {
        !displayContent.isEmpty || message.isStreaming || message.contentParts != nil
    }

    private var shouldShowMetadata: Bool {
        !displayContent.isEmpty || message.isStreaming || message.contentParts != nil
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            Text(message.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundColor(.secondary)

            Button(action: reloadMessage) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Reload message")

            /// Copy button: regular Button (matches the surrounding icon buttons)
            /// that opens a popover offering raw markdown ("Copy Source") or
            /// the rendered message as rich text ("Copy Formatted"). Using a
            /// Popover here rather than Menu keeps the icon visually identical
            /// to the adjacent reload/export/print icons - Menu adds its own
            /// internal padding for the indicator that doesn't go away with
            /// .menuIndicator(.hidden).
            Button {
                showCopyMenu.toggle()
            } label: {
                Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Copy message")
            .popover(isPresented: $showCopyMenu, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        copySource()
                        showCopyMenu = false
                    } label: {
                        Label("Copy Source", systemImage: "doc.plaintext")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    Button {
                        copyFormatted()
                        showCopyMenu = false
                    } label: {
                        Label("Copy Formatted", systemImage: "text.alignleft")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .padding(.vertical, 6)
            }

            Button(action: { messageToExport = message }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help(isFromUser ? "Export" : "Export to PDF")

            Button(action: printMessage) {
                Image(systemName: "printer")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Print message")

            /// Performance metrics are assistant-only; user messages don't have token counts.
            if !isFromUser {
                if let metrics = message.performanceMetrics {
                    Text("• \(metrics.tokenCount) tokens • \(String(format: "%.1f", metrics.timeToFirstToken))s TTFT • \(String(format: "%.0f", metrics.tokensPerSecond)) tok/s")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .help("Token count • Time to First Token • Tokens per second")
                } else if let processingTime = message.processingTime {
                    Text("• \(String(format: "%.1f", processingTime))s")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .help("Processing time")
                }
            }

            if message.isStreaming {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.primary)
            }
        }
    }

    private func reloadMessage() {
        reloadTrigger = UUID()
        /// Reset bubbleHeight so the rebuilt MarkdownWebView doesn't briefly
        /// show the previous incarnation's measured height before the new JS
        /// size callback arrives.
        bubbleHeight = 28
        logger.info("Reloading \(isFromUser ? "user" : "assistant") message: \(message.id)")
    }

    private func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayContent, forType: .string)
        flashCopyConfirmation()
    }

    /// Copy message with formatting preserved (RTF). Also includes plain text
    /// so targets that can't read RTF still get usable text. Empty-result
    /// fallback: if RTF generation fails, fall back to plain text only.
    @MainActor
    private func copyFormatted() {
        let parser = MarkdownASTParser()
        let ast = parser.parse(displayContent)
        let converter = MarkdownASTToNSAttributedString()
        let attributedString = converter.convertSync(ast)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        pasteboard.setString(displayContent, forType: .string)

        if let rtfData = try? attributedString.data(
            from: NSRange(location: 0, length: attributedString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            pasteboard.setData(rtfData, forType: .rtf)
        }

        flashCopyConfirmation()
    }

    private func flashCopyConfirmation() {
        showCopyConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            showCopyConfirmation = false
        }
    }

    @MainActor
    private func printMessage() {
        WKWebViewPrintService.printMessage(
            markdown: displayContent,
            isFromUser: isFromUser,
            title: "SAM Message"
        )
    }
}