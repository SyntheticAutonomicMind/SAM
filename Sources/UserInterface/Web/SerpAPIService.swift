// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

// MARK: - Data Models (defined first for proper type references)

public struct SerpAPISearchResult {
    public let query: [String: Any]
    public let engine: SerpAPIService.SearchEngine
    public let items: [Item]
    public let rawJSON: [String: Any]

    public struct Item {
        public let title: String
        public let link: String
        public let snippet: String?
        public let source: String
    }

    /// Format results as markdown for LLM consumption.
    public func toMarkdown() -> String {
        var markdown = "# Search Results (\(engine.displayName))\n\n"

        for (index, item) in items.enumerated() {
            markdown += "## \(index + 1). \(item.title)\n"
            markdown += "**Source:** \(item.source)\n"
            if !item.link.isEmpty {
                markdown += "**URL:** \(item.link)\n"
            }
            if let snippet = item.snippet {
                markdown += "\n\(snippet)\n"
            }
            markdown += "\n---\n\n"
        }

        return markdown
    }
}

/// SerpAPI service for web search integration Supports: Google Search, AI Overview, Bing, Amazon, Ebay, Walmart, TripAdvisor, Yelp.
public class SerpAPIService {
    private let logger = Logger(label: "com.syntheticautonomicmind.sam.SerpAPI")
    private let baseURL = "https://serpapi.com"

    /// Use ephemeral URLSession with timeout to prevent infinite hangs
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    /// Account information from SerpAPI Account API.
    public struct AccountInfo: Codable {
        public let apiKey: String
        public let accountEmail: String?
        public let planId: String?
        public let planName: String?
        public let searches: SearchesInfo?
        public let accountRateLimitPerMonth: Int?

        public struct SearchesInfo: Codable {
            public let thisMonth: Int?
            public let thisMonthLimit: Int?
            public let total: Int?

            enum CodingKeys: String, CodingKey {
                case thisMonth = "this_month"
                case thisMonthLimit = "this_month_limit"
                case total
            }
        }

        enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
            case accountEmail = "account_email"
            case planId = "plan_id"
            case planName = "plan_name"
            case searches
            case accountRateLimitPerMonth = "account_rate_limit_per_hour"
        }
    }

    /// Search engine types supported by SerpAPI.
    public enum SearchEngine: String, CaseIterable {
        case google = "google"
        case googleAIOverview = "google_ai_overview"
        case bing = "bing"
        case amazon = "amazon"
        case ebay = "ebay"
        case walmart = "walmart"
        case tripadvisor = "tripadvisor"
        case yelp = "yelp"

        public var displayName: String {
            switch self {
            case .google: return "Google Search"
            case .googleAIOverview: return "Google AI Overview"
            case .bing: return "Bing Search"
            case .amazon: return "Amazon Search"
            case .ebay: return "Ebay Search"
            case .walmart: return "Walmart Search"
            case .tripadvisor: return "TripAdvisor Search"
            case .yelp: return "Yelp Search"
            }
        }

        public var icon: String {
            switch self {
            case .google: return "magnifyingglass"
            case .googleAIOverview: return "brain"
            case .bing: return "globe"
            case .amazon: return "cart"
            case .ebay: return "tag"
            case .walmart: return "bag"
            case .tripadvisor: return "airplane"
            case .yelp: return "fork.knife"
            }
        }
    }

    public init() {}

    // MARK: - Public API

    /// Check if SerpAPI is enabled and configured.
    public func isEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: "serpAPIEnabled")
    }

    /// Get configured API key.
    private func getAPIKey() -> String? {
        return UserDefaults.standard.string(forKey: "serpAPIKey")
    }

    /// Check account information and usage limits.
    public func getAccountInfo() async throws -> AccountInfo {
        guard let apiKey = getAPIKey(), !apiKey.isEmpty else {
            throw SerpAPIError.missingAPIKey
        }

        var components = URLComponents(string: "\(baseURL)/account")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]

        guard let url = components.url else {
            throw SerpAPIError.invalidRequest
        }

        logger.debug("Fetching SerpAPI account info")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SerpAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw SerpAPIError.invalidAPIKey
            }
            throw SerpAPIError.apiError(statusCode: httpResponse.statusCode)
        }

        let accountInfo = try JSONDecoder().decode(AccountInfo.self, from: data)
        logger.info("SerpAPI account: \(accountInfo.accountEmail ?? "unknown"), plan: \(accountInfo.planName ?? "unknown")")

        return accountInfo
    }

    /// Check if account has reached usage limit.
    public func hasReachedLimit() async -> Bool {
        do {
            let accountInfo = try await getAccountInfo()

            /// Check monthly limit.
            if let searches = accountInfo.searches,
               let thisMonth = searches.thisMonth,
               let limit = searches.thisMonthLimit {
                let remaining = limit - thisMonth
                logger.debug("SerpAPI usage: \(thisMonth)/\(limit) this month (\(remaining) remaining)")

                if remaining <= 0 {
                    logger.warning("SerpAPI monthly limit reached: \(thisMonth)/\(limit)")
                    return true
                }
            }

            return false
        } catch {
            logger.error("Failed to check SerpAPI limit: \(error)")
            /// If we can't check the limit, assume we've reached it for safety.
            return true
        }
    }

    /// Perform a search using specified engine.
    public func search(
        query: String,
        engine: SearchEngine = .google,
        location: String? = nil,
        numResults: Int = 10
    ) async throws -> SerpAPISearchResult {
        guard isEnabled() else {
            throw SerpAPIError.serviceDisabled
        }

        guard let apiKey = getAPIKey(), !apiKey.isEmpty else {
            throw SerpAPIError.missingAPIKey
        }

        /// Check if limit reached.
        if await hasReachedLimit() {
            throw SerpAPIError.limitReached
        }

        /// Build request.
        var components = URLComponents(string: "\(baseURL)/search")!

        /// Engine-specific query parameter names.
        let queryParamName: String
        switch engine {
        case .ebay:
            queryParamName = "_nkw"
        case .walmart, .amazon:
            queryParamName = "query"
        default:
            queryParamName = "q"
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "engine", value: engine.rawValue),
            URLQueryItem(name: queryParamName, value: query),
            URLQueryItem(name: "api_key", value: apiKey)
        ]

        /// Add num parameter only for engines that support it (not eBay).
        if engine != .ebay {
            queryItems.append(URLQueryItem(name: "num", value: "\(numResults)"))
        }

        if let location = location {
            queryItems.append(URLQueryItem(name: "location", value: location))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw SerpAPIError.invalidRequest
        }

        logger.info("SerpAPI search: engine=\(engine.displayName), query=\"\(query)\"")
        logger.info("SerpAPI request URL: \(url.absoluteString.replacingOccurrences(of: apiKey, with: "***API_KEY***"))")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SerpAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            /// Log error response body for debugging.
            if let errorBody = String(data: data, encoding: .utf8) {
                logger.error("SerpAPI error response (\(httpResponse.statusCode)): \(errorBody)")
            }

            if httpResponse.statusCode == 401 {
                throw SerpAPIError.invalidAPIKey
            } else if httpResponse.statusCode == 429 {
                throw SerpAPIError.rateLimited
            }
            throw SerpAPIError.apiError(statusCode: httpResponse.statusCode)
        }

        /// Parse response based on engine.
        let result = try parseSearchResult(data: data, engine: engine)
        logger.info("SerpAPI returned \(result.items.count) results")

        return result
    }

    // MARK: - Response Parsing

    private func parseSearchResult(data: Data, engine: SearchEngine) throws -> SerpAPISearchResult {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let json = json else {
            throw SerpAPIError.parseError
        }

        var items: [SerpAPISearchResult.Item] = []

        switch engine {
        case .google, .bing:
            /// Parse organic results.
            if let organicResults = json["organic_results"] as? [[String: Any]] {
                for result in organicResults {
                    if let title = result["title"] as? String,
                       let link = result["link"] as? String {
                        let snippet = result["snippet"] as? String
                        items.append(SerpAPISearchResult.Item(
                            title: title,
                            link: link,
                            snippet: snippet,
                            source: engine.displayName
                        ))
                    }
                }
            }

        case .googleAIOverview:
            /// Parse AI overview.
            if let aiOverview = json["ai_overview"] as? [String: Any],
               let text = aiOverview["text"] as? String {
                items.append(SerpAPISearchResult.Item(
                    title: "AI Overview",
                    link: "",
                    snippet: text,
                    source: "Google AI"
                ))
            }

            /// Also include organic results.
            if let organicResults = json["organic_results"] as? [[String: Any]] {
                for result in organicResults {
                    if let title = result["title"] as? String,
                       let link = result["link"] as? String {
                        let snippet = result["snippet"] as? String
                        items.append(SerpAPISearchResult.Item(
                            title: title,
                            link: link,
                            snippet: snippet,
                            source: "Google"
                        ))
                    }
                }
            }

        case .amazon:
            /// Amazon uses organic_results with rich product data.
            if let organicResults = json["organic_results"] as? [[String: Any]] {
                for result in organicResults {
                    if let title = result["title"] as? String,
                       let link = result["link"] as? String {
                        var snippet = ""
                        /// Extract price.
                        if let price = result["price"] as? String {
                            snippet += price
                        }
                        /// Extract rating.
                        if let rating = result["rating"] as? Double {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += "\(rating)⭐"
                        }
                        /// Extract reviews count.
                        if let reviews = result["reviews"] as? Int {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += "\(reviews) reviews"
                        }
                        items.append(SerpAPISearchResult.Item(
                            title: title,
                            link: result["link_clean"] as? String ?? link,
                            snippet: snippet.isEmpty ? nil : snippet,
                            source: "Amazon"
                        ))
                    }
                }
            }

        case .walmart:
            /// Walmart uses organic_results (needs verification, may also have shopping_results).
            if let organicResults = json["organic_results"] as? [[String: Any]] {
                for result in organicResults {
                    if let title = result["title"] as? String,
                       let link = result["link"] as? String {
                        var snippet = ""
                        if let price = result["price"] as? String {
                            snippet += price
                        }
                        if let rating = result["rating"] as? Double {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += "\(rating)⭐"
                        }
                        items.append(SerpAPISearchResult.Item(
                            title: title,
                            link: link,
                            snippet: snippet.isEmpty ? nil : snippet,
                            source: "Walmart"
                        ))
                    }
                }
            }
            /// Fallback: Also check shopping_results if organic_results is empty.
            if items.isEmpty, let shoppingResults = json["shopping_results"] as? [[String: Any]] {
                for result in shoppingResults {
                    if let title = result["title"] as? String,
                       let link = result["link"] as? String {
                        var snippet = ""
                        if let price = result["price"] as? String {
                            snippet += price
                        }
                        if let rating = result["rating"] as? Double {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += "\(rating)⭐"
                        }
                        items.append(SerpAPISearchResult.Item(
                            title: title,
                            link: link,
                            snippet: snippet.isEmpty ? nil : snippet,
                            source: "Walmart"
                        ))
                    }
                }
            }

        case .ebay:
            /// eBay uses organic_results, not shopping_results.
            if let organicResults = json["organic_results"] as? [[String: Any]] {
                for result in organicResults {
                    if let title = result["title"] as? String,
                       let link = result["link"] as? String {
                        /// Extract price info from eBay structure.
                        var snippet = ""
                        if let priceInfo = result["price"] as? [String: Any] {
                            if let rawPrice = priceInfo["raw"] as? String {
                                snippet += "Price: \(rawPrice)"
                            } else if let fromPrice = priceInfo["from"] as? [String: Any],
                                      let fromRaw = fromPrice["raw"] as? String {
                                snippet += "From: \(fromRaw)"
                            }
                        }
                        if let condition = result["condition"] as? String {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += condition
                        }
                        if let shipping = result["shipping"] as? String {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += shipping
                        }
                        items.append(SerpAPISearchResult.Item(
                            title: title,
                            link: link,
                            snippet: snippet.isEmpty ? nil : snippet,
                            source: "eBay"
                        ))
                    }
                }
            }

        case .tripadvisor:
            /// Parse TripAdvisor results.
            if let results = json["local_results"] as? [[String: Any]] {
                for result in results {
                    if let title = result["title"] as? String {
                        let link = result["link"] as? String ?? ""
                        let rating = result["rating"] as? Double
                        let reviews = result["reviews"] as? Int
                        var snippet = ""
                        if let rating = rating {
                            snippet += "Rating: \(rating)⭐"
                        }
                        if let reviews = reviews {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += "\(reviews) reviews"
                        }
                        items.append(SerpAPISearchResult.Item(
                            title: title,
                            link: link,
                            snippet: snippet.isEmpty ? nil : snippet,
                            source: "TripAdvisor"
                        ))
                    }
                }
            }

        case .yelp:
            /// Parse Yelp results.
            if let results = json["organic_results"] as? [[String: Any]] {
                for result in results {
                    if let title = result["title"] as? String {
                        let link = result["link"] as? String ?? ""
                        let rating = result["rating"] as? Double
                        let reviews = result["reviews"] as? Int
                        let address = result["address"] as? String
                        var snippet = ""
                        if let rating = rating {
                            snippet += "Rating: \(rating)⭐"
                        }
                        if let reviews = reviews {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += "\(reviews) reviews"
                        }
                        if let address = address {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += address
                        }
                        items.append(SerpAPISearchResult.Item(
                            title: title,
                            link: link,
                            snippet: snippet.isEmpty ? nil : snippet,
                            source: "Yelp"
                        ))
                    }
                }
            }
        }

        return SerpAPISearchResult(
            query: json["search_parameters"] as? [String: Any] ?? [:],
            engine: engine,
            items: items,
            rawJSON: json
        )
    }
}

// MARK: - Error Types

public enum SerpAPIError: LocalizedError {
    case serviceDisabled
    case missingAPIKey
    case invalidAPIKey
    case invalidRequest
    case invalidResponse
    case parseError
    case apiError(statusCode: Int)
    case rateLimited
    case limitReached

    public var errorDescription: String? {
        switch self {
        case .serviceDisabled:
            return "SerpAPI service is not enabled. Enable it in Preferences."
        case .missingAPIKey:
            return "SerpAPI key not configured. Add your API key in Preferences."
        case .invalidAPIKey:
            return "Invalid SerpAPI key. Check your API key in Preferences."
        case .invalidRequest:
            return "Invalid SerpAPI request"
        case .invalidResponse:
            return "Invalid response from SerpAPI"
        case .parseError:
            return "Failed to parse SerpAPI response"
        case .apiError(let statusCode):
            return "SerpAPI error (status \(statusCode))"
        case .rateLimited:
            return "SerpAPI rate limit exceeded. Please wait and try again."
        case .limitReached:
            return "SerpAPI monthly search limit reached. Service temporarily disabled."
        }
    }
}
