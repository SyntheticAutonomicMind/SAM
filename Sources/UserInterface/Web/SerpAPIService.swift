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
    private let logger = Logger(label: "com.sam.web.serpapi")
    private let baseURL = "https://serpapi.com"

    /// Use ephemeral URLSession with timeout to prevent infinite hangs
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    // MARK: - Engine Configuration

    /// Configuration for engine-specific parameters and behavior.
    private struct EngineConfig {
        /// Query parameter name (e.g., "q", "query", "_nkw", "find_desc").
        let queryParamName: String
        /// Whether query parameter is required (false for Yelp where find_desc is optional).
        let queryRequired: Bool

        /// Whether this engine supports location parameter.
        let supportsLocation: Bool
        /// Location parameter name (e.g., "location", "find_loc").
        let locationParamName: String?
        /// Whether location is required (true for Yelp).
        let locationRequired: Bool

        /// Whether this engine supports result count parameter.
        let supportsResultCount: Bool
        /// Result count parameter name (e.g., "limit" for TripAdvisor).
        let resultCountParamName: String?

        /// JSON key for main results array (e.g., "organic_results", "shopping_results", "places").
        let resultKey: String

        /// Additional required parameters as key-value pairs.
        let additionalParams: [String: String]
    }

    /// Get engine-specific configuration.
    private func getEngineConfig(for engine: SearchEngine) -> EngineConfig {
        switch engine {
        case .google:
            return EngineConfig(
                queryParamName: "q",
                queryRequired: true,
                supportsLocation: true,
                locationParamName: "location",
                locationRequired: false,
                supportsResultCount: false,  // Google ignores num parameter
                resultCountParamName: nil,
                resultKey: "organic_results",
                additionalParams: [:]
            )

        case .bing:
            return EngineConfig(
                queryParamName: "q",
                queryRequired: true,
                supportsLocation: true,
                locationParamName: "location",
                locationRequired: false,
                supportsResultCount: false,  // Bing ignores num parameter
                resultCountParamName: nil,
                resultKey: "organic_results",
                additionalParams: [:]
            )

        case .amazon:
            return EngineConfig(
                queryParamName: "k",
                queryRequired: true,
                supportsLocation: false,  // Amazon doesn't use location (uses domain instead)
                locationParamName: nil,
                locationRequired: false,
                supportsResultCount: false,  // Amazon does NOT support num parameter
                resultCountParamName: nil,
                resultKey: "organic_results",
                additionalParams: ["amazon_domain": "amazon.com"]  // Default to .com
            )

        case .ebay:
            return EngineConfig(
                queryParamName: "_nkw",
                queryRequired: true,
                supportsLocation: false,
                locationParamName: nil,
                locationRequired: false,
                supportsResultCount: false,  // eBay does NOT support num parameter
                resultCountParamName: nil,
                resultKey: "organic_results",
                additionalParams: [:]
            )

        case .walmart:
            return EngineConfig(
                queryParamName: "query",
                queryRequired: true,
                supportsLocation: false,  // Walmart uses store_id, not location
                locationParamName: nil,
                locationRequired: false,
                supportsResultCount: false,  // Walmart does NOT support num parameter
                resultCountParamName: nil,
                resultKey: "organic_results",
                additionalParams: [:]
            )

        case .tripadvisor:
            return EngineConfig(
                queryParamName: "q",
                queryRequired: true,
                supportsLocation: false,  // TripAdvisor uses lat+lon, not location text
                locationParamName: nil,
                locationRequired: false,
                supportsResultCount: true,  // TripAdvisor supports "limit" parameter
                resultCountParamName: "limit",
                resultKey: "places",  // TripAdvisor uses "places", not "organic_results"
                additionalParams: [:]
            )

        case .yelp:
            return EngineConfig(
                queryParamName: "find_desc",
                queryRequired: false,  // Yelp's find_desc is optional
                supportsLocation: true,
                locationParamName: "find_loc",
                locationRequired: true,  // Yelp REQUIRES location via find_loc
                supportsResultCount: false,  // Yelp does NOT support num parameter
                resultCountParamName: nil,
                resultKey: "organic_results",
                additionalParams: [:]
            )
        }
    }

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
        case bing = "bing"
        case amazon = "amazon"
        case ebay = "ebay"
        case walmart = "walmart"
        case tripadvisor = "tripadvisor"
        case yelp = "yelp"

        public var displayName: String {
            switch self {
            case .google: return "Google Search"
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

        /// Get engine-specific configuration.
        let config = getEngineConfig(for: engine)

        /// Validate required parameters.
        if config.queryRequired && query.isEmpty {
            throw SerpAPIError.invalidRequest
        }

        if config.locationRequired && (location == nil || location!.isEmpty) {
            logger.error("Engine \(engine.displayName) requires location parameter (via \(config.locationParamName ?? "location"))")
            throw SerpAPIError.missingRequiredParameter(parameter: config.locationParamName ?? "location")
        }

        /// Build request.
        var components = URLComponents(string: "\(baseURL)/search")!
        var queryItems: [URLQueryItem] = []

        /// Add engine parameter.
        queryItems.append(URLQueryItem(name: "engine", value: engine.rawValue))

        /// Add query parameter (if query provided or required).
        if config.queryRequired || !query.isEmpty {
            queryItems.append(URLQueryItem(name: config.queryParamName, value: query))
        }

        /// Add location parameter (if supported and provided).
        if config.supportsLocation, let location = location, !location.isEmpty {
            queryItems.append(URLQueryItem(name: config.locationParamName!, value: location))
        }

        /// Add result count parameter (if supported).
        if config.supportsResultCount, let resultCountParam = config.resultCountParamName {
            queryItems.append(URLQueryItem(name: resultCountParam, value: "\(numResults)"))
        }

        /// Add additional required parameters.
        for (key, value) in config.additionalParams {
            queryItems.append(URLQueryItem(name: key, value: value))
        }

        /// Add API key last.
        queryItems.append(URLQueryItem(name: "api_key", value: apiKey))

        components.queryItems = queryItems

        guard let url = components.url else {
            throw SerpAPIError.invalidRequest
        }

        logger.info("SerpAPI search: engine=\(engine.displayName), query=\"\(query)\"")
        logger.debug("SerpAPI request URL: \(url.absoluteString.replacingOccurrences(of: apiKey, with: "***API_KEY***"))")

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
        let result = try parseSearchResult(data: data, engine: engine, config: config)
        logger.info("SerpAPI returned \(result.items.count) results")

        return result
    }

    // MARK: - Response Parsing

    private func parseSearchResult(data: Data, engine: SearchEngine, config: EngineConfig) throws -> SerpAPISearchResult {
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

        case .google:
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
            /// Walmart uses organic_results with product_page_url instead of link.
            if let organicResults = json["organic_results"] as? [[String: Any]] {
                for result in organicResults {
                    if let title = result["title"] as? String,
                       let productURL = result["product_page_url"] as? String {
                        var snippet = ""
                        
                        /// Extract price from primary_offer.offer_price.
                        if let primaryOffer = result["primary_offer"] as? [String: Any],
                           let offerPrice = primaryOffer["offer_price"] as? Double {
                            snippet += "$\(String(format: "%.2f", offerPrice))"
                        }
                        
                        /// Add rating if available.
                        if let rating = result["rating"] as? Double, rating > 0 {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += "\(rating)⭐"
                        }
                        
                        /// Add reviews count if available.
                        if let reviews = result["reviews"] as? Int, reviews > 0 {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += "\(reviews) reviews"
                        }
                        
                        items.append(SerpAPISearchResult.Item(
                            title: title,
                            link: productURL,
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
            /// Parse TripAdvisor results (uses "places" key, not "local_results").
            if let results = json["places"] as? [[String: Any]] {
                for result in results {
                    if let title = result["title"] as? String {
                        let link = result["link"] as? String ?? ""
                        let rating = result["rating"] as? Double
                        let reviews = result["reviews"] as? Int
                        let location = result["location"] as? String
                        var snippet = ""
                        if let rating = rating {
                            snippet += "Rating: \(rating)⭐"
                        }
                        if let reviews = reviews {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += "\(reviews) reviews"
                        }
                        if let location = location {
                            snippet += snippet.isEmpty ? "" : " • "
                            snippet += location
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
    case missingRequiredParameter(parameter: String)

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
        case .missingRequiredParameter(let parameter):
            return "Missing required parameter: \(parameter)"
        }
    }
}
