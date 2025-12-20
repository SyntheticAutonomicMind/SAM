// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Injects memory context into agent prompts to prevent duplicate memory stores.
/// This addresses the issue where agents repeatedly store the same content across
/// auto-continue iterations because they don't "remember" what was just stored.
///
/// Pattern: Track recently stored memories and inject a reminder into the LLM prompt
/// so it knows not to re-store the same content.
public class MemoryReminderInjector {
    private let logger = Logging.Logger(label: "com.sam.MemoryReminderInjector")

    /// Recently stored memories: Key = conversationId, Value = array of (memoryId, timestamp, contentPreview)
    private var recentlyStoredMemories: [UUID: [(memoryId: UUID, timestamp: Date, contentPreview: String)]] = [:]

    /// How long to remember stored memories (5 minutes - matches workflow session duration)
    private let memoryWindowSeconds: TimeInterval = 300

    public nonisolated(unsafe) static let shared = MemoryReminderInjector()

    private init() {
        logger.debug("MemoryReminderInjector initialized")
    }

    /// Record that a memory was stored (called by MemoryOperationsTool after successful store)
    public func recordMemoryStored(
        conversationId: UUID,
        memoryId: UUID,
        contentPreview: String
    ) {
        // Clean up old entries first
        cleanupExpiredEntries(for: conversationId)

        // Add new entry
        if recentlyStoredMemories[conversationId] == nil {
            recentlyStoredMemories[conversationId] = []
        }
        recentlyStoredMemories[conversationId]?.append((memoryId, Date(), contentPreview))

        logger.debug("Recorded memory store: \(memoryId.uuidString.prefix(8)) for conversation \(conversationId.uuidString.prefix(8))")
    }

    /// Clear memories for a conversation (e.g., when starting fresh)
    public func clearMemories(for conversationId: UUID) {
        recentlyStoredMemories.removeValue(forKey: conversationId)
        logger.debug("Cleared memory tracking for conversation \(conversationId.uuidString.prefix(8))")
    }

    /// Clean up expired entries for a conversation
    private func cleanupExpiredEntries(for conversationId: UUID) {
        guard var entries = recentlyStoredMemories[conversationId] else { return }

        let now = Date()
        let originalCount = entries.count
        entries = entries.filter { now.timeIntervalSince($0.timestamp) < memoryWindowSeconds }

        if entries.count != originalCount {
            logger.debug("Cleaned up \(originalCount - entries.count) expired memory entries for conversation \(conversationId.uuidString.prefix(8))")
        }

        recentlyStoredMemories[conversationId] = entries
    }

    /// Check if reminder should be injected
    /// Returns true if there are recently stored memories for this conversation
    public func shouldInjectReminder(conversationId: UUID) -> Bool {
        cleanupExpiredEntries(for: conversationId)

        guard let entries = recentlyStoredMemories[conversationId] else {
            return false
        }

        return !entries.isEmpty
    }

    /// Get count of recently stored memories
    public func getStoredCount(for conversationId: UUID) -> Int {
        cleanupExpiredEntries(for: conversationId)
        return recentlyStoredMemories[conversationId]?.count ?? 0
    }

    /// Format memory reminder for injection into prompt
    /// Lists recently stored memories so the LLM knows not to re-store them
    public func formatMemoryReminder(conversationId: UUID) -> String? {
        cleanupExpiredEntries(for: conversationId)

        guard let entries = recentlyStoredMemories[conversationId], !entries.isEmpty else {
            return nil
        }

        var reminder = """
        <recentlyStoredMemories>
        IMPORTANT: The following memories were ALREADY STORED during this session.
        DO NOT store them again - move on to the next task.

        """

        for (index, entry) in entries.enumerated() {
            reminder += "\(index + 1). [\(entry.memoryId.uuidString.prefix(8))...] \(entry.contentPreview)\n"
        }

        reminder += """

        If you are about to store any of the above content, STOP.
        That memory already exists. Move to the NEXT task instead.
        </recentlyStoredMemories>
        """

        return reminder
    }
}
