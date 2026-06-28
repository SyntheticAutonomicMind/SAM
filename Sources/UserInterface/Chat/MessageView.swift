// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import ConversationEngine
import APIFramework
import os

private let logger = Logger(subsystem: "com.sam.chat", category: "messageview")

/// Get user-friendly display name for a tool from the registry Uses UniversalToolRegistry for proper metadata lookup.
@MainActor
private func getToolDisplayName(_ toolName: String?, registry: UniversalToolRegistry?) -> String {
    guard let toolName = toolName else {
        return "Tool Operation"
    }

    /// Try registry lookup first.
    if let registry = registry, let displayName = registry.getToolMetadata(for: toolName)?.displayName {
        return displayName
    }

    /// Fallback: auto-generate from tool name.
    return UniversalTool.generateDisplayName(from: toolName)
}

/// Extract operation-specific display name from tool message content E.g., "SUCCESS: Researching: query" → "Web Search" E.g., "SUCCESS: Creating: file.md" → "Create File".
@MainActor
private func getOperationDisplayName(from content: String, toolName: String?, displayData: ToolDisplayData? = nil) -> String {
    /// PREFERRED: Use structured display data if available
    if let display = displayData {
        return display.actionDisplayName
    }

    /// SECOND CHOICE: Use toolName if available (e.g., "file_operations" → "File Operations")
    /// This prevents parsing success messages as titles
    if let toolName = toolName, !toolName.isEmpty {
        return getToolDisplayName(toolName, registry: nil)
    }

    /// FALLBACK: Extract the action verb from "SUCCESS: Action: ..." pattern (for backward compatibility).
    /// Only use this when toolName is unavailable (legacy messages)
    if content.hasPrefix("SUCCESS: ") {
        let withoutPrefix = content.dropFirst(9).trimmingCharacters(in: .whitespaces)
        if let colonIndex = withoutPrefix.firstIndex(of: ":") {
            let action = String(withoutPrefix[..<colonIndex]).trimmingCharacters(in: .whitespaces)

            /// Map common actions to display names.
            switch action.lowercased() {
            case "researching":
                return "Web Search"

            case "creating":
                return "Create File"

            case "reading":
                return "Read File"

            case "writing", "editing":
                return "Edit File"

            case "searching":
                return "Search"

            case "fetching":
                return "Fetch"

            case "scraping":
                return "Scrape"

            case "running", "executing":
                return "Run Command"

            case "analyzing":
                return "Analyze"

            case "importing":
                return "Import"

            default:
                /// Capitalize the action.
                return action.prefix(1).uppercased() + action.dropFirst()
            }
        }
    }

    /// Last resort fallback to tool name-based display.
    return getToolDisplayName(toolName, registry: nil)
}

/// Router component that renders appropriate UI based on message type Replaces monolithic EnhancedMessageBubble with specialized components.
struct MessageView: View {
    let message: EnhancedMessage
    let enableAnimations: Bool
    let conversation: ConversationModel
    @Binding var messageToExport: EnhancedMessage?

    var body: some View {
        return Group {
            switch message.type {
            case .user:
                UserMessageBubble(message: message, enableAnimations: enableAnimations, conversation: conversation, messageToExport: $messageToExport)

            case .assistant:
                AssistantMessageBubble(message: message, enableAnimations: enableAnimations, conversation: conversation, messageToExport: $messageToExport)

            case .toolExecution, .subagentExecution:
                ToolExecutionCard(message: message, enableAnimations: enableAnimations)

            case .systemStatus:
                SystemStatusCard(message: message, enableAnimations: enableAnimations)

            case .thinking:
                ThinkingCard(message: message, enableAnimations: enableAnimations)
            }
        }
        .id("\(message.id)-\(message.type.rawValue)")
    }
}

// MARK: - User Message Bubble (Right-Aligned)

/// User (right-aligned) wrapper around the shared MessageBubble.
/// Filter logic: strip mini-prompt context (kept in stored message
/// for the API but never shown back to the user).
struct UserMessageBubble: View {
    let message: EnhancedMessage
    let enableAnimations: Bool
    let conversation: ConversationModel
    @Binding var messageToExport: EnhancedMessage?

    private var displayContent: String {
        var result = message.content

        /// New XML format: <userContext>...</userContext>
        if let xmlStart = result.range(of: "\n\n<userContext>"),
           let xmlEnd = result.range(of: "</userContext>", range: xmlStart.upperBound..<result.endIndex) {
            result = String(result[..<xmlStart.lowerBound])
        }

        /// Legacy bracket format: [User Context: ...]
        if let contextStart = result.range(of: "\n\n[User Context:") {
            result = String(result[..<contextStart.lowerBound])
        }

        return result
    }

    var body: some View {
        MessageBubble(
            message: message,
            isFromUser: true,
            enableAnimations: enableAnimations,
            messageToExport: $messageToExport,
            displayContent: displayContent
        )
    }
}

// MARK: - Assistant Message Bubble (Left-Aligned)

struct AssistantMessageBubble: View {
    let message: EnhancedMessage
    let enableAnimations: Bool
    let conversation: ConversationModel
    @Binding var messageToExport: EnhancedMessage?

    /// ANTI-FLICKER: Track filtered content separately so streaming updates animate
    /// smoothly without rebuilding the entire view hierarchy. When `message.content`
    /// changes during streaming, only this @State updates.
    @State private var displayedContent: String = ""

    private let logger = Logger(subsystem: "com.sam.chat", category: "assistantbubble")

    /// Strip workflow-control status markers ({"status": "continue"}, etc.)
    /// before rendering. These are emitted by orchestration logic and should
    /// never be displayed to the user.
    private func filterContent(_ content: String) -> String {
        var filtered = content

        let statusPatterns = [
            #"\{\s*"status"\s*:\s*"continue"\s*\}"#,
            #"\{\s*"status"\s*:\s*"complete"\s*\}"#,
            #"\{\s*"status"\s*:\s*"stop"\s*\}"#
        ]

        for pattern in statusPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(filtered.startIndex..., in: filtered)
                filtered = regex.stringByReplacingMatches(in: filtered, range: range, withTemplate: "")
            }
        }

        filtered = filtered.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        filtered = filtered.trimmingCharacters(in: .whitespacesAndNewlines)

        return filtered
    }

    var body: some View {
        MessageBubble(
            message: message,
            isFromUser: false,
            enableAnimations: enableAnimations,
            messageToExport: $messageToExport,
            displayContent: displayedContent
        )
        .onAppear {
            // Initialize displayedContent when view first appears
            displayedContent = filterContent(message.content)
            logger.info("[ASSISTANT_BUBBLE] Initial render message \(message.id) with \(message.content.count) chars, filtered=\(displayedContent.count) chars")
        }
        .onChange(of: message.content) { _, newValue in
            // Streaming: re-filter and update @State so the change animates smoothly
            let filtered = filterContent(newValue)
            if displayedContent != filtered {
                displayedContent = filtered
            }
        }
    }
}

// MARK: - Tool Execution Card (Full Width)

struct ToolExecutionCard: View {
    let message: EnhancedMessage
    let enableAnimations: Bool
    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            /// Header (clickable to expand/collapse) - compact to match "Click to expand" height.
            HStack(spacing: 8) {
                /// Icon from MCP metadata (SF Symbol) or fallback - smaller.
                if let iconName = message.toolIcon {
                    Image(systemName: iconName)
                        .font(.body)
                        .foregroundColor(.primary)
                } else {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.body)
                        .foregroundColor(.primary)
                }

                /// Tool name - smaller font.
                Text(getOperationDisplayName(from: message.content, toolName: message.toolName, displayData: message.toolDisplayData))
                    .font(.subheadline)
                    .foregroundColor(.primary)

                Spacer()

                /// Status badge (already compact).
                statusBadge

                /// Expand/collapse button.
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
                    .font(.caption)
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

            /// Collapsed view - NO bottom section, only header is visible
            /// User must click header to see details

            /// Expanded details - show divider and content
            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    /// Tool metadata (result data - NEW!)
                    if let metadata = message.toolMetadata, !metadata.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Result:")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            ForEach(Array(metadata.keys.sorted()), id: \.self) { key in
                                if let value = metadata[key] {
                                    HStack(alignment: .top, spacing: 4) {
                                        Text("\(formatMetadataKey(key)):")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text(value)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.accentColor.opacity(0.05))
                        .cornerRadius(6)
                    }

                    /// Full operation details.
                    if let details = message.toolDetails, !details.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Operations:")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            ForEach(details, id: \.self) { detail in
                                Text("• \(detail)")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                        }
                    }

                    /// Tool output/content.
                    /// Show SUCCESS messages as output (they contain important result info)
                    /// Only hide "→ " progress indicators (streaming progress updates)
                    let isProgressIndicator = message.content.hasPrefix("→ ")
                    if !message.content.isEmpty && !isProgressIndicator {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Output:")
                                .font(.caption)
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

                    /// Performance metrics.
                    if let duration = message.toolDuration {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Performance:")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            Text("Duration: \(String(format: "%.1f", duration))s")
                                .font(.caption)
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
            /// Auto-expand on errors.
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
                .font(.caption)
                .foregroundColor(statusColor)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.15))
        )
    }

    private var statusColor: Color {
        switch message.toolStatus {
        case .queued:
            return .secondary

        case .running:
            return .primary

        case .success:
            return .primary

        case .error:
            return .red

        case .userInputRequired:
            return .secondary

        case .none:
            return .secondary
        }
    }

    private var statusText: String {
        switch message.toolStatus {
        case .queued:
            return "Queued"

        case .running:
            return "Running"

        case .success:
            return "Complete"

        case .error:
            return "Error"

        case .userInputRequired:
            return "Waiting"

        case .none:
            return "Unknown"
        }
    }

    /// Format metadata key for display (convert snake_case to Title Case)
    private func formatMetadataKey(_ key: String) -> String {
        /// Convert snake_case and camelCase to Title Case
        let words = key.split(separator: "_").map { word in
            String(word.prefix(1).uppercased() + word.dropFirst())
        }
        return words.joined(separator: " ")
    }
}

// MARK: - System Status Card (Placeholder)

struct SystemStatusCard: View {
    let message: EnhancedMessage
    let enableAnimations: Bool

    var body: some View {
        HStack {
            Spacer()
            Text(message.content)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                )
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Thinking Card

/// Unified with ToolExecutionCard pattern for consistent persistence and rendering This ensures thinking cards persist correctly across app restarts.
struct ThinkingCard: View {
    let message: EnhancedMessage
    let enableAnimations: Bool
    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            /// Header (clickable to expand/collapse) - matches ToolExecutionCard.
            HStack(spacing: 8) {
                /// Brain icon for thinking/reasoning.
                Image(systemName: message.toolIcon ?? "brain.head.profile")
                    .font(.body)
                    .foregroundColor(.primary)

                /// Display name - use "Reasoning" instead of raw toolName.
                Text("Reasoning")
                    .font(.subheadline)
                    .foregroundColor(.primary)

                Spacer()

                /// Status badge (same pattern as ToolExecutionCard).
                statusBadge

                /// Expand/collapse button.
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
                    .font(.caption)
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

            /// Collapsed view - minimal single line summary.
            if !isExpanded {
                HStack {
                    if let duration = message.toolDuration {
                        Text("Completed in \(String(format: "%.1f", duration))s")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Click to expand")
                            .font(.caption)
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

            /// Expanded details.
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    /// Reasoning content (primary content for thinking cards).
                    let displayContent = message.reasoningContent ?? message.content
                    let cleanedContent = displayContent
                        .replacingOccurrences(of: "SUCCESS: Thinking:", with: "")
                        .replacingOccurrences(of: "Thinking:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !cleanedContent.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reasoning:")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            MarkdownText(cleanedContent)
                                .font(.caption)
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(6)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Status:")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            Text("No reasoning content available")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }

                    /// Performance metrics (if available).
                    if let duration = message.toolDuration {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Performance:")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            Text("Duration: \(String(format: "%.1f", duration))s")
                                .font(.caption)
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
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption)
                .foregroundColor(statusColor)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.15))
        )
    }

    private var statusColor: Color {
        switch message.toolStatus {
        case .success:
            return .primary
        case .running:
            return .primary
        case .error:
            return .red
        default:
            return .primary
        }
    }

    private var statusText: String {
        switch message.toolStatus {
        case .success:
            return "Complete"
        case .running:
            return "Thinking"
        case .error:
            return "Error"
        default:
            return "Thinking"
        }
    }
}
