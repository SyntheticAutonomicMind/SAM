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
/// Text wraps normally inside the bubble - no shrink-wrap to content.
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
    @State private var bubbleHeight: CGFloat = 100
    @State private var reloadTrigger = UUID()

    /// Bubble width bounds. Min keeps short content from looking weirdly
    /// narrow. No max - bubble fills the chat column. Long unbreakable
    /// strings (URLs, hashes) wrap via CSS word-wrap, not by capping.
    private static let minBubbleWidth: CGFloat = 200

    private var bubbleAlignment: HorizontalAlignment {
        isFromUser ? .trailing : .leading
    }

    private var backgroundFill: Color {
        isFromUser ? Color.accentColor : Color.primary.opacity(0.05)
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
            Button("Copy Message") { copyMessage() }
            Button("Reload Message") { reloadMessage() }
            Divider()
            Button("Export...") { messageToExport = message }
            Button("Print Message...") { printMessage() }
        }
        .animation(enableAnimations ? .easeInOut(duration: 0.2) : nil, value: showCopyConfirmation)
    }

    /// Bubble wrapped in GeometryReader so the dynamic cap reflects actual
    /// chat width. Without this, content with no breakable characters
    /// (URLs, hashes) overflowed the chat frame.
    private var bubble: some View {
        GeometryReader { geo in
            /// Cap the bubble to the chat column width (minus Spacer). Long
            /// unbreakable strings (URLs, hashes) wrap via CSS word-wrap,
            /// so no upper cap is needed. minBubbleWidth prevents awkwardly
            /// narrow bubbles on tiny windows.
            let width = max(geo.size.width, Self.minBubbleWidth)

            MarkdownWebView(
                markdown: displayContent,
                isFromUser: isFromUser,
                maxBubbleWidth: width,
                bubbleWidth: .constant(width),
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
        }
        .frame(height: bubbleHeight + 24)  /// bubble height + vertical padding (12 + 12)
    }

    /// Always render the bubble while content exists or streaming is
    /// active so the container doesn't collapse and reappear (flicker).
    private var shouldShowBubble: Bool {
        !message.content.isEmpty || message.isStreaming || message.contentParts != nil
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

            Button(action: copyMessage) {
                Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Copy message")

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
        logger.info("Reloading \(isFromUser ? "user" : "assistant") message: \(message.id)")
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayContent, forType: .string)
        showCopyConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            showCopyConfirmation = false
        }
    }

    @MainActor
    private func exportMessageToPDF() {
        Task.detached(priority: .userInitiated) {
            do {
                let fileURL = try await MessageExportService.exportMessageToPDFAsync(
                    message: message,
                    conversationTitle: "Conversation",
                    modelName: nil
                )

                await MainActor.run {
                    let savePanel = NSSavePanel()
                    savePanel.allowedContentTypes = [.pdf]
                    savePanel.nameFieldStringValue = "SAM_Message_\(message.timestamp.formatted(date: .abbreviated, time: .shortened).replacingOccurrences(of: "/", with: "-")).pdf"
                    savePanel.message = "Export message to PDF"

                    let result = savePanel.runModal()
                    if result == .OK, let url = savePanel.url {
                        do {
                            if FileManager.default.fileExists(atPath: url.path) {
                                try FileManager.default.removeItem(at: url)
                            }
                            try FileManager.default.copyItem(at: fileURL, to: url)
                            try? FileManager.default.removeItem(at: fileURL)
                            NSWorkspace.shared.open(url)
                        } catch {
                            logger.error("Failed to save PDF: \(error)")
                        }
                    }
                }
            } catch {
                logger.error("Failed to export message to PDF: \(error)")
            }
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