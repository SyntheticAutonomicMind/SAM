// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import ConversationEngine
import APIFramework
import os

private let logger = Logger(subsystem: "com.sam.chat", category: "messageview")

/// Maximum width ratio for message content blocks.
/// User and assistant messages are constrained to this fraction of the
/// chat column width so the conversation doesn't sprawl on wide windows.
/// Metadata (timestamp, tokens) sits to the right of this block.
private let maxMessageWidthRatio: CGFloat = 0.85

/// Get user-friendly display name for a tool from the registry.
@MainActor
private func getToolDisplayName(_ toolName: String?, registry: UniversalToolRegistry?) -> String {
    guard let toolName = toolName else { return "Tool Operation" }
    if let registry = registry, let displayName = registry.getToolMetadata(for: toolName)?.displayName {
        return displayName
    }
    return UniversalTool.generateDisplayName(from: toolName)
}

/// Extract operation-specific display name from tool message content.
@MainActor
private func getOperationDisplayName(from content: String, toolName: String?, displayData: ToolDisplayData? = nil) -> String {
    if let display = displayData { return display.actionDisplayName }
    if let toolName = toolName, !toolName.isEmpty { return getToolDisplayName(toolName, registry: nil) }
    if content.hasPrefix("SUCCESS: ") {
        let withoutPrefix = content.dropFirst(9).trimmingCharacters(in: .whitespaces)
        if let colonIndex = withoutPrefix.firstIndex(of: ":") {
            let action = String(withoutPrefix[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            switch action.lowercased() {
            case "search", "searching", "scraping", "scraping:": return "Web Search"
            case "creating", "create": return "Create File"
            case "editing", "edit": return "Edit File"
            case "reading", "read": return "Read File"
            case "writing", "write": return "Write File"
            case "running", "executing": return "Run Command"
            case "analyzing": return "Analyze"
            case "importing": return "Import"
            default: return action.prefix(1).uppercased() + action.dropFirst()
            }
        }
    }
    return getToolDisplayName(toolName, registry: nil)
}

/// Format metadata key for display (snake_case -> Title Case).
@MainActor
private func formatMetadataKey(_ key: String) -> String {
    let words = key.split(separator: "_").map { word in
        String(word.prefix(1).uppercased() + word.dropFirst())
    }
    return words.joined(separator: " ")
}

/// Router component that renders appropriate UI based on message type.
/// No bubble wrappers — messages render directly as content + metadata.
struct MessageView: View {
    let message: EnhancedMessage
    let enableAnimations: Bool
    let conversation: ConversationModel
    @Binding var messageToExport: EnhancedMessage?

    @Environment(\.fontSizeScale) var fontSizeScale

    var body: some View {
        Group {
            switch message.type {
            case .user:
                MessageRow(
                    message: message,
                    isFromUser: true,
                    enableAnimations: enableAnimations,
                    conversation: conversation,
                    fontSizeScale: fontSizeScale,
                    messageToExport: $messageToExport
                )

            case .assistant:
                MessageRow(
                    message: message,
                    isFromUser: false,
                    enableAnimations: enableAnimations,
                    conversation: conversation,
                    fontSizeScale: fontSizeScale,
                    messageToExport: $messageToExport
                )

            case .toolExecution, .subagentExecution:
                ToolExecutionCard(message: message, enableAnimations: enableAnimations, fontSizeScale: fontSizeScale)

            case .systemStatus:
                SystemStatusCard(message: message, enableAnimations: enableAnimations, fontSizeScale: fontSizeScale)

            case .thinking:
                ThinkingCard(message: message, enableAnimations: enableAnimations, fontSizeScale: fontSizeScale)
            }
        }
        .id("\(message.id)-\(message.type.rawValue)")
    }
}

// MARK: - Message Separator

/// Fixed-height hairline divider between messages in the LazyVStack.
/// Stays anchored in layout — does not scroll with content, so separators
/// remain visible as stable visual anchors during scrolling and streaming.
struct MessageSeparator: View {
    var body: some View {
        HStack {
            Spacer()
            Divider()
                .frame(height: 1)
                .background(Color.secondary.opacity(0.25))
                .padding(.horizontal, 8)
            Spacer()
        }
        .frame(height: 1)
        .padding(.vertical, 6)
    }
}

// MARK: - Message Row (Unified User/Assistant Layout)

/// Unified message row that handles both user (right-aligned) and assistant
/// (left-aligned) messages with clean visual separation.
///
/// Layout:
/// ```
/// [timestamp • metrics • controls]     ← metadata gutter (right-aligned)
///                                       ← thin divider (between messages)
/// Content that flows naturally.         ← content block (max 85% width)
///                                       ← thin divider (between messages)
/// ```
struct MessageRow: View {
    let message: EnhancedMessage
    let isFromUser: Bool
    let enableAnimations: Bool
    let conversation: ConversationModel
    let fontSizeScale: Double
    @Binding var messageToExport: EnhancedMessage?

    @State private var displayedContent: String = ""
    @State private var showCopyConfirmation = false
    @State private var showCopyMenu = false

    // MARK: - Content Filtering

    /// Strip workflow-control status markers and session-naming markers.
    private func filterContent(_ content: String) -> String {
        var filtered = content

        // Remove status JSON markers.
        let statusPatterns = [
            #"\{\s*"status"\s*:\s*"continue"\s*\}"#,
            #"\{\s*"status"\s*:\s*"complete"\s*\}"#,
            #"\{\s*"status"\s*:\s*"stop"\s*\}"#,
            #"\s*<!--[^>]*session:[^>]*-->\s*"#
        ]
        for pattern in statusPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let range = NSRange(filtered.startIndex..., in: filtered)
                filtered = regex.stringByReplacingMatches(in: filtered, range: range, withTemplate: "")
            }
        }

        filtered = filtered.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        filtered = filtered.trimmingCharacters(in: .whitespacesAndNewlines)

        return filtered
    }

    /// Strip user context markers from display content.
    private var userDisplayContent: String {
        var result = message.content

        if let xmlStart = result.range(of: "\n\n<userContext>"),
           let xmlEnd = result.range(of: "</userContext>", range: xmlStart.upperBound..<result.endIndex) {
            result = String(result[..<xmlStart.lowerBound])
        }

        if let contextStart = result.range(of: "\n\n[User Context:") {
            result = String(result[..<contextStart.lowerBound])
        }

        return result
    }

    // MARK: - Content Rendering

    /// During streaming: parse complete lines as markdown, render partials as plain Text.
    /// After streaming: full MarkdownText rendering.
    ///
    /// Line-by-line approach: split content at the last complete line boundary.
    /// Complete lines get parsed and rendered as markdown. The trailing partial
    /// line (being typed) renders as plain Text. This gives incremental markdown
    /// rendering (headings, bold, lists, code) without re-parsing the entire
    /// content on every single-character delta — only complete lines trigger
    /// a new AST parse.
    @ViewBuilder
    private var contentView: some View {
        let effectiveContent = displayedContent.isEmpty ? message.content : displayedContent
        let rawContent = isFromUser ? userDisplayContent : effectiveContent

        if message.isStreaming {
            // Split at the last newline — everything before is complete lines.
            let lastNewlineIdx = rawContent.lastIndex(of: "\n")

            if let splitIdx = lastNewlineIdx {
                let completeLines = String(rawContent[..<splitIdx])
                let partialLine = String(rawContent[splitIdx...].dropFirst()) // skip newline

                VStack(alignment: isFromUser ? .trailing : .leading, spacing: 0) {
                    if !completeLines.isEmpty {
                        MarkdownText(completeLines)
                            .textSelection(.enabled)
                            .environment(\.openURL, OpenURLAction { url in
                                #if os(macOS)
                                NSWorkspace.shared.open(url)
                                #else
                                UIApplication.shared.open(url)
                                #endif
                                return .handled
                            })
                    }
                    if !partialLine.isEmpty {
                        Text(partialLine)
                            .foregroundColor(.primary)
                            .font(FontManager.shared.body(fontSizeScale))
                    }
                }
            } else {
                // Single line still being typed — render as plain text.
                Text(rawContent)
                    .foregroundColor(.primary)
            }
        } else {
            // Full markdown rendering after streaming completes.
            MarkdownText(rawContent)
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    UIApplication.shared.open(url)
                    #endif
                    return .handled
                })
        }
    }    // MARK: - Metadata Gutter

    /// Right-aligned metadata: timestamp, copy/export/print buttons, token count.
    @ViewBuilder
    private var metadataGutter: some View {
        HStack(spacing: 6) {
            Text(message.timestamp, format: .dateTime.hour().minute().second())
                .font(FontManager.shared.caption2(fontSizeScale))
                .foregroundColor(.secondary)

            Button(action: copySource) {
                Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                    .font(FontManager.shared.caption2(fontSizeScale))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Copy source")
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
                    .font(FontManager.shared.caption2(fontSizeScale))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help(isFromUser ? "Export" : "Export to PDF")

            Button(action: printMessage) {
                Image(systemName: "printer")
                    .font(FontManager.shared.caption2(fontSizeScale))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Print message")

            if !isFromUser {
                if let metrics = message.performanceMetrics {
                    Text("• \(metrics.tokenCount) tokens • \(String(format: "%.1f", metrics.timeToFirstToken))s TTFT • \(String(format: "%.0f", metrics.tokensPerSecond)) tok/s")
                        .font(FontManager.shared.caption2(fontSizeScale))
                        .foregroundColor(.secondary)
                } else if let processingTime = message.processingTime {
                    Text("• \(String(format: "%.1f", processingTime))s")
                        .font(FontManager.shared.caption2(fontSizeScale))
                        .foregroundColor(.secondary)
                }
            }

            if message.isStreaming {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.primary)
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: isFromUser ? .trailing : .leading, spacing: 4) {
            // Content block — constrained width, aligned by message direction.
            // User messages narrower (70%) to create visual rhythm; assistant wider (85%).
            contentView
                .frame(maxWidth: .infinity, alignment: isFromUser ? .trailing : .leading)
                .layoutPriority(1)
                .font(FontManager.shared.body(fontSizeScale))

            // Metadata gutter — aligned with content, not the full row width.
            // Left-aligned for assistant (matches content start), right-aligned for user.
            metadataGutter
                .frame(maxWidth: .infinity, alignment: isFromUser ? .trailing : .leading)
        }
        // Constrain inner content to max-width ratio, not the full row width.
        // This prevents content from stretching across the entire chat column.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: isFromUser ? .trailing : .leading)
        .padding(.leading, isFromUser ? 40 : 8)
        .padding(.trailing, isFromUser ? 8 : 40)
        // Visual separation: thicker background band + content-aligned border.
        // The border creates a subtle vertical line on the "gutter side" of each
        // message — left border for assistant, right border for user — giving a
        // clear left/right turn structure at a glance.
        .background(
            ZStack(alignment: isFromUser ? .trailing : .leading) {
                // Background band.
                (isFromUser ? Color.accentColor.opacity(0.05) : Color.secondary.opacity(0.05))

                // Content-aligned border — thin vertical line on the gutter side.
                Rectangle()
                    .frame(width: 2)
                    .foregroundColor(isFromUser ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.2))
                    .allowsHitTesting(false)
            }
        )
        .contextMenu {
            contextMenuContent
        }
        .onAppear {
            displayedContent = filterContent(message.content)
        }
        .onChange(of: message.content) { _, newValue in
            let filtered = filterContent(newValue)
            if displayedContent != filtered {
                displayedContent = filtered
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        Menu("Copy") {
            Button("Copy Source") { copySource() }
            Button("Copy Formatted") { copyFormatted() }
        }
        Button("Export...") { messageToExport = message }
        Button("Print Message...") { printMessage() }
    }

    // MARK: - Actions

    private func copySource() {
        let content = isFromUser ? userDisplayContent : (displayedContent.isEmpty ? message.content : displayedContent)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        flashCopyConfirmation()
    }

    @MainActor
    private func copyFormatted() {
        let content = isFromUser ? userDisplayContent : (displayedContent.isEmpty ? message.content : displayedContent)
        let parser = MarkdownASTParser()
        let ast = parser.parse(content)
        let converter = MarkdownASTToNSAttributedString()
        let attributedString = converter.convertSync(ast)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)

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
        let content = isFromUser ? userDisplayContent : (displayedContent.isEmpty ? message.content : displayedContent)
        WKWebViewPrintService.printMessage(
            markdown: content,
            isFromUser: isFromUser,
            title: "SAM Message"
        )
    }
}

// MARK: - Tool Execution Card (Full Width, Unchanged)

struct ToolExecutionCard: View {
    let message: EnhancedMessage
    let enableAnimations: Bool
    let fontSizeScale: Double
    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let iconName = message.toolIcon {
                    Image(systemName: iconName)
                        .font(FontManager.shared.body(fontSizeScale))
                        .foregroundColor(.primary)
                } else {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(FontManager.shared.body(fontSizeScale))
                        .foregroundColor(.primary)
                }

                Text(getOperationDisplayName(from: message.content, toolName: message.toolName, displayData: message.toolDisplayData))
                    .font(FontManager.shared.subheadline(fontSizeScale))
                    .foregroundColor(.primary)

                Spacer()

                statusBadge

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
                    .font(FontManager.shared.caption(fontSizeScale))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation { isExpanded.toggle() }
            }
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .background(isHovering && !isExpanded ? Color.accentColor.opacity(0.05) : Color.clear)

            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    if let metadata = message.toolMetadata, !metadata.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Result:")
                                .font(FontManager.shared.caption(fontSizeScale))
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            ForEach(Array(metadata.keys.sorted()), id: \.self) { key in
                                if let value = metadata[key] {
                                    HStack(alignment: .top, spacing: 4) {
                                        Text("\(formatMetadataKey(key)):")
                                            .font(FontManager.shared.caption(fontSizeScale))
                                            .foregroundColor(.secondary)
                                        Text(value)
                                            .font(FontManager.shared.caption(fontSizeScale))
                                            .foregroundColor(.primary)
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.accentColor.opacity(0.05))
                        .cornerRadius(6)
                    }

                    if let details = message.toolDetails, !details.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Operations:")
                                .font(FontManager.shared.caption(fontSizeScale))
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            ForEach(details, id: \.self) { detail in
                                Text("• \(detail)")
                                    .font(FontManager.shared.caption(fontSizeScale))
                                    .foregroundColor(.primary)
                            }
                        }
                    }

                    let isProgressIndicator = message.content.hasPrefix("-> ")
                    if !message.content.isEmpty && !isProgressIndicator {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Output:")
                                .font(FontManager.shared.caption(fontSizeScale))
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            MarkdownText(message.content)
                                .font(.caption)
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(6)
                        }
                    }

                    if let duration = message.toolDuration {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Performance:")
                                .font(FontManager.shared.caption(fontSizeScale))
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            Text("Duration: \(String(format: "%.1f", duration))s")
                                .font(FontManager.shared.caption(fontSizeScale))
                                .foregroundColor(.primary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .padding(.top, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.2))
                )
        )
        .padding(.horizontal)
        .padding(.vertical, 4)
        .onAppear {
            if message.toolStatus == .error {
                isExpanded = true
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(FontManager.shared.caption(fontSizeScale))
                .foregroundColor(statusColor)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(statusColor.opacity(0.15)))
    }

    private var statusColor: Color {
        switch message.toolStatus {
        case .queued: return .secondary
        case .running: return .primary
        case .success: return .primary
        case .error: return .red
        case .userInputRequired: return .secondary
        case .none: return .secondary
        }
    }

    private var statusText: String {
        switch message.toolStatus {
        case .queued: return "Queued"
        case .running: return "Running"
        case .success: return "Complete"
        case .error: return "Error"
        case .userInputRequired: return "Waiting"
        case .none: return "Unknown"
        }
    }
}

// MARK: - System Status Card

struct SystemStatusCard: View {
    let message: EnhancedMessage
    let enableAnimations: Bool
    let fontSizeScale: Double

    var body: some View {
        HStack {
            Spacer()
            Text(message.content)
                .font(FontManager.shared.caption(fontSizeScale))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(NSColor.controlBackgroundColor).opacity(0.5)))
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Thinking Card

struct ThinkingCard: View {
    let message: EnhancedMessage
    let enableAnimations: Bool
    let fontSizeScale: Double
    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: message.toolIcon ?? "brain.head.profile")
                    .font(FontManager.shared.body(fontSizeScale))
                    .foregroundColor(.primary)

                Text("Reasoning")
                    .font(FontManager.shared.subheadline(fontSizeScale))
                    .foregroundColor(.primary)

                Spacer()
                statusBadge

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
                    .font(FontManager.shared.caption(fontSizeScale))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation { isExpanded.toggle() }
            }
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .background(isHovering && !isExpanded ? Color.accentColor.opacity(0.05) : Color.clear)

            Divider()

            if !isExpanded {
                HStack {
                    if let duration = message.toolDuration {
                        Text("Completed in \(String(format: "%.1f", duration))s")
                            .font(FontManager.shared.caption(fontSizeScale))
                            .foregroundColor(.secondary)
                    } else {
                        Text("Click to expand")
                            .font(FontManager.shared.caption(fontSizeScale))
                            .foregroundColor(.secondary)
                            .italic()
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { isExpanded.toggle() }
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    let displayContent = message.reasoningContent ?? message.content
                    let cleanedContent = displayContent
                        .replacingOccurrences(of: "SUCCESS: Thinking:", with: "")
                        .replacingOccurrences(of: "Thinking:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !cleanedContent.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reasoning:")
                                .font(FontManager.shared.caption(fontSizeScale))
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            MarkdownText(cleanedContent)
                                .font(FontManager.shared.caption(fontSizeScale))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(6)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Status:")
                                .font(FontManager.shared.caption(fontSizeScale))
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            Text("No reasoning content available")
                                .font(FontManager.shared.caption(fontSizeScale))
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }

                    if let duration = message.toolDuration {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Performance:")
                                .font(FontManager.shared.caption(fontSizeScale))
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            Text("Duration: \(String(format: "%.1f", duration))s")
                                .font(FontManager.shared.caption(fontSizeScale))
                                .foregroundColor(.primary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .padding(.top, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor).opacity(0.2)))
        )
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(FontManager.shared.caption(fontSizeScale))
                .foregroundColor(statusColor)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(statusColor.opacity(0.15)))
    }

    private var statusColor: Color {
        switch message.toolStatus {
        case .success: return .primary
        case .running: return .primary
        case .error: return .red
        default: return .primary
        }
    }

    private var statusText: String {
        switch message.toolStatus {
        case .success: return "Complete"
        case .running: return "Thinking"
        case .error: return "Error"
        default: return "Thinking"
        }
    }
}

// MARK: - Previews

struct MessageView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            MessageView(message: .init(type: .user, content: "Hello world", isFromUser: true), enableAnimations: true, conversation: ConversationModel.withId(UUID(), title: "Test"), messageToExport: .constant(nil))
            Divider().padding(.vertical, 8)
            MessageView(message: .init(type: .assistant, content: "# Hello\n\nThis is **bold** text", isFromUser: false), enableAnimations: true, conversation: ConversationModel.withId(UUID(), title: "Test"), messageToExport: .constant(nil))
        }
        .padding()
    }
}
