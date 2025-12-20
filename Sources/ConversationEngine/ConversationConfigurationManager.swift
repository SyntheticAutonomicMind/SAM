// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// File-based conversation persistence replacing UserDefaults.
@MainActor
public class ConversationConfigurationManager: ObservableObject {
    private let logger = Logger(label: "com.syntheticautonomicmind.sam.ConversationConfigurationManager")

    // MARK: - File Configuration

    private let conversationsFileName = "conversations.json"
    private let activeConversationFileName = "active-conversation.json"

    /// Base configuration directory: ~/Library/Application Support/SAM/.
    private let configurationDirectory: URL

    /// Conversations directory: ~/Library/Application Support/SAM/conversations/.
    private let conversationsDirectory: URL

    public init() {
        /// Get Application Support directory.
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        /// Create SAM configuration directory structure.
        configurationDirectory = applicationSupport.appendingPathComponent("SAM")
        conversationsDirectory = configurationDirectory.appendingPathComponent("conversations")

        /// Create directory structure on initialization.
        createDirectoryStructure()
    }

    private func createDirectoryStructure() {
        let directories = [configurationDirectory, conversationsDirectory]

        for directory in directories {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                logger.error("Failed to create directory \(directory.path): \(error)")
            }
        }
    }

    // MARK: - Conversation Management (Per-File Storage)

    /// Save single conversation to per-file storage.
    /// Each conversation is stored in: conversations/{UUID}/conversation.json
    public func saveConversation(_ conversation: ConversationModel) throws {
        let conversationDir = conversationsDirectory.appendingPathComponent(conversation.id.uuidString)
        try FileManager.default.createDirectory(at: conversationDir, withIntermediateDirectories: true)

        let fileURL = conversationDir.appendingPathComponent("conversation.json")
        let conversationData = conversation.toConversationData()
        try saveJSON(conversationData, to: fileURL)

        logger.debug("Saved conversation \(conversation.id) to per-file storage")
    }

    /// Load single conversation from per-file storage.
    public func loadConversation(id: UUID) throws -> ConversationModel? {
        let fileURL = conversationsDirectory
            .appendingPathComponent(id.uuidString)
            .appendingPathComponent("conversation.json")

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let conversationData: ConversationData = try loadJSON(from: fileURL)
        return ConversationModel.from(data: conversationData)
    }

    /// Load all conversations with migration from legacy single-file storage.
    /// Priority: per-file storage > legacy conversations.json
    /// After loading from legacy, moves the file to backups directory.
    public func loadConversationsWithMigration() throws -> [ConversationModel] {
        var conversations: [ConversationModel] = []
        var loadedIds = Set<UUID>()

        // 1. Load from per-file storage first (takes priority)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: conversationsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        for item in (contents ?? []) {
            // Skip non-directories and special directories
            guard item.hasDirectoryPath else { continue }
            let dirName = item.lastPathComponent
            guard dirName != "backups" else { continue }

            let conversationFile = item.appendingPathComponent("conversation.json")
            guard FileManager.default.fileExists(atPath: conversationFile.path) else { continue }

            do {
                let data: ConversationData = try loadJSON(from: conversationFile)
                let conversation = ConversationModel.from(data: data)
                conversations.append(conversation)
                loadedIds.insert(conversation.id)
                logger.debug("Loaded conversation \(conversation.id) from per-file storage")
            } catch {
                logger.error("Failed to load \(item.lastPathComponent): \(error)")
            }
        }

        // 2. Load legacy file (for conversations not yet migrated)
        let legacyFile = conversationsDirectory.appendingPathComponent(conversationsFileName)
        if FileManager.default.fileExists(atPath: legacyFile.path) {
            do {
                let legacyData: [ConversationData] = try loadJSON(from: legacyFile)
                var migratedCount = 0

                for data in legacyData where !loadedIds.contains(data.id) {
                    let conversation = ConversationModel.from(data: data)
                    conversations.append(conversation)
                    migratedCount += 1
                    logger.debug("Loaded conversation \(conversation.id) from legacy file")
                }

                if migratedCount > 0 {
                    logger.info("Migrated \(migratedCount) conversations from legacy storage")

                    // Move legacy file to backups after migration
                    try moveLegacyFileToBackups()
                }
            } catch {
                logger.error("Failed to load legacy conversations.json: \(error)")
            }
        }

        logger.info("Loaded \(conversations.count) total conversations (\(loadedIds.count) from per-file)")
        return conversations
    }

    /// Move legacy conversations.json to backups directory after migration.
    private func moveLegacyFileToBackups() throws {
        let legacyFile = conversationsDirectory.appendingPathComponent(conversationsFileName)
        guard FileManager.default.fileExists(atPath: legacyFile.path) else { return }

        // Create backups directory if needed
        let backupsDir = conversationsDirectory.appendingPathComponent("backups")
        if !FileManager.default.fileExists(atPath: backupsDir.path) {
            try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        }

        // Create timestamped backup filename
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupFilename = "conversations_migrated_\(timestamp).json"
        let backupURL = backupsDir.appendingPathComponent(backupFilename)

        // Move (not copy) legacy file to backups
        try FileManager.default.moveItem(at: legacyFile, to: backupURL)
        logger.info("Moved legacy conversations.json to backups: \(backupFilename)")
    }

    /// Delete conversation file from per-file storage.
    /// Note: Only deletes conversation.json, not the directory (memory.db may exist).
    public func deleteConversationFile(_ conversationId: UUID) throws {
        let conversationFile = conversationsDirectory
            .appendingPathComponent(conversationId.uuidString)
            .appendingPathComponent("conversation.json")

        if FileManager.default.fileExists(atPath: conversationFile.path) {
            try FileManager.default.removeItem(at: conversationFile)
            logger.debug("Deleted conversation file for \(conversationId)")
        }
    }

    // MARK: - Legacy Conversation Management (Deprecated)

    /// Save all conversations to single JSON file.
    /// @deprecated Use saveConversation(_:) for per-file storage instead.
    public func saveConversations(_ conversations: [ConversationModel]) throws {
        let conversationDataArray = conversations.map { $0.toConversationData() }
        let fileURL = conversationsDirectory.appendingPathComponent(conversationsFileName)

        try saveJSON(conversationDataArray, to: fileURL)

        logger.debug("Saved \(conversations.count) conversations to legacy file storage")
    }

    /// Load all conversations from single JSON file.
    /// @deprecated Use loadConversationsWithMigration() instead.
    public func loadConversations() throws -> [ConversationModel] {
        let fileURL = conversationsDirectory.appendingPathComponent(conversationsFileName)

        /// Check if conversations file exists.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.debug("No conversations file found, returning empty array")
            return []
        }

        do {
            let conversationDataArray: [ConversationData] = try loadJSON(from: fileURL)
            let conversations = conversationDataArray.map { ConversationModel.from(data: $0) }
            logger.debug("Loaded \(conversations.count) conversations from file storage")

            return conversations

        } catch {
            logger.error("Failed to load conversations: \(error)")
            throw error
        }
    }

    /// Save active conversation ID.
    public func saveActiveConversationId(_ conversationId: UUID) throws {
        let activeConversation = ActiveConversationReference(id: conversationId, updated: Date())
        let fileURL = conversationsDirectory.appendingPathComponent(activeConversationFileName)

        try saveJSON(activeConversation, to: fileURL)

        logger.debug("Saved active conversation ID: \(conversationId)")
    }

    /// Load active conversation ID.
    public func loadActiveConversationId() -> UUID? {
        let fileURL = conversationsDirectory.appendingPathComponent(activeConversationFileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.debug("No active conversation file found")
            return nil
        }

        do {
            let activeConversation: ActiveConversationReference = try loadJSON(from: fileURL)
            logger.debug("Loaded active conversation ID: \(activeConversation.id)")
            return activeConversation.id

        } catch {
            logger.error("Failed to load active conversation ID: \(error)")
            return nil
        }
    }

    // MARK: - Helper Methods

    /// Save any Codable object to JSON file with atomic write.
    private func saveJSON<T: Codable>(_ object: T, to fileURL: URL) throws {
        let tempURL = fileURL.appendingPathExtension("tmp")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(object)

            /// Atomic write: write to temp file first, then rename.
            try data.write(to: tempURL)

            /// Atomic rename operation.
            _ = try FileManager.default.replaceItem(at: fileURL, withItemAt: tempURL,
                                                 backupItemName: nil, options: [],
                                                 resultingItemURL: nil)
        } catch {
            /// Clean up temp file if operation failed.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// Load any Codable object from JSON file.
    private func loadJSON<T: Codable>(_ type: T.Type = T.self, from fileURL: URL) throws -> T {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(type, from: data)
    }

    /// Delete specific conversation by ID.
    /// @deprecated Use deleteConversationFile(_:) for per-file storage cleanup.
    public func deleteConversation(_ conversationId: UUID, from conversations: inout [ConversationModel]) throws {
        /// Remove from array.
        conversations.removeAll { $0.id == conversationId }

        /// Delete per-file storage if it exists.
        try? deleteConversationFile(conversationId)

        /// If this was the active conversation, clear the active conversation reference.
        if let activeId = loadActiveConversationId(), activeId == conversationId {
            let activeFileURL = conversationsDirectory.appendingPathComponent(activeConversationFileName)
            try? FileManager.default.removeItem(at: activeFileURL)
        }

        logger.debug("Deleted conversation: \(conversationId)")
    }

    // MARK: - Export/Import

    /// Export conversation to JSON file.
    public func exportConversation(_ conversation: ConversationModel, to url: URL) throws {
        let conversationData = conversation.toConversationData()
        let exportData = ExportedConversation(
            conversation: conversationData,
            exportedAt: Date(),
            samVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )

        /// Use JSONEncoder directly for export.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(exportData)
        try data.write(to: url)

        logger.debug("Exported conversation to: \(url.path)")
    }

    /// Import conversation from JSON file.
    public func importConversation(from url: URL) throws -> ConversationModel {
        let data = try Data(contentsOf: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        /// Try to decode as exported conversation first.
        if let exportedConversation = try? decoder.decode(ExportedConversation.self, from: data) {
            let conversation = ConversationModel.from(data: exportedConversation.conversation)
            logger.debug("Imported exported conversation: \(conversation.title)")
            return conversation
        }

        /// Fallback: try to decode as direct ConversationData.
        let conversationData = try decoder.decode(ConversationData.self, from: data)
        let conversation = ConversationModel.from(data: conversationData)

        logger.debug("Imported conversation data: \(conversation.title)")
        return conversation
    }

    /// Clear all conversation data (for fresh start).
    public func clearAllConversations() throws {
        /// Delete legacy conversations file.
        let conversationsFileURL = conversationsDirectory.appendingPathComponent(conversationsFileName)
        if FileManager.default.fileExists(atPath: conversationsFileURL.path) {
            try FileManager.default.removeItem(at: conversationsFileURL)
        }

        /// Delete all per-file conversation.json files
        let contents = try? FileManager.default.contentsOfDirectory(
            at: conversationsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        for item in (contents ?? []) {
            guard item.hasDirectoryPath else { continue }
            let dirName = item.lastPathComponent
            guard dirName != "backups" else { continue }

            let conversationFile = item.appendingPathComponent("conversation.json")
            if FileManager.default.fileExists(atPath: conversationFile.path) {
                try FileManager.default.removeItem(at: conversationFile)
                logger.debug("Deleted per-file conversation: \(dirName)")
            }
        }

        /// Delete active conversation file.
        let activeFileURL = conversationsDirectory.appendingPathComponent(activeConversationFileName)
        if FileManager.default.fileExists(atPath: activeFileURL.path) {
            try FileManager.default.removeItem(at: activeFileURL)
        }

        logger.debug("Cleared all conversation data")
    }
}

// MARK: - Supporting Models

private struct ActiveConversationReference: Codable {
    let id: UUID
    let updated: Date
}

public struct ExportedConversation: Codable {
    let conversation: ConversationData
    let exportedAt: Date
    let samVersion: String
}
