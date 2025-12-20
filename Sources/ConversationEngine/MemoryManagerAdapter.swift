// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import MCPFramework

/// Adapter to bridge MemoryManager with MemoryManagerProtocol This adapter allows the existing MemoryManager to work with the MCP memory tools without circular dependencies or major refactoring.
public class MemoryManagerAdapter: MemoryManagerProtocol, @unchecked Sendable {
    private let memoryManager: MemoryManager
    private let vectorRAGService: VectorRAGService?

    public init(memoryManager: MemoryManager, vectorRAGService: VectorRAGService? = nil) {
        self.memoryManager = memoryManager
        self.vectorRAGService = vectorRAGService
    }

    public func searchMemories(query: String, limit: Int, similarityThreshold: Double? = nil, conversationId: UUID? = nil) async throws -> [any MemoryEntry] {
        /// Cap threshold to 0.3 maximum, default to 0.15 Voyage AI embeddings produce scores of 0.15-0.25 for relevant document chunks AI assistants sometimes pass unreasonably high thresholds (e.g., 0.8) which filter out ALL results Cap at 0.3 to prevent this failure mode while still allowing some flexibility.
        let requestedThreshold = similarityThreshold ?? 0.15
        let threshold = min(requestedThreshold, 0.3)

        /// Use retrieveRelevantMemories() directly (same as UI) This bypasses the VectorRAGService.semanticSearch() complexity and uses the proven UI code path UI uses: memoryManager.retrieveRelevantMemories(for: query, conversationId: id, limit: 10, similarityThreshold: 0.2).
        if let conversationId = conversationId {
            /// Conversation-scoped search - call MemoryManager.retrieveRelevantMemories() directly.
            let memories = try await memoryManager.retrieveRelevantMemories(
                for: query,
                conversationId: conversationId,
                limit: limit,
                similarityThreshold: threshold
            )

            return memories.map { memory in
                ConversationMemoryAdapter(memory: memory)
            }
        }

        /// Global search (no conversationId) - search across all conversations.
        let crossConversationMemories = try await memoryManager.searchAllConversations(
            query: query,
            limit: limit,
            similarityThreshold: threshold
        )

        return crossConversationMemories.map { memory in
            ConversationMemoryAdapter(memory: memory)
        }
    }

    public func storeMemory(content: String, contentType: MCPFramework.MemoryContentType, context: String, conversationId: String?, tags: [String]) async throws -> UUID {
        /// Map MCPFramework.MemoryContentType to ConversationEngine.MemoryContentType.
        let engineContentType: ConversationEngine.MemoryContentType
        switch contentType {
        case .interaction:
            engineContentType = .message

        case .fact:
            engineContentType = .contextInfo

        case .preference:
            engineContentType = .userInput

        case .task:
            engineContentType = .toolResult

        case .document:
            engineContentType = .contextInfo
        }

        /// Use existing storeMemory method (note: no context parameter in the actual method).
        let conversationUUID = conversationId.flatMap { UUID(uuidString: $0) } ?? UUID()
        return try await memoryManager.storeMemory(
            content: content,
            conversationId: conversationUUID,
            contentType: engineContentType,
            importance: 0.5,
            tags: tags
        )
    }

    public func getMemoryStatistics() async throws -> any MCPFramework.MemoryStatistics {
        /// Get actual global statistics from database.
        let stats = try await memoryManager.getGlobalMemoryStatistics()

        /// Map ConversationEngine content types to MCPFramework counts ConversationEngine has: message, userInput, assistantResponse, systemEvent, toolResult, contextInfo, document MCPFramework expects: interaction, fact, preference, task, document.

        let interactionCount = (stats.byType[.message] ?? 0) +
                               (stats.byType[.assistantResponse] ?? 0)
        let factCount = stats.byType[.contextInfo] ?? 0
        let preferenceCount = (stats.byType[.userInput] ?? 0) +
                              (stats.byType[.systemEvent] ?? 0)
        let taskCount = stats.byType[.toolResult] ?? 0
        let documentCount = stats.byType[.document] ?? 0

        return SimpleMemoryStatistics(
            totalMemories: stats.totalCount,
            interactionCount: interactionCount,
            factCount: factCount,
            preferenceCount: preferenceCount,
            taskCount: taskCount,
            documentCount: documentCount,
            recentMemories: stats.recentCount,
            averageImportance: stats.averageImportance
        )
    }

    public func getConversationMemories(conversationId: String, limit: Int) async throws -> [any MemoryEntry] {
        guard let uuid = UUID(uuidString: conversationId) else {
            return []
        }

        let memories = try await memoryManager.getAllMemories(for: uuid)
        let limitedMemories = Array(memories.prefix(limit))

        return limitedMemories.map { memory in
            ConversationMemoryAdapter(memory: memory)
        }
    }

    public func getRecentMemories(limit: Int) async throws -> [any MemoryEntry] {
        /// This requires implementing a cross-conversation recent memories query For now, return empty array.
        return []
    }
}

// MARK: - Supporting Types

/// Simple implementation of MCPFramework.MemoryStatistics protocol.
private struct SimpleMemoryStatistics: MCPFramework.MemoryStatistics {
    let totalMemories: Int
    let interactionCount: Int
    let factCount: Int
    let preferenceCount: Int
    let taskCount: Int
    let documentCount: Int
    let recentMemories: Int
    let averageImportance: Double
}

/// Adapter to make ConversationMemory conform to MemoryEntry.
private struct ConversationMemoryAdapter: MemoryEntry {
    let memory: ConversationMemory

    var id: UUID { memory.id }
    var content: String { memory.content }
    var context: String { "" }
    var contentType: MCPFramework.MemoryContentType {
        /// Map from ConversationEngine.MemoryContentType to MCPFramework.MemoryContentType.
        switch memory.contentType {
        case .message:
            return .interaction

        case .userInput:
            return .preference

        case .assistantResponse:
            return .interaction

        case .systemEvent:
            return .fact

        case .toolResult:
            return .task

        case .contextInfo:
            return .document

        case .document:
            return .document
        }
    }
    var importance: Double { memory.importance }
    var timestamp: Date { memory.createdAt }
    var tags: [String] { memory.tags }
    var relevanceScore: Double? { memory.similarity }
}

/// Adapter for Vector RAG semantic search results to MemoryEntry protocol.
public struct SemanticMemoryAdapter: MemoryEntry {
    private let semanticResult: SemanticSearchResult

    init(semanticResult: SemanticSearchResult) {
        self.semanticResult = semanticResult
    }

    public var id: UUID { semanticResult.id }
    public var content: String { semanticResult.content }
    public var contentType: MCPFramework.MemoryContentType {
        /// Map based on metadata tags or default to fact.
        let tags = semanticResult.metadata["tags"] as? [String] ?? []
        if tags.contains("document") || tags.contains("rag") {
            return .document
        }
        return .fact
    }
    public var context: String { semanticResult.context }
    public var conversationId: String? { semanticResult.documentId.uuidString }
    public var importance: Double { semanticResult.importance }
    public var timestamp: Date { semanticResult.timestamp }
    public var tags: [String] {
        let metaTags = semanticResult.metadata["tags"] as? [String] ?? []
        return metaTags + ["semantic", "rag"]
    }
    public var relevanceScore: Double? { semanticResult.similarity }
}
