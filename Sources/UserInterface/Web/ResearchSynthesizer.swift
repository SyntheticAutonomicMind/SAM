// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConversationEngine
import Logging
public class ResearchSynthesizer {
    private let vectorRAGService: VectorRAGService
    private let logger = Logger(label: "com.sam.web.ResearchSynthesis")

    public init(vectorRAGService: VectorRAGService) {
        self.vectorRAGService = vectorRAGService
    }

    /// Synthesize multiple content sources into coherent insights.
    public func synthesizeContent(_ contents: [WebPageContent], topic: String, conversationId: UUID? = nil) async throws -> ResearchSynthesis {
        logger.debug("Synthesizing \(contents.count) sources for topic: '\(topic)' with conversationId: \(conversationId?.uuidString ?? "nil")")

        guard !contents.isEmpty else {
            throw WebResearchError.invalidConfiguration("No content provided for synthesis")
        }

        /// Step 1: Process all content through Vector RAG for semantic analysis.
        let ragDocuments = try await ingestContentIntoRAG(contents, conversationId: conversationId)

        /// Step 2: Identify key themes using semantic search.
        let keyThemes = try await identifyKeyThemes(ragDocuments, topic: topic)

        /// Step 3: Extract supporting evidence for each theme.
        let keyFindings = try await generateKeyFindings(from: keyThemes, documents: ragDocuments, originalTopic: topic)

        /// Step 4: Calculate synthesis confidence based on source diversity and agreement.
        let confidence = calculateSynthesisConfidence(keyFindings, sourceCount: contents.count)

        /// Step 5: Create research sources with credibility assessment.
        let researchSources = contents.map { content in
            ResearchSource(
                url: content.url,
                title: content.title,
                extractedAt: content.extractedAt,
                credibilityScore: assessSourceCredibility(content)
            )
        }

        let synthesis = ResearchSynthesis(
            topic: topic,
            keyFindings: keyFindings,
            sourceCount: contents.count,
            confidence: confidence,
            sources: researchSources
        )

        logger.debug("Synthesis complete: \(keyFindings.count) key findings, \(String(format: "%.1f", confidence * 100))% confidence")
        return synthesis
    }

    // MARK: - Helper Methods

    private func ingestContentIntoRAG(_ contents: [WebPageContent], conversationId: UUID?) async throws -> [RAGDocument] {
        /// WebResearchService.processContentThroughRAG() already ingests documents
        /// This method just creates RAGDocument instances for semantic search queries
        /// Duplicate ingestion would cause unnecessary processing and memory usage
        logger.debug("Creating RAGDocument instances for synthesis (already ingested in processContentThroughRAG)")

        var ragDocuments: [RAGDocument] = []

        for content in contents {
            let ragDoc = RAGDocument(
                id: UUID(),
                title: content.title,
                content: content.content,
                type: .web,
                conversationId: conversationId,
                metadata: [
                    "sourceURL": content.url.absoluteString,
                    "extractedAt": ISO8601DateFormatter().string(from: content.extractedAt),
                    "contentType": "web_research",
                    "summary": content.summary
                ]
            )

            /// NO INGESTION HERE - already done in WebResearchService.processContentThroughRAG()
            /// Just collect RAGDocument instances for semantic search queries
            ragDocuments.append(ragDoc)
        }

        return ragDocuments
    }

    private func identifyKeyThemes(_ documents: [RAGDocument], topic: String) async throws -> [ResearchTheme] {
        logger.debug("Identifying key themes for topic: '\(topic)'")

        /// Generate semantic queries to explore different aspects of the topic.
        let themeQueries = generateThemeQueries(for: topic)
        var themes: [ResearchTheme] = []

        for query in themeQueries {
            do {
                let results = try await vectorRAGService.semanticSearch(
                    query: query,
                    limit: 15,
                    similarityThreshold: 0.3
                )

                if !results.isEmpty {
                    let relevantDocuments = results.compactMap { result in
                        documents.first { $0.id == result.documentId }
                    }

                    let theme = ResearchTheme(
                        title: query,
                        relevantContent: results.map { $0.content },
                        sources: relevantDocuments,
                        strength: calculateThemeStrength(results, totalDocuments: documents.count),
                        query: query
                    )

                    themes.append(theme)
                }
            } catch {
                logger.warning("Theme query failed for '\(query)': \(error)")
            }
        }

        /// Sort themes by strength and return top themes.
        return themes.sorted { $0.strength > $1.strength }.prefix(8).map { $0 }
    }

    private func generateThemeQueries(for topic: String) -> [String] {
        /// Generate diverse queries to explore different aspects of the topic.
        let baseQueries = [
            topic,
            "\(topic) definition explanation",
            "\(topic) benefits advantages",
            "\(topic) challenges problems",
            "\(topic) future trends",
            "\(topic) current state",
            "\(topic) key features",
            "\(topic) applications uses"
        ]

        /// Add topic-specific queries based on common patterns.
        var enhancedQueries = baseQueries

        if topic.lowercased().contains("technology") || topic.lowercased().contains("ai") {
            enhancedQueries.append(contentsOf: [
                "\(topic) implementation",
                "\(topic) technical specifications",
                "\(topic) performance metrics"
            ])
        }

        if topic.lowercased().contains("market") || topic.lowercased().contains("business") {
            enhancedQueries.append(contentsOf: [
                "\(topic) market analysis",
                "\(topic) industry impact",
                "\(topic) competitive landscape"
            ])
        }

        return enhancedQueries
    }

    private func calculateThemeStrength(_ results: [SemanticSearchResult], totalDocuments: Int) -> Double {
        guard !results.isEmpty && totalDocuments > 0 else { return 0.0 }

        /// Calculate strength based on: 1.
        let documentCoverage = Double(results.count) / Double(totalDocuments)

        /// 2.
        let averageSimilarity = results.map { $0.similarity }.reduce(0, +) / Double(results.count)

        /// 3.
        let uniqueSources = Set(results.map { $0.documentId }).count
        let sourceDiversity = Double(uniqueSources) / Double(results.count)

        /// Combine metrics with weighted average.
        return (documentCoverage * 0.4) + (averageSimilarity * 0.4) + (sourceDiversity * 0.2)
    }

    private func generateKeyFindings(from themes: [ResearchTheme], documents: [RAGDocument], originalTopic: String) async throws -> [KeyFinding] {
        var keyFindings: [KeyFinding] = []

        for theme in themes.prefix(6) {
            /// Generate a more specific query to extract key insights.
            let insightQuery = "key insights about \(theme.title) related to \(originalTopic)"

            do {
                let insightResults = try await vectorRAGService.semanticSearch(
                    query: insightQuery,
                    limit: 10,
                    similarityThreshold: 0.4
                )

                if !insightResults.isEmpty {
                    /// Extract evidence from the most relevant results.
                    let evidence = insightResults.prefix(5).map { result in
                        extractKeyEvidence(from: result.content, maxLength: 200)
                    }.filter { !$0.isEmpty }

                    /// Get supporting sources.
                    let supportingSources = insightResults.compactMap { result in
                        documents.first { $0.id == result.documentId }
                    }.map { (doc: RAGDocument) in
                        ResearchSource(
                            url: URL(string: (doc.metadata["sourceURL"] as? String) ?? "")!,
                            title: doc.title,
                            extractedAt: ISO8601DateFormatter().date(from: (doc.metadata["extractedAt"] as? String) ?? "") ?? Date(),
                            credibilityScore: 0.7
                        )
                    }

                    let finding = KeyFinding(
                        title: generateFindingTitle(from: theme.title),
                        summary: generateFindingSummary(from: evidence, theme: theme.title),
                        evidence: evidence,
                        confidence: calculateFindingConfidence(insightResults, themeStrength: theme.strength),
                        supportingSources: supportingSources
                    )

                    keyFindings.append(finding)
                }
            } catch {
                logger.warning("Failed to generate findings for theme '\(theme.title)': \(error)")
            }
        }

        return keyFindings.sorted { $0.confidence > $1.confidence }
    }

    private func extractKeyEvidence(from content: String, maxLength: Int) -> String {
        /// Extract meaningful sentences that could serve as evidence.
        let sentences = content.components(separatedBy: ". ")

        /// Find sentences that contain important keywords or are well-structured.
        let importantSentences = sentences.filter { sentence in
            let wordCount = sentence.components(separatedBy: .whitespaces).count
            return wordCount >= 5 && wordCount <= 30 &&
                   sentence.contains(where: { $0.isLetter }) &&
                   !sentence.lowercased().contains("click here") &&
                   !sentence.lowercased().contains("read more")
        }

        /// Select the first good sentence that fits within length limit.
        for sentence in importantSentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= maxLength && !trimmed.isEmpty {
                return trimmed + (trimmed.hasSuffix(".") ? "" : ".")
            }
        }

        /// Fallback: truncate the original content.
        return String(content.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func generateFindingTitle(from themeTitle: String) -> String {
        /// Convert query-like theme titles into proper finding titles.
        let title = themeTitle.lowercased()

        if title.contains("benefits") || title.contains("advantages") {
            return "Key Benefits and Advantages"
        } else if title.contains("challenges") || title.contains("problems") {
            return "Major Challenges and Limitations"
        } else if title.contains("future") || title.contains("trends") {
            return "Future Outlook and Emerging Trends"
        } else if title.contains("current") || title.contains("state") {
            return "Current State and Recent Developments"
        } else if title.contains("definition") || title.contains("explanation") {
            return "Core Concepts and Definitions"
        } else if title.contains("applications") || title.contains("uses") {
            return "Practical Applications and Use Cases"
        } else if title.contains("features") {
            return "Key Features and Characteristics"
        } else {
            /// Clean up the original title.
            return themeTitle.capitalized
                             .replacingOccurrences(of: " definition explanation", with: "")
                             .replacingOccurrences(of: " benefits advantages", with: "")
                             .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func generateFindingSummary(from evidence: [String], theme: String) -> String {
        guard !evidence.isEmpty else {
            return "No specific evidence found for this theme."
        }

        /// Create a concise summary from the evidence.
        if evidence.count == 1 {
            return evidence.first!
        }

        /// For multiple pieces of evidence, create a synthesized summary.
        let combinedLength = evidence.joined().count

        if combinedLength <= 300 {
            return evidence.joined(separator: " ")
        } else {
            /// Take key points from each piece of evidence.
            let keyPoints = evidence.map { evidence in
                String(evidence.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return keyPoints.joined(separator: ". ") + "."
        }
    }

    private func calculateFindingConfidence(_ searchResults: [SemanticSearchResult], themeStrength: Double) -> Double {
        guard !searchResults.isEmpty else { return 0.0 }

        /// Base confidence on semantic similarity and theme strength.
        let averageSimilarity = searchResults.map { $0.similarity }.reduce(0, +) / Double(searchResults.count)
        let resultCount = min(Double(searchResults.count) / 10.0, 1.0)

        /// Combine metrics.
        let confidence = (averageSimilarity * 0.5) + (themeStrength * 0.3) + (resultCount * 0.2)

        return min(max(confidence, 0.0), 1.0)
    }

    private func calculateSynthesisConfidence(_ findings: [KeyFinding], sourceCount: Int) -> Double {
        guard !findings.isEmpty && sourceCount > 0 else { return 0.0 }

        /// Calculate based on: 1.
        let averageFindingConfidence = findings.map { $0.confidence }.reduce(0, +) / Double(findings.count)

        /// 2.
        let sourceDiversityBonus = min(Double(sourceCount) / 10.0, 1.0) * 0.2

        /// 3.
        let findingCountBonus = min(Double(findings.count) / 6.0, 1.0) * 0.1

        let confidence = (averageFindingConfidence * 0.7) + sourceDiversityBonus + findingCountBonus

        return min(max(confidence, 0.0), 1.0)
    }

    private func assessSourceCredibility(_ content: WebPageContent) -> Double {
        var score = 0.5

        guard let host = content.url.host?.lowercased() else {
            return score
        }

        /// Increase score for trusted domains.
        let trustedDomains = [
            ".edu", ".gov", ".org",
            "wikipedia.org", "britannica.com",
            "reuters.com", "bbc.com", "npr.org",
            "nature.com", "science.org", "ieee.org"
        ]

        for domain in trustedDomains {
            if host.contains(domain) {
                score += 0.3
                break
            }
        }

        /// Increase score for HTTPS.
        if content.url.scheme == "https" {
            score += 0.1
        }

        /// Increase score for comprehensive content.
        if content.content.count > 2000 {
            score += 0.1
        }

        /// Increase score if content has good metadata.
        if !content.metadata.isEmpty {
            score += 0.1
        }

        /// Decrease score for very recent content (may be unverified).
        let hoursSinceExtraction = Date().timeIntervalSince(content.extractedAt) / 3600
        if hoursSinceExtraction < 2 {
            score -= 0.1
        }

        return min(max(score, 0.0), 1.0)
    }
}

// MARK: - Supporting Models

/// Research theme identified through semantic analysis.
public struct ResearchTheme {
    let title: String
    let relevantContent: [String]
    let sources: [RAGDocument]
    let strength: Double
    let query: String

    public init(title: String, relevantContent: [String], sources: [RAGDocument], strength: Double, query: String) {
        self.title = title
        self.relevantContent = relevantContent
        self.sources = sources
        self.strength = strength
        self.query = query
    }
}
