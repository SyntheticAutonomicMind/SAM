// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// UI-level notification names for application-wide events These notifications are used by the UI layer (MainWindowView, SAMCommands, etc.) to communicate user actions and trigger UI state changes.
public extension Notification.Name {
    // MARK: - UI Setup

    /// Show preferences window.
    static let showPreferences = Notification.Name("SAM.UI.showPreferences")

    /// Show welcome screen.
    static let showWelcome = Notification.Name("SAM.UI.showWelcome")

    /// Show What's New screen.
    static let showWhatsNew = Notification.Name("SAM.UI.showWhatsNew")

    /// Show help window.
    static let showHelp = Notification.Name("SAM.UI.showHelp")

    /// Show API reference window.
    static let showAPIReference = Notification.Name("SAM.UI.showAPIReference")

    // MARK: - Conversation Management

    /// Create new conversation.
    static let newConversation = Notification.Name("SAM.UI.newConversation")

    /// Clear current conversation.
    static let clearConversation = Notification.Name("SAM.UI.clearConversation")

    /// Rename current conversation.
    static let renameConversation = Notification.Name("SAM.UI.renameConversation")

    /// Duplicate current conversation.
    static let duplicateConversation = Notification.Name("SAM.UI.duplicateConversation")

    /// Convert conversation to shared topic.
    static let convertToSharedTopic = Notification.Name("SAM.UI.convertToSharedTopic")

    /// Export conversation to file.
    static let exportConversation = Notification.Name("SAM.UI.exportConversation")

    /// Export conversation to specific path (includes path in userInfo).
    static let exportConversationWithPath = Notification.Name("SAM.UI.exportConversationWithPath")

    /// Copy conversation to clipboard.
    static let copyConversation = Notification.Name("SAM.UI.copyConversation")

    /// Print conversation.
    static let printConversation = Notification.Name("SAM.UI.printConversation")

    /// Switch to a specific conversation (includes conversationId in userInfo).
    static let switchConversation = Notification.Name("SAM.UI.switchConversation")

    /// Delete conversation.
    static let deleteConversation = Notification.Name("SAM.UI.deleteConversation")

    /// Delete all conversations.
    static let deleteAllConversations = Notification.Name("SAM.UI.deleteAllConversations")

    /// Clear all conversations (alias for deleteAllConversations).
    static let clearAllConversations = Notification.Name("SAM.UI.clearAllConversations")

    /// Create new folder.
    static let createFolder = Notification.Name("SAM.UI.createFolder")

    // MARK: - Search and Navigation

    /// Show global search overlay (Cmd+F).
    static let showGlobalSearch = Notification.Name("SAM.UI.showGlobalSearch")

    /// Scroll to a specific message (includes messageId in userInfo).
    static let scrollToMessage = Notification.Name("SAM.UI.scrollToMessage")

    /// Scroll to top of conversation.
    static let scrollToTop = Notification.Name("SAM.UI.scrollToTop")

    /// Scroll to bottom of conversation.
    static let scrollToBottom = Notification.Name("SAM.UI.scrollToBottom")

    /// Page up in conversation.
    static let pageUp = Notification.Name("SAM.UI.pageUp")

    /// Page down in conversation.
    static let pageDown = Notification.Name("SAM.UI.pageDown")

    // MARK: - System Prompt Management

    /// Switch system prompt (includes promptName in userInfo).
    static let switchSystemPrompt = Notification.Name("SAM.UI.switchSystemPrompt")
}
