// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

// MARK: - Google Search Provider

/// Google Custom Search API implementation Requires API key and Custom Search Engine ID configuration.
final class GoogleSearchProvider: SearchProvider, @unchecked Sendable {
    public let name = "Google"

    private let logger = Logger(label: "com.sam.web.GoogleSearch")
    private let apiKey: String
    private let searchEngineId: String
    private let baseURL = "https://www.googleapis.com/customsearch/v1"

    /// Use ephemeral URLSession to prevent keychain prompts.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    public var isAvailable: Bool {
        return !apiKey.isEmpty && !searchEngineId.isEmpty
    }

    public init() {
        /// Load from environment variables (no Keychain to avoid password prompts).
        self.apiKey = ProcessInfo.processInfo.environment["GOOGLE_SEARCH_API_KEY"] ?? ""
        self.searchEngineId = ProcessInfo.processInfo.environment["GOOGLE_SEARCH_ENGINE_ID"] ?? ""

        if !isAvailable {
            logger.warning("Google Search not available - missing API credentials")
        }
    }

    public func search(query: String, options: SearchOptions) async throws -> [SearchResult] {
        guard isAvailable else {
            throw WebResearchError.invalidConfiguration("Google Search API credentials not configured")
        }

        logger.debug("Performing Google search for: '\(query)'")

        let url = buildSearchURL(query: query, options: options)
        let response = try await performHTTPRequest(url: url)
        let results = try parseGoogleResults(response, searchEngine: name)

        logger.debug("Google search returned \(results.count) results for: '\(query)'")
        return results
    }

    public func searchNews(query: String, options: NewsSearchOptions) async throws -> [NewsResult] {
        guard isAvailable else {
            throw WebResearchError.invalidConfiguration("Google Search API credentials not configured")
        }

        logger.debug("Performing Google news search for: '\(query)'")

        /// Use Google News site restriction for news-specific results.
        let newsQuery = "site:news.google.com OR site:reuters.com OR site:bbc.com \(query)"
        let searchOptions = SearchOptions(
            maxResults: options.maxResults,
            dateRestriction: convertTimeRangeToDateRestriction(options.timeRange),
            language: options.language,
            safeSearch: .moderate
        )

        let searchResults = try await search(query: newsQuery, options: searchOptions)
        return convertSearchResultsToNews(searchResults)
    }

    public func searchImages(query: String, options: ImageSearchOptions) async throws -> [ImageResult] {
        guard isAvailable else {
            throw WebResearchError.invalidConfiguration("Google Search API credentials not configured")
        }

        logger.debug("Performing Google image search for: '\(query)'")

        let url = buildImageSearchURL(query: query, options: options)
        let response = try await performHTTPRequest(url: url)
        let results = try parseGoogleImageResults(response)

        logger.debug("Google image search returned \(results.count) results for: '\(query)'")
        return results
    }

    // MARK: - Helper Methods

    private func buildSearchURL(query: String, options: SearchOptions) -> URL {
        var components = URLComponents(string: baseURL)!

        var queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "cx", value: searchEngineId),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "num", value: String(min(options.maxResults, 10))),
            URLQueryItem(name: "safe", value: options.safeSearch.rawValue),
            URLQueryItem(name: "lr", value: "lang_\(options.language.rawValue)")
        ]

        if let dateRestriction = options.dateRestriction {
            queryItems.append(URLQueryItem(name: "dateRestrict", value: dateRestriction.rawValue))
        }

        components.queryItems = queryItems
        return components.url!
    }

    private func buildImageSearchURL(query: String, options: ImageSearchOptions) -> URL {
        var components = URLComponents(string: baseURL)!

        var queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "cx", value: searchEngineId),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "num", value: String(min(options.maxResults, 10))),
            URLQueryItem(name: "searchType", value: "image"),
            URLQueryItem(name: "safe", value: options.safeSearch.rawValue)
        ]

        if options.imageType != .any {
            queryItems.append(URLQueryItem(name: "imgType", value: options.imageType.rawValue))
        }

        if options.imageSize != .any {
            queryItems.append(URLQueryItem(name: "imgSize", value: options.imageSize.rawValue))
        }

        components.queryItems = queryItems
        return components.url!
    }

    private func performHTTPRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("SAM-Research/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30.0

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebResearchError.httpError(response)
        }

        guard 200...299 ~= httpResponse.statusCode else {
            logger.error("Google API error: \(httpResponse.statusCode)")
            throw WebResearchError.httpError(response)
        }

        return data
    }

    private func parseGoogleResults(_ data: Data, searchEngine: String) throws -> [SearchResult] {
        struct GoogleResponse: Codable {
            let items: [GoogleItem]?

            struct GoogleItem: Codable {
                let title: String
                let link: String
                let snippet: String
                let displayLink: String?
            }
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(GoogleResponse.self, from: data)

        return response.items?.compactMap { item in
            guard let url = URL(string: item.link) else { return nil }

            return SearchResult(
                title: item.title,
                url: url,
                snippet: item.snippet,
                relevanceScore: 1.0,
                searchEngine: searchEngine
            )
        } ?? []
    }

    private func parseGoogleImageResults(_ data: Data) throws -> [ImageResult] {
        struct GoogleImageResponse: Codable {
            let items: [GoogleImageItem]?

            struct GoogleImageItem: Codable {
                let title: String
                let link: String
                let image: ImageInfo

                struct ImageInfo: Codable {
                    let contextLink: String
                    let thumbnailLink: String
                    let width: Int
                    let height: Int
                    let byteSize: Int?
                }
            }
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(GoogleImageResponse.self, from: data)

        return response.items?.compactMap { item in
            guard let imageURL = URL(string: item.link),
                  let thumbnailURL = URL(string: item.image.thumbnailLink),
                  let sourceURL = URL(string: item.image.contextLink) else {
                return nil
            }

            return ImageResult(
                title: item.title,
                imageURL: imageURL,
                thumbnailURL: thumbnailURL,
                sourceURL: sourceURL,
                width: item.image.width,
                height: item.image.height,
                fileSize: item.image.byteSize
            )
        } ?? []
    }

    private func convertSearchResultsToNews(_ searchResults: [SearchResult]) -> [NewsResult] {
        return searchResults.map { result in
            NewsResult(
                title: result.title,
                url: result.url,
                summary: result.snippet,
                source: extractSourceFromURL(result.url),
                publishedAt: Date(),
                relevanceScore: result.relevanceScore
            )
        }
    }

    private func extractSourceFromURL(_ url: URL) -> String {
        return url.host?.replacingOccurrences(of: "www.", with: "") ?? "Unknown"
    }

    private func convertTimeRangeToDateRestriction(_ timeRange: TimeRange) -> DateRestriction? {
        switch timeRange {
        case .lastHour, .last24Hours: return .lastDay
        case .last7Days: return .lastWeek
        case .lastMonth: return .lastMonth
        case .lastYear: return .lastYear
        }
    }
}

// MARK: - Bing Search Provider

/// Microsoft Bing Web Search API implementation Requires Bing Search API subscription key.
final class BingSearchProvider: SearchProvider, @unchecked Sendable {
    public let name = "Bing"

    private let logger = Logger(label: "com.sam.web.BingSearch")
    private let apiKey: String
    private let baseURL = "https://api.bing.microsoft.com/v7.0"

    /// Use ephemeral URLSession to prevent keychain prompts.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    public var isAvailable: Bool {
        return !apiKey.isEmpty
    }

    public init() {
        /// Load from environment variables (no Keychain to avoid password prompts).
        self.apiKey = ProcessInfo.processInfo.environment["BING_SEARCH_API_KEY"] ?? ""

        if !isAvailable {
            logger.warning("Bing Search not available - missing API key")
        }
    }

    public func search(query: String, options: SearchOptions) async throws -> [SearchResult] {
        guard isAvailable else {
            throw WebResearchError.invalidConfiguration("Bing Search API key not configured")
        }

        logger.debug("Performing Bing search for: '\(query)'")

        let url = URL(string: "\(baseURL)/search")!
        let response = try await performBingRequest(url: url, query: query, options: options)
        let results = try parseBingResults(response, searchEngine: name)

        logger.debug("Bing search returned \(results.count) results for: '\(query)'")
        return results
    }

    public func searchNews(query: String, options: NewsSearchOptions) async throws -> [NewsResult] {
        guard isAvailable else {
            throw WebResearchError.invalidConfiguration("Bing Search API key not configured")
        }

        logger.debug("Performing Bing news search for: '\(query)'")

        let url = URL(string: "\(baseURL)/news/search")!
        let response = try await performBingNewsRequest(url: url, query: query, options: options)
        let results = try parseBingNewsResults(response)

        logger.debug("Bing news search returned \(results.count) results for: '\(query)'")
        return results
    }

    public func searchImages(query: String, options: ImageSearchOptions) async throws -> [ImageResult] {
        guard isAvailable else {
            throw WebResearchError.invalidConfiguration("Bing Search API key not configured")
        }

        logger.debug("Performing Bing image search for: '\(query)'")

        let url = URL(string: "\(baseURL)/images/search")!
        let response = try await performBingImageRequest(url: url, query: query, options: options)
        let results = try parseBingImageResults(response)

        logger.debug("Bing image search returned \(results.count) results for: '\(query)'")
        return results
    }

    // MARK: - Helper Methods

    private func performBingRequest(url: URL, query: String, options: SearchOptions) async throws -> Data {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!

        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(options.maxResults)),
            URLQueryItem(name: "safeSearch", value: options.safeSearch.rawValue),
            URLQueryItem(name: "mkt", value: "\(options.language.rawValue)-US")
        ]

        if let dateRestriction = options.dateRestriction {
            queryItems.append(URLQueryItem(name: "freshness", value: convertDateRestrictionToBingFreshness(dateRestriction)))
        }

        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("SAM-Research/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30.0

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            logger.error("Bing API error: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw WebResearchError.httpError(response)
        }

        return data
    }

    private func performBingNewsRequest(url: URL, query: String, options: NewsSearchOptions) async throws -> Data {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!

        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(options.maxResults)),
            URLQueryItem(name: "mkt", value: "\(options.language.rawValue)-US"),
            URLQueryItem(name: "sortBy", value: options.sortBy.rawValue),
            URLQueryItem(name: "freshness", value: convertTimeRangeToBingFreshness(options.timeRange))
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("SAM-Research/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30.0

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw WebResearchError.httpError(response)
        }

        return data
    }

    private func performBingImageRequest(url: URL, query: String, options: ImageSearchOptions) async throws -> Data {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!

        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(options.maxResults)),
            URLQueryItem(name: "safeSearch", value: options.safeSearch.rawValue)
        ]

        if options.imageType != .any {
            queryItems.append(URLQueryItem(name: "imageType", value: options.imageType.rawValue))
        }

        if options.imageSize != .any {
            queryItems.append(URLQueryItem(name: "size", value: options.imageSize.rawValue))
        }

        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("SAM-Research/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30.0

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw WebResearchError.httpError(response)
        }

        return data
    }

    private func parseBingResults(_ data: Data, searchEngine: String) throws -> [SearchResult] {
        struct BingResponse: Codable {
            let webPages: WebPages?

            struct WebPages: Codable {
                let value: [WebPage]

                struct WebPage: Codable {
                    let name: String
                    let url: String
                    let snippet: String
                    let displayUrl: String?
                }
            }
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(BingResponse.self, from: data)

        return response.webPages?.value.compactMap { page in
            guard let url = URL(string: page.url) else { return nil }

            return SearchResult(
                title: page.name,
                url: url,
                snippet: page.snippet,
                relevanceScore: 1.0,
                searchEngine: searchEngine
            )
        } ?? []
    }

    private func parseBingNewsResults(_ data: Data) throws -> [NewsResult] {
        struct BingNewsResponse: Codable {
            let value: [NewsArticle]

            struct NewsArticle: Codable {
                let name: String
                let url: String
                let description: String?
                let provider: [Provider]
                let datePublished: String?
                let image: Image?

                struct Provider: Codable {
                    let name: String
                }

                struct Image: Codable {
                    let thumbnail: Thumbnail?

                    struct Thumbnail: Codable {
                        let contentUrl: String
                    }
                }
            }
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(BingNewsResponse.self, from: data)

        let dateFormatter = ISO8601DateFormatter()

        return response.value.compactMap { article in
            guard let url = URL(string: article.url) else { return nil }

            let publishedAt: Date
            if let dateString = article.datePublished {
                publishedAt = dateFormatter.date(from: dateString) ?? Date()
            } else {
                publishedAt = Date()
            }

            let imageURL: URL?
            if let imageUrlString = article.image?.thumbnail?.contentUrl {
                imageURL = URL(string: imageUrlString)
            } else {
                imageURL = nil
            }

            return NewsResult(
                title: article.name,
                url: url,
                summary: article.description,
                source: article.provider.first?.name ?? "Unknown",
                publishedAt: publishedAt,
                imageURL: imageURL
            )
        }
    }

    private func parseBingImageResults(_ data: Data) throws -> [ImageResult] {
        struct BingImageResponse: Codable {
            let value: [Image]

            struct Image: Codable {
                let name: String
                let contentUrl: String
                let thumbnailUrl: String
                let hostPageUrl: String
                let width: Int
                let height: Int
                let contentSize: String?
                let encodingFormat: String?
            }
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(BingImageResponse.self, from: data)

        return response.value.compactMap { image in
            guard let imageURL = URL(string: image.contentUrl),
                  let thumbnailURL = URL(string: image.thumbnailUrl),
                  let sourceURL = URL(string: image.hostPageUrl) else {
                return nil
            }

            let fileSize: Int?
            if let sizeString = image.contentSize,
               let size = Int(sizeString.replacingOccurrences(of: " B", with: "")) {
                fileSize = size
            } else {
                fileSize = nil
            }

            return ImageResult(
                title: image.name,
                imageURL: imageURL,
                thumbnailURL: thumbnailURL,
                sourceURL: sourceURL,
                width: image.width,
                height: image.height,
                fileSize: fileSize,
                mimeType: image.encodingFormat
            )
        }
    }

    private func convertDateRestrictionToBingFreshness(_ restriction: DateRestriction) -> String {
        switch restriction {
        case .lastDay: return "Day"
        case .lastWeek: return "Week"
        case .lastMonth: return "Month"
        case .lastYear: return "Year"
        }
    }

    private func convertTimeRangeToBingFreshness(_ range: TimeRange) -> String {
        switch range {
        case .lastHour, .last24Hours: return "Day"
        case .last7Days: return "Week"
        case .lastMonth: return "Month"
        case .lastYear: return "Year"
        }
    }
}

// MARK: - DuckDuckGo Search Provider

/// DuckDuckGo Instant Answer API implementation Privacy-focused search with no API key required.
final class DuckDuckGoSearchProvider: SearchProvider, @unchecked Sendable {
    public let name = "DuckDuckGo"
    public let isAvailable = true

    private let logger = Logger(label: "com.sam.web.DuckDuckGoSearch")
    private let baseURL = "https://api.duckduckgo.com"

    /// Use ephemeral URLSession to prevent keychain prompts.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    public func search(query: String, options: SearchOptions) async throws -> [SearchResult] {
        logger.debug("Performing DuckDuckGo web scraping search for: '\(query)'")

        /// Use DuckDuckGo HTML search page scraping for actual web results.
        let searchURL = "https://html.duckduckgo.com/html/"

        var components = URLComponents(string: searchURL)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "s", value: "0")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30.0

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw WebResearchError.httpError(response)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw WebResearchError.invalidData("Unable to decode HTML response")
        }

        let results = try parseHTMLResults(html, searchEngine: name, maxResults: options.maxResults)
        logger.debug("DuckDuckGo web scraping returned \(results.count) results for: '\(query)'")

        return results
    }

    public func searchNews(query: String, options: NewsSearchOptions) async throws -> [NewsResult] {
        /// DuckDuckGo doesn't have a dedicated news API Fall back to regular search with news-related query modification.
        logger.debug("Performing DuckDuckGo news search for: '\(query)'")

        let newsQuery = "\(query) news"
        let searchOptions = SearchOptions(
            maxResults: options.maxResults,
            language: options.language,
            safeSearch: .moderate
        )

        let searchResults = try await search(query: newsQuery, options: searchOptions)
        return convertSearchResultsToNews(searchResults)
    }

    public func searchImages(query: String, options: ImageSearchOptions) async throws -> [ImageResult] {
        /// DuckDuckGo doesn't provide direct image search API access This is a placeholder implementation.
        logger.debug("DuckDuckGo image search not supported via public API")
        return []
    }

    // MARK: - Helper Methods

    private func parseDuckDuckGoResults(_ data: Data, searchEngine: String) throws -> [SearchResult] {
        struct DDGResponse: Codable {
            let Abstract: String?
            let AbstractURL: String?
            let AbstractSource: String?
            let RelatedTopics: [RelatedTopic]?
            let Results: [Result]?

            struct RelatedTopic: Codable {
                let Text: String?
                let FirstURL: String?
            }

            struct Result: Codable {
                let Text: String?
                let FirstURL: String?
            }
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(DDGResponse.self, from: data)

        var results: [SearchResult] = []

        /// Add abstract result if available.
        if let abstract = response.Abstract,
           !abstract.isEmpty,
           let urlString = response.AbstractURL,
           let url = URL(string: urlString) {

            results.append(SearchResult(
                title: response.AbstractSource ?? "DuckDuckGo Abstract",
                url: url,
                snippet: abstract,
                relevanceScore: 1.0,
                searchEngine: searchEngine
            ))
        }

        /// Add related topics.
        if let relatedTopics = response.RelatedTopics {
            for topic in relatedTopics {
                if let text = topic.Text,
                   let urlString = topic.FirstURL,
                   let url = URL(string: urlString) {

                    let title = extractTitleFromText(text)
                    let snippet = extractSnippetFromText(text)

                    results.append(SearchResult(
                        title: title,
                        url: url,
                        snippet: snippet,
                        relevanceScore: 0.8,
                        searchEngine: searchEngine
                    ))
                }
            }
        }

        /// Add direct results.
        if let directResults = response.Results {
            for result in directResults {
                if let text = result.Text,
                   let urlString = result.FirstURL,
                   let url = URL(string: urlString) {

                    let title = extractTitleFromText(text)
                    let snippet = extractSnippetFromText(text)

                    results.append(SearchResult(
                        title: title,
                        url: url,
                        snippet: snippet,
                        relevanceScore: 0.9,
                        searchEngine: searchEngine
                    ))
                }
            }
        }

        return results
    }

    private func extractTitleFromText(_ text: String) -> String {
        /// DuckDuckGo format often has title at beginning before " - ".
        if let separatorRange = text.range(of: " - ") {
            return String(text[..<separatorRange.lowerBound])
        }

        /// Fallback: use first 60 characters.
        return String(text.prefix(60))
    }

    private func extractSnippetFromText(_ text: String) -> String {
        /// Remove HTML tags and clean up text.
        let cleanText = text
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        /// Return up to 200 characters.
        return String(cleanText.prefix(200))
    }

    private func convertSearchResultsToNews(_ searchResults: [SearchResult]) -> [NewsResult] {
        return searchResults.map { result in
            NewsResult(
                title: result.title,
                url: result.url,
                summary: result.snippet,
                source: extractSourceFromURL(result.url),
                publishedAt: Date(),
                relevanceScore: result.relevanceScore
            )
        }
    }

    private func extractSourceFromURL(_ url: URL) -> String {
        return url.host?.replacingOccurrences(of: "www.", with: "") ?? "Unknown"
    }
}

// MARK: - Rate Limiting

/// Rate limiter to respect website resources and API limits.
public class RateLimiter {
    private var lastRequests: [String: Date] = [:]
    private let minimumInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.sam.web.ratelimiter", attributes: .concurrent)

    public init(minimumInterval: TimeInterval = 1.0) {
        self.minimumInterval = minimumInterval
    }

    public func canMakeRequest(to host: String) -> Bool {
        var canRequest = false
        var shouldUpdate = false

        /// First check if we can make the request (read-only operation).
        queue.sync {
            let now = Date()

            if let lastRequest = lastRequests[host] {
                let timeSinceLastRequest = now.timeIntervalSince(lastRequest)
                canRequest = timeSinceLastRequest >= minimumInterval
                shouldUpdate = canRequest
            } else {
                canRequest = true
                shouldUpdate = true
            }
        }

        /// If we can request, update the timestamp with a barrier (write operation).
        if shouldUpdate {
            queue.async(flags: .barrier) { [weak self] in
                self?.lastRequests[host] = Date()
            }
        }

        return canRequest
    }

    public func waitForNextAllowedRequest(to host: String) async {
        while !canMakeRequest(to: host) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

// MARK: - Helper Methods
extension DuckDuckGoSearchProvider {

    private func parseHTMLResults(_ html: String, searchEngine: String, maxResults: Int) throws -> [SearchResult] {
        var results: [SearchResult] = []

        /// Parse DuckDuckGo HTML search results using basic string parsing.
        let lines = html.components(separatedBy: .newlines)

        var i = 0
        while i < lines.count && results.count < maxResults {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)

            /// Look for result links - DuckDuckGo uses specific patterns.
            if line.contains("result__a") && line.contains("href=") {
                if let url = extractURLFromHref(line),
                   let title = extractTitleFromResultLine(line) {

                    /// Look for snippet in following lines.
                    let snippet = extractSnippetFromFollowingLines(lines, startingAt: i)

                    results.append(SearchResult(
                        title: title,
                        url: url,
                        snippet: snippet,
                        relevanceScore: Double(maxResults - results.count) / Double(maxResults),
                        searchEngine: searchEngine
                    ))
                }
            }
            i += 1
        }

        return results
    }

    private func extractURLFromHref(_ line: String) -> URL? {
        /// Extract URL from href="/url?q=..." pattern.
        guard let hrefStart = line.range(of: "href=\"")?.upperBound,
              let hrefEnd = line[hrefStart...].range(of: "\"")?.lowerBound else {
            return nil
        }

        var hrefValue = String(line[hrefStart..<hrefEnd])

        /// Handle protocol-relative URLs (//example.com).
        if hrefValue.hasPrefix("//") {
            hrefValue = "https:" + hrefValue
        }

        /// Handle DuckDuckGo redirect URLs.
        if hrefValue.contains("uddg=") {
            /// Parse the actual URL from DuckDuckGo's redirect parameter Format: //duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com&...
            guard let urlStart = hrefValue.range(of: "uddg=")?.upperBound else { return nil }
            let remainder = String(hrefValue[urlStart...])
            /// Extract just the encoded URL (stop at & if present).
            let encodedURL: String
            if let ampIndex = remainder.firstIndex(of: "&") {
                encodedURL = String(remainder[..<ampIndex])
            } else {
                encodedURL = remainder
            }
            guard let decodedURL = encodedURL.removingPercentEncoding else { return nil }
            return URL(string: decodedURL)
        }

        return URL(string: hrefValue)
    }

    private func extractTitleFromResultLine(_ line: String) -> String? {
        /// Extract title from the link text.
        guard let titleStart = line.range(of: ">")?.upperBound,
              let titleEnd = line[titleStart...].range(of: "</a>")?.lowerBound else {
            return nil
        }

        let title = String(line[titleStart..<titleEnd])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return title.isEmpty ? nil : title
    }

    private func extractSnippetFromFollowingLines(_ lines: [String], startingAt index: Int) -> String {
        /// Look for snippet in the next few lines.
        let maxLookAhead = 5
        var snippet = ""

        for i in (index + 1)..<min(index + maxLookAhead, lines.count) {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)

            if line.contains("result__snippet") || line.contains("description") {
                /// Extract text content.
                let cleanLine = line
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !cleanLine.isEmpty && cleanLine.count > 20 {
                    snippet = String(cleanLine.prefix(200))
                    break
                }
            }
        }

        return snippet.isEmpty ? "No description available" : snippet
    }
}
