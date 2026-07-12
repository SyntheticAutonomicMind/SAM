// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import SwiftUI
import AppKit
import ConfigurationSystem
import ConversationEngine
import APIFramework

/// Assistant message row. Renders streaming and final states from the same
/// view body, swapping only the input source (buffer vs. cleaned bus content).
/// Markdown parse is cached in @State so it only re-runs when the underlying
/// content actually changes.
struct AssistantMessageRow: View {
    let message: EnhancedMessage
    let displayedContent: String
    let isStreaming: Bool
    let buffer: StreamingBuffer?
    let enableAnimations: Bool

    @State private var cachedAttributed: AttributedString?
    @State private var lastCachedContent: String = ""
    @State private var showCopyConfirmation: Bool = false
    @State private var reloadTrigger: UUID = UUID()
    @State private var contentVisible: Bool = true

    private var hasRenderableContent: Bool {
        !displayedContent.isEmpty
            || message.isStreaming
            || (message.contentParts?.isEmpty == false)
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if hasRenderableContent {
                    bubble
                        .opacity(isStreaming ? 0.85 : 1.0)
                        .animation(.easeOut(duration: 0.2), value: isStreaming)
                }

                /// Render content parts (images, etc.)
                if let parts = message.contentParts, !parts.isEmpty {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        if case .imageUrl(let imageURL) = part {
                            imagePartView(imageURL)
                        }
                    }
                }

                metadataRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
    }

    private var bubble: some View {
        Group {
            if let attributed = cachedAttributed {
                Text(attributed)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        NSWorkspace.shared.open(url)
                        return .handled
                    })
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(displayedContent)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        NSWorkspace.shared.open(url)
                        return .handled
                    })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(alignment: .bottomTrailing) {
            if isStreaming {
                streamingCursor
                    .padding(8)
            }
        }
        .onChange(of: displayedContent) { _, newValue in
            rebuildAttributedString(from: newValue)
        }
        .onAppear {
            rebuildAttributedString(from: displayedContent)
        }
    }

    private var streamingCursor: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 4)
                    .opacity(isStreaming ? 1.0 : 0.0)
                    .animation(
                        .easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.15),
                        value: isStreaming
                    )
            }
        }
    }

    private func imagePartView(_ imageURL: ImageURL) -> some View {
        Group {
            if let url = URL(string: imageURL.url),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 512, maxHeight: 512)
                    .cornerRadius(8)
            } else {
                Text("![image](\(imageURL.url))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            Text(message.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundColor(.secondary)

            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Reload message")

            Button(action: copy) {
                Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(showCopyConfirmation ? .green : .secondary)
            .help("Copy message")

            if let metrics = message.performanceMetrics {
                HStack(spacing: 2) {
                    Image(systemName: "speedometer")
                        .font(.caption2)
                    Text(String(format: "%.1f t/s", metrics.tokensPerSecond))
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
                .help(String(format: "Tokens: %d, TTFT: %.2fs, Total: %.2fs",
                             metrics.tokenCount,
                             metrics.timeToFirstToken,
                             metrics.processingTime))
            }
        }
    }

    private func rebuildAttributedString(from content: String) {
        guard content != lastCachedContent else { return }
        lastCachedContent = content
        // Defer the actual Markdown parse to the next runloop tick so we don't
        // block the streaming frame. By the time the tick fires, the buffer
        // will have more content and we'll re-parse once.
        let snapshot = content
        Task { @MainActor in
            // Slight coalescing window.
            try? await Task.sleep(nanoseconds: 5_000_000)
            if lastCachedContent == snapshot {
                cachedAttributed = Self.parseMarkdown(snapshot)
            } else {
                // Content moved on - just re-parse the latest; the @State
                // .onChange will pick it up on the next frame.
                cachedAttributed = Self.parseMarkdown(lastCachedContent)
            }
        }
    }

    private static func parseMarkdown(_ text: String) -> AttributedString? {
        guard !text.isEmpty else { return nil }
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .full
            return try AttributedString(markdown: text, options: options)
        } catch {
            return AttributedString(text)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedContent, forType: .string)
        showCopyConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopyConfirmation = false
        }
    }

    private func reload() {
        reloadTrigger = UUID()
        cachedAttributed = nil
        rebuildAttributedString(from: displayedContent)
    }
}
