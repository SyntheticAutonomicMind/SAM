// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

// MARK: - Research Depth Configuration

/// Defines the depth and scope of web research.
public enum ResearchDepth: String, CaseIterable, Codable {
    case shallow = "shallow"
    case standard = "standard"
    case comprehensive = "comprehensive"

    var maxResultsPerSource: Int {
        switch self {
        case .shallow: return 5
        case .standard: return 10
        case .comprehensive: return 20
        }
    }

    var maxTotalResults: Int {
        switch self {
        case .shallow: return 15
        case .standard: return 30
        case .comprehensive: return 60
        }
    }

    var dateRestriction: DateRestriction? {
        switch self {
        case .shallow: return .lastMonth
        case .standard: return .lastYear
        case .comprehensive: return nil
        }
    }
}

/// Date restrictions for search queries.
public enum DateRestriction: String, CaseIterable, Sendable {
    case lastDay = "d1"
    case lastWeek = "w1"
    case lastMonth = "m1"
    case lastYear = "y1"
}

/// Research type specializations.
public enum ResearchType: String, CaseIterable {
    case general = "general"
    case news = "news"
    case technical = "technical"
}

// MARK: - Protocol Conformance

/// Protocol for different search engine providers.
public protocol SearchProvider: Sendable {
    var name: String { get }
    var isAvailable: Bool { get }

    func search(query: String, options: SearchOptions) async throws -> [SearchResult]
    func searchNews(query: String, options: NewsSearchOptions) async throws -> [NewsResult]
    func searchImages(query: String, options: ImageSearchOptions) async throws -> [ImageResult]
}

// MARK: - Search Options

/// Configuration for general web searches.
public struct SearchOptions: Sendable {
    let maxResults: Int
    let dateRestriction: DateRestriction?
    let language: SearchLanguage
    let safeSearch: SafeSearchLevel

    public init(
        maxResults: Int = 10,
        dateRestriction: DateRestriction? = nil,
        language: SearchLanguage = .english,
        safeSearch: SafeSearchLevel = .moderate
    ) {
        self.maxResults = maxResults
        self.dateRestriction = dateRestriction
        self.language = language
        self.safeSearch = safeSearch
    }
}

/// Configuration for news searches.
public struct NewsSearchOptions: Sendable {
    let maxResults: Int
    let timeRange: TimeRange
    let language: SearchLanguage
    let sortBy: NewsSortOption

    public init(
        maxResults: Int = 20,
        timeRange: TimeRange = .last7Days,
        language: SearchLanguage = .english,
        sortBy: NewsSortOption = .relevance
    ) {
        self.maxResults = maxResults
        self.timeRange = timeRange
        self.language = language
        self.sortBy = sortBy
    }
}

/// Configuration for image searches.
public struct ImageSearchOptions {
    let maxResults: Int
    let imageType: ImageType
    let imageSize: ImageSize
    let safeSearch: SafeSearchLevel

    public init(
        maxResults: Int = 10,
        imageType: ImageType = .any,
        imageSize: ImageSize = .any,
        safeSearch: SafeSearchLevel = .moderate
    ) {
        self.maxResults = maxResults
        self.imageType = imageType
        self.imageSize = imageSize
        self.safeSearch = safeSearch
    }
}

/// Search language options.
public enum SearchLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case chinese = "zh"
    case japanese = "ja"
}

/// Safe search levels.
public enum SafeSearchLevel: String, CaseIterable, Sendable {
    case off = "off"
    case moderate = "moderate"
    case strict = "strict"
}

/// Time range for news searches.
public enum TimeRange: String, CaseIterable, Sendable {
    case lastHour = "h1"
    case last24Hours = "d1"
    case last7Days = "w1"
    case lastMonth = "m1"
    case lastYear = "y1"
}

/// News sorting options.
public enum NewsSortOption: String, CaseIterable, Sendable {
    case relevance = "relevance"
    case date = "date"
    case popularity = "popularity"
}

/// Image type filters.
public enum ImageType: String, CaseIterable {
    case any = "any"
    case photo = "photo"
    case clipart = "clipart"
    case drawing = "drawing"
    case transparent = "transparent"
}

/// Image size filters.
public enum ImageSize: String, CaseIterable {
    case any = "any"
    case small = "small"
    case medium = "medium"
    case large = "large"
    case extraLarge = "xlarge"
}

// MARK: - Search Results

/// Standard web search result.
public struct SearchResult: Identifiable, Codable {
    public var id = UUID()
    public let title: String
    public let url: URL
    public let snippet: String
    public let relevanceScore: Double
    public let searchEngine: String
    public let retrievedAt: Date

    public init(
        title: String,
        url: URL,
        snippet: String,
        relevanceScore: Double = 1.0,
        searchEngine: String,
        retrievedAt: Date = Date()
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.relevanceScore = relevanceScore
        self.searchEngine = searchEngine
        self.retrievedAt = retrievedAt
    }
}

/// News search result with publication information.
public struct NewsResult: Identifiable, Codable {
    public var id = UUID()
    public let title: String
    public let url: URL
    public let summary: String?
    public let source: String
    public let author: String?
    public let publishedAt: Date
    public let imageURL: URL?
    public let relevanceScore: Double
    public let retrievedAt: Date

    public init(
        title: String,
        url: URL,
        summary: String? = nil,
        source: String,
        author: String? = nil,
        publishedAt: Date,
        imageURL: URL? = nil,
        relevanceScore: Double = 1.0,
        retrievedAt: Date = Date()
    ) {
        self.title = title
        self.url = url
        self.summary = summary
        self.source = source
        self.author = author
        self.publishedAt = publishedAt
        self.imageURL = imageURL
        self.relevanceScore = relevanceScore
        self.retrievedAt = retrievedAt
    }
}

/// Image search result.
public struct ImageResult: Identifiable, Codable {
    public var id = UUID()
    public let title: String
    public let imageURL: URL
    public let thumbnailURL: URL
    public let sourceURL: URL
    public let width: Int
    public let height: Int
    public let fileSize: Int?
    public let mimeType: String?
    public let retrievedAt: Date

    public init(
        title: String,
        imageURL: URL,
        thumbnailURL: URL,
        sourceURL: URL,
        width: Int,
        height: Int,
        fileSize: Int? = nil,
        mimeType: String? = nil,
        retrievedAt: Date = Date()
    ) {
        self.title = title
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
        self.sourceURL = sourceURL
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.retrievedAt = retrievedAt
    }
}

// MARK: - Web Content Models

/// Extracted web page content.
public struct WebPageContent: Identifiable, Codable, Sendable {
    public var id = UUID()
    public let url: URL
    public let title: String
    public let content: String
    public let summary: String
    public let metadata: [String: String]
    public let extractedAt: Date

    public init(
        url: URL,
        title: String,
        content: String,
        summary: String,
        metadata: [String: String] = [:],
        extractedAt: Date = Date()
    ) {
        self.url = url
        self.title = title
        self.content = content
        self.summary = summary
        self.metadata = metadata
        self.extractedAt = extractedAt
    }
}

/// Research source attribution.
public struct ResearchSource: Identifiable, Codable {
    public var id = UUID()
    public let url: URL
    public let title: String
    public let extractedAt: Date
    public let credibilityScore: Double

    public init(
        url: URL,
        title: String,
        extractedAt: Date = Date(),
        credibilityScore: Double = 0.5
    ) {
        self.url = url
        self.title = title
        self.extractedAt = extractedAt
        self.credibilityScore = credibilityScore
    }
}

// MARK: - Research Reports

/// Comprehensive research report.
public struct ResearchReport: Identifiable, Codable {
    public var id = UUID()
    public let topic: String
    public let searchResults: [SearchResult]
    public let extractedContent: [WebPageContent]
    public let synthesis: ResearchSynthesis
    public let sources: [ResearchSource]
    public let conductedAt: Date
    public let researchDepth: ResearchDepth

    public init(
        topic: String,
        searchResults: [SearchResult],
        extractedContent: [WebPageContent],
        synthesis: ResearchSynthesis,
        sources: [ResearchSource],
        conductedAt: Date = Date(),
        researchDepth: ResearchDepth
    ) {
        self.topic = topic
        self.searchResults = searchResults
        self.extractedContent = extractedContent
        self.synthesis = synthesis
        self.sources = sources
        self.conductedAt = conductedAt
        self.researchDepth = researchDepth
    }
}

/// News-focused research report.
public struct NewsResearchReport: Identifiable, Codable {
    public var id = UUID()
    public let topic: String
    public let newsResults: [NewsResult]
    public let timeline: [TimelineEvent]
    public let keyDevelopments: [KeyDevelopment]
    public let sources: [NewsSource]
    public let conductedAt: Date

    public init(
        topic: String,
        newsResults: [NewsResult],
        timeline: [TimelineEvent],
        keyDevelopments: [KeyDevelopment],
        sources: [NewsSource],
        conductedAt: Date = Date()
    ) {
        self.topic = topic
        self.newsResults = newsResults
        self.timeline = timeline
        self.keyDevelopments = keyDevelopments
        self.sources = sources
        self.conductedAt = conductedAt
    }
}

/// Technical research report.
public struct TechnicalResearchReport: Identifiable, Codable {
    public var id = UUID()
    public let topic: String
    public let authorityScore: Double
    public let concepts: [TechnicalConcept]
    public let documentation: [DocumentationLink]
    public let relatedTopics: [String]
    public let sources: [ResearchSource]
    public let conductedAt: Date

    public init(
        topic: String,
        authorityScore: Double,
        concepts: [TechnicalConcept],
        documentation: [DocumentationLink],
        relatedTopics: [String],
        sources: [ResearchSource],
        conductedAt: Date = Date()
    ) {
        self.topic = topic
        self.authorityScore = authorityScore
        self.concepts = concepts
        self.documentation = documentation
        self.relatedTopics = relatedTopics
        self.sources = sources
        self.conductedAt = conductedAt
    }
}

// MARK: - Research Analysis Models

/// Research synthesis combining multiple sources.
public struct ResearchSynthesis: Codable {
    public let topic: String
    public let keyFindings: [KeyFinding]
    public let sourceCount: Int
    public let confidence: Double
    public let sources: [ResearchSource]
    public let generatedAt: Date

    public init(
        topic: String,
        keyFindings: [KeyFinding],
        sourceCount: Int,
        confidence: Double,
        sources: [ResearchSource],
        generatedAt: Date = Date()
    ) {
        self.topic = topic
        self.keyFindings = keyFindings
        self.sourceCount = sourceCount
        self.confidence = confidence
        self.sources = sources
        self.generatedAt = generatedAt
    }
}

/// Key research finding with supporting evidence.
public struct KeyFinding: Identifiable, Codable {
    public var id = UUID()
    public let title: String
    public let summary: String
    public let evidence: [String]
    public let confidence: Double
    public let supportingSources: [ResearchSource]

    public init(
        title: String,
        summary: String,
        evidence: [String],
        confidence: Double,
        supportingSources: [ResearchSource]
    ) {
        self.title = title
        self.summary = summary
        self.evidence = evidence
        self.confidence = confidence
        self.supportingSources = supportingSources
    }
}

/// Technical concept extracted from research.
public struct TechnicalConcept: Identifiable, Codable {
    public var id = UUID()
    public let name: String
    public let description: String
    public let category: ConceptCategory
    public let frequency: Int
    public let sources: [String]

    public init(
        name: String,
        description: String,
        category: ConceptCategory,
        frequency: Int,
        sources: [String]
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.frequency = frequency
        self.sources = sources
    }
}

/// Technical concept categories.
public enum ConceptCategory: String, CaseIterable, Codable {
    case framework = "framework"
    case library = "library"
    case `protocol` = "protocol"
    case interface = "interface"
    case algorithm = "algorithm"
    case pattern = "pattern"
    case tool = "tool"
    case methodology = "methodology"
}

/// Documentation link with quality assessment.
public struct DocumentationLink: Identifiable, Codable {
    public var id = UUID()
    public let title: String
    public let url: URL
    public let type: DocumentationType
    public let quality: Double

    public init(
        title: String,
        url: URL,
        type: DocumentationType,
        quality: Double
    ) {
        self.title = title
        self.url = url
        self.type = type
        self.quality = quality
    }
}

/// Documentation types.
public enum DocumentationType: String, CaseIterable, Codable {
    case api = "api"
    case tutorial = "tutorial"
    case guide = "guide"
    case reference = "reference"
    case specification = "specification"
    case general = "general"
}

// MARK: - News Analysis Models

/// Processed news content with analysis.
public struct ProcessedNewsContent: Identifiable, Codable {
    public var id = UUID()
    public let originalNews: NewsResult
    public let extractedContent: WebPageContent
    public let credibilityScore: Double
    public let sentiment: SentimentAnalysis
    public let keyPoints: [String]

    public init(
        originalNews: NewsResult,
        extractedContent: WebPageContent,
        credibilityScore: Double,
        sentiment: SentimentAnalysis,
        keyPoints: [String]
    ) {
        self.originalNews = originalNews
        self.extractedContent = extractedContent
        self.credibilityScore = credibilityScore
        self.sentiment = sentiment
        self.keyPoints = keyPoints
    }
}

/// Timeline event for chronological news analysis.
public struct TimelineEvent: Identifiable, Codable {
    public var id = UUID()
    public let date: Date
    public let title: String
    public let description: String
    public let source: String
    public let url: URL

    public init(
        date: Date,
        title: String,
        description: String,
        source: String,
        url: URL
    ) {
        self.date = date
        self.title = title
        self.description = description
        self.source = source
        self.url = url
    }
}

/// Key development in news research.
public struct KeyDevelopment: Identifiable, Codable {
    public var id = UUID()
    public let title: String
    public let summary: String
    public let importance: Double
    public let source: String
    public let date: Date

    public init(
        title: String,
        summary: String,
        importance: Double,
        source: String,
        date: Date
    ) {
        self.title = title
        self.summary = summary
        self.importance = importance
        self.source = source
        self.date = date
    }
}

/// News source analysis.
public struct NewsSource: Identifiable, Codable {
    public var id = UUID()
    public let name: String
    public let articleCount: Int
    public let credibilityScore: Double
    public let latestArticle: Date

    public init(
        name: String,
        articleCount: Int,
        credibilityScore: Double,
        latestArticle: Date
    ) {
        self.name = name
        self.articleCount = articleCount
        self.credibilityScore = credibilityScore
        self.latestArticle = latestArticle
    }
}

/// Sentiment analysis result.
public struct SentimentAnalysis: Codable {
    public let polarity: SentimentPolarity
    public let confidence: Double

    public init(polarity: SentimentPolarity, confidence: Double) {
        self.polarity = polarity
        self.confidence = confidence
    }
}

/// Sentiment polarity.
public enum SentimentPolarity: String, CaseIterable, Codable {
    case positive = "positive"
    case neutral = "neutral"
    case negative = "negative"
}

// MARK: - Error Types

/// Web research specific errors.
public enum WebResearchError: Error, LocalizedError {
    case noSearchProviders
    case allSearchProvidersFailed
    case robotsBlocked(URL)
    case httpError(URLResponse?)
    case contentExtractionFailed(URL)
    case synthesisTimeout
    case invalidConfiguration(String)
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case .noSearchProviders:
            return "No search providers available"

        case .allSearchProvidersFailed:
            return "All search providers failed to return results"

        case .robotsBlocked(let url):
            return "Access blocked by robots.txt for \(url.host ?? "unknown")"

        case .httpError(let response):
            return "HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? 0)"

        case .contentExtractionFailed(let url):
            return "Failed to extract content from \(url)"

        case .synthesisTimeout:
            return "Research synthesis timed out"

        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"

        case .invalidData(let message):
            return "Invalid data: \(message)"
        }
    }
}
