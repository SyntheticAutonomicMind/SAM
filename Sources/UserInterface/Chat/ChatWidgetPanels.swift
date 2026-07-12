// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConversationEngine
import ConfigurationSystem
import Logging

extension ChatWidget {
    // MARK: - Conditional Panels
    
    @ViewBuilder
    var conditionalPanels: some View {
        if showingPerformanceMetrics {
            Divider()
            UserInterface.PerformanceMetricsView(
                performanceMonitor: performanceMonitor,
                isVisible: $showingPerformanceMetrics
            )
        }

        if showingMemoryPanel {
            Divider()
            sessionIntelligencePanel
        }

        if showingWorkingDirectoryPanel {
            Divider()
            workingDirectoryPanel
        }

    }

    var sessionIntelligencePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Session Intelligence")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                /// Close button.
                Button(action: {
                    withAnimation { showingMemoryPanel.toggle() }
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Session Intelligence panel")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            /// SECTION 1: Memory Status
            memoryStatusSection
                .padding(.horizontal, 16)

            Divider()
                .padding(.horizontal, 16)

            /// SECTION 2: Context Management
            contextManagementSection
                .padding(.horizontal, 16)

            Divider()
                .padding(.horizontal, 16)

            /// SECTION 3: Enhanced Search
            enhancedSearchSection
                .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
        .background(Color.clear)
        .onAppear {
            loadMemoryStatistics()
        }
        .onChange(of: activeConversation?.id) { _, _ in
            loadMemoryStatistics()
            conversationMemories.removeAll()
            memorySearchQuery = ""
        }
        .onChange(of: activeConversation?.settings.sharedTopicId) { _, _ in
            loadMemoryStatistics()
            conversationMemories.removeAll()
            memorySearchQuery = ""
        }
    }

    var workingDirectoryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Working Directory")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                /// Close button.
                Button(action: {
                    withAnimation { showingWorkingDirectoryPanel.toggle() }
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close working directory panel")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            /// Current working directory.
            if let conversation = conversationManager.activeConversation {
                VStack(alignment: .leading, spacing: 8) {
                    /// Shared topic indicator (when enabled)
                    if conversation.settings.useSharedData,
                       let topicName = conversation.settings.sharedTopicName {
                        HStack(spacing: 6) {
                            Image(systemName: "tray.full")
                                .font(.caption2)
                                .foregroundColor(.mint)
                            Text("Shared Topic: \(topicName)")
                                .font(.caption)
                                .foregroundColor(.mint)
                        }
                    }

                    Text(conversation.settings.useSharedData ? "Current Directory (Shared):" : "Current Directory:")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(conversationManager.getEffectiveWorkingDirectory(for: conversation))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(conversation.settings.useSharedData ? .mint : .primary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(conversation.settings.useSharedData ?
                            Color.mint.opacity(0.05) : Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(conversation.settings.useSharedData ? Color.mint.opacity(0.3) : Color.clear, lineWidth: 1)
                        )

                    Text(conversation.settings.useSharedData ?
                        "Using shared topic workspace. All file operations use this shared directory across conversations." :
                        "All file operations will use this directory unless an absolute path is specified.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(3)

                    HStack(spacing: 8) {
                        Button("Change...") {
                            selectWorkingDirectory()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Choose a different folder for SAM to work in")
                        .disabled(conversation.settings.useSharedData)

                        Button("Reveal in Finder") {
                            revealWorkingDirectoryInFinder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open this folder in Finder")

                        Button(conversation.settings.useSharedData ? "Disable Shared Topic" : "Reset to Default") {
                            if conversation.settings.useSharedData {
                                // Disable shared data
                                useSharedData = false
                                conversationManager.detachSharedTopic()
                                syncSettingsToConversation()
                            } else {
                                resetWorkingDirectoryToDefault()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(conversation.settings.useSharedData ?
                            "Switch back to conversation-specific directory" :
                            "Return to using your home directory")
                    }
                }
                .padding(.horizontal, 16)
            } else {
                Text("No active conversation")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 8)
        .background(Color.clear)
    }

}
