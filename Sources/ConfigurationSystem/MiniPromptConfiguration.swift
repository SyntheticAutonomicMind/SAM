// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Combine
import Logging

/// A mini-prompt that can be injected into the system prompt.
public struct MiniPrompt: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var content: String
    public var createdAt: Date
    public var modifiedAt: Date

    /// Display order for sorting (lower = higher priority).
    public var displayOrder: Int

    /// Conversation IDs this prompt is associated with (nil = global) Global prompts (conversationIds == nil) are available to all conversations Scoped prompts are only available to specific conversations.
    public var conversationIds: Set<UUID>?

    public init(
        id: UUID = UUID(),
        name: String,
        content: String,
        displayOrder: Int = 0,
        conversationIds: Set<UUID>? = nil
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.displayOrder = displayOrder
        self.conversationIds = conversationIds
    }

    public mutating func update(name: String? = nil, content: String? = nil) {
        if let name = name { self.name = name }
        if let content = content { self.content = content }
        self.modifiedAt = Date()
    }

    // MARK: - Codable (Custom to handle migration from old format)

    enum CodingKeys: String, CodingKey {
        case id, name, content, createdAt, modifiedAt, displayOrder, conversationIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)

        /// New fields with defaults for backward compatibility.
        displayOrder = try container.decodeIfPresent(Int.self, forKey: .displayOrder) ?? 0
        conversationIds = try container.decodeIfPresent(Set<UUID>.self, forKey: .conversationIds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(displayOrder, forKey: .displayOrder)
        try container.encodeIfPresent(conversationIds, forKey: .conversationIds)
    }
}

/// Manages mini-prompts for contextual injection.
public class MiniPromptManager: ObservableObject {
    nonisolated(unsafe) public static let shared = MiniPromptManager()

    @Published public var miniPrompts: [MiniPrompt] = []

    private let logger = Logger(label: "com.sam.miniprompts")
    private let fileURL: URL

    private init() {
        /// Save to Application Support/SAM/mini_prompts.json.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let samDir = appSupport.appendingPathComponent("SAM", isDirectory: true)

        try? FileManager.default.createDirectory(at: samDir, withIntermediateDirectories: true)

        fileURL = samDir.appendingPathComponent("mini_prompts.json")

        loadPrompts()
    }

    /// Add a new prompt.
    public func addPrompt(_ prompt: MiniPrompt) {
        miniPrompts.append(prompt)
        savePrompts()
        logger.info("Added mini-prompt: \(prompt.name)")
    }

    /// Update existing prompt.
    public func updatePrompt(_ prompt: MiniPrompt) {
        if let index = miniPrompts.firstIndex(where: { $0.id == prompt.id }) {
            miniPrompts[index] = prompt
            savePrompts()
            logger.info("Updated mini-prompt: \(prompt.name)")
        }
    }

    /// Delete prompt.
    public func deletePrompt(id: UUID) {
        miniPrompts.removeAll { $0.id == id }
        savePrompts()
        logger.info("Deleted mini-prompt: \(id)")
    }

    /// Get all enabled prompts for a specific conversation.
    public func enabledPrompts(for conversationId: UUID, enabledIds: Set<UUID>) -> [MiniPrompt] {
        miniPrompts
            .filter { enabledIds.contains($0.id) }
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    /// Get combined text of enabled prompts for a conversation.
    public func getInjectedText(for conversationId: UUID, enabledIds: Set<UUID>) -> String {
        let prompts = enabledPrompts(for: conversationId, enabledIds: enabledIds)
        let texts = prompts.map { $0.content }
        return texts.joined(separator: "\n\n")
    }

    /// Reorder a prompt to a new position - Parameters: - promptId: UUID of the prompt to reorder - toIndex: New position index (0-based).
    public func reorder(prompt promptId: UUID, to toIndex: Int) {
        guard let fromIndex = miniPrompts.firstIndex(where: { $0.id == promptId }) else {
            logger.warning("Cannot reorder prompt: not found")
            return
        }

        /// Move the prompt.
        let prompt = miniPrompts.remove(at: fromIndex)
        let safeIndex = min(toIndex, miniPrompts.count)
        miniPrompts.insert(prompt, at: safeIndex)

        /// Update displayOrder for all prompts.
        for (index, _) in miniPrompts.enumerated() {
            miniPrompts[index].displayOrder = index
        }

        savePrompts()
        logger.info("Reordered mini-prompt: \(prompt.name) to position \(toIndex)")
    }

    /// Associate a prompt with a specific conversation - Parameters: - promptId: UUID of the prompt - conversationId: UUID of the conversation to associate with.
    public func associate(prompt promptId: UUID, with conversationId: UUID) {
        guard let index = miniPrompts.firstIndex(where: { $0.id == promptId }) else {
            logger.warning("Cannot associate prompt: not found")
            return
        }

        /// If conversationIds is nil (global), create a new set.
        if miniPrompts[index].conversationIds == nil {
            miniPrompts[index].conversationIds = Set([conversationId])
        } else {
            miniPrompts[index].conversationIds?.insert(conversationId)
        }

        savePrompts()
        logger.info("Associated mini-prompt: \(miniPrompts[index].name) with conversation \(conversationId)")
    }

    /// Dissociate a prompt from a specific conversation - Parameters: - promptId: UUID of the prompt - conversationId: UUID of the conversation to dissociate from.
    public func dissociate(prompt promptId: UUID, from conversationId: UUID) {
        guard let index = miniPrompts.firstIndex(where: { $0.id == promptId }) else {
            logger.warning("Cannot dissociate prompt: not found")
            return
        }

        miniPrompts[index].conversationIds?.remove(conversationId)

        /// If conversationIds becomes empty, set to nil (make it global again).
        if miniPrompts[index].conversationIds?.isEmpty == true {
            miniPrompts[index].conversationIds = nil
        }

        savePrompts()
        logger.info("Dissociated mini-prompt: \(miniPrompts[index].name) from conversation \(conversationId)")
    }

    /// Get prompts for a specific conversation (including global prompts) - Parameters: - conversationId: UUID of the conversation - includeGlobal: Whether to include global prompts (default: true) - Returns: Filtered and sorted prompts.
    public func prompts(for conversationId: UUID, includeGlobal: Bool = true) -> [MiniPrompt] {
        miniPrompts
            .filter { prompt in
                /// Global prompts (conversationIds == nil).
                if prompt.conversationIds == nil {
                    return includeGlobal
                }
                /// Conversation-specific prompts.
                return prompt.conversationIds?.contains(conversationId) == true
            }
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    /// Toggle enabled state for a conversation.
    public func toggleEnabled(id: UUID, for conversationId: UUID, currentIds: inout Set<UUID>) {
        if currentIds.contains(id) {
            currentIds.remove(id)
            logger.info("Disabled mini-prompt for conversation \(conversationId): \(miniPrompts.first(where: { $0.id == id })?.name ?? "unknown")")
        } else {
            currentIds.insert(id)
            logger.info("Enabled mini-prompt for conversation \(conversationId): \(miniPrompts.first(where: { $0.id == id })?.name ?? "unknown")")
        }
    }

    /// Check if a prompt is enabled for a conversation.
    public func isEnabled(id: UUID, for conversationId: UUID, enabledIds: Set<UUID>) -> Bool {
        enabledIds.contains(id)
    }

    // MARK: - Persistence

    private func loadPrompts() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.info("No saved mini-prompts found, starting fresh")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            miniPrompts = try JSONDecoder().decode([MiniPrompt].self, from: data)
            logger.info("Loaded \(miniPrompts.count) mini-prompts")
        } catch {
            logger.error("Failed to load mini-prompts: \(error)")
        }
    }

    private func savePrompts() {
        do {
            /// Create backup before saving (protect against data loss).
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let backupURL = fileURL.deletingPathExtension().appendingPathExtension("backup.json")
                try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            }

            let data = try JSONEncoder().encode(miniPrompts)
            try data.write(to: fileURL)
            logger.debug("Saved \(miniPrompts.count) mini-prompts")
        } catch {
            logger.error("Failed to save mini-prompts: \(error)")
        }
    }
}
