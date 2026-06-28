// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Combine
import Logging

/// A custom instruction that can be injected into the conversation context.
/// Custom instructions are persistent text blocks that users can enable per-conversation
/// to give the model additional context or behavioral guidance (e.g., "Always use tabs",
/// "Here is my project structure", "Act as a TypeScript expert").
public struct CustomInstruction: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var content: String
    public var createdAt: Date
    public var modifiedAt: Date

    /// Display order for sorting (lower = higher priority).
    public var displayOrder: Int

    /// Conversation IDs this instruction is associated with (nil = global).
    /// Global instructions (conversationIds == nil) are available to all conversations.
    /// Scoped instructions are only available to specific conversations.
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

    // MARK: - Codable

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

/// Manages custom instructions for per-conversation context injection.
public class CustomInstructionManager: ObservableObject {
    nonisolated(unsafe) public static let shared = CustomInstructionManager()

    @Published public var customInstructions: [CustomInstruction] = []

    private let logger = Logger(label: "com.sam.custominstructions")
    private let fileURL: URL

    private init() {
        /// Save to Application Support/SAM/custom_instructions.json.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let samDir = appSupport.appendingPathComponent("SAM", isDirectory: true)

        try? FileManager.default.createDirectory(at: samDir, withIntermediateDirectories: true)

        fileURL = samDir.appendingPathComponent("custom_instructions.json")

        loadInstructions()
    }

    /// Add a new instruction.
    public func addInstruction(_ instruction: CustomInstruction) {
        customInstructions.append(instruction)
        saveInstructions()
        logger.info("Added custom instruction: \(instruction.name)")
    }

    /// Update existing instruction.
    public func updateInstruction(_ instruction: CustomInstruction) {
        if let index = customInstructions.firstIndex(where: { $0.id == instruction.id }) {
            customInstructions[index] = instruction
            saveInstructions()
            logger.info("Updated custom instruction: \(instruction.name)")
        }
    }

    /// Delete instruction.
    public func deleteInstruction(id: UUID) {
        customInstructions.removeAll { $0.id == id }
        saveInstructions()
        logger.info("Deleted custom instruction: \(id)")
    }

    /// Get all enabled instructions for a specific conversation.
    public func enabledInstructions(for conversationId: UUID, enabledIds: Set<UUID>) -> [CustomInstruction] {
        customInstructions
            .filter { enabledIds.contains($0.id) }
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    /// Get combined text of enabled instructions for a conversation.
    public func getInjectedText(for conversationId: UUID, enabledIds: Set<UUID>) -> String {
        let instructions = enabledInstructions(for: conversationId, enabledIds: enabledIds)
        let texts = instructions.map { $0.content }
        return texts.joined(separator: "\n\n")
    }

    /// Reorder an instruction to a new position.
    /// - Parameters:
    ///   - instructionId: UUID of the instruction to reorder
    ///   - toIndex: New position index (0-based)
    public func reorder(instruction instructionId: UUID, to toIndex: Int) {
        guard let fromIndex = customInstructions.firstIndex(where: { $0.id == instructionId }) else {
            logger.warning("Cannot reorder instruction: not found")
            return
        }

        /// Move the instruction.
        let instruction = customInstructions.remove(at: fromIndex)
        let safeIndex = min(toIndex, customInstructions.count)
        customInstructions.insert(instruction, at: safeIndex)

        /// Update displayOrder for all instructions.
        for (index, _) in customInstructions.enumerated() {
            customInstructions[index].displayOrder = index
        }

        saveInstructions()
        logger.info("Reordered custom instruction: \(instruction.name) to position \(toIndex)")
    }

    /// Associate an instruction with a specific conversation.
    /// - Parameters:
    ///   - instructionId: UUID of the instruction
    ///   - conversationId: UUID of the conversation to associate with
    public func associate(instruction instructionId: UUID, with conversationId: UUID) {
        guard let index = customInstructions.firstIndex(where: { $0.id == instructionId }) else {
            logger.warning("Cannot associate instruction: not found")
            return
        }

        /// If conversationIds is nil (global), create a new set.
        if customInstructions[index].conversationIds == nil {
            customInstructions[index].conversationIds = Set([conversationId])
        } else {
            customInstructions[index].conversationIds?.insert(conversationId)
        }

        saveInstructions()
        logger.info("Associated custom instruction: \(customInstructions[index].name) with conversation \(conversationId)")
    }

    /// Dissociate an instruction from a specific conversation.
    /// - Parameters:
    ///   - instructionId: UUID of the instruction
    ///   - conversationId: UUID of the conversation to dissociate from
    public func dissociate(instruction instructionId: UUID, from conversationId: UUID) {
        guard let index = customInstructions.firstIndex(where: { $0.id == instructionId }) else {
            logger.warning("Cannot dissociate instruction: not found")
            return
        }

        customInstructions[index].conversationIds?.remove(conversationId)

        /// If conversationIds becomes empty, set to nil (make it global again).
        if customInstructions[index].conversationIds?.isEmpty == true {
            customInstructions[index].conversationIds = nil
        }

        saveInstructions()
        logger.info("Dissociated custom instruction: \(customInstructions[index].name) from conversation \(conversationId)")
    }

    /// Get instructions for a specific conversation (including global instructions).
    /// - Parameters:
    ///   - conversationId: UUID of the conversation
    ///   - includeGlobal: Whether to include global instructions (default: true)
    /// - Returns: Filtered and sorted instructions
    public func instructions(for conversationId: UUID, includeGlobal: Bool = true) -> [CustomInstruction] {
        customInstructions
            .filter { instruction in
                /// Global instructions (conversationIds == nil).
                if instruction.conversationIds == nil {
                    return includeGlobal
                }
                /// Conversation-specific instructions.
                return instruction.conversationIds?.contains(conversationId) == true
            }
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    /// Toggle enabled state for a conversation.
    public func toggleEnabled(id: UUID, for conversationId: UUID, currentIds: inout Set<UUID>) {
        if currentIds.contains(id) {
            currentIds.remove(id)
            logger.info("Disabled custom instruction for conversation \(conversationId): \(customInstructions.first(where: { $0.id == id })?.name ?? "unknown")")
        } else {
            currentIds.insert(id)
            logger.info("Enabled custom instruction for conversation \(conversationId): \(customInstructions.first(where: { $0.id == id })?.name ?? "unknown")")
        }
    }

    /// Check if an instruction is enabled for a conversation.
    public func isEnabled(id: UUID, for conversationId: UUID, enabledIds: Set<UUID>) -> Bool {
        enabledIds.contains(id)
    }

    // MARK: - Persistence

    private func loadInstructions() {
        /// Migration: if the old mini_prompts.json exists and custom_instructions.json doesn't,
        /// load from the old file then save to the new location.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let samDir = appSupport.appendingPathComponent("SAM", isDirectory: true)
        let legacyURL = samDir.appendingPathComponent("mini_prompts.json")

        if !FileManager.default.fileExists(atPath: fileURL.path)
            && FileManager.default.fileExists(atPath: legacyURL.path) {
            logger.info("Migrating from legacy mini_prompts.json to custom_instructions.json")
            do {
                let data = try Data(contentsOf: legacyURL)
                customInstructions = try JSONDecoder().decode([CustomInstruction].self, from: data)
                saveInstructions()
                logger.info("Migrated \(customInstructions.count) custom instructions")
                return
            } catch {
                logger.error("Failed to migrate legacy mini_prompts.json: \(error)")
            }
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.info("No saved custom instructions found, starting fresh")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            customInstructions = try JSONDecoder().decode([CustomInstruction].self, from: data)
            logger.info("Loaded \(customInstructions.count) custom instructions")
        } catch {
            logger.error("Failed to load custom instructions: \(error)")
        }
    }

    private func saveInstructions() {
        do {
            /// Create backup before saving (protect against data loss).
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let backupURL = fileURL.deletingPathExtension().appendingPathExtension("backup.json")
                try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            }

            let data = try JSONEncoder().encode(customInstructions)
            try data.write(to: fileURL)
            logger.debug("Saved \(customInstructions.count) custom instructions")
        } catch {
            logger.error("Failed to save custom instructions: \(error)")
        }
    }
}
