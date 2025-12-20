// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConfigurationSystem

/// SAM-specific configuration paths for conversation-scoped data SAM stores conversation-specific configuration in: ~/Library/Application Support/SAM/conversations/{CONVERSATION_ID}/ SAM uses conversation-scoped configuration instead of project-specific paths.
public struct SAMConfigurationPaths {
    /// Get the SAM configuration directory for a specific conversation Returns: ~/Library/Application Support/SAM/conversations/{conversationId}/.
    public static func conversationConfigDirectory(conversationId: String) throws -> URL {
        let fileManager = FileManager.default

        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let samDirectory = appSupport.appendingPathComponent("SAM")
        let conversationsDirectory = samDirectory.appendingPathComponent("conversations")
        let conversationDirectory = conversationsDirectory.appendingPathComponent(conversationId)

        /// Create directory structure if it doesn't exist.
        try fileManager.createDirectory(
            at: conversationDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        return conversationDirectory
    }

    /// Get the path to tasks.json for a specific conversation Returns: ~/Library/Application Support/SAM/conversations/{conversationId}/tasks.json.
    public static func tasksFilePath(conversationId: String) throws -> URL {
        let configDir = try conversationConfigDirectory(conversationId: conversationId)
        return configDir.appendingPathComponent("tasks.json")
    }

    /// Get the conversation working directory (for file operations) DEPRECATED: Use conversation.workingDirectory instead Returns: ~/SAM/{conversationId}/ (legacy UUID-based path, should not be used for new code).
    @available(*, deprecated, message: "Use conversation.workingDirectory from ConversationModel instead")
    public static func conversationWorkingDirectory(conversationId: String) -> String {
        return NSString(string: "~/SAM/\(conversationId)/").expandingTildeInPath
    }
}
