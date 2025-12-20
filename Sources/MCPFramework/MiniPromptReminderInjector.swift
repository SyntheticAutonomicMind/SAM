// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

/// Injects mini prompt reminders into agent prompts during multi-turn conversations.
/// When a user has enabled mini prompts for a conversation, this reminds the agent
/// of those instructions before each response.
///
/// This addresses the issue where agents "forget" user-specified instructions during long
/// research sessions and output interim summaries/bullet lists instead of following the user's requirements.
public class MiniPromptReminderInjector {
    private let logger = Logging.Logger(label: "com.sam.MiniPromptReminderInjector")

    public nonisolated(unsafe) static let shared = MiniPromptReminderInjector()

    private init() {
        logger.debug("MiniPromptReminderInjector initialized")
    }

    /// Check if reminder should be injected.
    /// Returns true if:
    /// 1. There are enabled mini prompts for this conversation
    /// 2. This isn't the first response (agent should already see context on first turn)
    public func shouldInjectReminder(
        conversationId: UUID,
        enabledMiniPromptIds: Set<UUID>,
        currentResponseCount: Int
    ) -> Bool {
        /// Only inject after first turn (agent sees context naturally on first turn).
        guard currentResponseCount > 1 else { return false }

        /// Check if there are any enabled mini prompts.
        return !enabledMiniPromptIds.isEmpty
    }

    /// Format mini prompt reminder for injection.
    /// Gets the enabled mini prompts and creates a reminder.
    public func formatMiniPromptReminder(
        conversationId: UUID,
        enabledMiniPromptIds: Set<UUID>
    ) -> String? {
        let enabledPrompts = MiniPromptManager.shared.enabledPrompts(
            for: conversationId,
            enabledIds: enabledMiniPromptIds
        )

        guard !enabledPrompts.isEmpty else {
            return nil
        }

        let promptsText = MiniPromptManager.shared.getInjectedText(
            for: conversationId,
            enabledIds: enabledMiniPromptIds
        )

        /// Create a concise but strong reminder.
        return """
        <miniPromptReminder>
        IMPORTANT REMINDER - User has specified the following instructions that you MUST follow:

        \(promptsText)

        These instructions take priority. Follow them exactly.
        </miniPromptReminder>
        """
    }
}
