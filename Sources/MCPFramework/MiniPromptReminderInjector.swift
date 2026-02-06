// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

/// Injects mini prompt reminders into agent prompts during multi-turn conversations.
/// When a user has enabled mini prompts for a conversation, this reminds the agent
/// of those instructions ONCE (not repeatedly).
///
/// Handles scenarios:
/// - User enables mini-prompt mid-conversation -> injects once
/// - User toggles mini-prompt off/on -> injects again once
/// - User changes which mini-prompts are enabled -> injects the new set once
public class MiniPromptReminderInjector {
    private let logger = Logging.Logger(label: "com.sam.MiniPromptReminderInjector")

    public nonisolated(unsafe) static let shared = MiniPromptReminderInjector()

    /// Track which mini-prompt sets have been injected for each conversation.
    /// Key: conversationId, Value: Set of mini-prompt UUIDs that were last injected.
    /// When enabledMiniPromptIds changes, we detect it and inject the new set.
    private var injectedMiniPrompts: [UUID: Set<UUID>] = [:]

    private init() {
        logger.debug("MiniPromptReminderInjector initialized")
    }

    /// Check if reminder should be injected.
    /// Returns true if the current set of enabled mini-prompts differs from what was last injected.
    ///
    /// CRITICAL: Mini-prompts should be injected ONCE when enabled, not repeatedly.
    /// - Detects when user enables new mini-prompts mid-conversation
    /// - Detects when user toggles mini-prompts off/on
    /// - Detects when user changes which mini-prompts are selected
    /// - Skips injection if the same set was already sent
    ///
    /// Call recordInjection() after successful injection to update tracking.
    public func shouldInjectReminder(
        conversationId: UUID,
        enabledMiniPromptIds: Set<UUID>,
        currentResponseCount: Int
    ) -> Bool {
        logger.debug("MINI_PROMPT_TRACE: shouldInjectReminder called - convId=\(conversationId.uuidString.prefix(8)), enabledCount=\(enabledMiniPromptIds.count), responseCount=\(currentResponseCount)")
        
        /// If no mini-prompts are enabled, CLEAR any recorded state and skip injection.
        /// This handles the disable scenario - when user disables all prompts, we forget
        /// what was injected so that re-enabling will trigger a fresh injection.
        guard !enabledMiniPromptIds.isEmpty else {
            if injectedMiniPrompts[conversationId] != nil {
                injectedMiniPrompts[conversationId] = nil
                logger.info("MINI_PROMPT_TRACE: Cleared injection state (mini-prompts disabled)")
            } else {
                logger.debug("MINI_PROMPT_TRACE: No mini-prompts enabled, returning false")
            }
            return false
        }

        /// Check if we've already injected this exact set of mini-prompts.
        if let alreadyInjected = injectedMiniPrompts[conversationId] {
            if alreadyInjected == enabledMiniPromptIds {
                /// Same set already injected - skip.
                logger.debug("MINI_PROMPT_TRACE: Same set already injected (\(alreadyInjected.count) prompts), returning false")
                return false
            } else {
                /// Different set - inject the new one.
                logger.info("MINI_PROMPT: Detected change in enabled mini-prompts for conversation \(conversationId.uuidString.prefix(8)) (was: \(alreadyInjected.count), now: \(enabledMiniPromptIds.count))")
                return true
            }
        } else {
            /// Never injected for this conversation - inject now.
            logger.info("MINI_PROMPT: First injection for conversation \(conversationId.uuidString.prefix(8)) (\(enabledMiniPromptIds.count) mini-prompts)")
            return true
        }
    }

    /// Record that we successfully injected mini-prompts for this conversation.
    /// Call this after formatMiniPromptReminder() returns non-nil and is added to messages.
    public func recordInjection(
        conversationId: UUID,
        enabledMiniPromptIds: Set<UUID>
    ) {
        injectedMiniPrompts[conversationId] = enabledMiniPromptIds
        logger.info("MINI_PROMPT_TRACE: Recorded injection for conversation \(conversationId.uuidString.prefix(8)) (\(enabledMiniPromptIds.count) mini-prompts) - IDs: \(enabledMiniPromptIds.map { $0.uuidString.prefix(8) }.joined(separator: ", "))")
    }

    /// Format mini prompt reminder for injection.
    /// Gets the enabled mini prompts and creates a reminder.
    public func formatMiniPromptReminder(
        conversationId: UUID,
        enabledMiniPromptIds: Set<UUID>
    ) -> String? {
        logger.debug("MINI_PROMPT_TRACE: formatMiniPromptReminder called - convId=\(conversationId.uuidString.prefix(8)), enabledCount=\(enabledMiniPromptIds.count)")
        
        let enabledPrompts = MiniPromptManager.shared.enabledPrompts(
            for: conversationId,
            enabledIds: enabledMiniPromptIds
        )

        guard !enabledPrompts.isEmpty else {
            logger.debug("MINI_PROMPT_TRACE: No enabled prompts from MiniPromptManager, returning nil")
            return nil
        }

        let promptsText = MiniPromptManager.shared.getInjectedText(
            for: conversationId,
            enabledIds: enabledMiniPromptIds
        )

        logger.info("MINI_PROMPT_TRACE: Formatted reminder with \(enabledPrompts.count) prompts: \(enabledPrompts.map { $0.name }.joined(separator: ", "))")
        
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
