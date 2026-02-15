// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

// MARK: - API Response Types

/// Response from GitHub's internal Copilot user API
/// Endpoint: GET https://api.github.com/copilot_internal/user
public struct CopilotUserResponse: Codable, Sendable {
    public let login: String?
    public let copilotPlan: String?
    public let accessTypeSku: String?
    public let quotaResetDate: String?
    public let quotaResetDateUTC: String?
    public let quotaSnapshots: [String: QuotaSnapshot]?
    public let endpoints: Endpoints?
    
    enum CodingKeys: String, CodingKey {
        case login
        case copilotPlan = "copilot_plan"
        case accessTypeSku = "access_type_sku"
        case quotaResetDate = "quota_reset_date"
        case quotaResetDateUTC = "quota_reset_date_utc"
        case quotaSnapshots = "quota_snapshots"
        case endpoints
    }
    
    /// Quota snapshot for a specific resource type (premium_interactions, chat, completions)
    public struct QuotaSnapshot: Codable, Sendable {
        public let entitlement: Int
        public let remaining: Int
        public let percentRemaining: Double
        public let unlimited: Bool
        public let overageCount: Int?
        public let overagePermitted: Bool?
        public let quotaId: String?
        public let timestampUTC: String?
        
        enum CodingKeys: String, CodingKey {
            case entitlement
            case remaining
            case percentRemaining = "percent_remaining"
            case unlimited
            case overageCount = "overage_count"
            case overagePermitted = "overage_permitted"
            case quotaId = "quota_id"
            case timestampUTC = "timestamp_utc"
        }
        
        /// Calculate used count from entitlement and remaining
        /// More accurate than percentage-based calculation
        public var used: Int {
            guard entitlement > 0, !unlimited else { return 0 }
            return max(0, entitlement - remaining)
        }
        
        /// Calculate percent used for UI display
        public var percentUsed: Double {
            guard entitlement > 0, !unlimited else { return 0.0 }
            return 100.0 - percentRemaining
        }
    }
    
    /// API endpoints returned by the user API
    public struct Endpoints: Codable, Sendable {
        public let api: String?
        public let proxy: String?
        public let originTracker: String?
        public let telemetry: String?
        
        enum CodingKeys: String, CodingKey {
            case api
            case proxy
            case originTracker = "origin-tracker"
            case telemetry
        }
    }
    
    /// Get the premium interactions quota (most relevant for chat/agent usage)
    public var premiumQuota: QuotaSnapshot? {
        return quotaSnapshots?["premium_interactions"]
    }
    
    /// Get the chat quota (usually unlimited)
    public var chatQuota: QuotaSnapshot? {
        return quotaSnapshots?["chat"]
    }
    
    /// Get the completions quota (usually unlimited)
    public var completionsQuota: QuotaSnapshot? {
        return quotaSnapshots?["completions"]
    }
}

// MARK: - API Client

/// Actor-based client for fetching GitHub Copilot user data
/// Thread-safe with built-in caching to minimize API calls
public actor CopilotUserAPIClient {
    private let logger = Logger(label: "com.sam.copilot.userapi")
    private let baseURL = URL(string: "https://api.github.com/copilot_internal/user")!
    
    // Cache management
    private var cachedResponse: CopilotUserResponse?
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes
    
    // Shared instance for app-wide use
    public static let shared = CopilotUserAPIClient()
    
    public init() {}
    
    /// Fetch user data from GitHub API
    /// - Parameter token: GitHub user token (NOT Copilot token)
    /// - Parameter forceRefresh: Bypass cache and fetch fresh data
    /// - Returns: CopilotUserResponse with user info and quota data
    public func fetchUser(token: String, forceRefresh: Bool = false) async throws -> CopilotUserResponse {
        // Return cached response if valid and not forcing refresh
        if !forceRefresh, let cached = getCachedResponse() {
            logger.debug("Returning cached user response")
            return cached
        }
        
        logger.info("Fetching Copilot user info from API")
        
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        // IMPORTANT: Use "token <token>" format, NOT "Bearer <token>"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SAM/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CopilotUserError.invalidResponse
        }
        
        switch httpResponse.statusCode {
        case 200:
            let decoded = try JSONDecoder().decode(CopilotUserResponse.self, from: data)
            
            // Cache the successful response
            self.cachedResponse = decoded
            self.cacheTimestamp = Date()
            
            // Log useful info
            if let login = decoded.login {
                logger.info("Fetched user info for: \(login)")
            }
            if let premium = decoded.premiumQuota {
                logger.info("Premium quota: \(premium.used)/\(premium.entitlement) (\(String(format: "%.1f", premium.percentUsed))% used)")
            }
            
            return decoded
            
        case 401:
            logger.error("Unauthorized - token may be invalid or expired")
            throw CopilotUserError.unauthorized
            
        case 403:
            logger.error("Forbidden - user may not have Copilot access")
            throw CopilotUserError.forbidden
            
        case 404:
            logger.error("Not found - user may not have Copilot subscription")
            throw CopilotUserError.notFound
            
        case 429:
            logger.warning("Rate limited by GitHub API")
            throw CopilotUserError.rateLimited
            
        default:
            logger.error("HTTP error: \(httpResponse.statusCode)")
            throw CopilotUserError.httpError(httpResponse.statusCode)
        }
    }
    
    /// Get cached user data if available and not expired
    public func getCachedResponse() -> CopilotUserResponse? {
        guard let cached = cachedResponse,
              let timestamp = cacheTimestamp,
              Date().timeIntervalSince(timestamp) < cacheTTL else {
            return nil
        }
        return cached
    }
    
    /// Check if cache is valid (not expired)
    public func isCacheValid() -> Bool {
        guard let timestamp = cacheTimestamp else { return false }
        return Date().timeIntervalSince(timestamp) < cacheTTL
    }
    
    /// Get cache age in seconds
    public func getCacheAge() -> TimeInterval? {
        guard let timestamp = cacheTimestamp else { return nil }
        return Date().timeIntervalSince(timestamp)
    }
    
    /// Clear the cache (forces next fetch to hit API)
    public func clearCache() {
        cachedResponse = nil
        cacheTimestamp = nil
        logger.debug("User API cache cleared")
    }
    
    /// Get premium quota from cached response without hitting API
    /// Returns nil if no cached data available
    public func getCachedPremiumQuota() -> CopilotUserResponse.QuotaSnapshot? {
        return cachedResponse?.premiumQuota
    }
    
    /// Get login from cached response
    public func getCachedLogin() -> String? {
        return cachedResponse?.login
    }
    
    /// Get plan type from cached response
    public func getCachedPlan() -> String? {
        return cachedResponse?.copilotPlan
    }
    
    /// Get API endpoint from cached response
    /// This can be used to discover the correct chat API endpoint
    public func getCachedAPIEndpoint() -> String? {
        return cachedResponse?.endpoints?.api
    }
}

// MARK: - Errors

public enum CopilotUserError: LocalizedError, Sendable {
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case invalidResponse
    case httpError(Int)
    
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "GitHub token is invalid or expired. Please re-authenticate."
        case .forbidden:
            return "Access denied. Your account may not have Copilot access."
        case .notFound:
            return "Copilot subscription not found for this account."
        case .rateLimited:
            return "Rate limited by GitHub API. Please try again later."
        case .invalidResponse:
            return "Invalid response from GitHub API."
        case .httpError(let code):
            return "GitHub API error (HTTP \(code))."
        }
    }
}
