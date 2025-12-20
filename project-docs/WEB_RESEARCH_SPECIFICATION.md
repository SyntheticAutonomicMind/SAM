<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# SAM Web Research Specification

## Overview

This specification defines comprehensive web research capabilities for SAM, enabling users to conduct sophisticated web searches, content analysis, and research through natural conversation. The system integrates web crawling, search engine APIs, and content extraction with the existing Vector RAG Service for intelligent information synthesis.

## Design Philosophy

### User Experience Principles
- **Conversational Research**: All web research accessible through natural language requests
- **Intelligent Synthesis**: Combine multiple sources into coherent insights
- **Source Transparency**: Clear attribution and source verification for all information
- **Real-Time Access**: Current information retrieval for time-sensitive queries

### Technical Principles
- **Multi-Source Integration**: Combine search engines, direct web access, and API sources
- **Vector RAG Enhancement**: Process web content through semantic analysis pipeline
- **Privacy Conscious**: Respect robots.txt, rate limiting, and user privacy
- **Performance Optimized**: Efficient concurrent processing with proper resource management

## Web Research Architecture

### Core Components

#### WebResearchService
**Purpose**: Central service coordinating all web research operations
**Integration**: Works with Vector RAG Service for content processing and analysis

```swift
/**
 Central web research service providing comprehensive web information capabilities.
 
 This service coordinates the complete web research pipeline:
 - Multi-source search engine integration (Google, Bing, DuckDuckGo)
 - Intelligent web crawling with content extraction
 - Real-time information synthesis and analysis
 - Integration with Vector RAG for semantic content processing
 */
@MainActor
public class WebResearchService: ObservableObject {
    private let vectorRAGService: VectorRAGService
    private let conversationManager: ConversationManager
    private let logger = Logger(label: "com.sam.web.research")
    
    @Published public var isResearching: Bool = false
    @Published public var researchProgress: Double = 0.0
    @Published public var currentOperation: String = ""
    
    // Search providers
    private let searchProviders: [SearchProvider]
    private let contentExtractor: WebContentExtractor
    private let researchSynthesizer: ResearchSynthesizer
    
    public init(vectorRAGService: VectorRAGService, conversationManager: ConversationManager) {
        self.vectorRAGService = vectorRAGService
        self.conversationManager = conversationManager
        
        // Initialize search providers
        self.searchProviders = [
            GoogleSearchProvider(),
            BingSearchProvider(),
            DuckDuckGoSearchProvider()
        ]
        
        self.contentExtractor = WebContentExtractor()
        self.researchSynthesizer = ResearchSynthesizer(vectorRAGService: vectorRAGService)
    }
}
```

#### Search Engine Integration
**Purpose**: Integrate with multiple search engines for comprehensive coverage

```swift
// Protocol for search engine providers
protocol SearchProvider {
    var name: String { get }
    var isAvailable: Bool { get }
    
    func search(query: String, options: SearchOptions) async throws -> [SearchResult]
    func searchNews(query: String, options: NewsSearchOptions) async throws -> [NewsResult]
    func searchImages(query: String, options: ImageSearchOptions) async throws -> [ImageResult]
}

// Google Search Provider (using Custom Search API)
class GoogleSearchProvider: SearchProvider {
    let name = "Google"
    private let apiKey: String
    private let searchEngineId: String
    
    var isAvailable: Bool {
        return !apiKey.isEmpty && !searchEngineId.isEmpty
    }
    
    func search(query: String, options: SearchOptions) async throws -> [SearchResult] {
        let url = buildSearchURL(query: query, options: options)
        let response = try await performHTTPRequest(url: url)
        return try parseGoogleResults(response)
    }
    
    private func buildSearchURL(query: String, options: SearchOptions) -> URL {
        var components = URLComponents(string: "https://www.googleapis.com/customsearch/v1")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "cx", value: searchEngineId),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "num", value: "\(options.maxResults)"),
            URLQueryItem(name: "dateRestrict", value: options.dateRestriction?.rawValue)
        ]
        return components.url!
    }
}

// Bing Search Provider (using Bing Web Search API)
class BingSearchProvider: SearchProvider {
    let name = "Bing"
    private let apiKey: String
    
    var isAvailable: Bool {
        return !apiKey.isEmpty
    }
    
    func search(query: String, options: SearchOptions) async throws -> [SearchResult] {
        var request = URLRequest(url: URL(string: "https://api.bing.microsoft.com/v7.0/search")!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        
        // Build query parameters and execute search
        let response = try await performBingSearch(request: request, query: query, options: options)
        return try parseBingResults(response)
    }
}

// DuckDuckGo Search Provider (using Instant Answer API)
class DuckDuckGoSearchProvider: SearchProvider {
    let name = "DuckDuckGo"
    
    var isAvailable: Bool { return true } // No API key required
    
    func search(query: String, options: SearchOptions) async throws -> [SearchResult] {
        // Use DuckDuckGo's Instant Answer API for privacy-focused search
        let url = URL(string: "https://api.duckduckgo.com/?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&format=json&no_html=1&skip_disambig=1")!
        
        let response = try await performHTTPRequest(url: url)
        return try parseDuckDuckGoResults(response)
    }
}
```

#### Web Content Extraction
**Purpose**: Extract clean, structured content from web pages

```swift
/**
 Web content extraction service using WebKit and content parsing.
 */
class WebContentExtractor {
    private let logger = Logger(label: "com.sam.web.content")
    
    /**
     Extract structured content from a web page URL.
     */
    func extractContent(from url: URL) async throws -> WebPageContent {
        logger.info("Extracting content from: \(url.absoluteString)")
        
        // Validate URL and check robots.txt
        try await validateURLAccess(url)
        
        // Fetch raw HTML content
        let htmlContent = try await fetchHTMLContent(from: url)
        
        // Parse and extract structured content
        let extractedContent = try parseHTMLContent(htmlContent, sourceURL: url)
        
        // Clean and structure the content
        let cleanedContent = cleanExtractedContent(extractedContent)
        
        return WebPageContent(
            url: url,
            title: extractedContent.title,
            content: cleanedContent.text,
            summary: try await generateContentSummary(cleanedContent.text),
            metadata: extractedContent.metadata,
            extractedAt: Date()
        )
    }
    
    private func validateURLAccess(_ url: URL) async throws {
        // Check robots.txt compliance
        let robotsChecker = RobotsChecker()
        let isAllowed = try await robotsChecker.canAccess(url: url, userAgent: "SAM-Research-Bot/1.0")
        
        guard isAllowed else {
            throw WebResearchError.robotsBlocked(url)
        }
    }
    
    private func fetchHTMLContent(from url: URL) async throws -> String {
        // Use URLSession with proper headers and timeout
        var request = URLRequest(url: url)
        request.setValue("SAM-Research-Bot/1.0 (+https://github.com/SyntheticAutonomicMind/SAM)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30.0
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw WebResearchError.httpError(response)
        }
        
        // Detect encoding and convert to string
        let encoding = detectTextEncoding(from: data, response: httpResponse)
        return String(data: data, encoding: encoding) ?? ""
    }
    
    private func parseHTMLContent(_ html: String, sourceURL: URL) throws -> ExtractedContent {
        // Use comprehensive HTML parsing to extract clean content
        let parser = HTMLContentParser()
        
        return ExtractedContent(
            title: parser.extractTitle(from: html),
            text: parser.extractMainText(from: html),
            headings: parser.extractHeadings(from: html),
            links: parser.extractLinks(from: html, baseURL: sourceURL),
            metadata: parser.extractMetadata(from: html)
        )
    }
}
```

### Research Methodologies

#### Comprehensive Research Workflow
```swift
extension WebResearchService {
    /**
     Conduct comprehensive research on a topic using multiple sources and analysis methods.
     */
    func conductResearch(on topic: String, depth: ResearchDepth = .standard) async throws -> ResearchReport {
        logger.info("Starting research on topic: \(topic)")
        isResearching = true
        currentOperation = "Initializing research"
        researchProgress = 0.0
        
        // Step 1: Multi-source search
        currentOperation = "Searching multiple sources"
        let searchResults = try await performMultiSourceSearch(topic: topic, depth: depth)
        researchProgress = 0.2
        
        // Step 2: Content extraction and analysis
        currentOperation = "Extracting and analyzing content"
        let extractedContent = try await extractContentFromResults(searchResults)
        researchProgress = 0.5
        
        // Step 3: Vector RAG processing
        currentOperation = "Processing content semantically"
        let processedContent = try await processContentThroughRAG(extractedContent)
        researchProgress = 0.7
        
        // Step 4: Synthesis and report generation
        currentOperation = "Synthesizing findings"
        let synthesis = try await synthesizeFindings(processedContent, originalTopic: topic)
        researchProgress = 0.9
        
        // Step 5: Generate comprehensive report
        let report = ResearchReport(
            topic: topic,
            searchResults: searchResults,
            extractedContent: extractedContent,
            synthesis: synthesis,
            sources: extractedContent.map { $0.sourceURL },
            conductedAt: Date(),
            researchDepth: depth
        )
        
        researchProgress = 1.0
        isResearching = false
        currentOperation = "Research complete"
        
        logger.info("Research completed: \(searchResults.count) sources, \(extractedContent.count) pages analyzed")
        return report
    }
    
    private func performMultiSourceSearch(topic: String, depth: ResearchDepth) async throws -> [SearchResult] {
        var allResults: [SearchResult] = []
        
        // Search across available providers
        for provider in searchProviders.filter({ $0.isAvailable }) {
            do {
                let results = try await provider.search(
                    query: topic,
                    options: SearchOptions(
                        maxResults: depth.maxResultsPerSource,
                        dateRestriction: depth.dateRestriction,
                        language: .english,
                        safeSearch: .moderate
                    )
                )
                allResults.append(contentsOf: results)
                
            } catch {
                logger.warning("Search provider \(provider.name) failed: \(error)")
                // Continue with other providers
            }
        }
        
        // Deduplicate and rank results
        return deduplicateAndRankResults(allResults)
    }
}
```

#### Specialized Search Types
```swift
extension WebResearchService {
    /**
     Perform news-focused research for current events and recent developments.
     */
    func researchCurrentEvents(topic: String) async throws -> NewsResearchReport {
        let newsResults = try await searchProviders.asyncMap { provider in
            try await provider.searchNews(
                query: topic,
                options: NewsSearchOptions(
                    maxResults: 20,
                    timeRange: .last7Days,
                    language: .english,
                    sortBy: .relevance
                )
            )
        }.flatMap { $0 }
        
        // Process news content with emphasis on recency and credibility
        let processedNews = try await processNewsContent(newsResults)
        
        return NewsResearchReport(
            topic: topic,
            newsResults: newsResults,
            timeline: createEventTimeline(from: processedNews),
            keyDevelopments: extractKeyDevelopments(from: processedNews),
            sources: extractNewsSources(from: newsResults)
        )
    }
    
    /**
     Research technical or academic topics with focus on authoritative sources.
     */
    func researchTechnicalTopic(topic: String) async throws -> TechnicalResearchReport {
        // Focus on academic, documentation, and authoritative technical sources
        let technicalResults = try await performTechnicalSearch(topic: topic)
        
        // Extract and analyze technical content
        let technicalContent = try await extractTechnicalContent(from: technicalResults)
        
        // Generate technical analysis and documentation
        return TechnicalResearchReport(
            topic: topic,
            authorityScore: calculateAuthorityScore(technicalContent),
            concepts: extractTechnicalConcepts(technicalContent),
            documentation: extractDocumentationLinks(technicalContent),
            relatedTopics: identifyRelatedTechnicalTopics(technicalContent)
        )
    }
}
```

### Content Analysis and Synthesis

#### Intelligent Content Processing
```swift
/**
 Research synthesis service using Vector RAG for intelligent content combination.
 */
class ResearchSynthesizer {
    private let vectorRAGService: VectorRAGService
    private let logger = Logger(label: "com.sam.research.synthesis")
    
    init(vectorRAGService: VectorRAGService) {
        self.vectorRAGService = vectorRAGService
    }
    
    /**
     Synthesize multiple content sources into coherent insights.
     */
    func synthesizeContent(_ contents: [WebPageContent], topic: String) async throws -> ResearchSynthesis {
        // Process all content through Vector RAG for semantic analysis
        var ragDocuments: [RAGDocument] = []
        
        for content in contents {
            let ragDoc = RAGDocument(
                id: UUID(),
                content: content.content,
                title: content.title,
                type: .document,
                conversationId: nil, // Research context, not conversation-specific
                metadata: [
                    "sourceURL": content.url.absoluteString,
                    "extractedAt": ISO8601DateFormatter().string(from: content.extractedAt),
                    "contentType": "web_research"
                ]
            )
            
            // Ingest content for semantic processing
            _ = try await vectorRAGService.ingestDocument(ragDoc)
            ragDocuments.append(ragDoc)
        }
        
        // Perform semantic analysis to identify key themes
        let keyThemes = try await identifyKeyThemes(ragDocuments, topic: topic)
        
        // Extract supporting evidence for each theme
        let themeEvidence = try await extractThemeEvidence(keyThemes, documents: ragDocuments)
        
        // Generate synthesis with source attribution
        let synthesis = ResearchSynthesis(
            topic: topic,
            keyFindings: generateKeyFindings(from: themeEvidence),
            sourceCount: contents.count,
            confidence: calculateSynthesisConfidence(themeEvidence),
            sources: contents.map { ResearchSource(url: $0.url, title: $0.title) },
            generatedAt: Date()
        )
        
        return synthesis
    }
    
    private func identifyKeyThemes(_ documents: [RAGDocument], topic: String) async throws -> [ResearchTheme] {
        // Use Vector RAG semantic search to identify common themes
        let themeQueries = generateThemeQueries(for: topic)
        var themes: [ResearchTheme] = []
        
        for query in themeQueries {
            let results = try await vectorRAGService.semanticSearch(
                query: query,
                limit: 10,
                similarityThreshold: 0.3
            )
            
            if !results.isEmpty {
                let theme = ResearchTheme(
                    title: query,
                    relevantContent: results.map { $0.content },
                    sources: results.compactMap { result in
                        documents.first { $0.id.uuidString == result.documentId }
                    },
                    strength: Double(results.count) / Double(documents.count)
                )
                themes.append(theme)
            }
        }
        
        return themes.sorted { $0.strength > $1.strength }
    }
}
```

### Conversational Integration

#### Natural Language Research Interface
**User Interaction Patterns**:
```
User: "Research the latest developments in AI safety"
SAM: "I'll research current AI safety developments across multiple sources. This may take a moment..."
[Performs multi-source search, content extraction, and synthesis]
SAM: "Based on my research of 15 recent sources, here are the key developments in AI safety..."

User: "What are experts saying about renewable energy costs?"
SAM: "Let me search for expert opinions on renewable energy costs..."
[Focuses on authoritative sources and expert analysis]
SAM: "I found expert analysis from 8 authoritative sources. The consensus shows..."

User: "Find technical documentation for Swift async/await"
SAM: "I'll search for official Swift documentation and technical resources..."
[Prioritizes official documentation and technical sources]
SAM: "Here's the comprehensive technical information I found..."
```

#### MCP Tool Integration
```swift
// Enhanced research tools for conversational access
class WebResearchTool: MCPTool {
    let name = "web_research"
    let description = "Conduct comprehensive web research on any topic"
    
    func execute(parameters: [String: Any]) async throws -> MCPToolResult {
        guard let topic = parameters["topic"] as? String else {
            throw MCPError.missingParameter("topic")
        }
        
        let depth = ResearchDepth(rawValue: parameters["depth"] as? String ?? "standard") ?? .standard
        let researchType = ResearchType(rawValue: parameters["type"] as? String ?? "general") ?? .general
        
        let researchService = WebResearchService.shared
        
        switch researchType {
        case .general:
            let report = try await researchService.conductResearch(on: topic, depth: depth)
            return MCPToolResult.success(data: report.toJSON())
            
        case .news:
            let newsReport = try await researchService.researchCurrentEvents(topic: topic)
            return MCPToolResult.success(data: newsReport.toJSON())
            
        case .technical:
            let techReport = try await researchService.researchTechnicalTopic(topic: topic)
            return MCPToolResult.success(data: techReport.toJSON())
        }
    }
}
```

### Performance and Ethics

#### Rate Limiting and Respectful Crawling
```swift
class RateLimiter {
    private var lastRequest: [String: Date] = [:]
    private let minimumInterval: TimeInterval = 1.0 // 1 second between requests
    
    func canMakeRequest(to host: String) -> Bool {
        guard let lastTime = lastRequest[host] else {
            lastRequest[host] = Date()
            return true
        }
        
        let timeSinceLastRequest = Date().timeIntervalSince(lastTime)
        if timeSinceLastRequest >= minimumInterval {
            lastRequest[host] = Date()
            return true
        }
        
        return false
    }
}

class RobotsChecker {
    func canAccess(url: URL, userAgent: String) async throws -> Bool {
        guard let host = url.host else { return false }
        
        let robotsURL = URL(string: "https://\(host)/robots.txt")!
        
        do {
            let (data, _) = try await URLSession.shared.data(from: robotsURL)
            let robotsContent = String(data: data, encoding: .utf8) ?? ""
            return parseRobotsTxt(robotsContent, userAgent: userAgent, path: url.path)
        } catch {
            // If robots.txt is not accessible, assume access is allowed
            return true
        }
    }
}
```

#### Privacy and Source Attribution
```swift
struct ResearchSource {
    let url: URL
    let title: String
    let extractedAt: Date
    let contentHash: String // For deduplication
    
    // Source credibility scoring
    var credibilityScore: Double {
        // Algorithm to assess source credibility based on:
        // - Domain authority
        // - HTTPS usage
        // - Content freshness
        // - Cross-reference validation
    }
}

class SourceAttributionManager {
    func generateSourceAttribution(_ sources: [ResearchSource]) -> String {
        let sortedSources = sources.sorted { $0.credibilityScore > $1.credibilityScore }
        
        var attribution = "Sources:\n"
        for (index, source) in sortedSources.enumerated() {
            attribution += "\(index + 1). \(source.title) - \(source.url.host ?? "unknown")\n"
        }
        
        return attribution
    }
    
    func validateSourceDiversity(_ sources: [ResearchSource]) -> Bool {
        let uniqueHosts = Set(sources.compactMap { $0.url.host })
        let diversityRatio = Double(uniqueHosts.count) / Double(sources.count)
        
        // Ensure at least 60% source diversity
        return diversityRatio >= 0.6
    }
}
```

## Implementation Phases

### Phase 1: Foundation (Basic Web Research)
1. **WebResearchService Setup**: Core service architecture with single search provider
2. **Google Search Integration**: Custom Search API implementation
3. **Basic Content Extraction**: HTML parsing and clean text extraction
4. **Vector RAG Integration**: Process web content through existing semantic pipeline
5. **Conversational Interface**: Basic web search through MCP tools

### Phase 2: Enhanced Search (Multi-Source)
1. **Multiple Search Providers**: Bing and DuckDuckGo integration
2. **Advanced Content Extraction**: Better HTML parsing, metadata extraction
3. **Research Synthesis**: Combine multiple sources intelligently
4. **Performance Optimization**: Rate limiting, concurrent processing
5. **Error Handling**: Comprehensive error recovery and fallback strategies

### Phase 3: Specialized Research (Domain Expertise)
1. **News Research**: Time-sensitive information with credibility scoring
2. **Technical Research**: Academic and documentation source prioritization
3. **Advanced Analysis**: Trend detection, sentiment analysis, fact checking
4. **Source Validation**: Authority scoring and cross-reference validation
5. **Export Capabilities**: Research report generation and sharing

### Phase 4: Intelligence & Ethics (Production Ready)
1. **AI-Powered Analysis**: LLM-driven content analysis and insight generation
2. **Ethical Crawling**: Complete robots.txt compliance and respectful access
3. **Privacy Protection**: User data protection and anonymized research
4. **Performance Tuning**: Optimize for speed and resource usage
5. **Comprehensive Documentation**: User guides and developer documentation

## Success Criteria

### Functional Requirements
- Multi-source web search with intelligent result aggregation
- Clean content extraction from diverse web page formats
- Vector RAG integration for semantic content processing
- Conversational access to all research capabilities
- Comprehensive source attribution and credibility assessment

### Performance Requirements
- **Search Speed**: Return initial results within 10 seconds
- **Content Processing**: Process typical web pages within 5 seconds
- **Synthesis Quality**: Generate coherent insights from multiple sources
- **Rate Limiting**: Respect website resources and robots.txt guidelines

### Ethical Requirements
- **Source Attribution**: Always provide clear source citations
- **Robots.txt Compliance**: Respect website crawling preferences
- **Privacy Protection**: No tracking or personal data collection from web sources
- **Fact Verification**: Encourage source diversity and cross-reference validation

This comprehensive web research specification enables SAM to conduct sophisticated research across the web while maintaining ethical standards and integrating seamlessly with the existing conversational interface and Vector RAG capabilities.