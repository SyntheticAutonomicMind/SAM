// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// ContextArchiveManager.swift
/// SAM Long-Term Memory System for Archived Conversation Context
///
/// PURPOSE:
/// When YaRN compresses context to fit model limits, this manager archives
/// the rolled-off messages so agents can recall them later using the
/// recall_history tool.
///
/// ARCHITECTURE:
/// - Archives stored per-conversation in SQLite
/// - Each archive chunk includes summary and key topics
/// - Memory map provides quick lookup of available context
/// - Chunks retrievable by query, time, or topic

import Foundation
import SQLite
import Logging
import ConfigurationSystem
import MCPFramework

// MARK: - Data Types

/// Reason why context was archived
public enum ArchiveReason: String, Codable {
    case yarnCompression = "yarn_compression"
    case manualArchive = "manual"
    case tokenLimitReached = "token_limit"
    case conversationTrimmed = "conversation_trimmed"
}

/// An archived message with metadata
public struct ArchivedMessage: Codable {
    public let id: UUID
    public let content: String
    public let isFromUser: Bool
    public let timestamp: Date
    public let role: String

    public init(id: UUID, content: String, isFromUser: Bool, timestamp: Date, role: String) {
        self.id = id
        self.content = content
        self.isFromUser = isFromUser
        self.timestamp = timestamp
        self.role = role
    }
}

/// A chunk of archived context
public struct ArchiveChunk: Codable {
    public let id: UUID
    public let conversationId: UUID
    public let messages: [ArchivedMessage]
    public let timeRange: TimeRange
    public let summary: String
    public let keyTopics: [String]
    public let tokenCount: Int
    public let reason: ArchiveReason
    public let createdAt: Date

    public struct TimeRange: Codable {
        public let start: Date
        public let end: Date

        public var description: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "\(formatter.string(from: start))-\(formatter.string(from: end))"
        }
    }
}

/// Summary of a chunk for quick lookup
public struct ChunkSummary: Codable {
    public let chunkId: UUID
    public let timeRange: String
    public let summary: String
    public let keyTopics: [String]
    public let messageCount: Int
    public let tokenCount: Int
}

/// Memory map showing all available archived context
public struct MemoryMap: Codable {
    public let conversationId: UUID
    public let totalChunks: Int
    public let totalTokensArchived: Int
    public let chunks: [ChunkSummary]

    /// Generate context hint for injection into system prompt
    public func generateContextHint() -> String? {
        guard totalChunks > 0 else { return nil }

        let allTopics = Set(chunks.flatMap { $0.keyTopics })
        let topicList = allTopics.prefix(10).joined(separator: ", ")

        return """
        [Memory Status]
        You have \(totalChunks) archived context chunk\(totalChunks == 1 ? "" : "s") from earlier in this conversation.
        Topics covered: \(topicList)
        Use the recall_history tool if you need to reference earlier context.
        """
    }
}

// MARK: - Context Archive Manager

@MainActor
public class ContextArchiveManager: ObservableObject {
    private let logger = Logger(label: "com.sam.context.archive")
    private var database: Connection?
    private var conversationDatabases: [UUID: Connection] = [:]

    // Database schema
    private let archives = Table("context_archives")
    private let id = column("id") as SQLite.Expression<String>
    private let conversationId = column("conversation_id") as SQLite.Expression<String>
    private let messagesJson = column("messages_json") as SQLite.Expression<String>
    private let timeStart = column("time_start") as SQLite.Expression<Date>
    private let timeEnd = column("time_end") as SQLite.Expression<Date>
    private let summary = column("summary") as SQLite.Expression<String>
    private let keyTopicsJson = column("key_topics_json") as SQLite.Expression<String>
    private let tokenCount = column("token_count") as SQLite.Expression<Int>
    private let reason = column("reason") as SQLite.Expression<String>
    private let createdAt = column("created_at") as SQLite.Expression<Date>

    @Published public var totalArchivedChunks: Int = 0

    public init() {
        logger.debug("ContextArchiveManager initialized")
    }

    // MARK: - Database Management

    private func getDatabasePath(for conversationId: UUID) throws -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let samDir = appSupport.appendingPathComponent("SAM/conversations/\(conversationId.uuidString)")

        if !FileManager.default.fileExists(atPath: samDir.path) {
            try FileManager.default.createDirectory(at: samDir, withIntermediateDirectories: true)
        }

        return samDir.appendingPathComponent("context_archive.db").path
    }

    private func getDatabaseConnection(for conversationId: UUID) throws -> Connection {
        if let existing = conversationDatabases[conversationId] {
            return existing
        }

        let path = try getDatabasePath(for: conversationId)
        let db = try Connection(path)
        try createSchema(db: db)
        conversationDatabases[conversationId] = db

        logger.debug("Created archive database for conversation \(conversationId)")
        return db
    }

    private func createSchema(db: Connection) throws {
        try db.run(archives.create(ifNotExists: true) { t in
            t.column(id, primaryKey: true)
            t.column(conversationId)
            t.column(messagesJson)
            t.column(timeStart)
            t.column(timeEnd)
            t.column(summary)
            t.column(keyTopicsJson)
            t.column(tokenCount)
            t.column(reason)
            t.column(createdAt)
        })

        // Create indexes for efficient querying
        try db.run(archives.createIndex(conversationId, ifNotExists: true))
        try db.run(archives.createIndex(timeStart, ifNotExists: true))
    }

    // MARK: - Archive Operations

    /// Archive messages that are being removed from context
    /// - Parameters:
    ///   - messages: Messages to archive
    ///   - conversationId: The conversation UUID
    ///   - reason: Why context is being archived
    /// - Returns: The created archive chunk
    public func archiveMessages(
        _ messages: [EnhancedMessage],
        conversationId: UUID,
        reason archiveReason: ArchiveReason
    ) async throws -> ArchiveChunk {
        guard !messages.isEmpty else {
            throw ArchiveError.emptyMessages
        }

        let db = try getDatabaseConnection(for: conversationId)

        // Convert to archived format
        let archivedMessages = messages.map { msg in
            ArchivedMessage(
                id: msg.id,
                content: msg.content,
                isFromUser: msg.isFromUser,
                timestamp: msg.timestamp,
                role: msg.isFromUser ? "user" : (msg.isPinned ? "system" : "assistant")
            )
        }

        // Calculate time range
        let sortedByTime = messages.sorted { $0.timestamp < $1.timestamp }
        let timeRange = ArchiveChunk.TimeRange(
            start: sortedByTime.first!.timestamp,
            end: sortedByTime.last!.timestamp
        )

        // Generate summary (simple extraction for now - could use LLM later)
        let generatedSummary = generateSummary(from: messages)
        let extractedTopics = extractKeyTopics(from: messages)
        let estimatedTokens = estimateTokenCount(messages)

        // Create chunk
        let chunkId = UUID()
        let chunk = ArchiveChunk(
            id: chunkId,
            conversationId: conversationId,
            messages: archivedMessages,
            timeRange: timeRange,
            summary: generatedSummary,
            keyTopics: extractedTopics,
            tokenCount: estimatedTokens,
            reason: archiveReason,
            createdAt: Date()
        )

        // Store in database
        let encoder = JSONEncoder()
        let messagesData = try encoder.encode(archivedMessages)
        let topicsData = try encoder.encode(extractedTopics)

        try db.run(archives.insert(
            id <- chunkId.uuidString,
            self.conversationId <- conversationId.uuidString,
            messagesJson <- String(data: messagesData, encoding: .utf8)!,
            timeStart <- timeRange.start,
            timeEnd <- timeRange.end,
            summary <- generatedSummary,
            keyTopicsJson <- String(data: topicsData, encoding: .utf8)!,
            tokenCount <- estimatedTokens,
            reason <- archiveReason.rawValue,
            createdAt <- Date()
        ))

        totalArchivedChunks += 1

        logger.info("Archived \(messages.count) messages as chunk \(chunkId.uuidString.prefix(8))", metadata: [
            "conversation": "\(conversationId.uuidString.prefix(8))",
            "tokens": "\(estimatedTokens)",
            "reason": "\(archiveReason.rawValue)"
        ])

        return chunk
    }

    /// Get memory map showing available archived context
    public func getMemoryMap(conversationId: UUID) async throws -> MemoryMap {
        let db = try getDatabaseConnection(for: conversationId)

        var chunks: [ChunkSummary] = []
        var totalTokens = 0

        let query = archives.filter(self.conversationId == conversationId.uuidString)
            .order(timeStart.desc)

        for row in try db.prepare(query) {
            let chunkId = UUID(uuidString: row[id])!
            let decoder = JSONDecoder()
            let messagesData = row[messagesJson].data(using: .utf8)!
            let topicsData = row[keyTopicsJson].data(using: .utf8)!

            let messages = try decoder.decode([ArchivedMessage].self, from: messagesData)
            let topics = try decoder.decode([String].self, from: topicsData)

            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            let timeRange = "\(timeFormatter.string(from: row[timeStart]))-\(timeFormatter.string(from: row[timeEnd]))"

            chunks.append(ChunkSummary(
                chunkId: chunkId,
                timeRange: timeRange,
                summary: row[summary],
                keyTopics: topics,
                messageCount: messages.count,
                tokenCount: row[tokenCount]
            ))

            totalTokens += row[tokenCount]
        }

        return MemoryMap(
            conversationId: conversationId,
            totalChunks: chunks.count,
            totalTokensArchived: totalTokens,
            chunks: chunks
        )
    }

    /// Recall archived history by query
    public func recallHistory(
        query: String,
        conversationId: UUID,
        limit: Int = 3
    ) async throws -> [ArchiveChunk] {
        let db = try getDatabaseConnection(for: conversationId)

        var results: [(chunk: ArchiveChunk, relevance: Double)] = []
        let queryLower = query.lowercased()
        let queryTerms = queryLower.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        let dbQuery = archives.filter(self.conversationId == conversationId.uuidString)
            .order(timeStart.desc)

        let decoder = JSONDecoder()

        for row in try db.prepare(dbQuery) {
            let chunkId = UUID(uuidString: row[id])!
            let messagesData = row[messagesJson].data(using: .utf8)!
            let topicsData = row[keyTopicsJson].data(using: .utf8)!

            let messages = try decoder.decode([ArchivedMessage].self, from: messagesData)
            let topics = try decoder.decode([String].self, from: topicsData)

            let chunk = ArchiveChunk(
                id: chunkId,
                conversationId: conversationId,
                messages: messages,
                timeRange: ArchiveChunk.TimeRange(start: row[timeStart], end: row[timeEnd]),
                summary: row[summary],
                keyTopics: topics,
                tokenCount: row[tokenCount],
                reason: ArchiveReason(rawValue: row[reason]) ?? .yarnCompression,
                createdAt: row[createdAt]
            )

            // Calculate relevance score
            let relevance = calculateRelevance(chunk: chunk, queryTerms: queryTerms)
            if relevance > 0 {
                results.append((chunk, relevance))
            }
        }

        // Sort by relevance and limit
        results.sort { $0.relevance > $1.relevance }
        return results.prefix(limit).map { $0.chunk }
    }

    /// Recall history by time (recent, early, or specific range)
    public func recallHistoryByTime(
        conversationId: UUID,
        timeHint: String,
        limit: Int = 3
    ) async throws -> [ArchiveChunk] {
        let db = try getDatabaseConnection(for: conversationId)

        var dbQuery = archives.filter(self.conversationId == conversationId.uuidString)

        switch timeHint.lowercased() {
        case "recent":
            dbQuery = dbQuery.order(timeStart.desc)
        case "early":
            dbQuery = dbQuery.order(timeStart.asc)
        default:
            dbQuery = dbQuery.order(timeStart.desc)
        }

        dbQuery = dbQuery.limit(limit)

        var results: [ArchiveChunk] = []
        let decoder = JSONDecoder()

        for row in try db.prepare(dbQuery) {
            let chunkId = UUID(uuidString: row[id])!
            let messagesData = row[messagesJson].data(using: .utf8)!
            let topicsData = row[keyTopicsJson].data(using: .utf8)!

            let messages = try decoder.decode([ArchivedMessage].self, from: messagesData)
            let topics = try decoder.decode([String].self, from: topicsData)

            results.append(ArchiveChunk(
                id: chunkId,
                conversationId: conversationId,
                messages: messages,
                timeRange: ArchiveChunk.TimeRange(start: row[timeStart], end: row[timeEnd]),
                summary: row[summary],
                keyTopics: topics,
                tokenCount: row[tokenCount],
                reason: ArchiveReason(rawValue: row[reason]) ?? .yarnCompression,
                createdAt: row[createdAt]
            ))
        }

        return results
    }

    // MARK: - Helper Methods

    private func generateSummary(from messages: [EnhancedMessage]) -> String {
        // Simple summary generation - extract first user message and assistant response
        let userMessages = messages.filter { $0.isFromUser }
        let assistantMessages = messages.filter { !$0.isFromUser && !$0.isPinned }

        var summaryParts: [String] = []

        if let firstUser = userMessages.first {
            let preview = String(firstUser.content.prefix(200))
            summaryParts.append("User asked: \(preview)")
        }

        if let firstAssistant = assistantMessages.first {
            let preview = String(firstAssistant.content.prefix(200))
            summaryParts.append("Discussion about: \(preview)")
        }

        return summaryParts.joined(separator: ". ")
    }

    private func extractKeyTopics(from messages: [EnhancedMessage]) -> [String] {
        // Simple keyword extraction - in production, use NLP
        let allContent = messages.map { $0.content }.joined(separator: " ")
        let words = allContent.lowercased()
            .components(separatedBy: .punctuationCharacters)
            .joined()
            .components(separatedBy: .whitespaces)
            .filter { $0.count > 4 }

        // Count word frequency
        var frequency: [String: Int] = [:]
        for word in words {
            frequency[word, default: 0] += 1
        }

        // Return top topics (excluding common words)
        let stopWords = Set(["about", "after", "again", "being", "could", "would", "should", "their", "there", "these", "those", "where", "which", "while"])

        return frequency
            .filter { !stopWords.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { $0.key }
    }

    private func estimateTokenCount(_ messages: [EnhancedMessage]) -> Int {
        // Rough estimate: ~4 characters per token
        let totalChars = messages.map { $0.content.count }.reduce(0, +)
        return totalChars / 4
    }

    private func calculateRelevance(chunk: ArchiveChunk, queryTerms: [String]) -> Double {
        var score = 0.0

        let summaryLower = chunk.summary.lowercased()
        let topicsLower = chunk.keyTopics.map { $0.lowercased() }
        let contentLower = chunk.messages.map { $0.content.lowercased() }.joined(separator: " ")

        for term in queryTerms {
            // Check summary (high weight)
            if summaryLower.contains(term) {
                score += 3.0
            }

            // Check topics (medium weight)
            if topicsLower.contains(where: { $0.contains(term) }) {
                score += 2.0
            }

            // Check content (low weight)
            if contentLower.contains(term) {
                score += 1.0
            }
        }

        return score
    }
}

// MARK: - Errors

public enum ArchiveError: Error, LocalizedError {
    case emptyMessages
    case databaseError(String)
    case chunkNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptyMessages:
            return "Cannot archive empty message list"
        case .databaseError(let message):
            return "Archive database error: \(message)"
        case .chunkNotFound(let id):
            return "Archive chunk not found: \(id)"
        }
    }
}

// MARK: - ContextArchiveProvider Adapter

/// Adapter that wraps ContextArchiveManager for use with RecallHistoryTool
/// This avoids the circular dependency issue by keeping protocol in MCPFramework
public class ContextArchiveProviderAdapter: ContextArchiveProvider {
    private let manager: ContextArchiveManager
    private let logger = Logger(label: "com.sam.context.archive.adapter")

    /// Function to get conversations in a topic (injected at initialization)
    public var getConversationsInTopicCallback: ((UUID) async throws -> [UUID])?

    public init(manager: ContextArchiveManager) {
        self.manager = manager
    }

    @MainActor
    public func recallHistory(query: String, conversationId: UUID, limit: Int) async throws -> [RecallChunk] {
        let chunks = try await manager.recallHistory(query: query, conversationId: conversationId, limit: limit)
        return chunks.map { convertToRecallChunk($0) }
    }

    @MainActor
    public func recallHistoryByTime(conversationId: UUID, timeHint: String, limit: Int) async throws -> [RecallChunk] {
        let chunks = try await manager.recallHistoryByTime(conversationId: conversationId, timeHint: timeHint, limit: limit)
        return chunks.map { convertToRecallChunk($0) }
    }

    @MainActor
    public func getMemoryMap(conversationId: UUID) async throws -> RecallMemoryMap {
        let map = try await manager.getMemoryMap(conversationId: conversationId)
        return RecallMemoryMap(
            conversationId: map.conversationId,
            totalChunks: map.totalChunks,
            totalTokensArchived: map.totalTokensArchived,
            chunkSummaries: map.chunks.map { ($0.chunkId, $0.timeRange, $0.summary, $0.keyTopics) }
        )
    }

    // MARK: - Topic-Wide Search Methods

    /// Get list of conversation IDs that belong to a topic
    @MainActor
    public func getConversationsInTopic(topicId: UUID) async throws -> [UUID] {
        guard let callback = getConversationsInTopicCallback else {
            logger.warning("getConversationsInTopicCallback not set - returning empty list")
            return []
        }
        return try await callback(topicId)
    }

    /// Recall history across ALL conversations in a shared topic
    @MainActor
    public func recallTopicHistory(query: String, topicId: UUID, limit: Int) async throws -> [RecallChunk] {
        // Get all conversations in the topic
        let conversationIds = try await getConversationsInTopic(topicId: topicId)

        guard !conversationIds.isEmpty else {
            logger.debug("No conversations found in topic \(topicId)")
            return []
        }

        logger.debug("Searching \(conversationIds.count) conversations in topic \(topicId.uuidString.prefix(8))")

        // Gather results from all conversations
        var allResults: [(chunk: RecallChunk, relevance: Double)] = []
        let queryTerms = query.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        for conversationId in conversationIds {
            do {
                let chunks = try await manager.recallHistory(
                    query: query,
                    conversationId: conversationId,
                    limit: limit  // Get up to limit from each conversation
                )

                // Score and add to results
                for chunk in chunks {
                    let relevance = calculateRelevance(chunk: chunk, queryTerms: queryTerms)
                    let recallChunk = convertToRecallChunk(chunk)
                    allResults.append((recallChunk, relevance))
                }
            } catch {
                // Log but continue - some conversations might not have archives
                logger.debug("No archive for conversation \(conversationId): \(error.localizedDescription)")
            }
        }

        // Sort by relevance and return top results
        allResults.sort { $0.relevance > $1.relevance }
        return allResults.prefix(limit).map { $0.chunk }
    }

    /// Get memory map for an entire topic (aggregated from all conversations)
    @MainActor
    public func getTopicMemoryMap(topicId: UUID) async throws -> RecallMemoryMap {
        let conversationIds = try await getConversationsInTopic(topicId: topicId)

        var allChunks: [(id: UUID, timeRange: String, summary: String, topics: [String])] = []
        var totalTokens = 0

        for conversationId in conversationIds {
            do {
                let map = try await manager.getMemoryMap(conversationId: conversationId)
                totalTokens += map.totalTokensArchived

                for chunk in map.chunks {
                    allChunks.append((chunk.chunkId, chunk.timeRange, chunk.summary, chunk.keyTopics))
                }
            } catch {
                logger.debug("No memory map for conversation \(conversationId): \(error.localizedDescription)")
            }
        }

        // Use a placeholder UUID for topic-level memory map
        return RecallMemoryMap(
            conversationId: topicId,  // Using topicId as identifier for topic-level map
            totalChunks: allChunks.count,
            totalTokensArchived: totalTokens,
            chunkSummaries: allChunks
        )
    }

    // MARK: - Private Helpers

    private func convertToRecallChunk(_ chunk: ArchiveChunk) -> RecallChunk {
        RecallChunk(
            id: chunk.id,
            conversationId: chunk.conversationId,
            timeRange: chunk.timeRange.description,
            summary: chunk.summary,
            keyTopics: chunk.keyTopics,
            messageCount: chunk.messages.count,
            tokenCount: chunk.tokenCount,
            messages: chunk.messages.map { msg in
                RecallChunk.RecallMessage(
                    content: msg.content,
                    isFromUser: msg.isFromUser,
                    timestamp: msg.timestamp
                )
            }
        )
    }

    private func calculateRelevance(chunk: ArchiveChunk, queryTerms: [String]) -> Double {
        var score = 0.0

        let summaryLower = chunk.summary.lowercased()
        let topicsLower = chunk.keyTopics.map { $0.lowercased() }
        let contentLower = chunk.messages.map { $0.content.lowercased() }.joined(separator: " ")

        for term in queryTerms {
            if summaryLower.contains(term) { score += 3.0 }
            if topicsLower.contains(where: { $0.contains(term) }) { score += 2.0 }
            if contentLower.contains(term) { score += 1.0 }
        }

        return score
    }
}
