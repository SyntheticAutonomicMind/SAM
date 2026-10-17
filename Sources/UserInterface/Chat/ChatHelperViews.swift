// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import AppKit
import ConversationEngine
import ConfigurationSystem
import Logging

/// Helper views extracted from ChatWidget for maintainability.
/// Contains: EnhancedMemoryItemView, ProcessingStatus, ToolMessageWithChildren.

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

// MARK: - Enhanced Memory Item View

struct EnhancedMemoryItemView: View {
    let memory: ConversationMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            /// Header with source badge.
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

            /// Content.
            Text(memory.content.prefix(200))
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(3)

            /// Context from tags.
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