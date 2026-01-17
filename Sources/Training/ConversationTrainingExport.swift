// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// ConversationTrainingExport.swift
/// Training data export extension for ConversationImportExportService

import Foundation
import ConversationEngine
import Logging

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
