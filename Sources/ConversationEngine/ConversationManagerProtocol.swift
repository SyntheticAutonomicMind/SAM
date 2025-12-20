// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

@MainActor
public protocol ConversationManagerProtocol: AnyObject {
    /// Get conversation count.
    func getConversationCount() -> Int

    /// Check if there's an active conversation.
    func hasActiveConversation() -> Bool

    /// Get conversation information as dictionaries (to avoid circular dependency on ConversationModel).
    func getConversationInfo() -> [[String: Any]]

    /// Export conversation to file - Parameters: - conversationId: Optional conversation ID (if nil, exports active conversation) - format: Export format (json, text, markdown) - outputPath: File path to write export - Returns: Tuple with success status and optional error message.
    func exportConversationToFile(conversationId: String?, format: String, outputPath: String) -> (success: Bool, error: String?)
}
