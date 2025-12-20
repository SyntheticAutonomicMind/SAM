// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// AppleNLEmbeddingGenerator.swift SAM Apple NLEmbedding-based semantic embedding generator Uses Apple's NaturalLanguage framework for offline, native embedding generation Created: October 15, 2025 Purpose: Replace hash-based mock embeddings with real semantic understanding.

import Foundation
@preconcurrency import NaturalLanguage
import Logging

/// Apple NLEmbedding-based embedding generator for semantic similarity Uses Apple's NaturalLanguage framework sentence embeddings (512 dimensions) for high-quality semantic search without requiring external APIs **THREAD-SAFETY**: - Wrapped as actor to serialize access per instance - CRITICAL: Uses global serial DispatchQueue to prevent system-wide concurrent access - Apple's NLEmbedding/CoreNLP/BNNS is NOT thread-safe at system level - Multiple concurrent vector() calls crash in libBNNS.dylib with SIGSEGV.
public actor AppleNLEmbeddingGenerator {
    /// Global serial queue for ALL NLEmbedding operations system-wide Apple's CoreNLP/BNNS library crashes with concurrent access even across different instances.
    private static let globalEmbeddingQueue = DispatchQueue(label: "com.sam.embeddings.global.serial")

    private let logger = Logger(label: "com.sam.embeddings.apple")
    private let sentenceEmbedding: NLEmbedding
    public let dimension: Int

    /// Initialize with Apple's sentence embedding model - Throws: EmbeddingError if sentence embedding not available.
    public init() throws {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbeddingError.sentenceEmbeddingNotAvailable
        }

        self.sentenceEmbedding = embedding
        self.dimension = embedding.dimension
        logger.debug("SUCCESS: Initialized Apple NLEmbedding (dimension: \(dimension), revision: \(embedding.revision))")
    }

    /// Generate semantic embedding for text using Apple's sentence embedding Returns 512-dimensional vector that captures semantic meaning - Parameter text: Text to generate embedding for (sentence, paragraph, or document chunk) - Returns: VectorEmbedding with semantic representation - Throws: EmbeddingError if vector generation fails.
    public func generateEmbedding(for text: String) async throws -> VectorEmbedding {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            /// Return zero vector for empty text.
            logger.debug("Generating zero vector for empty text")
            return VectorEmbedding(
                vector: Array(repeating: 0.0, count: dimension),
                model: "apple-nlembedding-sentence-v\(sentenceEmbedding.revision)"
            )
        }

        /// Defensive check - NLEmbedding crashes with very long text Apple's BNNS library has internal limits, truncate to safe length.
        let maxLength = 2000
        let safeText: String
        if cleanText.count > maxLength {
            safeText = String(cleanText.prefix(maxLength))
            logger.warning("Truncating text from \(cleanText.count) to \(maxLength) chars for embedding safety")
        } else {
            safeText = cleanText
        }

        /// Serialize access to NLEmbedding.vector() - NOT thread-safe AT SYSTEM LEVEL Even with actor isolation, Apple's CoreNLP/BNNS crashes with concurrent access Use global serial queue to prevent ANY concurrent vector generation across entire process.

        /// Store local reference for closure (avoid self capture issues).
        let embedding = sentenceEmbedding
        let embeddingLogger = logger

        return try await withCheckedThrowingContinuation { continuation in
            Self.globalEmbeddingQueue.async {
                guard let vector = embedding.vector(for: safeText) else {
                    embeddingLogger.warning("Failed to generate embedding for text: \(safeText.prefix(50))...")
                    continuation.resume(throwing: EmbeddingError.vectorGenerationFailed)
                    return
                }

                embeddingLogger.debug("Generated \(vector.count)-dimensional embedding for text (\(safeText.count) chars)")

                let result = VectorEmbedding(
                    vector: vector,
                    model: "apple-nlembedding-sentence-v\(embedding.revision)"
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Calculate semantic similarity between two texts (0.0 = different, 1.0 = identical) - Parameters: - text1: First text to compare - text2: Second text to compare - Returns: Similarity score in range [0.0, 1.0].
    public func calculateSimilarity(text1: String, text2: String) -> Double {
        let distance = sentenceEmbedding.distance(between: text1, and: text2)
        return convertDistanceToSimilarity(distance)
    }

    /// Convert NLEmbedding distance to cosine similarity score NLEmbedding uses Euclidean distance on normalized vectors Formula: cosine_similarity = 1 - (euclidean_distance^2 / 2) - Parameter nlDistance: Distance from NLEmbedding.distance() - Returns: Cosine similarity in range [0.0, 1.0].
    private func convertDistanceToSimilarity(_ nlDistance: Double) -> Double {
        /// NLEmbedding distance is Euclidean on normalized vectors Convert to cosine similarity: similarity = 1 - (distance^2 / 2).
        let euclideanSquared = nlDistance * nlDistance
        let cosineSimilarity = 1.0 - (euclideanSquared / 2.0)

        /// Clamp to [0, 1] range for safety.
        return max(0.0, min(1.0, cosineSimilarity))
    }

    /// Calculate cosine similarity between two pre-computed embedding vectors - Parameters: - vector1: First embedding vector - vector2: Second embedding vector - Returns: Cosine similarity in range [0.0, 1.0].
    public func calculateVectorSimilarity(vector1: [Double], vector2: [Double]) -> Double {
        guard vector1.count == vector2.count else {
            logger.warning("Vector dimension mismatch: \(vector1.count) vs \(vector2.count)")
            return 0.0
        }

        /// Calculate dot product.
        var dotProduct = 0.0
        for i in 0..<vector1.count {
            dotProduct += vector1[i] * vector2[i]
        }

        /// Calculate magnitudes.
        let magnitude1 = sqrt(vector1.reduce(0) { $0 + $1 * $1 })
        let magnitude2 = sqrt(vector2.reduce(0) { $0 + $1 * $1 })

        guard magnitude1 > 0 && magnitude2 > 0 else {
            logger.warning("Zero magnitude vector detected")
            return 0.0
        }

        /// Cosine similarity.
        let cosineSimilarity = dotProduct / (magnitude1 * magnitude2)

        /// Clamp to [0, 1] range (vectors should be normalized, but be safe).
        return max(0.0, min(1.0, cosineSimilarity))
    }
}

// MARK: - Error Types

public enum EmbeddingError: LocalizedError {
    case sentenceEmbeddingNotAvailable
    case vectorGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .sentenceEmbeddingNotAvailable:
            return "Apple NLEmbedding sentence embedding not available for English. This feature requires macOS 12.0 or later."

        case .vectorGenerationFailed:
            return "Failed to generate embedding vector from text. The text may contain unsupported characters or be too long."
        }
    }
}
