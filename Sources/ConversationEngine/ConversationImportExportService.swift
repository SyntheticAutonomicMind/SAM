// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// ConversationImportExportService.swift
/// SAM Conversation Import/Export System
/// Handles JSON export/import with full metadata and optional memory data

import Foundation
import ConfigurationSystem
import Logging
import Training

// MARK: - Export Data Structures

/// Complete export package for a conversation including all metadata
public struct ConversationExportPackage: Codable {
    /// Export format version for future compatibility
    public let formatVersion: String

    /// Export timestamp
    public let exportedAt: Date

    /// SAM version that created this export
    public let samVersion: String

    /// The conversation data
    public let conversation: ConversationData

    /// Optional: Conversation-scoped memory entries
    public let memories: [ExportedMemory]?

    /// Optional: Vector RAG chunks
    public let ragChunks: [ExportedRAGChunk]?

    /// Optional: Folder information for recreation on import
    public let folder: ExportedFolder?

    public init(
        conversation: ConversationData,
        memories: [ExportedMemory]? = nil,
        ragChunks: [ExportedRAGChunk]? = nil,
        folder: ExportedFolder? = nil
    ) {
        self.formatVersion = "1.0"
        self.exportedAt = Date()
        self.samVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        self.conversation = conversation
        self.memories = memories
        self.ragChunks = ragChunks
        self.folder = folder
    }
}

/// Exported folder information for recreation on import
public struct ExportedFolder: Codable {
    public let id: String
    public let name: String
    public let color: String?
    public let icon: String?

    public init(id: String, name: String, color: String? = nil, icon: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
    }
}

/// Exported memory entry (simplified for portability)
public struct ExportedMemory: Codable {
    public let id: UUID
    public let content: String
    public let contentType: String
    public let importance: Double
    public let createdAt: Date
    public let tags: [String]?

    public init(
        id: UUID,
        content: String,
        contentType: String,
        importance: Double,
        createdAt: Date,
        tags: [String]? = nil
    ) {
        self.id = id
        self.content = content
        self.contentType = contentType
        self.importance = importance
        self.createdAt = createdAt
        self.tags = tags
    }
}

/// Exported RAG chunk (simplified for portability)
public struct ExportedRAGChunk: Codable {
    public let id: UUID
    public let content: String
    public let context: String?
    public let importance: Double
    public let metadata: [String: String]

    public init(
        id: UUID,
        content: String,
        context: String?,
        importance: Double,
        metadata: [String: String]
    ) {
        self.id = id
        self.content = content
        self.context = context
        self.importance = importance
        self.metadata = metadata
    }
}

/// Bulk export package for multiple conversations
public struct BulkExportPackage: Codable {
    public let formatVersion: String
    public let exportedAt: Date
    public let samVersion: String
    public let conversationCount: Int
    public let conversations: [ConversationExportPackage]

    public init(conversations: [ConversationExportPackage]) {
        self.formatVersion = "1.0"
        self.exportedAt = Date()
        self.samVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        self.conversationCount = conversations.count
        self.conversations = conversations
    }
}

// MARK: - Import Options

/// Options for handling conflicts during import
public enum ImportConflictResolution {
    /// Create new conversation with unique ID (default)
    case createNew
    /// Skip if conversation with same ID exists
    case skip
    /// Replace existing conversation with imported data
    case replace
    /// Merge messages (append new messages to existing)
    case merge
}

/// Result of a single conversation import
public struct ConversationImportResult {
    public let originalId: UUID
    public let newId: UUID
    public let title: String
    public let messageCount: Int
    public let memoryCount: Int
    public let success: Bool
    public let error: String?
    public let conflictResolution: ImportConflictResolution?

    public init(
        originalId: UUID,
        newId: UUID,
        title: String,
        messageCount: Int,
        memoryCount: Int,
        success: Bool,
        error: String? = nil,
        conflictResolution: ImportConflictResolution? = nil
    ) {
        self.originalId = originalId
        self.newId = newId
        self.title = title
        self.messageCount = messageCount
        self.memoryCount = memoryCount
        self.success = success
        self.error = error
        self.conflictResolution = conflictResolution
    }
}

/// Result of bulk import operation
public struct BulkImportResult {
    public let totalAttempted: Int
    public let successCount: Int
    public let failedCount: Int
    public let skippedCount: Int
    public let results: [ConversationImportResult]

    public init(results: [ConversationImportResult]) {
        self.results = results
        self.totalAttempted = results.count
        self.successCount = results.filter { $0.success && $0.conflictResolution != .skip }.count
        self.failedCount = results.filter { !$0.success }.count
        self.skippedCount = results.filter { $0.conflictResolution == .skip }.count
    }
}

// MARK: - Export Error Types

public enum ConversationExportError: Error, LocalizedError {
    case encodingFailed(String)
    case writeFailed(String)
    case conversationNotFound(UUID)
    case memoryExportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed(let message):
            return "Failed to encode conversation: \(message)"
        case .writeFailed(let message):
            return "Failed to write export file: \(message)"
        case .conversationNotFound(let id):
            return "Conversation not found: \(id)"
        case .memoryExportFailed(let message):
            return "Failed to export memory data: \(message)"
        }
    }
}

// MARK: - Import Error Types

public enum ConversationImportError: Error, LocalizedError {
    case fileNotFound(String)
    case decodingFailed(String)
    case invalidFormat(String)
    case versionMismatch(String)
    case memoryImportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Import file not found: \(path)"
        case .decodingFailed(let message):
            return "Failed to decode import file: \(message)"
        case .invalidFormat(let message):
            return "Invalid import format: \(message)"
        case .versionMismatch(let version):
            return "Unsupported format version: \(version)"
        case .memoryImportFailed(let message):
            return "Failed to import memory data: \(message)"
        }
    }
}

// MARK: - Import/Export Service

@MainActor
public class ConversationImportExportService {
    private let logger = Logger(label: "com.sam.conversation.ImportExport")

    /// Reference to conversation manager for import operations
    private weak var conversationManager: ConversationManager?

    /// Reference to memory manager for memory export/import
    private weak var memoryManager: MemoryManager?

    /// Reference to folder manager for folder export/import
    private weak var folderManager: FolderManager?

    public init(conversationManager: ConversationManager? = nil, memoryManager: MemoryManager? = nil, folderManager: FolderManager? = nil) {
        self.conversationManager = conversationManager
        self.memoryManager = memoryManager
        self.folderManager = folderManager
    }

    /// Inject conversation manager (for delayed initialization)
    public func setConversationManager(_ manager: ConversationManager) {
        self.conversationManager = manager
        self.memoryManager = manager.memoryManager
    }

    /// Inject folder manager
    public func setFolderManager(_ manager: FolderManager) {
        self.folderManager = manager
    }

    // MARK: - Single Conversation Export

    /// Export a single conversation to JSON
    /// - Parameters:
    ///   - conversation: The conversation to export
    ///   - includeMemory: Whether to include conversation-scoped memory
    ///   - includeRAG: Whether to include Vector RAG chunks
    /// - Returns: The export package
    public func exportConversation(
        _ conversation: ConversationModel,
        includeMemory: Bool = true,
        includeRAG: Bool = true
    ) async throws -> ConversationExportPackage {
        logger.info("Exporting conversation: \(conversation.title) (ID: \(conversation.id))")

        let conversationData = conversation.toConversationData()

        /// Export memory if requested
        var memories: [ExportedMemory]?
        if includeMemory, let memoryManager = memoryManager {
            do {
                let conversationMemories = try await memoryManager.getAllMemories(for: conversation.id)
                memories = conversationMemories.map { memory in
                    ExportedMemory(
                        id: memory.id,
                        content: memory.content,
                        contentType: memory.contentType.rawValue,
                        importance: memory.importance,
                        createdAt: memory.createdAt,
                        tags: memory.tags
                    )
                }
                logger.debug("Exported \(memories?.count ?? 0) memory entries")
            } catch {
                logger.warning("Failed to export memory data: \(error)")
                /// Continue without memory data rather than failing entire export
            }
        }

        /// RAG chunks would need additional implementation to extract
        /// For now, we rely on memories which include RAG-tagged content
        let ragChunks: [ExportedRAGChunk]? = nil

        /// Export folder information if conversation is in a folder
        var exportedFolder: ExportedFolder?
        if let folderId = conversation.folderId,
           let folder = folderManager?.getFolder(by: folderId) {
            exportedFolder = ExportedFolder(
                id: folder.id,
                name: folder.name,
                color: folder.color,
                icon: folder.icon
            )
            logger.debug("Exported folder info: \(folder.name)")
        }

        let package = ConversationExportPackage(
            conversation: conversationData,
            memories: memories,
            ragChunks: ragChunks,
            folder: exportedFolder
        )

        logger.info("Export package created: \(conversation.messages.count) messages, \(memories?.count ?? 0) memories")
        return package
    }

    /// Export conversation to file
    /// - Parameters:
    ///   - conversation: The conversation to export
    ///   - outputURL: The file URL to write to
    ///   - includeMemory: Whether to include memory data
    /// - Returns: The file URL written to
    @discardableResult
    public func exportConversationToFile(
        _ conversation: ConversationModel,
        to outputURL: URL,
        includeMemory: Bool = true
    ) async throws -> URL {
        let package = try await exportConversation(conversation, includeMemory: includeMemory)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let jsonData = try encoder.encode(package)
            try jsonData.write(to: outputURL)
            logger.info("Exported conversation to: \(outputURL.path)")
            return outputURL
        } catch let encodingError as EncodingError {
            throw ConversationExportError.encodingFailed(encodingError.localizedDescription)
        } catch {
            throw ConversationExportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Bulk Export

    /// Export multiple conversations to a single file
    /// - Parameters:
    ///   - conversations: The conversations to export
    ///   - outputURL: The file URL to write to
    ///   - includeMemory: Whether to include memory data
    /// - Returns: The file URL written to
    @discardableResult
    public func exportConversations(
        _ conversations: [ConversationModel],
        to outputURL: URL,
        includeMemory: Bool = true
    ) async throws -> URL {
        logger.info("Bulk exporting \(conversations.count) conversations")

        var packages: [ConversationExportPackage] = []

        for conversation in conversations {
            do {
                let package = try await exportConversation(conversation, includeMemory: includeMemory)
                packages.append(package)
            } catch {
                logger.error("Failed to export conversation \(conversation.id): \(error)")
                /// Continue with other conversations
            }
        }

        let bulkPackage = BulkExportPackage(conversations: packages)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let jsonData = try encoder.encode(bulkPackage)
            try jsonData.write(to: outputURL)
            logger.info("Bulk exported \(packages.count) conversations to: \(outputURL.path)")
            return outputURL
        } catch let encodingError as EncodingError {
            throw ConversationExportError.encodingFailed(encodingError.localizedDescription)
        } catch {
            throw ConversationExportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Single Conversation Import

    /// Import a conversation from an export package
    /// - Parameters:
    ///   - package: The export package to import
    ///   - conflictResolution: How to handle ID conflicts
    ///   - importMemory: Whether to import memory data
    /// - Returns: The import result
    public func importConversation(
        from package: ConversationExportPackage,
        conflictResolution: ImportConflictResolution = .createNew,
        importMemory: Bool = true
    ) async throws -> ConversationImportResult {
        guard let conversationManager = conversationManager else {
            throw ConversationImportError.invalidFormat("ConversationManager not available")
        }

        let originalId = package.conversation.id
        let title = package.conversation.title

        logger.info("Importing conversation: \(title) (Original ID: \(originalId))")

        /// Check for existing conversation with same ID
        let existingConversation = conversationManager.conversations.first { $0.id == originalId }

        var newId = originalId
        var actualResolution = conflictResolution

        if existingConversation != nil {
            switch conflictResolution {
            case .skip:
                logger.info("Skipping import - conversation already exists: \(originalId)")
                return ConversationImportResult(
                    originalId: originalId,
                    newId: originalId,
                    title: title,
                    messageCount: 0,
                    memoryCount: 0,
                    success: true,
                    conflictResolution: .skip
                )

            case .replace:
                /// Delete existing conversation first
                if let existing = existingConversation {
                    _ = conversationManager.deleteConversation(existing, deleteWorkingDirectory: false)
                    logger.info("Replaced existing conversation: \(originalId)")
                }

            case .merge:
                /// Merge will be handled after creating/loading conversation
                logger.info("Will merge with existing conversation: \(originalId)")

            case .createNew:
                /// Generate new UUID for imported conversation
                newId = UUID()
                logger.info("Creating new conversation with ID: \(newId) (original: \(originalId))")
            }
        }

        /// Handle folder: ensure folder exists or clear the reference
        var resolvedFolderId: String? = package.conversation.folderId
        if let folderId = resolvedFolderId {
            /// Check if folder exists
            if folderManager?.getFolder(by: folderId) == nil {
                /// Folder doesn't exist - try to recreate it from export data
                if let exportedFolder = package.folder {
                    /// Create the folder with exported info
                    let newFolder = folderManager?.createFolder(
                        name: exportedFolder.name,
                        color: exportedFolder.color,
                        icon: exportedFolder.icon
                    )
                    /// Use the newly created folder's ID
                    if let createdFolder = newFolder {
                        resolvedFolderId = createdFolder.id
                        logger.info("Recreated folder '\(exportedFolder.name)' for imported conversation")
                    }
                } else {
                    /// No folder info available - move to uncategorized
                    resolvedFolderId = nil
                    logger.info("Folder \(folderId) not found and no folder info in export - moving to Uncategorized")
                }
            }
        }

        /// Create conversation data with potentially new ID
        let importData = ConversationData(
            id: newId,
            title: conflictResolution == .createNew && existingConversation != nil
                ? generateUniqueTitle(title, existingTitles: conversationManager.conversations.map { $0.title })
                : title,
            created: package.conversation.created,
            updated: Date(),
            messages: package.conversation.messages,
            settings: package.conversation.settings ?? ConversationSettings(),
            sessionId: package.conversation.sessionId,
            lastGitHubCopilotResponseId: package.conversation.lastGitHubCopilotResponseId,
            contextMessages: package.conversation.contextMessages,
            isPinned: package.conversation.isPinned ?? false,
            workingDirectory: nil, /// Will use default
            workingDirectoryBookmark: nil,
            enabledMiniPromptIds: package.conversation.enabledMiniPromptIds,
            folderId: resolvedFolderId,
            isFromAPI: package.conversation.isFromAPI ?? false
        )

        /// Handle merge case
        if actualResolution == .merge, let existing = existingConversation {
            /// Append new messages that don't already exist
            let existingMessageIds = Set(existing.messages.map { $0.id })
            let newMessages = importData.messages.filter { !existingMessageIds.contains($0.id) }

            for message in newMessages {
                if message.isFromUser {
                    existing.messageBus?.addUserMessage(
                        content: message.content,
                        timestamp: message.timestamp,
                        isPinned: message.isPinned
                    )
                } else if message.isToolMessage {
                    existing.messageBus?.addToolMessage(
                        name: message.toolName ?? "tool",
                        status: message.toolStatus ?? .success,
                        details: message.content.isEmpty ? nil : message.content,
                        detailsArray: message.toolDetails,
                        icon: message.toolIcon,
                        duration: message.toolDuration,
                        toolCallId: message.toolCallId
                    )
                } else {
                    existing.messageBus?.addAssistantMessage(
                        content: message.content,
                        timestamp: message.timestamp
                    )
                }
            }

            conversationManager.saveConversations()

            return ConversationImportResult(
                originalId: originalId,
                newId: existing.id,
                title: existing.title,
                messageCount: newMessages.count,
                memoryCount: 0,
                success: true,
                conflictResolution: .merge
            )
        }

        /// Create new conversation from import data
        let newConversation = ConversationModel.from(data: importData)
        newConversation.manager = conversationManager
        newConversation.initializeMessageBus(conversationManager: conversationManager)

        /// Add to conversation list and notify observers
        conversationManager.conversations.insert(newConversation, at: 0)
        conversationManager.objectWillChange.send()
        conversationManager.saveConversations()

        logger.info("Added imported conversation to list, total conversations: \(conversationManager.conversations.count)")

        /// Import memory data if requested and available
        var memoryCount = 0
        if importMemory, let memories = package.memories, let memoryManager = memoryManager {
            for memory in memories {
                do {
                    _ = try await memoryManager.storeMemory(
                        content: memory.content,
                        conversationId: newId,
                        contentType: MemoryContentType(rawValue: memory.contentType) ?? .message,
                        importance: memory.importance,
                        tags: memory.tags ?? []
                    )
                    memoryCount += 1
                } catch {
                    logger.warning("Failed to import memory \(memory.id): \(error)")
                }
            }
            logger.info("Imported \(memoryCount) memory entries")
        }

        logger.info("Successfully imported conversation: \(newConversation.title) with \(newConversation.messages.count) messages")

        return ConversationImportResult(
            originalId: originalId,
            newId: newId,
            title: newConversation.title,
            messageCount: newConversation.messages.count,
            memoryCount: memoryCount,
            success: true,
            conflictResolution: actualResolution
        )
    }

    /// Import conversation from file
    /// - Parameters:
    ///   - fileURL: The file to import from
    ///   - conflictResolution: How to handle ID conflicts
    ///   - importMemory: Whether to import memory data
    /// - Returns: The import result(s)
    public func importFromFile(
        _ fileURL: URL,
        conflictResolution: ImportConflictResolution = .createNew,
        importMemory: Bool = true
    ) async throws -> BulkImportResult {
        logger.info("Importing from file: \(fileURL.path)")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ConversationImportError.fileNotFound(fileURL.path)
        }

        let jsonData: Data
        do {
            jsonData = try Data(contentsOf: fileURL)
        } catch {
            throw ConversationImportError.fileNotFound(error.localizedDescription)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        /// Try to decode as bulk export first, then single export
        if let bulkPackage = try? decoder.decode(BulkExportPackage.self, from: jsonData) {
            return try await importBulkPackage(bulkPackage, conflictResolution: conflictResolution, importMemory: importMemory)
        }

        if let singlePackage = try? decoder.decode(ConversationExportPackage.self, from: jsonData) {
            let result = try await importConversation(from: singlePackage, conflictResolution: conflictResolution, importMemory: importMemory)
            return BulkImportResult(results: [result])
        }

        throw ConversationImportError.decodingFailed("File is not a valid SAM conversation export")
    }

    // MARK: - Bulk Import

    /// Import multiple conversations from a bulk package
    private func importBulkPackage(
        _ package: BulkExportPackage,
        conflictResolution: ImportConflictResolution,
        importMemory: Bool
    ) async throws -> BulkImportResult {
        logger.info("Bulk importing \(package.conversationCount) conversations")

        var results: [ConversationImportResult] = []

        for conversationPackage in package.conversations {
            do {
                let result = try await importConversation(
                    from: conversationPackage,
                    conflictResolution: conflictResolution,
                    importMemory: importMemory
                )
                results.append(result)
            } catch {
                logger.error("Failed to import conversation \(conversationPackage.conversation.id): \(error)")
                results.append(ConversationImportResult(
                    originalId: conversationPackage.conversation.id,
                    newId: conversationPackage.conversation.id,
                    title: conversationPackage.conversation.title,
                    messageCount: 0,
                    memoryCount: 0,
                    success: false,
                    error: error.localizedDescription
                ))
            }
        }

        let bulkResult = BulkImportResult(results: results)
        logger.info("Bulk import complete: \(bulkResult.successCount) succeeded, \(bulkResult.failedCount) failed, \(bulkResult.skippedCount) skipped")

        return bulkResult
    }

    // MARK: - Helper Methods

    /// Generate unique title for imported conversation
    private func generateUniqueTitle(_ baseName: String, existingTitles: [String]) -> String {
        let titles = Set(existingTitles)

        if !titles.contains(baseName) {
            return baseName
        }

        /// Try "baseName (Imported)"
        let importedName = "\(baseName) (Imported)"
        if !titles.contains(importedName) {
            return importedName
        }

        /// Find next available number
        var number = 2
        while titles.contains("\(baseName) (Imported \(number))") {
            number += 1
        }

        return "\(baseName) (Imported \(number))"
    }

    /// Generate default export filename
    public func generateExportFilename(for conversation: ConversationModel) -> String {
        let sanitizedTitle = conversation.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .prefix(50)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())

        return "SAM_\(sanitizedTitle)_\(dateString).json"
    }

    /// Generate default bulk export filename
    public func generateBulkExportFilename(count: Int) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateString = dateFormatter.string(from: Date())

        return "SAM_Export_\(count)_conversations_\(dateString).json"
    }
}

// MARK: - Training Data Export

extension ConversationImportExportService {
    /// Export a conversation as training data in JSONL format
    /// Includes conversation messages AND imported documents/memories from VectorRAG
    /// - Parameters:
    ///   - conversation: The conversation to export
    ///   - outputURL: Where to write the JSONL file
    ///   - options: Export configuration (PII, templates, etc.)
    /// - Returns: Export result with statistics and metadata
    public func exportAsTrainingData(
        conversation: ConversationModel,
        outputURL: URL,
        options: TrainingDataModels.ExportOptions
    ) async throws -> TrainingDataModels.ExportResult {
        let logger = Logger(label: "com.sam.training.export")
        let exporter = TrainingDataExporter()
        
        // Step 1: Export conversation messages to main JSONL file
        logger.info("Exporting conversation messages", metadata: [
            "conversationId": "\(conversation.id)",
            "messageCount": "\(conversation.messages.count)"
        ])
        
        let messageResult = try await exporter.exportConversation(
            messages: conversation.messages,
            outputURL: outputURL,
            options: options
        )
        
        // Step 2: Check if conversation has memories (imported documents/code)
        guard let memoryManager = self.memoryManager else {
            logger.debug("No memory manager available, skipping memory export")
            return messageResult
        }
        
        do {
            // MemoryManager is @MainActor, retrieve memories from MainActor context
            let conversationMemories = try await memoryManager.getAllMemories(for: conversation.id)
            
            guard !conversationMemories.isEmpty else {
                logger.debug("No memories found for conversation, only exporting messages")
                return messageResult
            }
            
            logger.info("Found conversation memories to export", metadata: [
                "memoryCount": "\(conversationMemories.count)"
            ])
            
            // Step 3: Convert ConversationMemory to ConversationMemorySnapshot
            let memorySnapshots = conversationMemories.map { memory in
                TrainingDataModels.ConversationMemorySnapshot(
                    id: memory.id,
                    content: memory.content,
                    contentType: memory.contentType.rawValue,
                    importance: memory.importance,
                    tags: memory.tags
                )
            }
            
            // Step 4: Create temporary file for memory export
            let memoryTempURL = outputURL.deletingLastPathComponent()
                .appendingPathComponent("temp_memories_\(UUID().uuidString).jsonl")
            
            // Step 5: Export memories using DocumentExportOptions (reuse existing method)
            let documentOptions = TrainingDataModels.DocumentExportOptions(
                chunkingStrategy: .semantic, // Memories are already chunked
                maxChunkTokens: options.template == .llama3 ? 4096 : 2048,
                overlapTokens: 0, // No overlap needed for pre-chunked memories
                stripPII: options.stripPII,
                selectedPIIEntities: options.selectedPIIEntities,
                template: options.template,
                customTemplate: options.customTemplate
            )
            
            let memoryResult = try await exporter.exportConversationMemory(
                memories: memorySnapshots,
                outputURL: memoryTempURL,
                options: documentOptions
            )
            
            logger.info("Exported conversation memories", metadata: [
                "memoryExamples": "\(memoryResult.statistics.totalExamples)"
            ])
            
            // Step 6: Combine message and memory JSONL files into single file
            let messageContent = try String(contentsOf: outputURL, encoding: .utf8)
            let memoryContent = try String(contentsOf: memoryTempURL, encoding: .utf8)
            
            let combinedContent = messageContent + "\n" + memoryContent
            try combinedContent.write(to: outputURL, atomically: true, encoding: .utf8)
            
            // Step 7: Clean up temp file
            try? FileManager.default.removeItem(at: memoryTempURL)
            
            // Step 8: Combine statistics
            let combinedStatistics = TrainingDataModels.ExportStatistics(
                totalExamples: messageResult.statistics.totalExamples + memoryResult.statistics.totalExamples,
                totalTokensEstimate: messageResult.statistics.totalTokensEstimate + memoryResult.statistics.totalTokensEstimate,
                piiRedactions: mergePIIRedactions(
                    messageResult.statistics.piiRedactions,
                    memoryResult.statistics.piiRedactions
                ),
                examplesWithToolCalls: messageResult.statistics.examplesWithToolCalls,
                examplesWithReasoning: messageResult.statistics.examplesWithReasoning,
                averageMessageLength: (messageResult.statistics.averageMessageLength * messageResult.statistics.totalExamples +
                                       memoryResult.statistics.averageMessageLength * memoryResult.statistics.totalExamples) /
                                      (messageResult.statistics.totalExamples + memoryResult.statistics.totalExamples),
                outputFileSize: messageResult.statistics.outputFileSize
            )
            
            logger.info("Combined export complete", metadata: [
                "totalExamples": "\(combinedStatistics.totalExamples)",
                "messageExamples": "\(messageResult.statistics.totalExamples)",
                "memoryExamples": "\(memoryResult.statistics.totalExamples)"
            ])
            
            return TrainingDataModels.ExportResult(
                outputURL: outputURL,
                statistics: combinedStatistics,
                template: options.template,
                options: options
            )
            
        } catch {
            logger.error("Failed to export memories: \(error.localizedDescription)")
            logger.error("Error details: \(String(describing: error))")
            // If memory export fails, return message-only result
            return messageResult
        }
    }
    
    /// Merge PII redaction counts from multiple exports
    private func mergePIIRedactions(
        _ first: [PIIDetector.PIIEntity: Int],
        _ second: [PIIDetector.PIIEntity: Int]
    ) -> [PIIDetector.PIIEntity: Int] {
        var merged = first
        for (entity, count) in second {
            merged[entity, default: 0] += count
        }
        return merged
    }
    
    /// Generate default training export filename
    /// - Parameters:
    ///   - conversation: The conversation being exported
    ///   - template: The chat template being used
    /// - Returns: Suggested filename with .jsonl extension
    public func generateTrainingExportFilename(
        for conversation: ConversationModel,
        template: ChatTemplate,
        modelId: String? = nil
    ) -> String {
        let sanitizedTitle = conversation.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .prefix(50)
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        
        // Use model ID if provided, otherwise use template name
        let modelIdentifier: String
        if let modelId = modelId {
            modelIdentifier = modelId
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: " ", with: "")
        } else {
            modelIdentifier = template.rawValue
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "/", with: "_")
        }
        
        return "training_\(sanitizedTitle)_\(modelIdentifier)_\(timestamp).jsonl"
    }
}

// MARK: - Shared Instance

extension ConversationImportExportService {
    /// Shared instance for convenient access
    public static let shared = ConversationImportExportService()
}
