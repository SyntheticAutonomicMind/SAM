// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConversationEngine
import ConfigurationSystem
import Logging

extension ChatWidget {
    // MARK: - Chat Header

    var chatHeader: some View {
        VStack(spacing: 0) {
            /// Conversation Info Header (when available).
            if let conversation = activeConversation {
                VStack(alignment: .leading, spacing: 0) {
                    /// Line 1: Title + Shared indicator with topic name
                    HStack {
                        Text(conversation.title)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .contextMenu {
                                conversationHeaderContextMenu(conversation)
                            }

                        Spacer()

                        /// Active mini-prompts (when sidebar closed) - shown on same line as title
                        if !showingMiniPrompts {
                            let miniPromptManager = MiniPromptManager.shared
                            let enabledPrompts = miniPromptManager.miniPrompts
                                .filter { conversation.enabledMiniPromptIds.contains($0.id) }
                                .sorted { $0.displayOrder < $1.displayOrder }

                            if !enabledPrompts.isEmpty {
                                let promptNames = enabledPrompts.map { $0.name }.joined(separator: ", ")
                                let displayText = promptNames.count > 80 ? String(promptNames.prefix(80)) + "..." : promptNames

                                Text(displayText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        /// Shared topic indicator with topic name
                        if conversation.settings.useSharedData {
                            HStack(spacing: 4) {
                                Image(systemName: "link.circle.fill")
                                    .foregroundColor(.mint)
                                if let topicName = conversation.settings.sharedTopicName {
                                    Text(topicName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("Shared")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                    }

                    /// Line 2: Message count, ID, provider status
                    HStack(spacing: 12) {
                        /// Message count
                        HStack(spacing: 4) {
                            Image(systemName: "message.fill")
                                .font(.caption)
                            Text("\(conversation.messages.count) messages")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)

                        /// Conversation ID (full, selectable)
                        Text("ID: \(conversation.id.uuidString)")
                            .font(.system(.caption2, design: .monospaced))
                            .fontWeight(.regular)
                            .foregroundColor(.secondary.opacity(0.7))
                            .textSelection(.enabled)

                        Spacer()

                        /// AI Credits usage indicator (GitHub Copilot only)
                        let isGitHubCopilot = selectedModel.starts(with: "github_copilot/")

                        if isGitHubCopilot, let quotaInfo = endpointManager.getGitHubCopilotQuotaInfo() {
                            if let creditsUsed = quotaInfo.creditsUsed, creditsUsed > 0 {
                                let creditsStr = String(format: "%.2f", creditsUsed)
                                Text("AI Credits: \(creditsStr) used")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("AI Credits billing")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.top, 4)  /// Space from Line 1 (or Line 2 if shown)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color(NSColor.separatorColor)),
                    alignment: .bottom
                )
            }
        }
    }
}
