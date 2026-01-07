// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import MCPFramework
import ConversationEngine
import ConfigurationSystem
import Logging

/// Consolidated Web Operations MCP Tool Combines web_research, web_search, and fetch_webpage into a single tool.
public class WebOperationsTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "web_operations"
    public let description = """
    Web research, search, scraping, and content retrieval.

    OPERATIONS (pass via 'operation' parameter):
    • research - Comprehensive multi-source research with synthesis (general/news/technical)
    • retrieve - Access previously stored research from memory
    • web_search - Quick web search for top results
    • serpapi - Professional search via SerpAPI (Google, Bing, Amazon, etc.) [if enabled]
    • scrape - Extract content from websites (WebKit rendering with JavaScript support)
    • fetch - Retrieve main content from webpage (basic HTTP, faster than scrape)

    WORKFLOW:
    1. Use research for comprehensive investigation with automatic synthesis
    2. Use web_search to find relevant URLs for targeted content
    3. Use fetch or scrape to extract content from specific URLs
    4. Use retrieve to ACCESS previously stored research from memory

    WHEN TO USE:
    - Current events, news, live information
    - Documentation lookup
    - Shopping/product research (use serpapi with engine=amazon/ebay/walmart)

    WHEN NOT TO USE:
    - Information already in context
    - Questions answerable from conversation history
    - Local file content (use file_operations)

    KEY PARAMETERS:
    • operation: REQUIRED - operation type (see above)
    • query: Search query (retrieve/web_search/serpapi)
    • url: Target URL (scrape/fetch) - MUST use HTTPS protocol
    • engine: Search engine (serpapi) - google/bing/amazon/ebay/walmart/tripadvisor/yelp
    • location: Search location (serpapi, optional)

    IMPORTANT: All URLs must use HTTPS (not HTTP) for security. HTTP URLs will be automatically converted to HTTPS.

    EXAMPLES:
    SUCCESS: {"operation": "web_search", "query": "Orlando FL news today"}
    SUCCESS: {"operation": "fetch", "url": "https://www.orlandosentinel.com/article/12345"}
    SUCCESS: {"operation": "retrieve", "query": "Orlando news"}
    SUCCESS: {"operation": "serpapi", "query": "best laptops 2025", "engine": "amazon"}
    SUCCESS: {"operation": "scrape", "url": "https://example.com"}
    """

    public var supportedOperations: [String] {
        var operations = [
            "research",
            "retrieve",
            "web_search",
            "scrape",
            "fetch"
        ]

        /// Only advertise serpapi operation if it's enabled and hasn't reached limit This prevents the LLM from trying to use it when it's not available.
        if isSerpAPIAvailable() {
            operations.append("serpapi")
        }

        return operations
    }

    public var parameters: [String: MCPToolParameter] {
        var baseParams: [String: MCPToolParameter] = [
            "operation": MCPToolParameter(
                type: .string,
                description: "Operation to perform",
                required: true,
                enumValues: isSerpAPIAvailable() ?
                    ["research", "retrieve", "web_search", "serpapi", "scrape", "fetch"] :
                    ["research", "retrieve", "web_search", "scrape", "fetch"]
            ),

            /// Research/search parameters.
            "query": MCPToolParameter(
                type: .string,
                description: "Search query or research question",
                required: false
            ),

            /// Scraping parameters.
            "url": MCPToolParameter(
                type: .string,
                description: "URL to scrape or fetch (for scrape/fetch operations - REQUIRED for these operations). Must use HTTPS protocol. HTTP URLs will be automatically converted to HTTPS.",
                required: false
            ),
            "selectors": MCPToolParameter(
                type: .object(properties: [:]),
                description: "CSS selectors for structured extraction (for scrape operation)",
                required: false
            )
        ]

        /// Add SerpAPI parameters only if it's available.
        if isSerpAPIAvailable() {
            baseParams["engine"] = MCPToolParameter(
                type: .string,
                description: "Search engine for serpapi operation: google, bing, amazon, ebay, walmart, tripadvisor, yelp",
                required: false,
                enumValues: ["google", "bing", "amazon", "ebay", "walmart", "tripadvisor", "yelp"]
            )
            baseParams["location"] = MCPToolParameter(
                type: .string,
                description: "Search location for serpapi (optional, e.g., 'New York, NY')",
                required: false
            )
        }

        return baseParams
    }

    private let logger = Logger(label: "com.sam.mcp.WebOperations")

    /// OPERATION DEDUPLICATION: Prevent AI from running identical operations multiple times.
    /// Pattern copied from RunInTerminalTool to fix redundant web_operations calls.
    private struct OperationCacheEntry {
        let operation: String
        let parameters: String  // Serialized parameters for cache key
        let result: MCPToolResult
        let timestamp: Date
    }
    nonisolated(unsafe) private static var operationCache: [String: OperationCacheEntry] = [:]
    private static let cacheWindow: TimeInterval = 30.0

    /// Delegate tools for operations.
    private var webResearchTool: WebResearchTool
    private var webSearchTool: WebSearchTool
    nonisolated(unsafe) private let serpAPIService = SerpAPIService()
    /// Note: FetchWebpageTool is in MCPFramework module, will be accessible.

    /// Content extractor for intelligent HTML parsing.
    private let contentExtractor = WebContentExtractor()

    /// Memory manager for 'retrieve' operation.
    private weak var memoryManagerAdapter: MemoryManagerProtocol?

    /// Tool result storage for large outputs.
    private let storage: ToolResultStorage

    public init(webResearchService: WebResearchService, memoryManager: MemoryManagerProtocol? = nil, storage: ToolResultStorage? = nil) {
        self.webResearchTool = WebResearchTool(webResearchService: webResearchService)
        self.webSearchTool = WebSearchTool(webResearchService: webResearchService)
        self.memoryManagerAdapter = memoryManager
        self.storage = storage ?? ToolResultStorage()
        logger.debug("WebOperationsTool initialized (consolidated: web_research + web_search + fetch_webpage + retrieve + serpapi)")

        /// Register with ToolDisplayInfoRegistry for proper progress indicators.
        ToolDisplayInfoRegistry.shared.register("web_operations", provider: WebOperationsTool.self)
    }

    // MARK: - SerpAPI Availability Check

    /// Check if SerpAPI is enabled and available (not at limit) This determines whether the serpapi operation is presented to the LLM.
    private func isSerpAPIAvailable() -> Bool {
        return serpAPIService.isEnabled()
    }

    // MARK: - Large Result Persistence

    /// Persist large tool result to disk and return formatted response **Purpose**: Prevents provider 400 errors by storing large outputs to disk instead of sending them inline in API requests.
    private func persistLargeResult(
        content: String,
        toolCallId: String,
        context: MCPExecutionContext,
        operation: String
    ) -> String {
        /// Estimate tokens in content.
        let estimatedTokens = TokenEstimator.estimateTokens(content)

        /// ALWAYS persist web operation results to prevent 400 errors Agent uses read_tool_result to access the data.
        guard let conversationId = context.conversationId else {
            logger.warning("\(operation): No conversation ID, cannot persist result (\(estimatedTokens) tokens) - returning truncated")
            /// Without conversation ID, cannot persist. Return truncated version to prevent 400 errors.
            let truncated = TokenEstimator.truncate(content, toTokenLimit: ToolResultStorage.previewTokenLimit)
            logger.info("\(operation): Truncated to \(TokenEstimator.estimateTokens(truncated)) tokens due to missing conversation ID")
            return truncated
        }

        /// Use processToolResult for consistent formatting with preview
        let processedResult = storage.processToolResult(
            toolCallId: toolCallId,
            content: content,
            conversationId: conversationId
        )

        logger.info("\(operation): Persisted result to disk (\(estimatedTokens) tokens)")
        return processedResult
    }

    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        logger.debug("WebOperationsTool routing to operation: \(operation)")

        /// DEDUPLICATION: Check if this exact operation was recently executed.
        /// Create cache key from operation + parameters (sorted to handle order variance)
        let sortedParams = parameters.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        let cacheKey = "\(operation):\(sortedParams)"

        /// Check cache (no lock needed - nonisolated(unsafe) dictionary access)
        let cachedResult = Self.operationCache[cacheKey]

        if let cached = cachedResult {
            let age = Date().timeIntervalSince(cached.timestamp)
            if age < Self.cacheWindow {
                logger.warning("DEDUPLICATION: Identical web_operations call executed \(String(format: "%.1f", age))s ago - returning cached result")
                logger.warning("DEDUPLICATION: Operation: \(operation), Parameters: \(sortedParams)")
                return cached.result
            } else {
                /// Cache expired, remove it.
                Self.operationCache.removeValue(forKey: cacheKey)
            }
        }

        /// Validate parameters before routing.
        if let validationError = validateParameters(operation: operation, parameters: parameters) {
            return validationError
        }

        switch operation {
        case "research":
            let result = await handleResearch(parameters: parameters, context: context)
            cacheResult(cacheKey: cacheKey, operation: operation, parameters: sortedParams, result: result)
            return result

        case "retrieve":
            let result = await handleRetrieve(parameters: parameters, context: context)
            cacheResult(cacheKey: cacheKey, operation: operation, parameters: sortedParams, result: result)
            return result

        case "web_search":
            let result = await handleSearch(parameters: parameters, context: context)
            cacheResult(cacheKey: cacheKey, operation: operation, parameters: sortedParams, result: result)
            return result

        case "serpapi":
            let result = await handleSerpAPI(parameters: parameters, context: context)
            cacheResult(cacheKey: cacheKey, operation: operation, parameters: sortedParams, result: result)
            return result

        case "scrape":
            let result = await handleScrape(parameters: parameters, context: context)
            cacheResult(cacheKey: cacheKey, operation: operation, parameters: sortedParams, result: result)
            return result

        case "fetch":
            let result = await handleFetch(parameters: parameters, context: context)
            cacheResult(cacheKey: cacheKey, operation: operation, parameters: sortedParams, result: result)
            return result

        default:
            return operationError(operation, message: "Unknown operation")
        }
    }

    /// Cache successful operation result to prevent redundant calls.
    private func cacheResult(cacheKey: String, operation: String, parameters: String, result: MCPToolResult) {
        /// Only cache successful results.
        guard result.success else {
            logger.debug("DEDUPLICATION: Not caching failed result for \(operation)")
            return
        }

        /// Store in cache (no lock needed - nonisolated(unsafe) dictionary access)
        Self.operationCache[cacheKey] = OperationCacheEntry(
            operation: operation,
            parameters: parameters,
            result: result,
            timestamp: Date()
        )

        logger.debug("DEDUPLICATION: Cached result for \(operation) (expires in \(Int(Self.cacheWindow))s)")
    }

    // MARK: - Parameter Validation

    private func validateParameters(operation: String, parameters: [String: Any]) -> MCPToolResult? {
        switch operation {
        case "research", "retrieve", "web_search", "serpapi":
            guard parameters["query"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'query'.

                    Usage: {
                        "operation": "\(operation)",
                        "query": "your search query here"
                    }

                    Example: {"operation": "\(operation)", "query": "Orlando FL headlines today"}
                    """)
            }

        case "scrape", "fetch":
            guard parameters["url"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'url'.

                    Usage: {
                        "operation": "\(operation)",
                        "url": "https://example.com"
                    }

                    Example: {"operation": "fetch", "url": "https://www.orlandosentinel.com"}

                    Note: URLs must use HTTPS protocol (not HTTP) for security.
                    """)
            }

        default:
            break
        }

        return nil
    }

    // MARK: - Helper Methods

    /// Ensures URL uses HTTPS protocol.
    private func ensureHTTPS(_ urlString: String) -> String {
        var url = urlString.trimmingCharacters(in: .whitespaces)

        /// If URL starts with http:// (not https://), convert to https://.
        if url.lowercased().hasPrefix("http://") {
            url = "https://" + url.dropFirst("http://".count)
            logger.info("Converted HTTP URL to HTTPS: \(urlString) -> \(url)")
        }
        /// If no protocol specified, add https://.
        else if !url.lowercased().hasPrefix("https://") && !url.lowercased().hasPrefix("http://") {
            url = "https://\(url)"
            logger.info("Added HTTPS protocol to URL: \(urlString) -> \(url)")
        }

        return url
    }

    /// Fast HTTP fetch with timeout (no JavaScript rendering)
    private func fetchWithTimeout(url: URL, timeout: TimeInterval) async throws -> (String, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)

        /// Create request fully before task group to avoid mutable capture
        var requestBuilder = URLRequest(url: url)
        requestBuilder.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        requestBuilder.timeoutInterval = timeout
        let request = requestBuilder  /// Make immutable for capture

        /// Execute fetch with timeout enforcement via Task
        return try await withThrowingTaskGroup(of: (String, HTTPURLResponse).self) { group in
            group.addTask { @Sendable in
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw WebOperationsError.invalidResponse
                }

                guard 200...299 ~= httpResponse.statusCode else {
                    throw WebOperationsError.httpError(statusCode: httpResponse.statusCode)
                }

                guard let html = String(data: data, encoding: .utf8) else {
                    throw WebOperationsError.decodingFailed
                }

                return (html, httpResponse)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebOperationsError.timeout(operation: "fetch", seconds: timeout)
            }

            /// Return first result (either success or timeout)
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Heuristic to detect if page needs JavaScript rendering
    nonisolated private func needsJavaScript(content: String) -> Bool {
        let lowercased = content.lowercased()

        /// Check for extremely short body (likely placeholder)
        if content.count < 200 {
            logger.debug("Detected minimal content (\(content.count) chars) - likely needs JS")
            return true
        }

        /// Check for empty or near-empty body tags
        if lowercased.contains("<body></body>") || lowercased.contains("<body />") {
            logger.debug("Detected empty body tag - needs JS")
            return true
        }

        /// Check for noscript tag suggesting JS-required content
        if lowercased.contains("<noscript>") {
            logger.debug("Detected noscript tag - likely needs JS")
            return true
        }

        /// Check for common SPA framework markers
        let spaMarkers = [
            "id=\"app\"",
            "id=\"root\"",
            "id='app'",
            "id='root'",
            "__next_data__",
            "window.__initial_state__",
            "<script type=\"module\"",
            "react",
            "vue",
            "angular"
        ]

        for marker in spaMarkers {
            if lowercased.contains(marker.lowercased()) {
                logger.debug("Detected SPA marker '\(marker)' - may need JS")
                /// Don't immediately return true for framework names alone
                /// Only if combined with minimal actual content
                if marker.contains("react") || marker.contains("vue") || marker.contains("angular") {
                    /// Check if there's actual text content
                    let bodyStart = lowercased.range(of: "<body")
                    let bodyEnd = lowercased.range(of: "</body>")
                    if let start = bodyStart?.upperBound, let end = bodyEnd?.lowerBound {
                        let bodyContent = String(lowercased[start..<end])
                        /// Remove tags and check actual text
                        let textOnly = bodyContent.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        if textOnly.trimmingCharacters(in: .whitespacesAndNewlines).count < 100 {
                            logger.debug("Framework detected with minimal text - needs JS")
                            return true
                        }
                    }
                } else {
                    return true
                }
            }
        }

        /// If we have substantial content, probably doesn't need JS
        return false
    }

    /// WebKit scraping with timeout enforcement
    /// Simplified to avoid Swift region isolation checker bug
    @MainActor
    private func scrapeWithTimeout(url: URL, timeout: TimeInterval) async throws -> String {
        let scraper = WebKitScraper()
        return try await scraper.scrape(url: url.absoluteString, waitSeconds: timeout - 1.0)
    }

    // MARK: - Research Operation

    @MainActor
    private func handleResearch(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// Collect progress events for nested tool hierarchy.
        var progressEvents: [MCPProgressEvent] = []

        /// Emit event when research operation starts.
        if let query = parameters["query"] as? String {
            progressEvents.append(MCPProgressEvent(
                eventType: .toolStarted,
                toolName: "research_query",
                parentToolName: "web_operations",
                display: ToolDisplayData(
                    action: "researching",
                    actionDisplayName: "Web Search",
                    summary: "Searching: \(query)",
                    status: .running,
                    icon: "magnifyingglass",
                    metadata: ["query": query]
                ),
                status: "running",
                message: "SUCCESS: Researching: \(query)...",
                details: [query]
            ))
        }

        /// Delegate to WebResearchTool implementation.
        let result = await webResearchTool.execute(parameters: parameters, context: context)

        /// Return full result inline (no persistence) Large results are handled by provider-level context limits.
        return MCPToolResult(
            toolName: result.toolName,
            executionId: result.executionId,
            success: result.success,
            output: result.output,
            metadata: result.metadata,
            performance: result.performance,
            progressEvents: progressEvents + result.progressEvents
        )
    }

    // MARK: - Retrieve Operation

    @MainActor
    private func handleRetrieve(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// Retrieve stored research results from memory using semantic search This delegates to memory_operations.search_memory internally.

        guard let query = parameters["query"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "Missing required parameter: query"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }

        guard let memoryManager = memoryManagerAdapter else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "Memory manager not available. Cannot retrieve stored research."
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }

        logger.debug("Retrieving stored research from memory: \(query)")

        do {
            /// Search memory with reasonable similarity threshold (0.3 works well for research results).
            let memories = try await memoryManager.searchMemories(
                query: query,
                limit: 20,
                similarityThreshold: 0.3,
                conversationId: context.conversationId
            )

            if memories.isEmpty {
                let emptyMessage = """
                {
                    "query": "\(query)",
                    "results_count": 0,
                    "message": "No stored research found for query: '\(query)'",
                    "recommendation": "Use operation='research' first to scrape web and store results, then use operation='retrieve' to access them."
                }
                """

                return MCPToolResult(
                    toolName: name,
                    success: true,
                    output: MCPOutput(content: emptyMessage, mimeType: "application/json")
                )
            }

            /// Format memories into readable output.
            var resultLines: [String] = []
            resultLines.append("RETRIEVED RESEARCH RESULTS:")
            resultLines.append("")
            resultLines.append("Query: \(query)")
            resultLines.append("Results found: \(memories.count)")
            resultLines.append("")

            for (index, memory) in memories.enumerated() {
                let relevance = memory.relevanceScore ?? 0.0
                resultLines.append("\(index + 1). [\(String(format: "%.0f%%", relevance * 100))] \(memory.content)")
                if !memory.context.isEmpty {
                    resultLines.append("   Context: \(memory.context)")
                }
                if !memory.tags.isEmpty {
                    resultLines.append("   Tags: \(memory.tags.joined(separator: ", "))")
                }
                resultLines.append("")
            }

            logger.debug("Retrieved \(memories.count) research results from memory")

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: resultLines.joined(separator: "\n"), mimeType: "text/plain")
            )

        } catch {
            logger.error("Failed to retrieve from memory: \(error.localizedDescription)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "Memory search failed: \(error.localizedDescription)"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }
    }

    // MARK: - Search Operation

    @MainActor
    private func handleSearch(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// Delegate to WebSearchTool implementation.
        let result = await webSearchTool.execute(parameters: parameters, context: context)

        /// Return full result inline (no persistence).
        return MCPToolResult(
            toolName: result.toolName,
            executionId: result.executionId,
            success: result.success,
            output: result.output,
            metadata: result.metadata,
            performance: result.performance,
            progressEvents: result.progressEvents
        )
    }

    // MARK: - SerpAPI Operation

    @MainActor
    private func handleSerpAPI(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let query = parameters["query"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "Missing required parameter: query"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }

        /// Check if SerpAPI is actually available (double-check at execution time).
        guard serpAPIService.isEnabled() else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "SerpAPI is not enabled. Enable it in Preferences."
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }

        /// Check if limit has been reached.
        if await serpAPIService.hasReachedLimit() {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "SerpAPI monthly search limit reached. Service temporarily unavailable."
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }

        /// Parse engine parameter.
        let engineString = parameters["engine"] as? String ?? "google"
        guard let engine = SerpAPIService.SearchEngine(rawValue: engineString) else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "Invalid engine '\(engineString)'. Valid engines: google, bing, amazon, ebay, walmart, tripadvisor, yelp"
                    }
                    """,
                    mimeType: "application/json"
                )
            )
        }

        /// Parse optional parameters.
        var location = parameters["location"] as? String
        let numResults = parameters["num_results"] as? Int ?? 10

        /// Auto-fill location from user preferences for Yelp if not provided
        if engine == .yelp && location == nil {
            if let userLocation = LocationManager.shared.getEffectiveLocation() {
                location = userLocation
                logger.info("Auto-filled Yelp location from user preferences: \(userLocation)")
            }
        }

        logger.info("SerpAPI search: query='\(query)', engine=\(engine.displayName)")

        /// Collect progress events.
        var progressEvents: [MCPProgressEvent] = []

        progressEvents.append(MCPProgressEvent(
            eventType: .toolStarted,
            toolName: name,
            display: ToolDisplayData(
                action: "searching",
                actionDisplayName: "Web Search",
                summary: "Searching \(engine.displayName) for '\(query)'",
                status: .running,
                icon: "magnifyingglass",
                metadata: ["query": query, "engine": engine.displayName]
            ),
            message: "Searching \(engine.displayName) for '\(query)'...",
            details: [query, engine.displayName]
        ))

        do {
            let result = try await serpAPIService.search(
                query: query,
                engine: engine,
                location: location,
                numResults: numResults
            )

            /// Report completion.
            progressEvents.append(MCPProgressEvent(
                eventType: .toolCompleted,
                toolName: name,
                display: ToolDisplayData(
                    action: "searching",
                    actionDisplayName: "Web Search",
                    summary: "Found \(result.items.count) results from \(engine.displayName)",
                    status: .success,
                    icon: "magnifyingglass",
                    metadata: ["resultCount": String(result.items.count), "engine": engine.displayName]
                ),
                message: "Found \(result.items.count) results from \(engine.displayName)",
                details: [String(result.items.count), engine.displayName]
            ))

            /// Format results as markdown.
            let markdown = result.toMarkdown()

            /// Return full result inline (no persistence).
            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(
                    content: markdown,
                    mimeType: "text/markdown"
                ),
                metadata: MCPResultMetadata(
                    additionalContext: [
                        "engine": engine.displayName,
                        "query": query,
                        "resultCount": String(result.items.count)
                    ]
                ),
                progressEvents: progressEvents
            )
        } catch {
            let errorMessage = error.localizedDescription
            logger.error("SerpAPI search failed: \(errorMessage)")

            /// Report error.
            progressEvents.append(MCPProgressEvent(
                eventType: .toolCompleted,
                toolName: name,
                display: ToolDisplayData(
                    action: "searching",
                    actionDisplayName: "Web Search",
                    summary: "Search failed: \(errorMessage)",
                    status: .error,
                    icon: "magnifyingglass"
                ),
                message: "Search failed: \(errorMessage)",
                details: [errorMessage]
            ))

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(
                    content: """
                    {
                        "error": true,
                        "message": "SerpAPI search failed: \(errorMessage)"
                    }
                    """,
                    mimeType: "application/json"
                ),
                progressEvents: progressEvents
            )
        }
    }

    // MARK: - Scrape Operation

    @MainActor
    private func handleScrape(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let urlString = parameters["url"] as? String else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "ERROR: Missing required parameter 'url'", mimeType: "text/plain"),
                toolName: "web_operations"
            )
        }

        let httpsURL = ensureHTTPS(urlString)

        guard let url = URL(string: httpsURL) else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "ERROR: Invalid URL: \(httpsURL)", mimeType: "text/plain"),
                toolName: "web_operations"
            )
        }

        logger.info("Scraping URL with fetch-first strategy: \(httpsURL)")

        var fetchError: Error?
        var scrapeError: Error?

        /// STRATEGY 1: Try fast HTTP fetch first (5s timeout)
        do {
            logger.debug("Attempting fast fetch (5s timeout)...")
            let (html, response) = try await fetchWithTimeout(url: url, timeout: 5.0)

            /// Check if content needs JavaScript rendering
            if needsJavaScript(content: html) {
                logger.info("Fast fetch succeeded but content needs JavaScript - falling back to scrape")
                /// Store the fetch result but continue to scrape
                fetchError = WebOperationsError.javascriptRequired
            } else {
                logger.info("Fast fetch succeeded with static content - using result")

                /// Extract clean content from HTML
                let extractedContent = extractCleanContent(from: html, sourceURL: url)

                /// Build output
                let output = """
                    SUCCESS: Fetched: \(httpsURL) (fast HTTP, no JS needed)

                    Title: \(extractedContent.title)
                    Content Size: \(extractedContent.text.count) characters (cleaned from \(html.count) HTML)

                    === EXTRACTED CONTENT ===
                    \(extractedContent.text)

                    === METADATA ===
                    \(formatMetadata(extractedContent.metadata))
                    """

                /// Persist large results
                let sizeThreshold = 50 * 1024  // 50KB
                if output.count > sizeThreshold {
                    logger.info("Fetch result exceeds \(sizeThreshold) bytes, persisting to disk")
                    let persistedOutput = persistLargeResult(
                        content: output,
                        toolCallId: context.toolCallId ?? UUID().uuidString,
                        context: context,
                        operation: "scrape"
                    )

                    return MCPToolResult(
                        toolName: "web_operations",
                        success: true,
                        output: MCPOutput(content: persistedOutput, mimeType: "text/plain"),
                        metadata: MCPResultMetadata(
                            additionalContext: [
                                "operation": "scrape",
                                "service": "FastFetch",
                                "url": httpsURL,
                                "contentLength": "\(extractedContent.text.count)",
                                "persisted": "true"
                            ]
                        )
                    )
                }

                return MCPToolResult(
                    toolName: "web_operations",
                    success: true,
                    output: MCPOutput(content: output, mimeType: "text/plain"),
                    metadata: MCPResultMetadata(
                        additionalContext: [
                            "operation": "scrape",
                            "service": "FastFetch",
                            "url": httpsURL,
                            "contentLength": "\(extractedContent.text.count)"
                        ]
                    )
                )
            }
        } catch {
            logger.info("Fast fetch failed: \(error.localizedDescription)")
            fetchError = error
        }

        /// STRATEGY 2: Fall back to WebKit scraping (10s timeout)
        do {
            logger.info("Falling back to WebKit scraping (10s timeout)...")

            let html = try await Task { @MainActor in
                try await scrapeWithTimeout(url: url, timeout: 10.0)
            }.value

            logger.info("WebKit scraping succeeded - extracting content")

            /// Extract clean content from HTML
            let extractedContent = extractCleanContent(from: html, sourceURL: url)

            /// Build output
            let output = """
                SUCCESS: Scraped: \(httpsURL) (WebKit with JavaScript rendering)

                Title: \(extractedContent.title)
                Content Size: \(extractedContent.text.count) characters (cleaned from \(html.count) HTML)

                === EXTRACTED CONTENT ===
                \(extractedContent.text)

                === METADATA ===
                \(formatMetadata(extractedContent.metadata))
                """

            /// Persist large results
            let sizeThreshold = 50 * 1024  // 50KB
            if output.count > sizeThreshold {
                logger.info("Scrape result exceeds \(sizeThreshold) bytes, persisting to disk")
                let persistedOutput = persistLargeResult(
                    content: output,
                    toolCallId: context.toolCallId ?? UUID().uuidString,
                    context: context,
                    operation: "scrape"
                )

                return MCPToolResult(
                    toolName: "web_operations",
                    success: true,
                    output: MCPOutput(content: persistedOutput, mimeType: "text/plain"),
                    metadata: MCPResultMetadata(
                        additionalContext: [
                            "operation": "scrape",
                            "service": "WebKit + ContentExtractor",
                            "url": httpsURL,
                            "rawHTMLLength": "\(html.count)",
                            "cleanContentLength": "\(extractedContent.text.count)",
                            "persisted": "true"
                        ]
                    )
                )
            }

            return MCPToolResult(
                toolName: "web_operations",
                success: true,
                output: MCPOutput(content: output, mimeType: "text/plain"),
                metadata: MCPResultMetadata(
                    additionalContext: [
                        "operation": "scrape",
                        "service": "WebKit + ContentExtractor",
                        "url": httpsURL,
                        "rawHTMLLength": "\(html.count)",
                        "cleanContentLength": "\(extractedContent.text.count)"
                    ]
                )
            )

        } catch {
            logger.error("WebKit scraping failed: \(error.localizedDescription)")
            scrapeError = error
        }

        /// BOTH STRATEGIES FAILED - Return structured error
        let errorOutput = """
            ERROR: Failed to scrape \(httpsURL)

            Both fetch and scrape strategies failed:

            1. Fast Fetch (5s timeout): \(fetchError?.localizedDescription ?? "Unknown error")
            2. WebKit Scrape (10s timeout): \(scrapeError?.localizedDescription ?? "Unknown error")

            Possible causes:
            - Site requires authentication
            - Aggressive bot protection (Cloudflare, etc.)
            - Network connectivity issues
            - Site is down or unreachable

            Recommendation: Try a different URL or check if the site requires login.
            """

        return MCPToolResult(
            toolName: "web_operations",
            success: false,
            output: MCPOutput(content: errorOutput, mimeType: "text/plain"),
            metadata: MCPResultMetadata(
                additionalContext: [
                    "operation": "scrape",
                    "url": httpsURL,
                    "fetchError": fetchError?.localizedDescription ?? "none",
                    "scrapeError": scrapeError?.localizedDescription ?? "none",
                    "fetchTimedOut": (fetchError as? WebOperationsError)?.isTimeout ?? false ? "true" : "false",
                    "scrapeTimedOut": (scrapeError as? WebOperationsError)?.isTimeout ?? false ? "true" : "false"
                ]
            )
        )
    }

    // MARK: - Content Extraction Helpers

    /// Extract clean content from HTML using HTMLContentParser.
    /// Removes scripts, nav, ads, and extracts meaningful text.
    private func extractCleanContent(from html: String, sourceURL: URL) -> ExtractedContent {
        let parser = HTMLContentParser()

        return ExtractedContent(
            title: parser.extractTitle(from: html),
            text: parser.extractMainText(from: html),
            headings: parser.extractHeadings(from: html),
            links: parser.extractLinks(from: html, baseURL: sourceURL),
            metadata: parser.extractMetadata(from: html)
        )
    }

    /// Format metadata dictionary for display.
    private func formatMetadata(_ metadata: [String: String]) -> String {
        guard !metadata.isEmpty else {
            return "No metadata found"
        }

        var formatted: [String] = []

        /// Prioritize important metadata fields.
        let priorityKeys = ["description", "og:description", "keywords", "author", "og:image"]

        for key in priorityKeys {
            if let value = metadata[key] {
                formatted.append("\(key): \(value)")
            }
        }

        /// Add remaining metadata (limit to prevent overwhelming output).
        let remainingKeys = metadata.keys.filter { !priorityKeys.contains($0) }
        for key in remainingKeys.prefix(5) {
            if let value = metadata[key] {
                formatted.append("\(key): \(value)")
            }
        }

        return formatted.isEmpty ? "No metadata found" : formatted.joined(separator: "\n")
    }

    // MARK: - Fetch Operation

    @MainActor
    private func handleFetch(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// Transform 'url' (singular) to 'urls' (array) for FetchWebpageTool WebOperationsTool validates/accepts 'url', but FetchWebpageTool requires 'urls' array.
        var fetchParameters = parameters

        if let urlString = parameters["url"] as? String {
            /// Ensure URL uses HTTPS.
            let httpsURL = ensureHTTPS(urlString)

            /// Convert singular url to array for FetchWebpageTool.
            fetchParameters["urls"] = [httpsURL]
            fetchParameters.removeValue(forKey: "url")

            logger.debug("Transformed url parameter to urls array for FetchWebpageTool (HTTPS enforced)")
        }

        /// FetchWebpageTool also requires 'query' parameter for context If not provided, use a generic query.
        if fetchParameters["query"] == nil {
            fetchParameters["query"] = "fetch webpage content"
            logger.debug("Added default query parameter for FetchWebpageTool")
        }

        /// Create FetchWebpageTool instance for this operation (FetchWebpageTool is in MCPFramework module).
        let fetchTool = FetchWebpageTool()
        let result = await fetchTool.execute(parameters: fetchParameters, context: context)

        /// Return full result inline (no persistence).
        return MCPToolResult(
            toolName: result.toolName,
            executionId: result.executionId,
            success: result.success,
            output: result.output,
            metadata: result.metadata,
            performance: result.performance,
            progressEvents: result.progressEvents
        )
    }
}

// MARK: - Protocol Conformance

extension WebOperationsTool: ToolDisplayInfoProvider {
    public static func extractDisplayInfo(from arguments: [String: Any]) -> String? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        switch operation.lowercased().replacingOccurrences(of: "_", with: "") {
        case "research":
            if let query = arguments["query"] as? String {
                return "Researching: \(query)"
            }
            return "Researching"

        case "retrieve":
            if let query = arguments["query"] as? String {
                return "Retrieving research: \(query)"
            }
            return "Retrieving research"

        case "websearch":
            if let query = arguments["query"] as? String {
                return "Searching web: \(query)"
            }
            return "Searching web"

        case "scrape":
            if let url = arguments["url"] as? String {
                /// Extract domain for display.
                if let urlObj = URL(string: url), let host = urlObj.host {
                    return "Scraping: \(host)"
                }
                return "Scraping: \(url)"
            }
            return "Scraping webpage"

        case "fetch":
            if let urls = arguments["urls"] as? [String] {
                if urls.count == 1, let url = urls.first {
                    if let urlObj = URL(string: url), let host = urlObj.host {
                        return "Fetching: \(host)"
                    }
                    return "Fetching webpage"
                } else if urls.count > 1 {
                    /// Show first few URLs.
                    let hosts = urls.prefix(3).compactMap { urlStr -> String? in
                        guard let url = URL(string: urlStr), let host = url.host else { return nil }
                        return host
                    }
                    let remaining = urls.count - hosts.count
                    let hostList = hosts.joined(separator: ", ")
                    if remaining > 0 {
                        return "Fetching: \(hostList), +\(remaining) more"
                    } else {
                        return "Fetching: \(hostList)"
                    }
                }
            }
            return "Fetching webpages"

        default:
            return nil
        }
    }

    public static func extractToolDetails(from arguments: [String: Any]) -> [String]? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        let normalizedOp = operation.lowercased().replacingOccurrences(of: "_", with: "")
        var details: [String] = []

        switch normalizedOp {
        case "research":
            if let query = arguments["query"] as? String {
                details.append("Query: \(query)")
            }
            if let engine = arguments["engine"] as? String {
                details.append("Engine: \(engine)")
            }
            return details.isEmpty ? nil : details

        case "retrieve":
            if let query = arguments["query"] as? String {
                details.append("Query: \(query)")
            }
            return details.isEmpty ? nil : details

        case "websearch":
            if let query = arguments["query"] as? String {
                details.append("Query: \(query)")
            }
            if let engine = arguments["engine"] as? String {
                details.append("Engine: \(engine)")
            }
            if let numResults = arguments["num_results"] as? Int {
                details.append("Results: \(numResults)")
            }
            return details.isEmpty ? nil : details

        case "scrape":
            if let url = arguments["url"] as? String {
                if let urlObj = URL(string: url) {
                    if let host = urlObj.host {
                        details.append("Domain: \(host)")
                    }
                    let path = urlObj.path
                    if !path.isEmpty && path != "/" {
                        let preview = path.count > 40 ? String(path.prefix(37)) + "..." : path
                        details.append("Path: \(preview)")
                    }
                } else {
                    let preview = url.count > 50 ? String(url.prefix(47)) + "..." : url
                    details.append("URL: \(preview)")
                }
            }
            return details.isEmpty ? nil : details

        case "fetch":
            if let urls = arguments["urls"] as? [String] {
                details.append("Pages: \(urls.count)")
                /// Show first 2 URLs.
                for url in urls.prefix(2) {
                    if let urlObj = URL(string: url), let host = urlObj.host {
                        details.append("• \(host)")
                    }
                }
                if urls.count > 2 {
                    details.append("• ... and \(urls.count - 2) more")
                }
            }
            return details.isEmpty ? nil : details

        default:
            return nil
        }
    }
}

// MARK: - Error Types

/// Web operations specific errors with timeout tracking
enum WebOperationsError: LocalizedError {
    case timeout(operation: String, seconds: TimeInterval)
    case httpError(statusCode: Int)
    case invalidResponse
    case decodingFailed
    case javascriptRequired

    var errorDescription: String? {
        switch self {
        case .timeout(let operation, let seconds):
            return "\(operation) timed out after \(seconds)s"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .decodingFailed:
            return "Failed to decode content"
        case .javascriptRequired:
            return "Content requires JavaScript rendering"
        }
    }

    var isTimeout: Bool {
        if case .timeout = self {
            return true
        }
        return false
    }
}
