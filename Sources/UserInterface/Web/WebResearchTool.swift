// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import MCPFramework
import Logging

/// MCP tool for web research capabilities Provides conversational access to comprehensive web research functionality.
public class WebResearchTool: MCPTool, @unchecked Sendable {
    public let name = "web_research"
    public let description = "Conduct comprehensive web research on any topic with multi-source search, content extraction, and intelligent synthesis"

    private let webResearchService: WebResearchService
    private let logger = Logger(label: "com.sam.mcp.WebResearch")

    public var parameters: [String: MCPToolParameter] {
        [
            "query": MCPToolParameter(
                type: .string,
                description: "The research query or question you want to investigate. Be specific and clear. Example: 'climate change impact on coastal cities', 'latest developments in quantum computing', 'Orlando FL news today'. This parameter uses 'query' for consistency with other web tools.",
                required: true
            ),
            "depth": MCPToolParameter(
                type: .string,
                description: "How thorough the research should be. Options: 'shallow' (quick overview, 3-5 sources), 'standard' (balanced research, 10-15 sources), 'comprehensive' (deep analysis, 20+ sources). Default: 'standard'. Example: 'standard'",
                required: false,
                enumValues: ["shallow", "standard", "comprehensive"]
            ),
            "type": MCPToolParameter(
                type: .string,
                description: "Type of research to conduct. Options: 'general' (broad overview), 'news' (current events and recent developments), 'technical' (documentation and technical details). Default: 'general'. Example: 'news'",
                required: false,
                enumValues: ["general", "news", "technical"]
            )
        ]
    }

    public init(webResearchService: WebResearchService) {
        self.webResearchService = webResearchService
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        logger.debug("Executing web research tool")

        /// FIXED: Use 'query' to match schema (same as fetch_webpage pattern).
        guard let query = parameters["query"] as? String else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: """
                    ERROR: Missing 'query' parameter

                    Required parameter: query (string, describes what you want to research)
                    Example: {"query": "climate change impact on coastal cities"}

                    You provided: \(parameters["query"] ?? "nothing")

                    TIP: This tool uses 'query' parameter (same as fetch_webpage tool)
                    """, mimeType: "text/plain"),
                toolName: name
            )
        }

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: """
                    ERROR: Parameter 'query' cannot be empty

                    The query parameter must contain a clear research question or topic.
                    Example: "latest developments in quantum computing", "Orlando FL news today"

                    You provided: "\(query)" (empty or whitespace only)

                    TIP: Be specific about what you want to research.
                    """, mimeType: "text/plain"),
                toolName: name
            )
        }

        /// Validate webResearchService is properly configured Check if service has necessary configuration (API keys, endpoints, etc.) This prevents cryptic errors during execution.
        let validationError = validateWebResearchConfiguration()
        if let error = validationError {
            logger.warning("Web research configuration invalid: \(error)")
            return MCPToolResult(
                success: false,
                output: MCPOutput(
                    content: """
                    Web research tool not properly configured: \(error)

                    This tool requires:
                    - Search API configuration (API key, endpoint)
                    - Network connectivity
                    - Valid API credentials

                    Please check preferences or contact administrator.
                    """,
                    mimeType: "text/plain"
                ),
                toolName: name
            )
        }

        let depthString = parameters["depth"] as? String ?? "standard"
        let typeString = parameters["type"] as? String ?? "general"

        guard let depth = ResearchDepth(rawValue: depthString) else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Invalid depth parameter. Must be 'shallow', 'standard', or 'comprehensive'", mimeType: "text/plain"),
                toolName: name
            )
        }

        guard let researchType = ResearchType(rawValue: typeString) else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Invalid type parameter. Must be 'general', 'news', or 'technical'", mimeType: "text/plain"),
                toolName: name
            )
        }

        logger.debug("Research request: query='\(query)', depth=\(depth.rawValue), type=\(researchType.rawValue)")

        do {
            switch researchType {
            case .general:
                /// Use conversationId for conversation-scoped RAG ingestion This allows research content to be indexed in conversation memory With chunking fixes (minChunkSize 200), RAG should work properly.
                let report = try await webResearchService.conductResearch(
                    on: query,
                    depth: depth,
                    conversationId: context.conversationId
                )

                /// Check if report has meaningful data.
                if report.sources.isEmpty {
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(
                            content: """
                            No research data found for query: "\(query)"

                            This usually means:
                            - Search providers (Google, Bing) require API keys that aren't configured
                            - DuckDuckGo search may have rate limits or connection issues
                            - The query may be too specific or have no web results

                            RECOMMENDATION: Use 'web_operations' tool with operation='fetch' to scrape specific URLs directly.
                            Example: {"operation": "fetch", "url": "https://example.com"}
                            """,
                            mimeType: "text/plain"
                        ),
                        toolName: name
                    )
                }

                let resultData = formatGeneralResearchResult(report)
                let jsonData = try JSONSerialization.data(withJSONObject: resultData, options: .prettyPrinted)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
                return MCPToolResult(
                    success: true,
                    output: MCPOutput(content: jsonString, mimeType: "application/json"),
                    toolName: name
                )

            case .news:
                let newsReport = try await webResearchService.researchCurrentEvents(topic: query)

                /// Check if news report has meaningful data.
                if newsReport.sources.isEmpty && newsReport.newsResults.isEmpty {
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(
                            content: """
                            No news data found for query: "\(query)"

                            This usually means:
                            - Search providers (Google, Bing) require API keys that aren't configured
                            - DuckDuckGo search may have rate limits or connection issues
                            - No recent news found for this query

                            RECOMMENDATION: Use 'web_operations' tool with operation='fetch' to scrape specific news websites directly.
                            """,
                            mimeType: "text/plain"
                        ),
                        toolName: name
                    )
                }

                let resultData = formatNewsResearchResult(newsReport)
                let jsonData = try JSONSerialization.data(withJSONObject: resultData, options: .prettyPrinted)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
                return MCPToolResult(
                    success: true,
                    output: MCPOutput(content: jsonString, mimeType: "application/json"),
                    toolName: name
                )

            case .technical:
                let techReport = try await webResearchService.researchTechnicalTopic(topic: query)

                /// Check if technical report has meaningful data.
                if techReport.sources.isEmpty {
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(
                            content: """
                            No technical research data found for query: "\(query)"

                            This usually means:
                            - Search providers (Google, Bing) require API keys that aren't configured
                            - DuckDuckGo search may have rate limits or connection issues
                            - The query may not have technical documentation available

                            RECOMMENDATION: Use 'web_operations' tool with operation='fetch' to scrape specific technical documentation sites directly.
                            """,
                            mimeType: "text/plain"
                        ),
                        toolName: name
                    )
                }

                let resultData = formatTechnicalResearchResult(techReport)
                let jsonData = try JSONSerialization.data(withJSONObject: resultData, options: .prettyPrinted)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
                return MCPToolResult(
                    success: true,
                    output: MCPOutput(content: jsonString, mimeType: "application/json"),
                    toolName: name
                )
            }
        } catch {
            logger.error("Web research failed: \(error)")
            /// Provide more specific error message based on error type.
            let errorMessage: String
            if error.localizedDescription.contains("API") || error.localizedDescription.contains("key") {
                errorMessage = """
                Research failed: Search provider API keys not configured

                The web_research tool requires API keys for Google and Bing search providers.
                Currently only DuckDuckGo is available (no API key required).

                RECOMMENDATION: Use 'web_operations' tool with operation='fetch' to scrape specific URLs directly instead.
                This is more reliable and doesn't require API keys.

                Technical details: \(error.localizedDescription)
                """
            } else if error.localizedDescription.contains("network") || error.localizedDescription.contains("connection") {
                errorMessage = """
                Research failed: Network connectivity issue

                Unable to connect to search providers.

                RECOMMENDATION: Try again, or use 'web_operations' tool with operation='fetch' to scrape specific URLs directly.

                Technical details: \(error.localizedDescription)
                """
            } else {
                errorMessage = """
                Research failed: \(error.localizedDescription)

                RECOMMENDATION: Use 'web_operations' tool with operation='fetch' to scrape specific URLs directly.
                This is more reliable for targeted information retrieval.
                """
            }

            return MCPToolResult(
                success: false,
                output: MCPOutput(content: errorMessage, mimeType: "text/plain"),
                toolName: name
            )
        }
    }

    // MARK: - Configuration Validation

    /// Validates that web research service is properly configured Returns error message if configuration is invalid, nil if valid.
    private func validateWebResearchConfiguration() -> String? {
        /// Check if webResearchService has required configuration This is a placeholder - actual implementation would check: - API keys are set - Endpoints are configured - Service is properly initialized.

        /// For now, we assume service is valid if it exists Real implementation would call webResearchService.isConfigured() or similar.
        return nil
    }

    // MARK: - Result Formatting

    private func formatGeneralResearchResult(_ report: ResearchReport) -> [String: Any] {
        var result: [String: Any] = [
            "type": "general_research",
            "topic": report.topic,
            "conducted_at": ISO8601DateFormatter().string(from: report.conductedAt),
            "source_count": report.sources.count,
            "confidence": report.synthesis.confidence,
            "research_depth": report.researchDepth.rawValue
        ]

        /// Format key findings.
        let findings = report.synthesis.keyFindings.map { finding in
            [
                "title": finding.title,
                "summary": finding.summary,
                "confidence": finding.confidence,
                "evidence_count": finding.evidence.count,
                "source_count": finding.supportingSources.count
            ]
        }
        result["key_findings"] = findings

        /// Format sources.
        let sources = report.sources.prefix(10).map { source in
            [
                "title": source.title,
                "url": source.url.absoluteString,
                "credibility_score": source.credibilityScore
            ]
        }
        result["top_sources"] = sources

        /// Create research summary.
        let summary = generateResearchSummary(from: report)
        result["summary"] = summary

        return result
    }

    private func formatNewsResearchResult(_ report: NewsResearchReport) -> [String: Any] {
        var result: [String: Any] = [
            "type": "news_research",
            "topic": report.topic,
            "conducted_at": ISO8601DateFormatter().string(from: report.conductedAt),
            "article_count": report.newsResults.count,
            "source_count": report.sources.count
        ]

        /// Format timeline.
        let timeline = report.timeline.prefix(10).map { event in
            [
                "date": ISO8601DateFormatter().string(from: event.date),
                "title": event.title,
                "description": event.description,
                "source": event.source,
                "url": event.url.absoluteString
            ]
        }
        result["timeline"] = timeline

        /// Format key developments.
        let developments = report.keyDevelopments.prefix(5).map { development in
            [
                "title": development.title,
                "summary": development.summary,
                "importance": development.importance,
                "source": development.source,
                "date": ISO8601DateFormatter().string(from: development.date)
            ]
        }
        result["key_developments"] = developments

        /// Format news sources.
        let newsSources = report.sources.prefix(10).map { source in
            [
                "name": source.name,
                "article_count": source.articleCount,
                "credibility_score": source.credibilityScore,
                "latest_article": ISO8601DateFormatter().string(from: source.latestArticle)
            ]
        }
        result["news_sources"] = newsSources

        /// Create news summary.
        let summary = generateNewsSummary(from: report)
        result["summary"] = summary

        return result
    }

    private func formatTechnicalResearchResult(_ report: TechnicalResearchReport) -> [String: Any] {
        var result: [String: Any] = [
            "type": "technical_research",
            "topic": report.topic,
            "conducted_at": ISO8601DateFormatter().string(from: report.conductedAt),
            "authority_score": report.authorityScore,
            "source_count": report.sources.count
        ]

        /// Format technical concepts.
        let concepts = report.concepts.prefix(10).map { concept in
            [
                "name": concept.name,
                "description": concept.description,
                "category": concept.category.rawValue,
                "frequency": concept.frequency
            ]
        }
        result["technical_concepts"] = concepts

        /// Format documentation links.
        let documentation = report.documentation.prefix(10).map { doc in
            [
                "title": doc.title,
                "url": doc.url.absoluteString,
                "type": doc.type.rawValue,
                "quality": doc.quality
            ]
        }
        result["documentation"] = documentation

        /// Format related topics.
        result["related_topics"] = Array(report.relatedTopics.prefix(10))

        /// Format sources.
        let sources = report.sources.prefix(10).map { source in
            [
                "title": source.title,
                "url": source.url.absoluteString,
                "credibility_score": source.credibilityScore
            ]
        }
        result["technical_sources"] = sources

        /// Create technical summary.
        let summary = generateTechnicalSummary(from: report)
        result["summary"] = summary

        return result
    }

    // MARK: - Summary Generation

    private func generateResearchSummary(from report: ResearchReport) -> String {
        var summary = "## Research Summary: \(report.topic)\n\n"

        summary += "**Sources Analyzed:** \(report.sources.count) sources with \(String(format: "%.1f", report.synthesis.confidence * 100))% confidence\n\n"

        /// Key findings.
        if !report.synthesis.keyFindings.isEmpty {
            summary += "**Key Findings:**\n\n"

            for (index, finding) in report.synthesis.keyFindings.prefix(5).enumerated() {
                summary += "\(index + 1). **\(finding.title)** (Confidence: \(String(format: "%.1f", finding.confidence * 100))%)\n"
                summary += "   \(finding.summary)\n\n"
            }
        }

        /// Top sources.
        if !report.sources.isEmpty {
            summary += "**Primary Sources:**\n\n"

            for source in report.sources.prefix(5) {
                summary += "- [\(source.title)](\(source.url.absoluteString))\n"
            }
            summary += "\n"
        }

        summary += "*Research conducted on \(DateFormatter.localizedString(from: report.conductedAt, dateStyle: .medium, timeStyle: .short)) using \(report.researchDepth.rawValue) depth analysis.*"

        return summary
    }

    private func generateNewsSummary(from report: NewsResearchReport) -> String {
        var summary = "## News Research: \(report.topic)\n\n"

        summary += "**Coverage:** \(report.newsResults.count) articles from \(report.sources.count) news sources\n\n"

        /// Recent developments.
        if !report.keyDevelopments.isEmpty {
            summary += "**Recent Developments:**\n\n"

            for development in report.keyDevelopments.prefix(5) {
                let dateString = DateFormatter.localizedString(from: development.date, dateStyle: .short, timeStyle: .none)
                summary += "- **\(dateString)**: \(development.title)\n"
                summary += "  \(development.summary)\n\n"
            }
        }

        /// Timeline highlights.
        if !report.timeline.isEmpty {
            summary += "**Recent Timeline:**\n\n"

            for event in report.timeline.prefix(3) {
                let dateString = DateFormatter.localizedString(from: event.date, dateStyle: .short, timeStyle: .none)
                summary += "- **\(dateString)**: [\(event.title)](\(event.url.absoluteString)) - \(event.source)\n"
            }
            summary += "\n"
        }

        /// Top news sources.
        if !report.sources.isEmpty {
            summary += "**News Sources:**\n\n"

            for source in report.sources.prefix(5) {
                summary += "- \(source.name) (\(source.articleCount) articles)\n"
            }
            summary += "\n"
        }

        summary += "*News research conducted on \(DateFormatter.localizedString(from: report.conductedAt, dateStyle: .medium, timeStyle: .short))*"

        return summary
    }

    private func generateTechnicalSummary(from report: TechnicalResearchReport) -> String {
        var summary = "## Technical Research: \(report.topic)\n\n"

        summary += "**Authority Score:** \(String(format: "%.1f", report.authorityScore * 100))% based on \(report.sources.count) technical sources\n\n"

        /// Key concepts.
        if !report.concepts.isEmpty {
            summary += "**Key Technical Concepts:**\n\n"

            for concept in report.concepts.prefix(5) {
                summary += "- **\(concept.name)** (\(concept.category.rawValue)): \(concept.description)\n"
            }
            summary += "\n"
        }

        /// Documentation.
        if !report.documentation.isEmpty {
            summary += "**Technical Documentation:**\n\n"

            for doc in report.documentation.prefix(5) {
                summary += "- [\(doc.title)](\(doc.url.absoluteString)) (\(doc.type.rawValue))\n"
            }
            summary += "\n"
        }

        /// Related topics.
        if !report.relatedTopics.isEmpty {
            summary += "**Related Topics:** \(report.relatedTopics.prefix(5).joined(separator: ", "))\n\n"
        }

        summary += "*Technical research conducted on \(DateFormatter.localizedString(from: report.conductedAt, dateStyle: .medium, timeStyle: .short))*"

        return summary
    }
}

/// Quick web search tool for simple queries.
public class WebSearchTool: MCPTool, @unchecked Sendable {
    public let name = "web_search"
    public let description = "Perform a quick web search and return top results"

    private let webResearchService: WebResearchService
    private let logger = Logger(label: "com.sam.mcp.WebSearch")

    public var parameters: [String: MCPToolParameter] {
        [
            "query": MCPToolParameter(
                type: .string,
                description: "Your search query - what you want to find on the web. Be specific for best results. Example: 'Python asyncio tutorial', 'best Italian restaurants Chicago', 'weather forecast Orlando'. This returns a list of web pages matching your query.",
                required: true
            ),
            "max_results": MCPToolParameter(
                type: .integer,
                description: "Maximum number of search results to return. Typical values: 5 (quick check), 10 (standard), 20 (comprehensive). Default: 10. Example: 10",
                required: false
            )
        ]
    }

    public init(webResearchService: WebResearchService) {
        self.webResearchService = webResearchService
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        logger.debug("Executing web search tool")

        guard let query = parameters["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Required parameter 'query' is missing or empty", mimeType: "text/plain"),
                toolName: name
            )
        }

        let maxResults = parameters["max_results"] as? Int ?? 10

        logger.debug("Search request: query='\(query)', max_results=\(maxResults)")

        do {
            /// For simple web search, just get search results without full research synthesis.
            let searchResults = try await webResearchService.performSimpleSearch(query: query, maxResults: maxResults)

            let results = searchResults.map { result in
                [
                    "title": result.title,
                    "url": result.url.absoluteString,
                    "snippet": result.snippet,
                    "source": result.searchEngine
                ]
            }

            let resultData: [String: Any] = [
                "type": "web_search",
                "query": query,
                "result_count": results.count,
                "results": results
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: resultData, options: .prettyPrinted)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            return MCPToolResult(
                success: true,
                output: MCPOutput(content: jsonString, mimeType: "application/json"),
                toolName: name
            )

        } catch {
            logger.error("Web search failed: \(error)")
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Search failed: \(error.localizedDescription)", mimeType: "text/plain"),
                toolName: name
            )
        }
    }
}
