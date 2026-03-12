// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import AppKit
import ConversationEngine
import ConfigurationSystem
import Logging

/// Helper views extracted from ChatWidget for maintainability.
/// Contains: MemoryItemView, EnhancedMemoryItemView, EnhancedMessageBubble,
/// ProcessingStatus, ProgressIndicatorView, ToolMessageWithChildren.

// MARK: - UI Setup

struct MemoryItemView: View {
    let memory: ConversationMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                /// Memory content type icon.
                Image(systemName: iconForContentType(memory.contentType))
                    .foregroundColor(colorForContentType(memory.contentType))
                    .font(.caption)

                /// Content preview.
                Text(memory.content)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                Spacer()

                /// Similarity score.
                Text(String(format: "%.0f%%", memory.similarity * 100))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack {
                Text(memory.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                Text("\(memory.accessCount) accesses")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if !memory.tags.isEmpty {
                    Text("• \(memory.tags.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func iconForContentType(_ type: ConversationEngine.MemoryContentType) -> String {
        switch type {
        case .message: return "message"
        case .userInput: return "person.crop.circle"
        case .assistantResponse: return "brain.head.profile"
        case .systemEvent: return "gear"
        case .toolResult: return "wrench.and.screwdriver"
        case .contextInfo: return "info.circle"
        case .document: return "doc.text"
        }
    }

    private func colorForContentType(_ type: ConversationEngine.MemoryContentType) -> Color {
        switch type {
        case .message: return .primary
        case .userInput: return .blue
        case .assistantResponse: return .green
        case .systemEvent: return .orange
        case .toolResult: return .purple
        case .contextInfo: return .secondary
        case .document: return .indigo
        }
    }
}

struct EnhancedMemoryItemView: View {
    let memory: ConversationMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            /// Header with source badge
            HStack(spacing: 6) {
                sourceIcon

                Text(sourceLabel)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(sourceColor)

                Spacer()

                if memory.similarity > 0 && memory.similarity < 1.0 {
                    Text(String(format: "%.0f%%", memory.similarity * 100))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            /// Content
            Text(memory.content.prefix(200))
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(3)

            /// Context from tags
            if !memory.tags.isEmpty {
                Text(memory.tags.first ?? "")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
        .padding(8)
        .background(sourceBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(sourceColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var sourceIcon: some View {
        Group {
            switch memory.contentType {
            case .message:
                if isFromActiveConversation {
                    Image(systemName: "message.fill")
                } else {
                    Image(systemName: "tray.full.fill")
                }
            case .contextInfo:
                Image(systemName: "archivebox.fill")
            default:
                Image(systemName: "tray.full.fill")
            }
        }
        .font(.caption2)
        .foregroundColor(sourceColor)
    }

    private var isFromActiveConversation: Bool {
        memory.tags.first?.contains("active conversation") ?? false
    }

    private var isFromArchive: Bool {
        memory.tags.first?.contains("archive") ?? false
    }

    private var sourceLabel: String {
        if isFromActiveConversation {
            return "ACTIVE"
        } else if isFromArchive {
            return "ARCHIVE"
        } else {
            return "STORED"
        }
    }

    private var sourceColor: Color {
        if isFromActiveConversation {
            return .blue
        } else if isFromArchive {
            return .orange
        } else {
            return .green
        }
    }

    private var sourceBackground: Color {
        sourceColor.opacity(0.05)
    }
}

// MARK: - Enhanced Message Bubble

struct EnhancedMessageBubble: View {
    let message: EnhancedMessage
    let enableAnimations: Bool
    @State private var showCopyConfirmation = false

    var body: some View {
        HStack(alignment: .top) {
            if message.isFromUser {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 8) {
                /// Reasoning content (for assistant messages only).
                if !message.isFromUser && message.hasReasoning {
                    ReasoningView(
                        reasoningContent: message.reasoningContent ?? "",
                        autoExpand: message.showReasoning
                    )
                }

                /// Enhanced message content with beautiful markdown support ONLY show message bubble if there's actual content.
                if !message.content.isEmpty {
                    HStack {
                        MarkdownText(message.content)
                            .id("markdown-\(message.id)")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(message.isFromUser ?
                                          Color.accentColor :
                                          Color.primary.opacity(0.05))
                                    .shadow(
                                        color: .primary.opacity(0.1),
                                        radius: 2,
                                        x: 0,
                                        y: 1
                                    )
                            )
                            .foregroundColor(message.isFromUser ? .white : .primary)

                        /// Copy button.
                        Button(action: copyMessage) {
                            Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .help("Copy message")
                    .opacity(0.7)
                }

                /// Timestamp and performance info ONLY show metadata if there's actual content.
                if !message.content.isEmpty {
                    HStack(spacing: 8) {
                        Text(message.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption2)
                            .foregroundColor(.secondary)

                    /// Performance metrics for AI responses.
                    if !message.isFromUser, let metrics = message.performanceMetrics {
                        /// More user-friendly formatting.
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

                    if !message.isFromUser && message.hasReasoning {
                        Text("• reasoning")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .help("This message includes reasoning")
                    }
                    }
                }
            }

            if !message.isFromUser {
                Spacer(minLength: 60)
            }
        }
        .animation(enableAnimations ? .easeInOut(duration: 0.2) : nil, value: showCopyConfirmation)
    }

    private func copyMessage() {
        var copyContent = message.content

        /// Include reasoning content if available.
        if message.hasReasoning {
            copyContent = "Reasoning:\n\(message.reasoningContent ?? "")\n\nResponse:\n\(message.content)"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyContent, forType: .string)

        showCopyConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            showCopyConfirmation = false
        }
    }
}

// MARK: - Processing Status

enum ProcessingStatus: Equatable {
    case loadingModel
    case thinking
    case processingTools(toolName: String)
    case generating
    case idle

    static func == (lhs: ProcessingStatus, rhs: ProcessingStatus) -> Bool {
        switch (lhs, rhs) {
        case (.loadingModel, .loadingModel),
             (.thinking, .thinking),
             (.generating, .generating),
             (.idle, .idle):
            return true

        case (.processingTools(let lhsName), .processingTools(let rhsName)):
            return lhsName == rhsName

        default:
            return false
        }
    }
}

// MARK: - UI Setup

private struct ProgressIndicatorView: View {
    let isProcessing: Bool
    let isAnyModelLoading: Bool
    let loadingModelName: String?
    private let logger = Logging.Logger(label: "com.sam.chat.indicator")

    var body: some View {
        Group {
            /// Log whenever this View body is evaluated.
            let _ = logger.debug("DEBUG: ProgressIndicatorView body evaluated - isAnyModelLoading=\(isAnyModelLoading), currentLoadingModelName=\(loadingModelName ?? "nil"), isProcessing=\(isProcessing)")

            if isAnyModelLoading, let modelName = loadingModelName {
                let _ = logger.debug("DEBUG: Showing ORANGE loading indicator for \(modelName)")
                /// Model is loading (highest priority).
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.primary)
                    Text("Loading \(modelName)...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .onAppear {
                    logger.debug("MODEL_LOADING_UI: Orange loading indicator appeared for \(modelName)")
                }
            } else if isProcessing {
                /// Generic processing (inference, tool execution, etc.).
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Processing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Tool Message with Nested Children

/// Renders a tool message with its nested child tool messages.
struct ToolMessageWithChildren: View {
    let message: EnhancedMessage
    let children: [EnhancedMessage]
    let enableAnimations: Bool
    let conversation: ConversationModel
    @Binding var messageToExport: EnhancedMessage?
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            /// Parent tool card.
            MessageView(message: message, enableAnimations: enableAnimations, conversation: conversation, messageToExport: $messageToExport)

            /// Child tool cards (indented).
            if !children.isEmpty && isExpanded {
                VStack(spacing: 8) {
                    ForEach(children) { child in
                        MessageView(message: child, enableAnimations: enableAnimations, conversation: conversation, messageToExport: $messageToExport)
                            .padding(.leading, 30)
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}
