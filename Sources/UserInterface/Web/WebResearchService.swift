// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConversationEngine

/// Core web research service providing comprehensive web information capabilities Integrates multi-source search engines, content extraction, and Vector RAG analysis.
@MainActor
public class WebResearchService: ObservableObject, @unchecked Sendable {
    // MARK: - Published Properties
    @Published public var isResearching: Bool = false
    @Published public var researchProgress: Double = 0.0
    @Published public var currentOperation: String = ""

    // MARK: - Dependencies
    private let vectorRAGService: VectorRAGService
    private let conversationManager: ConversationManager
    private let logger = Logger(label: "com.sam.web.research")

    // MARK: - Core Components
    private let searchProviders: [SearchProvider]
    nonisolated(unsafe) private let contentExtractor: WebContentExtractor
    nonisolated(unsafe) private let researchSynthesizer: ResearchSynthesizer
    private let rateLimiter: RateLimiter

    // MARK: - Lifecycle
    public init(vectorRAGService: VectorRAGService, conversationManager: ConversationManager) {
        self.vectorRAGService = vectorRAGService
        self.conversationManager = conversationManager

        /// Initialize search providers with configuration.
        self.searchProviders = [
            GoogleSearchProvider(),
            BingSearchProvider(),
            DuckDuckGoSearchProvider()
        ]

        self.contentExtractor = WebContentExtractor()
        self.researchSynthesizer = ResearchSynthesizer(vectorRAGService: vectorRAGService)
        self.rateLimiter = RateLimiter()

        logger.debug("WebResearchService initialized with \(self.searchProviders.count) search providers")
    }

    // MARK: - Public API

    /// Conduct comprehensive research on a topic using multiple sources.
    public func conductResearch(on topic: String, depth: ResearchDepth = .standard, conversationId: UUID? = nil) async throws -> ResearchReport {
        logger.debug("Starting research on topic: '\(topic)' with depth: \(depth.rawValue)")

        await updateResearchStatus(isResearching: true, operation: "Initializing research", progress: 0.0)

        do {
            /// Step 1: Multi-source search.
            await updateResearchStatus(operation: "Searching multiple sources", progress: 0.1)
            let searchResults = try await performMultiSourceSearch(topic: topic, depth: depth)

            /// Step 2: Content extraction and analysis.
            await updateResearchStatus(operation: "Extracting and analyzing content", progress: 0.3)
            let extractedContent = try await extractContentFromResults(searchResults)
            logger.debug("Content extraction completed: \(extractedContent.count) pages")

            /// Step 3: Optional Vector RAG processing (only if conversationId available).
            let processedContent: [WebPageContent]
            if let conversationId = conversationId {
                await updateResearchStatus(operation: "Processing content semantically", progress: 0.6)
                processedContent = try await processContentThroughRAG(extractedContent, conversationId: conversationId)
            } else {
                logger.debug("Skipping RAG processing - no conversationId provided")
                processedContent = extractedContent
            }

            /// Step 4: Synthesis and report generation.
            await updateResearchStatus(operation: "Synthesizing findings", progress: 0.8)
            let contentToSynthesize = processedContent  /// Capture before async
            let synthesis = try await researchSynthesizer.synthesizeContent(contentToSynthesize, topic: topic, conversationId: conversationId)

            /// Step 5: Generate comprehensive report.
            await updateResearchStatus(operation: "Finalizing report", progress: 0.95)
            let report = ResearchReport(
                topic: topic,
                searchResults: searchResults,
                extractedContent: processedContent,  /// Use processedContent (successful sources) instead of extractedContent
                synthesis: synthesis,
                sources: processedContent.map { ResearchSource(url: $0.url, title: $0.title, extractedAt: $0.extractedAt) },
                conductedAt: Date(),
                researchDepth: depth
            )

            await updateResearchStatus(isResearching: false, operation: "Research complete", progress: 1.0)
            logger.debug("Research completed: \(searchResults.count) sources, \(processedContent.count) pages analyzed")

            return report

        } catch {
            await updateResearchStatus(isResearching: false, operation: "Research failed", progress: 0.0)
            logger.error("Research failed for topic '\(topic)': \(error)")
            throw error
        }
    }

    /// Perform a simple web search returning raw search results without synthesis.
    public func performSimpleSearch(query: String, maxResults: Int = 10) async throws -> [SearchResult] {
        logger.debug("Performing simple search for: '\(query)'")

        let searchResults = try await performMultiSourceSearch(topic: query, depth: .shallow)

        /// Limit results to maxResults and return.
        return Array(searchResults.prefix(maxResults))
    }

    /// Research current events and news for time-sensitive information.
    public func researchCurrentEvents(topic: String) async throws -> NewsResearchReport {
        logger.debug("Starting news research for: '\(topic)'")

        await updateResearchStatus(isResearching: true, operation: "Searching news sources", progress: 0.0)

        var newsResults: [NewsResult] = []

        /// Create news options once for Sendable safety
        let newsOptions = NewsSearchOptions(
            maxResults: 20,
            timeRange: .last7Days,
            language: .english,
            sortBy: .relevance
        )

        /// Search news across all available providers.
        for provider in searchProviders.filter(\.isAvailable) {
            do {
                let results = try await provider.searchNews(
                    query: topic,
                    options: newsOptions
                )
                newsResults.append(contentsOf: results)
            } catch {
                logger.warning("News search failed for provider \(provider.name): \(error)")
            }
        }

        await updateResearchStatus(operation: "Processing news content", progress: 0.5)
        let processedNews = try await processNewsContent(newsResults)

        await updateResearchStatus(operation: "Creating timeline", progress: 0.8)
        let timeline = createEventTimeline(from: processedNews)
        let keyDevelopments = extractKeyDevelopments(from: processedNews)

        let report = NewsResearchReport(
            topic: topic,
            newsResults: newsResults,
            timeline: timeline,
            keyDevelopments: keyDevelopments,
            sources: extractNewsSources(from: newsResults),
            conductedAt: Date()
        )

        await updateResearchStatus(isResearching: false, operation: "News research complete", progress: 1.0)
        return report
    }

    /// Research technical topics with focus on authoritative sources.
    public func researchTechnicalTopic(topic: String) async throws -> TechnicalResearchReport {
        logger.debug("Starting technical research for: '\(topic)'")

        await updateResearchStatus(isResearching: true, operation: "Searching technical sources", progress: 0.0)

        /// Focus on academic, documentation, and authoritative technical sources.
        let technicalResults = try await performTechnicalSearch(topic: topic)

        await updateResearchStatus(operation: "Analyzing technical content", progress: 0.4)
        let technicalContent = try await extractTechnicalContent(from: technicalResults)

        await updateResearchStatus(operation: "Generating technical analysis", progress: 0.7)
        let authorityScore = calculateAuthorityScore(technicalContent)
        let concepts = extractTechnicalConcepts(technicalContent)
        let documentation = extractDocumentationLinks(technicalContent)
        let relatedTopics = identifyRelatedTechnicalTopics(technicalContent)

        let report = TechnicalResearchReport(
            topic: topic,
            authorityScore: authorityScore,
            concepts: concepts,
            documentation: documentation,
            relatedTopics: relatedTopics,
            sources: technicalContent.map { ResearchSource(url: $0.url, title: $0.title, extractedAt: $0.extractedAt) },
            conductedAt: Date()
        )

        await updateResearchStatus(isResearching: false, operation: "Technical research complete", progress: 1.0)
        return report
    }

    // MARK: - Helper Methods

    private func updateResearchStatus(isResearching: Bool? = nil, operation: String? = nil, progress: Double? = nil) async {
        if let isResearching = isResearching {
            self.isResearching = isResearching
        }
        if let operation = operation {
            self.currentOperation = operation
        }
        if let progress = progress {
            self.researchProgress = progress
        }
    }

    private func performMultiSourceSearch(topic: String, depth: ResearchDepth) async throws -> [SearchResult] {
        var allResults: [SearchResult] = []
        let searchOptions = SearchOptions(
            maxResults: depth.maxResultsPerSource,
            dateRestriction: depth.dateRestriction,
            language: .english,
            safeSearch: .moderate
        )

        /// Search across all available providers.
        logger.debug("Available search providers: \(self.searchProviders.filter(\.isAvailable).map(\.name).joined(separator: ", "))")

        let options = searchOptions  /// Capture as immutable for Sendable safety
        for provider in searchProviders.filter(\.isAvailable) {
            do {
                let providerName = provider.name  /// Capture before async
                logger.debug("Searching with provider: \(providerName)")
                let results = try await provider.search(query: topic, options: options)
                logger.debug("Provider \(providerName) returned \(results.count) results")
                allResults.append(contentsOf: results)

                /// Respect rate limiting between providers.
                try await Task.sleep(for: .milliseconds(500))

            } catch {
                logger.error("Search provider \(provider.name) failed: \(error)")
                /// Continue with other providers.
            }
        }

        logger.debug("Total search results collected: \(allResults.count)")

        /// Deduplicate and rank results.
        return deduplicateAndRankResults(allResults, maxResults: depth.maxTotalResults)
    }

    private func extractContentFromResults(_ searchResults: [SearchResult]) async throws -> [WebPageContent] {
        var extractedContent: [WebPageContent] = []

        for (index, result) in searchResults.enumerated() {
            do {
                let content = try await contentExtractor.extractContent(from: result.url)
                extractedContent.append(content)

                logger.debug("Extracted content from: \(result.url.lastPathComponent)")

                /// Update progress.
                let progress = 0.3 + (Double(index + 1) / Double(searchResults.count)) * 0.3
                await updateResearchStatus(progress: progress)

            } catch {
                logger.warning("Content extraction failed for \(result.url): \(error)")
                /// Continue with other URLs.
            }
        }

        return extractedContent
    }

    private func processContentThroughRAG(_ content: [WebPageContent], conversationId: UUID) async throws -> [WebPageContent] {
        /// Process each piece of content through the Vector RAG Service with conversation scope.
        var successfulContent: [WebPageContent] = []
        var failedCount = 0
        
        for webContent in content {
            let ragDocument = RAGDocument(
                id: UUID(),
                title: webContent.title,
                content: webContent.content,
                type: .web,
                conversationId: conversationId,
                metadata: [
                    "sourceURL": webContent.url.absoluteString,
                    "extractedAt": ISO8601DateFormatter().string(from: webContent.extractedAt),
                    "contentType": "web_research"
                ]
            )

            /// Ingest into Vector RAG for semantic processing.
            do {
                _ = try await vectorRAGService.ingestDocument(ragDocument)
                successfulContent.append(webContent)
            } catch let error as VectorRAGError {
                /// Log warning but continue processing other sources.
                logger.warning("Source ingestion failed for \(webContent.url.absoluteString): \(error.localizedDescription)")
                failedCount += 1
            } catch {
                /// Unexpected error type - log and continue.
                logger.warning("Unexpected error ingesting source \(webContent.url.absoluteString): \(error)")
                failedCount += 1
            }
        }

        /// If ALL sources failed, throw error.
        if successfulContent.isEmpty && !content.isEmpty {
            throw VectorRAGError.ingestionFailed("All \(content.count) sources failed ingestion. No useable content found. Please try a different search query or topic.")
        }

        logger.debug("RAG processing complete: \(successfulContent.count) successful, \(failedCount) failed")
        return successfulContent
    }

    private func deduplicateAndRankResults(_ results: [SearchResult], maxResults: Int) -> [SearchResult] {
        /// Remove duplicates based on URL.
        var uniqueResults: [SearchResult] = []
        var seenURLs: Set<URL> = []

        for result in results {
            if !seenURLs.contains(result.url) {
                uniqueResults.append(result)
                seenURLs.insert(result.url)
            }
        }

        /// Sort by relevance score and limit results.
        return Array(uniqueResults.sorted { $0.relevanceScore > $1.relevanceScore }.prefix(maxResults))
    }

    // MARK: - News Processing

    private func processNewsContent(_ newsResults: [NewsResult]) async throws -> [ProcessedNewsContent] {
        var processedContent: [ProcessedNewsContent] = []

        for news in newsResults {
            do {
                let content = try await contentExtractor.extractContent(from: news.url)

                let processed = ProcessedNewsContent(
                    originalNews: news,
                    extractedContent: content,
                    credibilityScore: calculateNewsCredibility(news),
                    sentiment: analyzeSentiment(content.content),
                    keyPoints: extractKeyPoints(content.content)
                )

                processedContent.append(processed)
            } catch {
                logger.warning("Failed to process news content from \(news.url): \(error)")
            }
        }

        return processedContent
    }

    private func createEventTimeline(from processedNews: [ProcessedNewsContent]) -> [TimelineEvent] {
        var events: [TimelineEvent] = []

        for content in processedNews {
            let event = TimelineEvent(
                date: content.originalNews.publishedAt,
                title: content.originalNews.title,
                description: content.originalNews.summary ?? String(content.extractedContent.content.prefix(200)) + "...",
                source: content.originalNews.source,
                url: content.originalNews.url
            )
            events.append(event)
        }

        return events.sorted { $0.date > $1.date }
    }

    private func extractKeyDevelopments(from processedNews: [ProcessedNewsContent]) -> [KeyDevelopment] {
        /// Extract key developments based on sentiment, recency, and source credibility.
        return processedNews
            .filter { $0.credibilityScore > 0.7 }
            .map { content in
                KeyDevelopment(
                    title: content.originalNews.title,
                    summary: content.keyPoints.joined(separator: " "),
                    importance: content.credibilityScore,
                    source: content.originalNews.source,
                    date: content.originalNews.publishedAt
                )
            }
            .sorted { $0.importance > $1.importance }
    }

    private func extractNewsSources(from newsResults: [NewsResult]) -> [NewsSource] {
        let groupedSources = Dictionary(grouping: newsResults) { $0.source }

        return groupedSources.map { source, articles in
            NewsSource(
                name: source,
                articleCount: articles.count,
                credibilityScore: articles.map { calculateNewsCredibility($0) }.reduce(0, +) / Double(articles.count),
                latestArticle: articles.max { $0.publishedAt < $1.publishedAt }?.publishedAt ?? Date()
            )
        }.sorted { $0.credibilityScore > $1.credibilityScore }
    }

    // MARK: - Technical Research

    private func performTechnicalSearch(topic: String) async throws -> [SearchResult] {
        let technicalQueries = [
            "\(topic) documentation",
            "\(topic) technical specification",
            "\(topic) API reference",
            "\(topic) academic paper",
            "\(topic) implementation guide"
        ]

        var allResults: [SearchResult] = []

        for query in technicalQueries {
            let results = try await performMultiSourceSearch(topic: query, depth: .shallow)
            allResults.append(contentsOf: results)
        }

        /// Filter for technical domains and authoritative sources.
        let technicalResults = allResults.filter { result in
            let host = result.url.host?.lowercased() ?? ""
            return isTechnicalDomain(host) || isAuthoritativeSource(host)
        }

        return Array(technicalResults.prefix(30))
    }

    private func extractTechnicalContent(from results: [SearchResult]) async throws -> [WebPageContent] {
        return try await extractContentFromResults(results)
    }

    private func calculateAuthorityScore(_ content: [WebPageContent]) -> Double {
        let domainScores = content.map { calculateDomainAuthority($0.url) }
        return domainScores.isEmpty ? 0.0 : domainScores.reduce(0, +) / Double(domainScores.count)
    }

    private func extractTechnicalConcepts(_ content: [WebPageContent]) -> [TechnicalConcept] {
        /// Extract technical concepts using pattern matching and keyword analysis.
        var concepts: [TechnicalConcept] = []

        for webContent in content {
            let text = webContent.content
            let detectedConcepts = detectTechnicalPatterns(in: text)
            concepts.append(contentsOf: detectedConcepts)
        }

        /// Group and rank concepts by frequency.
        let groupedConcepts = Dictionary(grouping: concepts) { $0.name.lowercased() }

        return groupedConcepts.compactMap { _, conceptList in
            guard let firstConcept = conceptList.first else { return nil }

            return TechnicalConcept(
                name: firstConcept.name,
                description: firstConcept.description,
                category: firstConcept.category,
                frequency: conceptList.count,
                sources: Array(Set(conceptList.flatMap { $0.sources }))
            )
        }.sorted { $0.frequency > $1.frequency }
    }

    private func extractDocumentationLinks(_ content: [WebPageContent]) -> [DocumentationLink] {
        var docLinks: [DocumentationLink] = []

        for webContent in content {
            if isDocumentationSite(webContent.url) {
                let link = DocumentationLink(
                    title: webContent.title,
                    url: webContent.url,
                    type: classifyDocumentationType(webContent.url),
                    quality: assessDocumentationQuality(webContent)
                )
                docLinks.append(link)
            }
        }

        return docLinks.sorted { $0.quality > $1.quality }
    }

    private func identifyRelatedTechnicalTopics(_ content: [WebPageContent]) -> [String] {
        /// Use keyword extraction and semantic analysis to identify related topics.
        let allText = content.map { $0.content }.joined(separator: " ")
        return extractRelatedTopics(from: allText)
    }

    // MARK: - Helper Methods

    private func calculateNewsCredibility(_ news: NewsResult) -> Double {
        var score = 0.5

        /// Increase score for trusted sources.
        let trustedSources = ["Reuters", "Associated Press", "BBC", "NPR"]
        if trustedSources.contains(news.source) {
            score += 0.3
        }

        /// Increase score for HTTPS.
        if news.url.scheme == "https" {
            score += 0.1
        }

        /// Decrease score for very recent articles (may be unverified).
        let hoursSincePublished = Date().timeIntervalSince(news.publishedAt) / 3600
        if hoursSincePublished < 2 {
            score -= 0.1
        }

        return min(1.0, max(0.0, score))
    }

    private func analyzeSentiment(_ text: String) -> SentimentAnalysis {
        /// Basic sentiment analysis - in production, use NaturalLanguage framework.
        let positiveWords = ["positive", "good", "success", "improvement", "progress"]
        let negativeWords = ["negative", "bad", "failure", "decline", "crisis"]

        let lowercasedText = text.lowercased()
        let positiveCount = positiveWords.map { lowercasedText.components(separatedBy: $0).count - 1 }.reduce(0, +)
        let negativeCount = negativeWords.map { lowercasedText.components(separatedBy: $0).count - 1 }.reduce(0, +)

        let totalSentimentWords = positiveCount + negativeCount
        guard totalSentimentWords > 0 else {
            return SentimentAnalysis(polarity: .neutral, confidence: 0.5)
        }

        let positiveRatio = Double(positiveCount) / Double(totalSentimentWords)

        if positiveRatio > 0.6 {
            return SentimentAnalysis(polarity: .positive, confidence: positiveRatio)
        } else if positiveRatio < 0.4 {
            return SentimentAnalysis(polarity: .negative, confidence: 1.0 - positiveRatio)
        } else {
            return SentimentAnalysis(polarity: .neutral, confidence: 0.5)
        }
    }

    private func extractKeyPoints(_ text: String) -> [String] {
        /// Extract key points using sentence analysis.
        let sentences = text.components(separatedBy: ". ")

        /// Simple heuristic: sentences with important keywords or at beginning/end.
        let importantSentences = sentences.filter { sentence in
            let lowercased = sentence.lowercased()
            let keywords = ["key", "important", "significant", "major", "critical", "main", "primary"]
            return keywords.contains { lowercased.contains($0) } || sentence.count > 50
        }

        return Array(importantSentences.prefix(5))
    }

    private func isTechnicalDomain(_ host: String) -> Bool {
        let technicalDomains = [
            "github.com", "stackoverflow.com", "developer.apple.com", "docs.microsoft.com",
            "developer.mozilla.org", "w3.org", "ietf.org", "rfc-editor.org"
        ]
        return technicalDomains.contains { host.contains($0) }
    }

    private func isAuthoritativeSource(_ host: String) -> Bool {
        let authoritativeDomains = [
            "ieee.org", "acm.org", "arxiv.org", ".edu", ".gov", "wikipedia.org"
        ]
        return authoritativeDomains.contains { host.contains($0) }
    }

    private func calculateDomainAuthority(_ url: URL) -> Double {
        guard let host = url.host?.lowercased() else { return 0.0 }

        if isTechnicalDomain(host) { return 0.9 }
        if isAuthoritativeSource(host) { return 0.8 }
        if host.contains(".edu") { return 0.85 }
        if host.contains(".gov") { return 0.8 }
        if host.hasPrefix("docs.") { return 0.75 }

        return 0.5
    }

    private func detectTechnicalPatterns(in text: String) -> [TechnicalConcept] {
        /// Simplified technical concept detection.
        var concepts: [TechnicalConcept] = []

        /// API patterns.
        if text.contains("API") || text.contains("endpoint") {
            concepts.append(TechnicalConcept(
                name: "API",
                description: "Application Programming Interface",
                category: .interface,
                frequency: 1,
                sources: []
            ))
        }

        /// Framework patterns.
        let frameworks = ["SwiftUI", "UIKit", "React", "Angular", "Vue"]
        for framework in frameworks {
            if text.contains(framework) {
                concepts.append(TechnicalConcept(
                    name: framework,
                    description: "\(framework) Framework",
                    category: .framework,
                    frequency: 1,
                    sources: []
                ))
            }
        }

        return concepts
    }

    private func isDocumentationSite(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }

        let docPatterns = ["docs.", "documentation", "api.", "reference", "guide"]
        return docPatterns.contains { host.contains($0) } || url.path.contains("docs")
    }

    private func classifyDocumentationType(_ url: URL) -> DocumentationType {
        let path = url.path.lowercased()

        if path.contains("api") { return .api }
        if path.contains("tutorial") { return .tutorial }
        if path.contains("guide") { return .guide }
        if path.contains("reference") { return .reference }

        return .general
    }

    private func assessDocumentationQuality(_ content: WebPageContent) -> Double {
        var score = 0.5

        /// Longer, more comprehensive documentation gets higher score.
        if content.content.count > 2000 { score += 0.2 }
        if content.content.count > 5000 { score += 0.1 }

        /// Code examples boost quality.
        if content.content.contains("```") || content.content.contains("<code>") {
            score += 0.2
        }

        return min(1.0, score)
    }

    private func extractRelatedTopics(from text: String) -> [String] {
        /// Extract potential related topics using keyword analysis.
        let words = text.lowercased().components(separatedBy: .whitespacesAndNewlines)
        let technicalWords = words.filter { word in
            word.count > 4 && (
                word.hasSuffix("ing") ||
                word.hasSuffix("tion") ||
                word.hasSuffix("ment") ||
                word.contains("tech") ||
                word.contains("dev")
            )
        }

        /// Return most frequent technical terms.
        let wordCounts = Dictionary(grouping: technicalWords) { $0 }
        return Array(wordCounts.sorted { $0.value.count > $1.value.count }.prefix(10).map { $0.key })
    }
}
