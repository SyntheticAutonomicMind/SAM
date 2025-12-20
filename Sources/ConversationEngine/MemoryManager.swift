// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// MemoryManager.swift SAM Memory management system for per-conversation context storage and retrieval.

import Foundation
import SQLite
import Logging
import NaturalLanguage

/// Core memory manager for conversation-scoped memory storage and retrieval.
@MainActor
public class MemoryManager: ObservableObject {
    private let logger = Logger(label: "com.sam.memory")
    private var database: Connection?
    private var conversationDatabases: [UUID: Connection] = [:]
    private let isTestMode: Bool
    private let appleEmbeddingGenerator: AppleNLEmbeddingGenerator?

    @Published public var isInitialized = false
    @Published public var totalMemories = 0
    @Published public var lastError: String?

    /// Database schema.
    private let memories = Table("conversation_memories")
    private let id = column("id") as SQLite.Expression<String>
    private let conversationId = column("conversation_id") as SQLite.Expression<String>
    private let content = column("content") as SQLite.Expression<String>
    private let contentType = column("content_type") as SQLite.Expression<String>
    private let embedding = columnOptional("embedding") as SQLite.Expression<Data?>
    private let importance = column("importance") as SQLite.Expression<Double>
    private let createdAt = column("created_at") as SQLite.Expression<Date>
    private let accessCount = column("access_count") as SQLite.Expression<Int>
    private let lastAccessed = column("last_accessed") as SQLite.Expression<Date>
    private let tags = columnOptional("tags") as SQLite.Expression<String?>

    public init(testMode: Bool = false) {
        self.isTestMode = testMode

        /// Try to initialize Apple NLEmbedding for real semantic understanding.
        do {
            self.appleEmbeddingGenerator = try AppleNLEmbeddingGenerator()
            logger.debug("MemoryManager initialized with Apple NLEmbedding (testMode: \(testMode))")
        } catch {
            self.appleEmbeddingGenerator = nil
            logger.warning("MemoryManager using hash-based fallback (testMode: \(testMode)): \(error)")
        }
    }

    /// Initialize the memory database and schema.
    public func initialize() async throws {
        logger.debug("Initializing memory database")

        do {
            if isTestMode {
                database = try Connection(":memory:")
                logger.debug("Using in-memory database for testing")
            } else {
                let dbPath = try getDatabasePath()
                database = try Connection(dbPath)
                logger.debug("Database initialized at: \(dbPath)")
            }

            try createSchema()
            try await loadStatistics()

            isInitialized = true
            logger.debug("Memory system initialized successfully")

        } catch {
            lastError = error.localizedDescription
            logger.error("Failed to initialize memory system: \(error)")
            throw MemoryError.initializationFailed(error.localizedDescription)
        }
    }

    /// Store memory content for a specific conversation.
    public func storeMemory(
        content: String,
        conversationId: UUID,
        contentType: MemoryContentType = .message,
        importance: Double = 0.5,
        tags: [String] = []
    ) async throws -> UUID {
        /// Use per-conversation database for memory isolation.
        let db = try getDatabaseConnection(for: conversationId)

        let memoryId = UUID()
        let embedding = try await generateEmbedding(for: content)
        let tagString = tags.isEmpty ? nil : tags.joined(separator: ",")

        logger.debug("SUCCESS: MEMORY_ISOLATION: Storing memory in conversation \(conversationId) database")

        do {
            try db.run(memories.insert(
                id <- memoryId.uuidString,
                self.conversationId <- conversationId.uuidString,
                self.content <- content,
                self.contentType <- contentType.rawValue,
                self.embedding <- embedding,
                self.importance <- importance,
                createdAt <- Date(),
                accessCount <- 0,
                lastAccessed <- Date(),
                self.tags <- tagString
            ))

            totalMemories += 1
            logger.debug("SUCCESS: MEMORY_ISOLATION: Stored memory \(memoryId) in conversation \(conversationId) isolated database")
            return memoryId

        } catch {
            lastError = error.localizedDescription
            logger.error("ERROR: Failed to store memory in conversation database: \(error)")
            throw MemoryError.storageFailed(error.localizedDescription)
        }
    }

    /// Retrieve relevant memories for a conversation using semantic search.
    public func retrieveRelevantMemories(
        for query: String,
        conversationId: UUID,
        limit: Int = 10,
        similarityThreshold: Double = 0.3
    ) async throws -> [ConversationMemory] {
        /// Use per-conversation database for memory isolation.
        let db = try getDatabaseConnection(for: conversationId)

        logger.debug("SUCCESS: MEMORY_ISOLATION: Retrieving memories from conversation \(conversationId) isolated database")

        do {
            let queryEmbedding = try await generateEmbedding(for: query)
            var relevantMemories: [ConversationMemory] = []

            /// Get all memories from this conversation's isolated database No filter needed - the per-conversation database already contains only this conversation's memories.
            for row in try db.prepare(memories) {
                let memoryId = UUID(uuidString: row[id])!
                let storedEmbedding = row[embedding]

                var similarity = 0.0
                if let embeddingData = storedEmbedding {
                    similarity = calculateCosineSimilarity(queryEmbedding, embeddingData)
                }

                /// Apply keyword boost for better matching.
                let keywordBoost = calculateKeywordBoost(query: query, content: row[content])
                let finalSimilarity = similarity + keywordBoost

                /// Log similarity scores to diagnose search failures (INFO level to ensure visibility).
                logger.debug("SIMILARITY DEBUG: content='\(row[content].prefix(80))', similarity=\(String(format: "%.4f", similarity)), keywordBoost=\(String(format: "%.4f", keywordBoost)), final=\(String(format: "%.4f", finalSimilarity)), threshold=\(similarityThreshold)")

                /// Include memories above similarity threshold (with keyword boost).
                if finalSimilarity >= similarityThreshold {
                    /// Update access statistics.
                    try updateAccessStatistics(memoryId: memoryId, in: db)

                    let memory = ConversationMemory(
                        id: memoryId,
                        conversationId: conversationId,
                        content: row[content],
                        contentType: MemoryContentType(rawValue: row[contentType]) ?? .message,
                        importance: row[importance],
                        similarity: finalSimilarity,
                        createdAt: row[createdAt],
                        accessCount: row[accessCount] + 1,
                        tags: row[tags]?.components(separatedBy: ",") ?? []
                    )
                    relevantMemories.append(memory)
                }
            }

            /// Sort by similarity and limit results.
            relevantMemories.sort { $0.similarity > $1.similarity }
            let limitedResults = Array(relevantMemories.prefix(limit))

            logger.debug("SUCCESS: MEMORY_ISOLATION: Retrieved \(limitedResults.count) memories from conversation \(conversationId) isolated database")
            return limitedResults

        } catch {
            lastError = error.localizedDescription
            logger.error("ERROR: Failed to retrieve memories from conversation database: \(error)")
            throw MemoryError.retrievalFailed(error.localizedDescription)
        }
    }

    /// Search across ALL conversations (cross-conversation search for memory tool) NOTE: With per-conversation databases, this searches only ACTIVE conversation databases.
    public func searchAllConversations(
        query: String,
        limit: Int = 10,
        similarityThreshold: Double = 0.3
    ) async throws -> [ConversationMemory] {
        logger.debug("WARNING: MEMORY_ISOLATION: Cross-conversation search requested (searches active conversation databases)")

        do {
            let queryEmbedding = try await generateEmbedding(for: query)
            var relevantMemories: [ConversationMemory] = []

            /// Search across all ACTIVE per-conversation databases.
            for (conversationId, db) in conversationDatabases {
                do {
                    for row in try db.prepare(memories) {
                        let memoryId = UUID(uuidString: row[id])!
                        let memoryConversationId = UUID(uuidString: row[self.conversationId])!
                        let storedEmbedding = row[embedding]
                        let contentText = row[content]

                        var similarity = 0.0
                        if let embeddingData = storedEmbedding {
                            similarity = calculateCosineSimilarity(queryEmbedding, embeddingData)
                        }

                        let keywordBoost = calculateKeywordBoost(query: query, content: contentText)
                        let finalSimilarity = similarity + keywordBoost

                        if finalSimilarity >= similarityThreshold {
                            try updateAccessStatistics(memoryId: memoryId, in: db)

                            let memory = ConversationMemory(
                                id: memoryId,
                                conversationId: memoryConversationId,
                                content: contentText,
                                contentType: MemoryContentType(rawValue: row[contentType]) ?? .message,
                                importance: row[importance],
                                similarity: finalSimilarity,
                                createdAt: row[createdAt],
                                accessCount: row[accessCount] + 1,
                                tags: row[tags]?.components(separatedBy: ",") ?? []
                            )
                            relevantMemories.append(memory)
                        }
                    }
                } catch {
                    logger.warning("WARNING: MEMORY_ISOLATION: Failed to search conversation \(conversationId): \(error)")
                    /// Continue searching other conversations.
                }
            }

            /// Also search legacy shared database if it exists and has content.
            if let legacyDb = database {
                do {
                    for row in try legacyDb.prepare(memories) {
                        let memoryId = UUID(uuidString: row[id])!
                        let memoryConversationId = UUID(uuidString: row[conversationId])!
                        let storedEmbedding = row[embedding]
                        let contentText = row[content]

                        var similarity = 0.0
                        if let embeddingData = storedEmbedding {
                            similarity = calculateCosineSimilarity(queryEmbedding, embeddingData)
                        }

                        let keywordBoost = calculateKeywordBoost(query: query, content: contentText)
                        let finalSimilarity = similarity + keywordBoost

                        if finalSimilarity >= similarityThreshold {
                            try updateAccessStatistics(memoryId: memoryId, in: legacyDb)

                            let memory = ConversationMemory(
                                id: memoryId,
                                conversationId: memoryConversationId,
                                content: contentText,
                                contentType: MemoryContentType(rawValue: row[contentType]) ?? .message,
                                importance: row[importance],
                                similarity: finalSimilarity,
                                createdAt: row[createdAt],
                                accessCount: row[accessCount] + 1,
                                tags: row[tags]?.components(separatedBy: ",") ?? []
                            )
                            relevantMemories.append(memory)
                        }
                    }
                } catch {
                    logger.warning("WARNING: MEMORY_ISOLATION: Failed to search legacy database: \(error)")
                }
            }

            /// Sort by similarity and limit results.
            relevantMemories.sort { $0.similarity > $1.similarity }
            let limitedResults = Array(relevantMemories.prefix(limit))

            logger.debug("WARNING: MEMORY_ISOLATION: Cross-conversation search found \(limitedResults.count) results across \(conversationDatabases.count) active conversations")
            return limitedResults

        } catch {
            lastError = error.localizedDescription
            logger.error("ERROR: Cross-conversation search failed: \(error)")
            throw MemoryError.retrievalFailed(error.localizedDescription)
        }
    }

    /// Get all memories for a specific conversation (for debugging/management).
    public func getAllMemories(for conversationId: UUID) async throws -> [ConversationMemory] {
        /// Use per-conversation database for memory isolation.
        let db = try getDatabaseConnection(for: conversationId)

        do {
            let conversationMemories = memories
                .filter(self.conversationId == conversationId.uuidString)
                .order(createdAt.desc)

            var allMemories: [ConversationMemory] = []

            for row in try db.prepare(conversationMemories) {
                let memory = ConversationMemory(
                    id: UUID(uuidString: row[id])!,
                    conversationId: conversationId,
                    content: row[content],
                    contentType: MemoryContentType(rawValue: row[contentType]) ?? .message,
                    importance: row[importance],
                    similarity: 1.0,
                    createdAt: row[createdAt],
                    accessCount: row[accessCount],
                    tags: row[tags]?.components(separatedBy: ",") ?? []
                )
                allMemories.append(memory)
            }

            logger.debug("Retrieved \(allMemories.count) total memories for conversation \(conversationId)")
            return allMemories

        } catch {
            logger.error("Failed to get all memories: \(error)")
            throw MemoryError.retrievalFailed(error.localizedDescription)
        }
    }

    /// Clear all memories for a specific conversation.
    public func clearMemories(for conversationId: UUID) async throws {
        guard let db = database else {
            throw MemoryError.databaseNotInitialized
        }

        do {
            let conversationMemories = memories.filter(self.conversationId == conversationId.uuidString)
            let deletedCount = try db.run(conversationMemories.delete())

            totalMemories = max(0, totalMemories - deletedCount)
            logger.debug("Cleared \(deletedCount) memories for conversation \(conversationId)")

        } catch {
            lastError = error.localizedDescription
            logger.error("Failed to clear memories: \(error)")
            throw MemoryError.operationFailed(error.localizedDescription)
        }
    }

    /// Get memory statistics for a conversation.
    public func getMemoryStatistics(for conversationId: UUID) async throws -> MemoryStatistics {
        /// Use per-conversation database (not legacy shared database).
        let db = try getDatabaseConnection(for: conversationId)

        do {
            let conversationMemories = memories.filter(self.conversationId == conversationId.uuidString)

            let totalCount = try db.scalar(conversationMemories.count)
            let averageImportance = try db.scalar(conversationMemories.select(importance.average)) ?? 0.0
            let totalAccesses = try db.scalar(conversationMemories.select(accessCount.sum)) ?? 0
            let oldestMemory = try db.scalar(conversationMemories.select(createdAt.min))
            let newestMemory = try db.scalar(conversationMemories.select(createdAt.max))

            logger.debug("Memory statistics for \(conversationId): \(totalCount) memories, \(totalAccesses) accesses, avg importance \(String(format: "%.2f", averageImportance))")

            return MemoryStatistics(
                totalMemories: totalCount,
                averageImportance: averageImportance,
                totalAccesses: totalAccesses,
                oldestMemory: oldestMemory,
                newestMemory: newestMemory
            )

        } catch {
            logger.error("Failed to get memory statistics: \(error)")
            throw MemoryError.operationFailed(error.localizedDescription)
        }
    }

    /// Get global memory statistics across all conversations with breakdown by content type.
    public func getGlobalMemoryStatistics() async throws -> GlobalMemoryStatistics {
        guard let db = database else {
            throw MemoryError.databaseNotInitialized
        }

        do {
            /// Get total count across all conversations.
            let totalCount = try db.scalar(memories.count)

            /// Get counts by content type.
            var byType: [MemoryContentType: Int] = [:]
            for type in MemoryContentType.allCases {
                let typeMemories = memories.filter(contentType == type.rawValue)
                let count = try db.scalar(typeMemories.count)
                byType[type] = count
            }

            /// Get recent memories (last 7 days).
            let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            let recentMemories = memories.filter(createdAt >= sevenDaysAgo)
            let recentCount = try db.scalar(recentMemories.count)

            /// Get average importance across all memories.
            let avgImportance = try db.scalar(memories.select(importance.average)) ?? 0.5

            logger.debug("Global memory statistics: \(totalCount) total memories, \(recentCount) recent, avg importance \(String(format: "%.2f", avgImportance))")

            return GlobalMemoryStatistics(
                totalCount: totalCount,
                byType: byType,
                recentCount: recentCount,
                averageImportance: avgImportance
            )

        } catch {
            logger.error("Failed to get global memory statistics: \(error)")
            throw MemoryError.operationFailed(error.localizedDescription)
        }
    }

    // MARK: - Helper Methods

    private func createSchema() throws {
        guard let db = database else {
            throw MemoryError.databaseNotInitialized
        }
        try createSchemaForConnection(db)
    }

    /// Create schema for a specific database connection (shared or per-conversation).
    private func createSchemaForConnection(_ db: Connection) throws {
        try db.run(memories.create(ifNotExists: true) { table in
            table.column(id, primaryKey: true)
            table.column(conversationId)
            table.column(content)
            table.column(contentType)
            table.column(embedding)
            table.column(importance)
            table.column(createdAt)
            table.column(accessCount, defaultValue: 0)
            table.column(lastAccessed)
            table.column(tags)
        })

        /// Create indexes for efficient querying.
        try db.run("CREATE INDEX IF NOT EXISTS idx_conversation_id ON conversation_memories(conversation_id)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_created_at ON conversation_memories(created_at)")
        try db.run("CREATE INDEX IF NOT EXISTS idx_importance ON conversation_memories(importance)")

        logger.debug("Memory database schema created for connection")
    }

    /// Get database path for a specific conversation - Parameter conversationId: Optional conversation ID for per-conversation isolation - Returns: Path to the database file (shared or conversation-specific).
    private func getDatabasePath(conversationId: UUID? = nil) throws -> String {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let samDirectory = appSupport.appendingPathComponent("SAM")
        try fileManager.createDirectory(at: samDirectory, withIntermediateDirectories: true)

        /// If conversationId provided, use per-conversation database.
        if let conversationId = conversationId {
            let conversationsDir = samDirectory.appendingPathComponent("conversations")
            try fileManager.createDirectory(at: conversationsDir, withIntermediateDirectories: true)

            let conversationDir = conversationsDir.appendingPathComponent(conversationId.uuidString)
            try fileManager.createDirectory(at: conversationDir, withIntermediateDirectories: true)

            let dbPath = conversationDir.appendingPathComponent("memory.db").path
            logger.debug("Using per-conversation database: \(dbPath)")
            return dbPath
        }

        /// Fallback to shared database (legacy compatibility).
        let sharedDbPath = samDirectory.appendingPathComponent("memory.db").path
        logger.debug("Using shared database: \(sharedDbPath)")
        return sharedDbPath
    }

    /// Get or create database connection for a specific conversation - Parameter conversationId: The conversation UUID to get database for - Returns: Database connection for the conversation - Throws: MemoryError if database creation fails.
    private func getDatabaseConnection(for conversationId: UUID) throws -> Connection {
        /// Check if we already have a connection for this conversation.
        if let existingConnection = conversationDatabases[conversationId] {
            return existingConnection
        }

        /// Create new connection for this conversation.
        let dbPath = try getDatabasePath(conversationId: conversationId)
        let connection = try Connection(dbPath)

        /// Create schema if this is a new database.
        try createSchemaForConnection(connection)

        /// Cache the connection.
        conversationDatabases[conversationId] = connection
        logger.debug("SUCCESS: MEMORY_ISOLATION: Created database for conversation \(conversationId)")

        return connection
    }

    /// Delete the database file for a specific conversation - Parameter conversationId: The conversation UUID to delete database for - Throws: MemoryError if deletion fails.
    public func deleteConversationDatabase(conversationId: UUID) throws {
        /// Close and remove cached connection first.
        conversationDatabases.removeValue(forKey: conversationId)

        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )

        let samDirectory = appSupport.appendingPathComponent("SAM")
        let conversationsDir = samDirectory.appendingPathComponent("conversations")
        let conversationDir = conversationsDir.appendingPathComponent(conversationId.uuidString)

        if fileManager.fileExists(atPath: conversationDir.path) {
            try fileManager.removeItem(at: conversationDir)
            logger.debug("SUCCESS: MEMORY_ISOLATION: Deleted database for conversation \(conversationId)")
        } else {
            logger.debug("No database found for conversation \(conversationId) (already deleted or never created)")
        }
    }

    private func loadStatistics() async throws {
        guard let db = database else { return }

        do {
            totalMemories = try db.scalar(memories.count)
            logger.debug("Loaded statistics: \(totalMemories) total memories")
        } catch {
            logger.warning("Could not load statistics: \(error)")
            totalMemories = 0
        }
    }

    private func generateEmbedding(for text: String) async throws -> Data {
        /// Try Apple NLEmbedding first for real semantic understanding.
        if let appleGen = appleEmbeddingGenerator {
            let vectorEmbedding = try await appleGen.generateEmbedding(for: text)
            /// Convert [Double] to Data.
            let vector = vectorEmbedding.vector
            return Data(bytes: vector, count: vector.count * MemoryLayout<Double>.size)
        }

        /// Fallback to hash-based (low quality).
        logger.debug("Using hash-based fallback embedding for memory")
        return generateHashBasedEmbedding(for: text)
    }

    // MARK: - Hash-Based Fallback (Legacy - Low Quality)

    /// Hash-based embedding fallback (does NOT provide real semantic understanding) Only used if Apple NLEmbedding unavailable.
    private func generateHashBasedEmbedding(for text: String) -> Data {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            return Data()
        }

        /// Extract words and normalize.
        let words = cleanText.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let uniqueWords = Set(words)

        /// Create a 256-dimensional feature vector.
        var vector = Array(repeating: 0.0, count: 256)

        /// Encode direct keyword features (improved matching).
        for word in uniqueWords {
            let wordHash = abs(word.hashValue)
            let vectorIndex = wordHash % 64
            vector[vectorIndex] = min(vector[vectorIndex] + 2.0, 10.0)
        }

        /// Encode word stems/prefixes for partial matching.
        for word in uniqueWords {
            if word.count >= 4 {
                let stem = String(word.prefix(4))
                let stemHash = abs(stem.hashValue)
                let vectorIndex = 64 + (stemHash % 64)
                vector[vectorIndex] = min(vector[vectorIndex] + 1.5, 8.0)
            }
        }

        /// Encode character n-grams for fuzzy matching.
        let chars = Array(cleanText.lowercased())
        if chars.count >= 3 {
            for i in 0..<min(chars.count - 2, 100) {
                let trigram = String(chars[i..<i + 3])
                let trigramHash = abs(trigram.hashValue)
                let vectorIndex = 128 + (trigramHash % 128)
                vector[vectorIndex] = min(vector[vectorIndex] + 0.5, 5.0)
            }
        }

        /// Normalize vector.
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if magnitude > 0 {
            vector = vector.map { $0 / magnitude }
        }

        /// Convert to Data.
        return Data(bytes: vector, count: vector.count * MemoryLayout<Double>.size)
    }

    private func calculateCosineSimilarity(_ embedding1: Data, _ embedding2: Data) -> Double {
        guard embedding1.count == embedding2.count && !embedding1.isEmpty else {
            return 0.0
        }

        let vector1 = embedding1.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Double.self))
        }

        let vector2 = embedding2.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Double.self))
        }

        guard vector1.count == vector2.count else { return 0.0 }

        let dotProduct = zip(vector1, vector2).map(*).reduce(0, +)
        let magnitude1 = sqrt(vector1.map { $0 * $0 }.reduce(0, +))
        let magnitude2 = sqrt(vector2.map { $0 * $0 }.reduce(0, +))

        guard magnitude1 > 0 && magnitude2 > 0 else { return 0.0 }

        return dotProduct / (magnitude1 * magnitude2)
    }

    private func calculateKeywordBoost(query: String, content: String) -> Double {
        /// Simple keyword overlap boost without hardcoded dictionaries.
        let queryWords = Set(query.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0.count > 2 })

        let contentWords = Set(content.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0.count > 2 })

        let intersection = queryWords.intersection(contentWords)
        let union = queryWords.union(contentWords)

        guard !union.isEmpty else { return 0.0 }

        /// Jaccard similarity as boost (0.0 to 1.0).
        let jaccardSimilarity = Double(intersection.count) / Double(union.count)

        /// Scale boost based on word overlap quality CRITICAL FIX (Bug #7): Increased max boost from 0.3 to 0.5 for better exact match ranking.
        return min(jaccardSimilarity * 0.5, 0.5)
    }

    private func updateAccessStatistics(memoryId: UUID, in db: Connection? = nil) throws {
        let database = db ?? self.database
        guard let database = database else { return }

        let memory = memories.filter(id == memoryId.uuidString)
        try database.run(memory.update(
            accessCount <- (accessCount + 1),
            lastAccessed <- Date()
        ))
    }
}

// MARK: - Supporting Types

/// Memory content types for categorizing different types of stored content.
public enum MemoryContentType: String, CaseIterable, Sendable {
    case message = "message"
    case userInput = "user_input"
    case assistantResponse = "assistant_response"
    case systemEvent = "system_event"
    case toolResult = "tool_result"
    case contextInfo = "context_info"
    case document = "document"
}

/// Represents a stored memory item with metadata.
public struct ConversationMemory: Identifiable, Sendable {
    public let id: UUID
    public let conversationId: UUID
    public let content: String
    public let contentType: MemoryContentType
    public let importance: Double
    public let similarity: Double
    public let createdAt: Date
    public let accessCount: Int
    public let tags: [String]
}

/// Statistics about memories for a conversation.
public struct MemoryStatistics {
    public let totalMemories: Int
    public let averageImportance: Double
    public let totalAccesses: Int
    public let oldestMemory: Date?
    public let newestMemory: Date?

    public var hasMemories: Bool {
        totalMemories > 0
    }

    public var memorySpan: TimeInterval? {
        guard let oldest = oldestMemory, let newest = newestMemory else {
            return nil
        }
        return newest.timeIntervalSince(oldest)
    }
}

/// Global memory statistics across all conversations with content type breakdown.
public struct GlobalMemoryStatistics: Sendable {
    public let totalCount: Int
    public let byType: [MemoryContentType: Int]
    public let recentCount: Int
    public let averageImportance: Double

    public var hasMemories: Bool {
        totalCount > 0
    }
}

/// Memory system errors.
public enum MemoryError: Error, LocalizedError {
    case databaseNotInitialized
    case initializationFailed(String)
    case storageFailed(String)
    case retrievalFailed(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "Memory database not initialized"

        case .initializationFailed(let message):
            return "Memory initialization failed: \(message)"

        case .storageFailed(let message):
            return "Memory storage failed: \(message)"

        case .retrievalFailed(let message):
            return "Memory retrieval failed: \(message)"

        case .operationFailed(let message):
            return "Memory operation failed: \(message)"
        }
    }
}
