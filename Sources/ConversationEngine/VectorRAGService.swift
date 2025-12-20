// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// VectorRAGService.swift SAM Enhanced Vector RAG System for sophisticated document processing and retrieval ARCHITECTURE OVERVIEW: - Document Ingestion: Chunks documents and generates 768-dimensional embeddings - Semantic Search: Cosine similarity matching for relevant content retrieval - Memory Integration: Stores processed chunks in MemoryManager with RAG tags - Cross-Conversation Search: Enhanced search across all stored memories KEY COMPONENTS: - DocumentChunker: Intelligent content segmentation preserving context - EmbeddingGenerator: 768-dimensional vector generation using NaturalLanguage - ProcessedChunk: Container for chunk content, embeddings, and metadata - SemanticSearchResult: Search results with similarity scores and context INTEGRATION POINTS: - MemoryManagerAdapter: Enhanced search with Vector RAG fallback - ConversationManager: Service lifecycle and initialization management - MCP Tools: Memory search integration for conversational access.

import Foundation
import Logging
import NaturalLanguage

/// Enhanced Vector RAG Service for sophisticated document processing and retrieval.
@MainActor
public class VectorRAGService: ObservableObject {
    private let logger = Logger(label: "com.sam.vectorrag")
    private let memoryManager: MemoryManager
    private let embeddingGenerator: EmbeddingGenerator
    private let documentChunker: DocumentChunker

    @Published public var isOperational: Bool = false
    @Published public var totalDocuments: Int = 0
    @Published public var totalChunks: Int = 0

    // MARK: - Lifecycle
    public init(memoryManager: MemoryManager) {
        self.memoryManager = memoryManager
        self.embeddingGenerator = EmbeddingGenerator()
        self.documentChunker = DocumentChunker()

        logger.debug("SUCCESS: VectorRAGService initialized")
    }

    // MARK: - Lifecycle
    public func initialize() async throws {
        logger.debug("WARNING: VECTOR RAG - Initializing enhanced search capabilities")

        try await embeddingGenerator.initialize()

        isOperational = true
        logger.debug("SUCCESS: VECTOR RAG - Enhanced search system operational")
    }

    // MARK: - Document Ingestion and Processing

    /// Ingest a document with sophisticated chunking and embedding generation.
    public func ingestDocument(_ document: RAGDocument) async throws -> DocumentIngestionResult {
        logger.debug("ERROR: INGESTING - \(document.title) (\(document.content.count) characters)")
        logger.debug("ERROR: CONVERSATION_ID - \(document.conversationId?.uuidString ?? "nil")")

        /// SECURITY FIX: Enforce conversation-scoped memory by requiring conversationId This prevents documents from being stored in wrong conversation databases and ensures proper memory isolation between conversations.
        guard let conversationId = document.conversationId else {
            let errorMessage = "Document import requires conversationId for conversation-scoped memory. Document: \(document.title)"
            logger.error("CRITICAL ERROR: \(errorMessage)")
            throw VectorRAGError.ingestionFailed(errorMessage)
        }

        logger.debug("Using conversationId: \(conversationId.uuidString)")

        /// Check if document has page information for page-aware chunking.
        var chunks: [DocumentChunk] = []

        if let pages = document.pages, !pages.isEmpty {
            /// PAGE-AWARE CHUNKING: Preserve document structure by respecting page boundaries.
            logger.debug("WARNING: Using page-aware chunking for \(pages.count) pages")
            chunks = try await chunkDocumentByPages(document, pages: pages)
        } else {
            /// FALLBACK: Use traditional semantic chunking for documents without page information.
            logger.debug("WARNING: Using linear chunking (no page information available)")
            chunks = try await documentChunker.chunkDocument(document)
        }

        logger.debug("WARNING: CHUNKED - Created \(chunks.count) semantic chunks")

        /// Step 2: Generate embeddings and store each chunk.
        var processedChunks: [ProcessedChunk] = []
        var failedChunks: [(index: Int, error: Error)] = []

        for (index, chunk) in chunks.enumerated() {
            logger.debug("ERROR: EMBEDDING - Chunk \(index + 1)/\(chunks.count)")

            do {
                let embedding = try await embeddingGenerator.generateEmbedding(for: chunk.content)
                let processedChunk = ProcessedChunk(
                    id: UUID(),
                    documentId: document.id,
                    chunkIndex: index,
                    content: chunk.content,
                    context: chunk.context,
                    importance: chunk.importance,
                    embedding: embedding,
                    metadata: chunk.metadata
                )

                /// Capture storeMemory result instead of discarding with '_' This ensures we can detect storage failures and report them properly CRITICAL FIX 2: Use conversationId from guard statement (enforces non-nil) Previous bug: ??.
                let memoryId = try await memoryManager.storeMemory(
                    content: chunk.content,
                    conversationId: conversationId,
                    contentType: .document,
                    importance: chunk.importance,
                    tags: ["rag", "document", document.type.rawValue] + Array(chunk.metadata.keys)
                )

                logger.debug("SUCCESS: Stored chunk \(index + 1) in memory with ID: \(memoryId)")
                processedChunks.append(processedChunk)

            } catch {
                /// Track failed chunks instead of letting entire ingestion fail This allows partial success and provides detailed error reporting to SAM.
                logger.error("ERROR: Failed to process chunk \(index + 1): \(error.localizedDescription)")
                failedChunks.append((index: index, error: error))
            }
        }

        /// Check if storage actually succeeded before claiming success If ALL chunks failed, throw error so SAM sees the failure.
        if processedChunks.isEmpty {
            let errorMessage = "Failed to store any chunks in memory. Errors: \(failedChunks.map { "Chunk \($0.index): \($0.error.localizedDescription)" }.joined(separator: ", "))"
            logger.error("CRITICAL: Document ingestion FAILED - \(errorMessage)")
            throw VectorRAGError.ingestionFailed(errorMessage)
        }

        /// Update statistics (only for successful chunks).
        totalDocuments += 1
        totalChunks += processedChunks.count

        /// Report partial failures to SAM so user knows what happened.
        if !failedChunks.isEmpty {
            logger.warning("WARNING: Partial ingestion - \(processedChunks.count) chunks stored, \(failedChunks.count) chunks failed")
        } else {
            logger.debug("SUCCESS: INGESTED - \(document.title) with \(chunks.count) chunks")
        }

        return DocumentIngestionResult(
            documentId: document.id,
            chunksCreated: processedChunks.count,
            embeddingsGenerated: processedChunks.count,
            processingTime: Date().timeIntervalSince(document.createdAt),
            success: true,
            partialFailure: !failedChunks.isEmpty,
            failedChunks: failedChunks.count,
            errorDetails: failedChunks.isEmpty ? nil : failedChunks.map { "Chunk \($0.index): \($0.error.localizedDescription)" }.joined(separator: "\n")
        )
    }

    // MARK: - Page-Aware Chunking

    /// Chunk document by page boundaries to preserve document structure.
    private func chunkDocumentByPages(_ document: RAGDocument, pages: [PageContent]) async throws -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []
        let targetChunkSize = 2500
        let chunkOverlap = 300
        let minChunkSize = 500
        let smallPageThreshold = 2000

        logger.debug("WARNING: Page-aware chunking starting for \(pages.count) pages")

        for page in pages {
            let pageLength = page.text.count
            let trimmedText = page.text.trimmingCharacters(in: .whitespacesAndNewlines)

            /// Skip empty pages.
            if trimmedText.isEmpty {
                logger.debug("DEBUG: Skipping empty page \(page.pageNumber)")
                continue
            }

            if pageLength < smallPageThreshold {
                /// SMALL PAGE: Create one chunk per page This preserves complete sections like TOC entries, chapter headers, etc.
                logger.debug("DEBUG: Small page \(page.pageNumber) (\(pageLength) chars) - creating single chunk")

                let chunk = DocumentChunk(
                    content: trimmedText,
                    context: "Text from \(document.title), page \(page.pageNumber)",
                    importance: calculateChunkImportance(trimmedText),
                    metadata: [
                        "source": document.title,
                        "type": "text",
                        "page_number": page.pageNumber,
                        "chunk_size": trimmedText.count,
                        "single_page": true
                    ]
                )
                chunks.append(chunk)

            } else {
                /// LARGE PAGE: Split into sub-chunks, all tagged with same page number This maintains page context while keeping chunks at optimal size.
                logger.debug("DEBUG: Large page \(page.pageNumber) (\(pageLength) chars) - splitting into sub-chunks")

                let pageChunks = try await chunkLargePage(
                    pageText: trimmedText,
                    pageNumber: page.pageNumber,
                    documentTitle: document.title,
                    targetSize: targetChunkSize,
                    overlap: chunkOverlap,
                    minSize: minChunkSize
                )

                chunks.append(contentsOf: pageChunks)
                logger.debug("DEBUG: Created \(pageChunks.count) sub-chunks for page \(page.pageNumber)")
            }
        }

        logger.debug("SUCCESS: Page-aware chunking created \(chunks.count) chunks from \(pages.count) pages")
        return chunks
    }

    /// Split a large page into sub-chunks while maintaining page context.
    private func chunkLargePage(
        pageText: String,
        pageNumber: Int,
        documentTitle: String,
        targetSize: Int,
        overlap: Int,
        minSize: Int
    ) async throws -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []

    /// Split into sentences to respect semantic boundaries (off-main).
    let sentences = await splitIntoSentences(pageText)

        var currentChunk = ""
        var currentChunkSentences: [String] = []
        var overlapText = ""

        for sentence in sentences {
            let sentenceClean = sentence.trimmingCharacters(in: .whitespaces)
            if sentenceClean.isEmpty { continue }

            let potentialChunk = currentChunk + (currentChunk.isEmpty ? "" : " ") + sentenceClean

            /// Check if adding this sentence would exceed target size.
            if potentialChunk.count > targetSize && !currentChunk.isEmpty {
                /// Create chunk from accumulated sentences.
                let chunkContent = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if chunkContent.count >= minSize {
                    let chunk = DocumentChunk(
                        content: chunkContent,
                        context: "Text from \(documentTitle), page \(pageNumber)",
                        importance: calculateChunkImportance(chunkContent),
                        metadata: [
                            "source": documentTitle,
                            "type": "text",
                            "page_number": pageNumber,
                            "chunk_size": chunkContent.count,
                            "single_page": false
                        ]
                    )
                    chunks.append(chunk)

                    /// Create overlap by keeping last few sentences.
                    overlapText = createOverlap(from: currentChunkSentences, targetLength: overlap)
                }

                /// Start new chunk with overlap.
                currentChunk = overlapText + (overlapText.isEmpty ? "" : " ") + sentenceClean
                currentChunkSentences = [sentenceClean]
            } else {
                currentChunk = potentialChunk
                currentChunkSentences.append(sentenceClean)
            }
        }

        /// Add final chunk if substantial content remains.
        if !currentChunk.isEmpty {
            let chunkContent = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if chunkContent.count >= minSize {
                let chunk = DocumentChunk(
                    content: chunkContent,
                    context: "Text from \(documentTitle), page \(pageNumber)",
                    importance: calculateChunkImportance(chunkContent),
                    metadata: [
                        "source": documentTitle,
                        "type": "text",
                        "page_number": pageNumber,
                        "chunk_size": chunkContent.count,
                        "single_page": false
                    ]
                )
                chunks.append(chunk)
            }
        }

        return chunks
    }

    /// Split text into sentences while respecting semantic boundaries.
    private func splitIntoSentences(_ text: String) async -> [String] {
        return await Task.detached(priority: .userInitiated) {
            var sentences: [String] = []
            /// Split lines by any newline characters, using a lightweight split.
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { String($0) }

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }

                /// Manual scanning to find sentence terminators and avoid heavy Foundation splits.
                var current = ""
                for ch in trimmed {
                    current.append(ch)
                    if ch == "." || ch == "!" || ch == "?" {
                        let clean = current.trimmingCharacters(in: .whitespaces)
                        if clean.count > 20 {
                            sentences.append(clean)
                        }
                        current = ""
                    }
                }

                let leftover = current.trimmingCharacters(in: .whitespaces)
                if leftover.count > 20 {
                    sentences.append(leftover + (leftover.last?.isPunctuation == true ? "" : "."))
                }
            }

            return sentences
        }.value
    }

    /// Create overlap from last sentences to preserve context.
    private func createOverlap(from sentences: [String], targetLength: Int) -> String {
        var overlap = ""
        for sentence in sentences.reversed() {
            let testOverlap = sentence + " " + overlap
            if testOverlap.count > targetLength {
                break
            }
            overlap = testOverlap
        }
        return overlap.trimmingCharacters(in: .whitespaces)
    }

    /// Calculate importance score for chunk based on content characteristics.
    private func calculateChunkImportance(_ content: String) -> Double {
        /// Simple heuristic: longer chunks with more diverse vocabulary are more important.
        let wordCount = content.components(separatedBy: .whitespacesAndNewlines).count
        let uniqueWords = Set(content.lowercased().components(separatedBy: .whitespacesAndNewlines)).count
        let diversity = uniqueWords > 0 ? Double(uniqueWords) / Double(wordCount) : 0.5
        return min(1.0, diversity * 1.5)
    }

    /// Perform sophisticated semantic search across ingested documents.
    public func semanticSearch(
        query: String,
        conversationId: UUID? = nil,
        limit: Int = 20,
        similarityThreshold: Double = 0.7,
        includeContext: Bool = true
    ) async throws -> [SemanticSearchResult] {

        logger.debug("ERROR: SEMANTIC SEARCH - '\(query.prefix(50))' (limit: \(limit), conversationId: \(conversationId?.uuidString ?? "nil"))")

        /// Use conversation-specific search when conversationId provided This loads the conversation database on-demand (fixes bug where database not in memory).
        let filteredMemories: [ConversationMemory]
        if let conversationId = conversationId {
            logger.debug("DEBUG: Using conversation-specific search (loads database on-demand)")
            filteredMemories = try await memoryManager.retrieveRelevantMemories(
                for: query,
                conversationId: conversationId,
                limit: limit * 2,
                similarityThreshold: similarityThreshold
            )
            logger.debug("DEBUG: Found \(filteredMemories.count) memories in conversation \(conversationId)")
        } else {
            logger.debug("DEBUG: Using cross-conversation search (global search)")
            let memories = try await memoryManager.searchAllConversations(
                query: query,
                limit: limit * 2,
                similarityThreshold: similarityThreshold
            )
            filteredMemories = memories
        }

        /// Filter for document-related memories and enhance with RAG scoring.
        let ragMemories = filteredMemories.filter { memory in
            memory.contentType == .document ||
            memory.tags.contains("rag") ||
            memory.tags.contains("document")
        }

        /// Convert to semantic search results with enhanced ranking.
        let semanticResults = try await convertToSemanticResults(
            memories: ragMemories,
            query: query,
            includeContext: includeContext
        )

        logger.debug("WARNING: SEMANTIC SEARCH - Found \(semanticResults.count) relevant results")
        return semanticResults
    }

    /// Retrieve augmented context for a query (RAG functionality).
    public func retrieveAugmentedContext(
        query: String,
        conversationId: UUID? = nil,
        maxTokens: Int = 2000,
        diversityFactor: Double = 0.3
    ) async throws -> AugmentedContext {

        logger.debug("ERROR: RAG RETRIEVAL - Augmenting context for '\(query.prefix(50))'")

        /// Step 1: Get diverse semantic search results.
        let searchResults = try await semanticSearch(
            query: query,
            conversationId: conversationId,
            limit: 15,
            similarityThreshold: 0.6,
            includeContext: true
        )

        /// Step 2: Apply diversity selection to avoid redundancy.
        let diverseResults = applyDiversitySelection(
            results: searchResults,
            diversityFactor: diversityFactor
        )

        /// Step 3: Rank by relevance and importance.
        let finalResults = rankByRelevanceAndImportance(diverseResults)

        /// Step 4: Construct augmented context within token limit.
        let augmentedContext = try await constructAugmentedContext(
            results: finalResults,
            query: query,
            maxTokens: maxTokens
        )

        logger.debug("SUCCESS: RAG CONTEXT - Generated \(augmentedContext.tokenCount) tokens from \(finalResults.count) sources")

        return augmentedContext
    }

    // MARK: - Enhanced Memory Integration

    /// Convert memory results to semantic search results with enhanced ranking.
    private func convertToSemanticResults(
        memories: [ConversationMemory],
        query: String,
        includeContext: Bool
    ) async throws -> [SemanticSearchResult] {

        var results: [SemanticSearchResult] = []

        for memory in memories {
            /// Enhanced relevance calculation.
            let contentRelevance = calculateContentRelevance(memory.content, query: query)
            let temporalRelevance = calculateTemporalRelevance(memory.createdAt)
            let importanceScore = memory.importance

            /// Combined relevance score.
            let combinedSimilarity = (
                contentRelevance * 0.4 +
                temporalRelevance * 0.3 +
                importanceScore * 0.3
            )

            let result = SemanticSearchResult(
                id: memory.id,
                documentId: memory.conversationId,
                content: memory.content,
                similarity: combinedSimilarity,
                importance: importanceScore,
                context: includeContext ? "From: \(memory.contentType.rawValue)" : "",
                metadata: extractMetadata(from: memory.tags),
                chunkIndex: 0,
                timestamp: memory.createdAt
            )

            results.append(result)
        }

        /// Sort by similarity.
        results.sort { $0.similarity > $1.similarity }
        return results
    }

    // MARK: - Helper Methods

    private func calculateContentRelevance(_ content: String, query: String) -> Double {
        let queryWords = Set(query.lowercased().split { $0.isWhitespace || $0.isNewline }.map { String($0) })
        let contentWords = Set(content.lowercased().split { $0.isWhitespace || $0.isNewline }.map { String($0) })

        let intersection = queryWords.intersection(contentWords)
        let union = queryWords.union(contentWords)

        return union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
    }

    private func calculateTemporalRelevance(_ timestamp: Date) -> Double {
        let ageInDays = Date().timeIntervalSince(timestamp) / 86400
        return max(0.1, 1.0 - (ageInDays / 365.0))
    }

    private func extractMetadata(from tags: [String]) -> [String: Any] {
        return ["tags": tags]
    }

    private func applyDiversitySelection(
        results: [SemanticSearchResult],
        diversityFactor: Double
    ) -> [SemanticSearchResult] {

        var selectedResults: [SemanticSearchResult] = []

        for result in results {
            let documentSimilarity = calculateDocumentSimilarity(result, selectedResults: selectedResults)
            let diversityScore = 1.0 - (documentSimilarity * diversityFactor)

            if diversityScore > 0.5 || selectedResults.count < 3 {
                selectedResults.append(result)
            }

            if selectedResults.count >= 10 { break }
        }

        return selectedResults
    }

    private func calculateDocumentSimilarity(
        _ result: SemanticSearchResult,
        selectedResults: [SemanticSearchResult]
    ) -> Double {

        guard !selectedResults.isEmpty else { return 0.0 }

        let similarities = selectedResults.map { selected in
            calculateContentRelevance(result.content, query: selected.content)
        }

        return similarities.max() ?? 0.0
    }

    private func rankByRelevanceAndImportance(_ results: [SemanticSearchResult]) -> [SemanticSearchResult] {
        return results.sorted { a, b in
            let scoreA = a.similarity * 0.7 + a.importance * 0.3
            let scoreB = b.similarity * 0.7 + b.importance * 0.3
            return scoreA > scoreB
        }
    }

    private func constructAugmentedContext(
        results: [SemanticSearchResult],
        query: String,
        maxTokens: Int
    ) async throws -> AugmentedContext {

        var contextParts: [String] = []
        var currentTokens = 0
        var sourcesUsed: [UUID] = []

        /// Add query context.
        let queryContext = "Query: \(query)\n\nRelevant Information:\n"
        contextParts.append(queryContext)
        currentTokens += estimateTokenCount(queryContext)

        /// Add results until token limit.
        for (index, result) in results.enumerated() {
            let resultText = "\n[\(index + 1)] \(result.content)"
            let resultTokens = estimateTokenCount(resultText)

            if currentTokens + resultTokens <= maxTokens {
                contextParts.append(resultText)
                currentTokens += resultTokens
                sourcesUsed.append(result.documentId)
            } else {
                break
            }
        }

        let finalContext = contextParts.joined()

        return AugmentedContext(
            originalQuery: query,
            augmentedText: finalContext,
            tokenCount: currentTokens,
            sourcesUsed: sourcesUsed,
            relevanceScore: results.first?.similarity ?? 0.0,
            generatedAt: Date()
        )
    }

    private func estimateTokenCount(_ text: String) -> Int {
        /// Rough estimation: ~4 characters per token.
        return text.count / 4
    }
}

// MARK: - Supporting Types and Data Structures

/// Page content structure for page-aware chunking.
public struct PageContent: Sendable {
    public let pageNumber: Int
    public let text: String

    public init(pageNumber: Int, text: String) {
        self.pageNumber = pageNumber
        self.text = text
    }
}

public struct RAGDocument: @unchecked Sendable {
    public let id: UUID
    public let title: String
    public let content: String
    public let type: DocumentType
    public let conversationId: UUID?
    public let metadata: [String: Any]
    public let createdAt: Date
    public let pages: [PageContent]?

    public init(
        id: UUID = UUID(),
        title: String,
        content: String,
        type: DocumentType,
        conversationId: UUID? = nil,
        metadata: [String: Any] = [:],
        pages: [PageContent]? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.type = type
        self.conversationId = conversationId
        self.metadata = metadata
        self.createdAt = Date()
        self.pages = pages
    }
}

public enum DocumentType: String, CaseIterable, Sendable {
    case text = "text"
    case markdown = "markdown"
    case code = "code"
    case pdf = "pdf"
    case web = "web"
    case conversation = "conversation"
}

/// Errors that can occur during VectorRAG operations.
public enum VectorRAGError: LocalizedError {
    case ingestionFailed(String)
    case searchFailed(String)
    case embeddingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ingestionFailed(let message):
            return "Document ingestion failed: \(message)"

        case .searchFailed(let message):
            return "Semantic search failed: \(message)"

        case .embeddingFailed(let message):
            return "Embedding generation failed: \(message)"
        }
    }
}

public struct DocumentChunk: @unchecked Sendable {
    public let content: String
    public let context: String
    public let importance: Double
    public let metadata: [String: Any]

    public init(content: String, context: String = "", importance: Double = 0.5, metadata: [String: Any] = [:]) {
        self.content = content
        self.context = context
        self.importance = importance
        self.metadata = metadata
    }
}

public struct ProcessedChunk: @unchecked Sendable {
    public let id: UUID
    public let documentId: UUID
    public let chunkIndex: Int
    public let content: String
    public let context: String
    public let importance: Double
    public let embedding: VectorEmbedding
    public let metadata: [String: Any]
}

public struct VectorEmbedding: Sendable {
    public let vector: [Double]
    public let dimension: Int
    public let model: String
    public let generatedAt: Date

    public init(vector: [Double], model: String = "sam-embeddings") {
        self.vector = vector
        self.dimension = vector.count
        self.model = model
        self.generatedAt = Date()
    }
}

public struct DocumentIngestionResult {
    public let documentId: UUID
    public let chunksCreated: Int
    public let embeddingsGenerated: Int
    public let processingTime: TimeInterval
    public let success: Bool
    public let partialFailure: Bool
    public let failedChunks: Int
    public let errorDetails: String?

    public init(
        documentId: UUID,
        chunksCreated: Int,
        embeddingsGenerated: Int,
        processingTime: TimeInterval,
        success: Bool,
        partialFailure: Bool = false,
        failedChunks: Int = 0,
        errorDetails: String? = nil
    ) {
        self.documentId = documentId
        self.chunksCreated = chunksCreated
        self.embeddingsGenerated = embeddingsGenerated
        self.processingTime = processingTime
        self.success = success
        self.partialFailure = partialFailure
        self.failedChunks = failedChunks
        self.errorDetails = errorDetails
    }
}

public struct SemanticSearchResult: @unchecked Sendable {
    public let id: UUID
    public let documentId: UUID
    public let content: String
    public let similarity: Double
    public let importance: Double
    public let context: String
    public let metadata: [String: Any]
    public let chunkIndex: Int
    public let timestamp: Date
}

public struct AugmentedContext {
    public let originalQuery: String
    public let augmentedText: String
    public let tokenCount: Int
    public let sourcesUsed: [UUID]
    public let relevanceScore: Double
    public let generatedAt: Date
}

// MARK: - Document Chunker

public class DocumentChunker: @unchecked Sendable {
    private let logger = Logger(label: "com.sam.chunker")

    /// Sophisticated document chunking with semantic awareness.
    public func chunkDocument(_ document: RAGDocument) async throws -> [DocumentChunk] {
        logger.debug("ERROR: CHUNKING - \(document.title) (\(document.type.rawValue))")

        switch document.type {
        case .text, .markdown:
            return try await chunkTextDocument(document)

        case .code:
            return try await chunkCodeDocument(document)

        case .conversation:
            return try await chunkConversationDocument(document)

        default:
            return try await chunkTextDocument(document)
        }
    }

    private func chunkTextDocument(_ document: RAGDocument) async throws -> [DocumentChunk] {
        /// IMPROVED CHUNKING STRATEGY based on SAM collaboration findings: - Larger chunks to preserve context (2000-3000 chars) - Overlap between chunks (200 chars) to preserve semantic continuity - Respect semantic boundaries (sentences, paragraphs).

        let targetChunkSize = 2500
        let chunkOverlap = 300
        let minChunkSize = 200

        /// Check if content is too small to chunk meaningfully.
        if document.content.count < minChunkSize {
            logger.warning("CONTENT_TOO_SMALL: Document '\(document.title)' has only \(document.content.count) characters (min: \(minChunkSize))")
            throw VectorRAGError.ingestionFailed("""
                Content too small to chunk: \(document.content.count) characters (minimum: \(minChunkSize)).

                RECOMMENDATION: Process this content directly without RAG ingestion.
                The content is brief enough to include in your response without needing semantic search.

                For very short content (summaries, snippets, brief articles):
                - Use the content directly in your synthesis
                - No need to store in memory
                - Reference the source URL for attribution
                """)
        }

        var chunks: [DocumentChunk] = []

        /// First, clean and normalize the text.
        let normalizedText = document.content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)

    /// Split into sentences to respect semantic boundaries (off-main).
    let sentences = await splitIntoSentences(normalizedText)

        var currentChunk = ""
        var currentChunkSentences: [String] = []
        var overlap = ""

        for sentence in sentences {
            let sentenceClean = sentence.trimmingCharacters(in: .whitespaces)
            if sentenceClean.isEmpty { continue }

            let potentialChunk = currentChunk + (currentChunk.isEmpty ? "" : " ") + sentenceClean

            /// Check if adding this sentence would exceed target size.
            if potentialChunk.count > targetChunkSize && !currentChunk.isEmpty {
                /// Create chunk from accumulated sentences.
                let chunkContent = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if chunkContent.count >= minChunkSize {
                    let chunk = DocumentChunk(
                        content: chunkContent,
                        context: "Text from \(document.title)",
                        importance: calculateChunkImportance(chunkContent),
                        metadata: ["source": document.title, "type": "text", "chunk_size": chunkContent.count]
                    )
                    chunks.append(chunk)

                    /// Create overlap by keeping last few sentences.
                    overlap = createOverlap(from: currentChunkSentences, targetLength: chunkOverlap)
                }

                /// Start new chunk with overlap.
                currentChunk = overlap + (overlap.isEmpty ? "" : " ") + sentenceClean
                currentChunkSentences = [sentenceClean]
            } else {
                currentChunk = potentialChunk
                currentChunkSentences.append(sentenceClean)
            }
        }

        /// Add final chunk if substantial content remains.
        if !currentChunk.isEmpty {
            let chunkContent = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if chunkContent.count >= minChunkSize {
                let chunk = DocumentChunk(
                    content: chunkContent,
                    context: "Text from \(document.title)",
                    importance: calculateChunkImportance(chunkContent),
                    metadata: ["source": document.title, "type": "text", "chunk_size": chunkContent.count]
                )
                chunks.append(chunk)
            }
        }

        /// Check if chunking produced zero chunks.
        if chunks.isEmpty {
            logger.warning("ZERO_CHUNKS: Document '\(document.title)' produced no chunks (content: \(document.content.count) chars, min: \(minChunkSize))")
            throw VectorRAGError.ingestionFailed("""
                No chunks created from content: Document has \(document.content.count) characters but all segments were below minimum chunk size (\(minChunkSize)).

                RECOMMENDATION: Process this content directly without RAG ingestion.
                The content is too fragmented or brief for semantic chunking.

                For very short or fragmented content:
                - Use the content directly in your synthesis
                - No need to store in memory
                - Reference the source URL for attribution
                """)
        }

        logger.debug("SUCCESS: CHUNKED - \(document.title) into \(chunks.count) semantic chunks (avg size: \(chunks.isEmpty ? 0 : chunks.map { $0.content.count }.reduce(0, +) / chunks.count) chars)")
        return chunks
    }

    /// Split text into sentences while respecting semantic boundaries (off-main implementation).
    private func splitIntoSentences(_ text: String) async -> [String] {
        return await Task.detached(priority: .userInitiated) {
            var sentences: [String] = []
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { String($0) }

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }

                var current = ""
                for ch in trimmed {
                    current.append(ch)
                    if ch == "." || ch == "!" || ch == "?" {
                        let clean = current.trimmingCharacters(in: .whitespaces)
                        if clean.count > 20 {
                            sentences.append(clean)
                        }
                        current = ""
                    }
                }

                let leftover = current.trimmingCharacters(in: .whitespaces)
                if leftover.count > 20 {
                    sentences.append(leftover + (leftover.last?.isPunctuation == true ? "" : "."))
                }
            }

            return sentences
        }.value
    }

    /// Create overlap from last sentences to preserve context.
    private func createOverlap(from sentences: [String], targetLength: Int) -> String {
        var overlap = ""
        for sentence in sentences.reversed() {
            let potential = sentence + " " + overlap
            if potential.count > targetLength {
                break
            }
            overlap = potential
        }
        return overlap.trimmingCharacters(in: .whitespaces)
    }

    private func chunkCodeDocument(_ document: RAGDocument) async throws -> [DocumentChunk] {
    /// Simple function-based chunking for code.
    let lines = document.content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { String($0) }
        var chunks: [DocumentChunk] = []
        var currentFunction = ""
        var inFunction = false

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            /// Detect function start (simplified).
            if trimmedLine.contains("func ") || trimmedLine.contains("function ") || trimmedLine.contains("def ") {
                if !currentFunction.isEmpty {
                    /// Save previous function.
                    let chunk = DocumentChunk(
                        content: currentFunction,
                        context: "Code function from \(document.title)",
                        importance: 0.8,
                        metadata: ["source": document.title, "type": "code", "language": detectLanguage(document.content)]
                    )
                    chunks.append(chunk)
                }
                currentFunction = line
                inFunction = true
            } else if inFunction {
                currentFunction += "\n" + line

                /// Simple end detection.
                if trimmedLine == "}" || (trimmedLine.isEmpty && currentFunction.count > 500) {
                    let chunk = DocumentChunk(
                        content: currentFunction,
                        context: "Code function from \(document.title)",
                        importance: 0.8,
                        metadata: ["source": document.title, "type": "code", "language": detectLanguage(document.content)]
                    )
                    chunks.append(chunk)
                    currentFunction = ""
                    inFunction = false
                }
            }
        }

        /// Handle remaining content.
        if !currentFunction.isEmpty {
            let chunk = DocumentChunk(
                content: currentFunction,
                context: "Code from \(document.title)",
                importance: 0.7,
                metadata: ["source": document.title, "type": "code"]
            )
            chunks.append(chunk)
        }

        return chunks
    }

    private func chunkConversationDocument(_ document: RAGDocument) async throws -> [DocumentChunk] {
        /// Split by conversation turns.
        let turns = document.content.components(separatedBy: "\n\n")
        return turns.enumerated().compactMap { index, turn in
            let trimmed = turn.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            return DocumentChunk(
                content: trimmed,
                context: "Conversation turn \(index + 1) from \(document.title)",
                importance: 0.6,
                metadata: ["source": document.title, "type": "conversation", "turn": index]
            )
        }
    }

    private func calculateChunkImportance(_ content: String) -> Double {
        var importance = 0.5

    /// Boost for longer content.
    if content.count > 500 { importance += 0.1 }
    if content.count > 1000 { importance += 0.1 }

    /// Boost for important keywords.
    let lowercased = content.lowercased()
    if lowercased.contains("important") || lowercased.contains("critical") { importance += 0.2 }
    if lowercased.contains("key") || lowercased.contains("main") { importance += 0.1 }
    if lowercased.contains("summary") || lowercased.contains("conclusion") { importance += 0.15 }

    /// Word diversity heuristic (use split instead of components to reduce allocations).
    let words = content.split { $0.isWhitespace || $0.isNewline }.map { String($0) }
    let wordCount = words.count
    let uniqueWords = Set(words.map { $0.lowercased() }).count
    let diversity = uniqueWords > 0 ? Double(uniqueWords) / Double(max(1, wordCount)) : 0.5
    importance = min(1.0, importance + diversity * 1.5)
    return min(importance, 1.0)
    }

    private func detectLanguage(_ code: String) -> String {
        let lowercased = code.lowercased()
        if lowercased.contains("func ") && lowercased.contains("var ") { return "swift" }
        if lowercased.contains("function ") && lowercased.contains("const ") { return "javascript" }
        if lowercased.contains("def ") && lowercased.contains("import ") { return "python" }
        return "unknown"
    }
}

// MARK: - Embedding Generator

public class EmbeddingGenerator: @unchecked Sendable {
    private let logger = Logger(label: "com.sam.embeddings")
    private let appleGenerator: AppleNLEmbeddingGenerator?
    private let embeddingDimension: Int

    public init() {
        /// Try to initialize Apple NLEmbedding for real semantic understanding.
        do {
            self.appleGenerator = try AppleNLEmbeddingGenerator()
            self.embeddingDimension = appleGenerator!.dimension
            logger.debug("SUCCESS: Using Apple NLEmbedding for semantic similarity (dimension: \(embeddingDimension))")
        } catch {
            self.appleGenerator = nil
            self.embeddingDimension = 768
            logger.warning("Apple NLEmbedding unavailable, using hash-based fallback (low quality): \(error)")
        }
    }

    public func initialize() async throws {
        if appleGenerator != nil {
            logger.debug("Apple NLEmbedding initialized successfully - real semantic search enabled")
        } else {
            logger.warning("Using hash-based embedding fallback - search quality will be limited")
        }
    }

    /// Generate semantic embeddings for text content Uses Apple NLEmbedding if available, falls back to hash-based if not.
    public func generateEmbedding(for text: String) async throws -> VectorEmbedding {
        /// Try Apple NLEmbedding first (real semantic understanding).
        if let appleGen = appleGenerator {
            return try await appleGen.generateEmbedding(for: text)
        }

        /// Fallback to hash-based (existing implementation - low quality).
        logger.debug("Using hash-based fallback embedding (search quality limited)")
        return generateHashBasedEmbedding(for: text)
    }

    // MARK: - Hash-Based Fallback (Legacy - Low Quality)

    /// Hash-based embedding fallback (does NOT provide real semantic understanding) Only used if Apple NLEmbedding unavailable.
    private func generateHashBasedEmbedding(for text: String) -> VectorEmbedding {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            return VectorEmbedding(vector: Array(repeating: 0.0, count: embeddingDimension))
        }

        var vector = Array(repeating: 0.0, count: embeddingDimension)

    /// Enhanced feature extraction with multiple encoding strategies.
    let words = cleanText.lowercased().split { $0.isWhitespace || $0.isNewline }.map { String($0) }.filter { !$0.isEmpty }

        /// Strategy 1: Word frequency encoding.
        let wordCounts = Dictionary(grouping: words) { $0 }.mapValues { $0.count }

        /// Strategy 2: N-gram encoding.
        let bigrams = generateBigrams(from: words)
        let trigrams = generateTrigrams(from: words)

        /// Encode word features.
        for (word, count) in wordCounts {
            let wordHash = abs(word.hashValue) % embeddingDimension
            vector[wordHash] += Double(count) / sqrt(Double(words.count))
        }

        /// Encode bigram features.
        for bigram in bigrams {
            let bigramHash = abs(bigram.hashValue) % embeddingDimension
            vector[bigramHash] += 0.5 / sqrt(Double(bigrams.count))
        }

        /// Encode trigram features.
        for trigram in trigrams {
            let trigramHash = abs(trigram.hashValue) % embeddingDimension
            vector[trigramHash] += 0.3 / sqrt(Double(trigrams.count))
        }

        /// Normalize vector.
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if magnitude > 0 {
            vector = vector.map { $0 / magnitude }
        }

        return VectorEmbedding(vector: vector, model: "sam-rag-embeddings-hashbased-fallback")
    }

    private func generateBigrams(from words: [String]) -> [String] {
        guard words.count >= 2 else { return [] }
        return (0..<words.count-1).map { i in
            "\(words[i]) \(words[i+1])"
        }
    }

    private func generateTrigrams(from words: [String]) -> [String] {
        guard words.count >= 3 else { return [] }
        return (0..<words.count-2).map { i in
            "\(words[i]) \(words[i+1]) \(words[i+2])"
        }
    }
}
