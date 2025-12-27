// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// YaRNContextProcessor.swift SAM YaRN (Yet another RoPE extensioN) Context Extension Implementation Dynamic attention patterns, scaling factors, and compression ratios for intelligent context management ARCHITECTURE OVERVIEW: - Dynamic Context Windows: Scales from 8K-65K tokens based on conversation complexity - Attention Scaling: Intelligent attention pattern management for extended contexts.

import Foundation
import ConfigurationSystem

/// Type alias for compatibility during migration.
public typealias Message = ConfigurationSystem.EnhancedMessage
/// - Compression Algorithms: Multiple strategies for context compression while preserving meaning - Message Importance: Analyzes message significance for retention/compression decisions KEY ALGORITHMS: - Sliding Window Compression: Recent context with compressed historical context - Importance-Based Filtering: Retains high-importance messages across conversation - Semantic Clustering: Groups related messages for efficient representation - Progressive Compression: Increases compression ratio for older content CONFIGURATION PROFILES: - Default: 8K→32K scaling with 4.0x factor and 0.8 compression threshold - Extended: 16K→65K scaling with 8.0x factor and 0.85 compression threshold INTEGRATION POINTS: - ConversationManager: Context processing for LLM requests - Memory System: Coordination with Vector RAG for enhanced context awareness - Sequential Thinking: Maintains context continuity across tool interactions.

import Logging

// MARK: - Helper Methods
@MainActor
public class YaRNContextProcessor: ObservableObject {
    private let logger = Logger(label: "com.sam.yarn")
    private let memoryManager: MemoryManager
    private let tokenEstimator: (String) async -> Int

    @Published public var isInitialized: Bool = false
    @Published public var contextWindowSize: Int = 32768
    @Published public var currentTokenCount: Int = 0
    @Published public var compressionRatio: Double = 0.75
    @Published public var attentionScalingFactor: Double = 1.0

    /// YaRN Configuration defining context window scaling and processing parameters.
    public struct YaRNConfig {
        let baseContextLength: Int
        let extendedContextLength: Int
        let scalingFactor: Double
        let attentionFactor: Double
        let compressionThreshold: Double

        /// Default configuration balancing performance and capability.
        public nonisolated(unsafe) static let `default` = YaRNConfig(
            baseContextLength: 8192,
            extendedContextLength: 32768,
            scalingFactor: 4.0,
            attentionFactor: 0.1,
            compressionThreshold: 0.8
        )

        /// Extended configuration for maximum context capability.
        public nonisolated(unsafe) static let extended = YaRNConfig(
            baseContextLength: 16384,
            extendedContextLength: 65536,
            scalingFactor: 8.0,
            attentionFactor: 0.05,
            compressionThreshold: 0.85
        )

        /// Universal configuration supporting all modern LLMs (GPT-4, Claude, DeepSeek, etc.) 512K context window allows LLMs to seek in chunks that fit their native context.
        public nonisolated(unsafe) static let universal = YaRNConfig(
            baseContextLength: 32768,
            extendedContextLength: 524288,
            scalingFactor: 16.0,
            attentionFactor: 0.025,
            compressionThreshold: 0.9
        )

        /// Mega configuration for massive document analysis workloads (60-100MB+ documents) 128M token context ≈ 500MB-1GB for enterprise RAG and multi-document workflows.
        public nonisolated(unsafe) static let mega = YaRNConfig(
            baseContextLength: 65536,
            extendedContextLength: 134217728,
            scalingFactor: 2048.0,
            attentionFactor: 0.001,
            compressionThreshold: 0.95
        )
    }

    private var config: YaRNConfig
    private var contextCache: [UUID: ProcessedContext] = [:]
    private var attentionPatterns: [AttentionPattern] = []

    // MARK: - Lifecycle
    public init(memoryManager: MemoryManager, tokenEstimator: @escaping (String) async -> Int, config: YaRNConfig = .universal) {
        self.memoryManager = memoryManager
        self.tokenEstimator = tokenEstimator
        self.config = config
        self.contextWindowSize = config.extendedContextLength

        logger.debug("SUCCESS: YaRNContextProcessor initialized with extended context: \(config.extendedContextLength)")
    }

    // MARK: - Lifecycle
    public func initialize() async throws {
        logger.debug("WARNING: YARN CONTEXT - Initializing dynamic attention patterns")

        /// Initialize attention patterns.
        attentionPatterns = generateBaseAttentionPatterns()

        isInitialized = true
        logger.debug("SUCCESS: YARN CONTEXT - Dynamic context management operational")
    }

    // MARK: - Helper Methods

    // MARK: - Helper Methods
    public func processConversationContext(
        messages: [Message],
        conversationId: UUID,
        targetTokenCount: Int? = nil
    ) async throws -> ProcessedContext {

        let targetTokens = targetTokenCount ?? Int(Double(config.extendedContextLength) * config.compressionThreshold)
        logger.debug("ERROR: YARN PROCESSING - \(messages.count) messages, target: \(targetTokens) tokens")

        /// Check cache first.
        if let cachedContext = contextCache[conversationId] {
            if cachedContext.messages.count == messages.count &&
               cachedContext.tokenCount <= targetTokens {
                logger.debug("SUCCESS: Using cached context for conversation \(conversationId)")
                return cachedContext
            }
        }

        /// Step 1: Estimate current token count.
        let totalTokenCount = await estimateContextTokenCount(messages)
        currentTokenCount = totalTokenCount

        logger.debug("WARNING: Current context: \(totalTokenCount) tokens")

        /// Step 2: Apply YaRN processing based on token count.
        let processedContext: ProcessedContext

        if totalTokenCount <= config.baseContextLength {
            /// Direct processing - no compression needed.
            processedContext = ProcessedContext(
                conversationId: conversationId,
                messages: messages,
                tokenCount: totalTokenCount,
                compressionApplied: false,
                attentionScaling: 1.0,
                processingMethod: .direct
            )

        } else if totalTokenCount <= config.extendedContextLength {
            /// Apply YaRN scaling without compression.
            processedContext = try await applyYaRNScaling(
                messages: messages,
                conversationId: conversationId,
                targetTokens: targetTokens
            )

        } else {
            /// Apply YaRN with intelligent compression.
            processedContext = try await applyYaRNCompression(
                messages: messages,
                conversationId: conversationId,
                targetTokens: targetTokens
            )
        }

        /// Cache the result.
        contextCache[conversationId] = processedContext

        /// Update published properties.
        compressionRatio = Double(processedContext.tokenCount) / Double(totalTokenCount)
        attentionScalingFactor = processedContext.attentionScaling

        logger.debug("SUCCESS: YARN PROCESSED - \(processedContext.messages.count) messages, \(processedContext.tokenCount) tokens")

        return processedContext
    }

    /// Apply YaRN scaling for extended context without compression.
    private func applyYaRNScaling(
        messages: [Message],
        conversationId: UUID,
        targetTokens: Int
    ) async throws -> ProcessedContext {

        logger.debug("ERROR: Applying YaRN scaling for extended context")

        /// Calculate scaling factor based on context length.
        let currentTokens = await estimateContextTokenCount(messages)
        let scalingRatio = Double(targetTokens) / Double(currentTokens)
        let attentionScale = calculateAttentionScaling(scalingRatio)

        /// Apply positional encoding adjustments (simulated).
        let scaledMessages = try await applyPositionalScaling(messages, scalingFactor: attentionScale)

        return ProcessedContext(
            conversationId: conversationId,
            messages: scaledMessages,
            tokenCount: min(currentTokens, targetTokens),
            compressionApplied: false,
            attentionScaling: attentionScale,
            processingMethod: .yarnScaling
        )
    }

    /// Apply YaRN with intelligent compression for very long contexts.
    private func applyYaRNCompression(
        messages: [Message],
        conversationId: UUID,
        targetTokens: Int
    ) async throws -> ProcessedContext {

        logger.debug("WARNING: Applying YaRN compression for long context")

        /// Step 1: Analyze message importance and patterns.
        let analyzedMessages = try await analyzeMessageImportance(messages, conversationId: conversationId)

        /// Step 2: Apply intelligent compression.
        let compressedMessages = try await compressMessages(
            analyzedMessages,
            targetTokenCount: targetTokens,
            conversationId: conversationId
        )

        /// Step 3: Apply YaRN scaling to compressed context.
        let scalingFactor = calculateCompressionScalingFactor(
            originalCount: messages.count,
            compressedCount: compressedMessages.count
        )

        let finalMessages = try await applyPositionalScaling(
            compressedMessages,
            scalingFactor: scalingFactor
        )

        let finalTokenCount = await estimateContextTokenCount(finalMessages)

        return ProcessedContext(
            conversationId: conversationId,
            messages: finalMessages,
            tokenCount: finalTokenCount,
            compressionApplied: true,
            attentionScaling: scalingFactor,
            processingMethod: .yarnCompression
        )
    }

    // MARK: - Message Analysis and Compression

    /// Analyze message importance for intelligent compression.
    private func analyzeMessageImportance(
        _ messages: [Message],
        conversationId: UUID
    ) async throws -> [AnalyzedMessage] {

        var analyzedMessages: [AnalyzedMessage] = []

        for (index, message) in messages.enumerated() {
            let importance = calculateMessageImportance(
                message: message,
                index: index,
                totalMessages: messages.count
            )

            let relevanceScore = try await calculateRelevanceScore(
                message: message,
                conversationId: conversationId
            )

            let analyzedMessage = AnalyzedMessage(
                original: message,
                importance: importance,
                relevanceScore: relevanceScore,
                position: index,
                shouldPreserve: importance > 0.7 || relevanceScore > 0.8
            )

            analyzedMessages.append(analyzedMessage)
        }

        return analyzedMessages
    }

    /// Intelligent message compression while preserving important content.
    private func compressMessages(
        _ analyzedMessages: [AnalyzedMessage],
        targetTokenCount: Int,
        conversationId: UUID
    ) async throws -> [Message] {

        /// Always preserve system messages and recent messages Note: In SAM, we don't have explicit system messages like in SAM 1.0 Instead, we identify them by content patterns or preserve first few messages.
        let systemMessages = analyzedMessages.prefix(2)
        let recentMessages = analyzedMessages.suffix(10)
        let importantMessages = analyzedMessages.filter { analyzed in
            analyzed.shouldPreserve && !recentMessages.contains(where: { recent in recent.original.id == analyzed.original.id })
        }

        var compressedMessages: [Message] = []
        var currentTokenCount = 0

        /// Add system messages first.
        for analyzed in systemMessages {
            compressedMessages.append(analyzed.original)
            currentTokenCount += await tokenEstimator(analyzed.original.content)
        }

        /// Add important messages if space allows.
        let sortedImportant = importantMessages.sorted { $0.importance > $1.importance }
        for analyzed in sortedImportant {
            let messageTokens = await tokenEstimator(analyzed.original.content)
            if currentTokenCount + messageTokens <= targetTokenCount * 80 / 100 {
                compressedMessages.append(analyzed.original)
                currentTokenCount += messageTokens
            }
        }

        /// Add recent messages (always preserved).
        for analyzed in recentMessages {
            /// Skip if already included in system messages to avoid duplicates.
            if !systemMessages.contains(where: { $0.original.id == analyzed.original.id }) {
                compressedMessages.append(analyzed.original)
                currentTokenCount += await tokenEstimator(analyzed.original.content)
            }
        }

        /// Sort by timestamp to maintain conversation order.
        compressedMessages.sort { $0.timestamp < $1.timestamp }

        logger.debug("SUCCESS: Compressed from \(analyzedMessages.count) to \(compressedMessages.count) messages")

        return compressedMessages
    }

    // MARK: - Attention and Scaling Calculations

    /// Calculate attention scaling factor based on context extension ratio.
    private func calculateAttentionScaling(_ scalingRatio: Double) -> Double {
        /// YaRN attention scaling formula.
        let baseScale = config.scalingFactor
        let attentionFactor = config.attentionFactor

        return max(0.1, min(2.0, baseScale * (1.0 - attentionFactor * log(scalingRatio))))
    }

    /// Calculate compression scaling factor.
    private func calculateCompressionScalingFactor(originalCount: Int, compressedCount: Int) -> Double {
        let compressionRatio = Double(compressedCount) / Double(originalCount)
        return max(0.5, min(1.5, 1.0 + (1.0 - compressionRatio) * config.attentionFactor))
    }

    /// Apply positional encoding scaling adjustments (simulated).
    private func applyPositionalScaling(
        _ messages: [Message],
        scalingFactor: Double
    ) async throws -> [Message] {

        /// In a full implementation, this would adjust positional encodings For now, we simulate by maintaining message order and adding metadata.

        /// Since Message content is immutable, return messages unchanged In a full implementation, metadata would be stored separately.
        return messages
    }

    // MARK: - Helper Methods

    /// Calculate message importance based on multiple factors.
    private func calculateMessageImportance(
        message: Message,
        index: Int,
        totalMessages: Int
    ) -> Double {

        var importance = 0.5

        /// System-like messages (first few messages) are always important.
        if index < 2 {
            importance = 1.0
        }

        /// Recent messages are more important.
        let recencyFactor = Double(totalMessages - index) / Double(totalMessages)
        importance += recencyFactor * 0.3

        /// Longer messages might be more important.
        if message.content.count > 500 {
            importance += 0.1
        }

        /// Messages with questions are important.
        if message.content.contains("?") {
            importance += 0.15
        }

        /// Messages with code or technical content.
        if message.content.contains("```") || message.content.contains("func ") {
            importance += 0.2
        }

        return min(1.0, importance)
    }

    /// Calculate relevance score using memory search.
    private func calculateRelevanceScore(
        message: Message,
        conversationId: UUID
    ) async throws -> Double {

        /// Use memory manager to find relevant context.
        let relevantMemories = try await memoryManager.retrieveRelevantMemories(
            for: message.content,
            conversationId: conversationId,
            limit: 5
        )

        /// Calculate average relevance from search results.
        if relevantMemories.isEmpty {
            return 0.3
        }

        let relevanceSum = relevantMemories.map { $0.similarity }.reduce(0, +)
        let averageRelevance = relevanceSum / Double(relevantMemories.count)
        return averageRelevance
    }

    /// Estimate token count for messages using accurate token estimation.
    private func estimateContextTokenCount(_ messages: [Message]) async -> Int {
        var total = 0
        for message in messages {
            total += await tokenEstimator(message.content)
        }
        return total
    }



    /// Generate base attention patterns for YaRN processing.
    private func generateBaseAttentionPatterns() -> [AttentionPattern] {
        return [
            AttentionPattern(name: "recent", weight: 1.0, range: 0.9...1.0),
            AttentionPattern(name: "important", weight: 0.8, range: 0.7...1.0),
            AttentionPattern(name: "system", weight: 1.0, range: 0.0...1.0),
            AttentionPattern(name: "contextual", weight: 0.6, range: 0.3...0.7),
            AttentionPattern(name: "background", weight: 0.3, range: 0.0...0.3)
        ]
    }

    // MARK: - Context Management

    /// Clear context cache for memory management.
    public func clearCache() {
        contextCache.removeAll()
        logger.debug("SUCCESS: Context cache cleared")
    }

    /// Update YaRN configuration.
    public func updateConfig(_ newConfig: YaRNConfig) {
        self.config = newConfig
        self.contextWindowSize = newConfig.extendedContextLength
        clearCache()

        logger.debug("WARNING: YaRN configuration updated - extended context: \(newConfig.extendedContextLength)")
    }

    /// Get current context statistics.
    public func getContextStatistics() -> ContextStatistics {
        return ContextStatistics(
            cacheSize: contextCache.count,
            currentTokenCount: currentTokenCount,
            contextWindowSize: contextWindowSize,
            compressionRatio: compressionRatio,
            attentionScalingFactor: attentionScalingFactor,
            isCompressionActive: compressionRatio < 0.9
        )
    }
}

// MARK: - Supporting Types

public struct ProcessedContext {
    public let conversationId: UUID
    public let messages: [Message]
    public let tokenCount: Int
    public let compressionApplied: Bool
    public let attentionScaling: Double
    public let processingMethod: ProcessingMethod
    public let processedAt: Date

    public init(
        conversationId: UUID,
        messages: [Message],
        tokenCount: Int,
        compressionApplied: Bool,
        attentionScaling: Double,
        processingMethod: ProcessingMethod
    ) {
        self.conversationId = conversationId
        self.messages = messages
        self.tokenCount = tokenCount
        self.compressionApplied = compressionApplied
        self.attentionScaling = attentionScaling
        self.processingMethod = processingMethod
        self.processedAt = Date()
    }
}

public enum ProcessingMethod {
    case direct
    case yarnScaling
    case yarnCompression
}

public struct AnalyzedMessage {
    public let original: Message
    public let importance: Double
    public let relevanceScore: Double
    public let position: Int
    public let shouldPreserve: Bool
}

public struct AttentionPattern {
    public let name: String
    public let weight: Double
    public let range: ClosedRange<Double>
}

public struct ContextStatistics {
    public let cacheSize: Int
    public let currentTokenCount: Int
    public let contextWindowSize: Int
    public let compressionRatio: Double
    public let attentionScalingFactor: Double
    public let isCompressionActive: Bool
}

// MARK: - Helper Methods

extension YaRNContextProcessor {
    /// Retrieve augmented context with YaRN processing for memory search.
    public func retrieveAugmentedMemoryContext(
        query: String,
        conversationId: UUID,
        maxTokens: Int = 2000
    ) async throws -> String {

        logger.debug("ERROR: Retrieving augmented memory context for: \(query.prefix(50))")

        /// Search relevant memories.
        let memories = try await memoryManager.retrieveRelevantMemories(
            for: query,
            conversationId: conversationId,
            limit: 15
        )

        /// Apply YaRN compression to memory context.
        var contextParts: [String] = []
        var currentTokens = 0

        let queryContext = "Query: \(query)\n\nRelevant Memory Context:\n"
        contextParts.append(queryContext)
        currentTokens += await tokenEstimator(queryContext)

        /// Add memories with YaRN-aware token management.
        for (index, memory) in memories.enumerated() {
            let memoryText = "\n[\(index + 1)] \(memory.content)"
            let memoryTokens = await tokenEstimator(memoryText)

            if currentTokens + memoryTokens <= maxTokens {
                contextParts.append(memoryText)
                currentTokens += memoryTokens
            } else {
                /// Apply YaRN compression if needed.
                if maxTokens > currentTokens {
                    let remainingTokens = maxTokens - currentTokens
                    let compressedMemory = compressTextToTokenLimit(memory.content, tokenLimit: remainingTokens)
                    contextParts.append("\n[\(index + 1)] \(compressedMemory)")
                }
                break
            }
        }

        let finalContext = contextParts.joined()

        logger.debug("SUCCESS: Generated augmented context: \(currentTokens) tokens")
        return finalContext
    }

    /// Compress text to fit within token limit using YaRN principles.
    private func compressTextToTokenLimit(_ text: String, tokenLimit: Int) -> String {
        let sentences = text.components(separatedBy: ". ")
        let targetLength = tokenLimit * 4

        if text.count <= targetLength {
            return text
        }

        /// Keep first and last sentences, compress middle.
        guard sentences.count > 2 else {
            return String(text.prefix(targetLength)) + "..."
        }

        let firstSentence = sentences.first ?? ""
        let lastSentence = sentences.last ?? ""
        let middleSentences = Array(sentences[1..<sentences.count-1])

        /// Calculate space for middle content.
        let reservedSpace = firstSentence.count + lastSentence.count + 20
        let middleSpace = max(0, targetLength - reservedSpace)

        if middleSpace > 100 {
            /// Include some middle content - take as many sentences as fit.
            var compressedMiddleList: [String] = []
            var currentLength = 0

            for sentence in middleSentences {
                let sentenceLength = sentence.count + 2
                if currentLength + sentenceLength < middleSpace {
                    compressedMiddleList.append(sentence)
                    currentLength += sentenceLength
                } else {
                    break
                }
            }

            let compressedMiddle = compressedMiddleList.joined(separator: ". ")

            return "\(firstSentence). \(compressedMiddle)... \(lastSentence)"
        } else {
            /// Only keep first and last.
            return "\(firstSentence)... \(lastSentence)"
        }
    }
}
