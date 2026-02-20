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

/// Disk-cache envelope written by both SAM and CLIO
/// Layout: `{ "data": <CopilotUserResponse>, "cached_at": <unix epoch seconds> }`
private struct CopilotUserCacheEnvelope: Codable {
    let data: CopilotUserResponse
    let cachedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case data
        case cachedAt = "cached_at"
    }
}

/// Actor-based client for fetching GitHub Copilot user data.
///
/// Thread-safe, with two levels of caching:
/// - **Memory cache**: in-actor `cachedResponse` – fast, cleared on app restart.
/// - **Disk cache**: written to `~/Library/Application Support/SAM/copilot_user_cache.json`
///   (same layout as CLIO's `~/.clio/copilot_user_cache.json`). Survives restarts and
///   ensures `getCopilotBaseURL()` returns the correct plan-specific endpoint immediately
///   on first request, before the network call has returned.
///
/// Cache TTL defaults to 5 minutes for the memory cache. The disk cache is read on
/// actor initialisation and is written every time a fresh response is fetched.  The disk
/// cache is treated as valid for up to 24 hours so that the plan-specific endpoint is
/// always available even when the user is offline at startup.
public actor CopilotUserAPIClient {
    private let logger = Logger(label: "com.sam.copilot.userapi")
    private let baseURL = URL(string: "https://api.github.com/copilot_internal/user")!

    // MARK: - Cache

    /// In-memory cache (cleared on restart)
    private var cachedResponse: CopilotUserResponse?
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes

    /// Disk cache TTL: 24 hours
    /// The plan-specific endpoint changes rarely so a long TTL is fine.
    private let diskCacheTTL: TimeInterval = 86_400

    /// Location of the disk cache file.
    private static var diskCacheURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("SAM/copilot_user_cache.json")
    }

    // MARK: - Shared instance

    public static let shared = CopilotUserAPIClient()

    public init() {
        // Pre-warm from disk so getCopilotBaseURL() works immediately on first call
        if let (response, _) = Self.loadFromDisk(maxAge: 86_400) {
            cachedResponse = response
            // Don't set cacheTimestamp so a network refresh is triggered when
            // fetchUser() is next called, but the endpoint is already available.
        }
    }

    // MARK: - Fetch

    /// Fetch user data from GitHub API.
    /// - Parameter token: GitHub user token (NOT Copilot token)
    /// - Parameter forceRefresh: Bypass memory cache and fetch fresh data
    /// - Returns: CopilotUserResponse with user info and quota data
    public func fetchUser(token: String, forceRefresh: Bool = false) async throws -> CopilotUserResponse {
        // Return memory-cached response if still valid
        if !forceRefresh, let cached = getMemoryCachedResponse() {
            logger.debug("Returning memory-cached user response")
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

            // Update in-memory cache
            self.cachedResponse = decoded
            self.cacheTimestamp = Date()

            // Persist to disk so next launch has the endpoint immediately
            Self.saveToDisk(decoded)

            // Log useful info
            if let login = decoded.login {
                logger.info("Fetched user info for: \(login)")
            }
            if let endpoint = decoded.endpoints?.api {
                logger.info("Copilot API endpoint: \(endpoint)")
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

    // MARK: - Cache Accessors

    /// Get in-memory cached response if still within TTL
    public func getMemoryCachedResponse() -> CopilotUserResponse? {
        guard let cached = cachedResponse,
              let timestamp = cacheTimestamp,
              Date().timeIntervalSince(timestamp) < cacheTTL else {
            return nil
        }
        return cached
    }

    /// Legacy alias kept for compatibility
    public func getCachedResponse() -> CopilotUserResponse? {
        return getMemoryCachedResponse()
    }

    /// Check if memory cache is valid (not expired)
    public func isCacheValid() -> Bool {
        guard let timestamp = cacheTimestamp else { return false }
        return Date().timeIntervalSince(timestamp) < cacheTTL
    }

    /// Get cache age in seconds
    public func getCacheAge() -> TimeInterval? {
        guard let timestamp = cacheTimestamp else { return nil }
        return Date().timeIntervalSince(timestamp)
    }

    /// Clear both memory and disk cache (forces next fetch to hit API)
    public func clearCache() {
        cachedResponse = nil
        cacheTimestamp = nil
        try? FileManager.default.removeItem(at: Self.diskCacheURL)
        logger.debug("User API cache cleared (memory + disk)")
    }

    /// Get premium quota from cached response without hitting API
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
    public func getCachedAPIEndpoint() -> String? {
        return cachedResponse?.endpoints?.api
    }

    /// Get the best available GitHub Copilot API base URL.
    ///
    /// GitHub assigns each user a plan-specific API endpoint (e.g.
    /// `api.individual.githubcopilot.com` for Individual/Pro subscribers,
    /// `api.business.githubcopilot.com` for Business, etc.).  Using the
    /// correct endpoint is required to see the full model catalogue - the
    /// generic `api.githubcopilot.com` hostname only surfaces a subset of
    /// models for some plans.
    ///
    /// Resolution order (mirrors CLIO-dist `Config::_get_copilot_user_api_endpoint`):
    /// 1. `endpoints.api` from the current in-memory cache (populated by `fetchUser`).
    /// 2. Fall back to `"https://api.githubcopilot.com"` if the cache is empty.
    ///
    /// The disk cache is pre-loaded into memory during `init()`, so this method
    /// returns the correct endpoint even on the very first call after a cold start.
    ///
    /// - Returns: The user-specific API base URL, e.g.
    ///   `"https://api.individual.githubcopilot.com"`.
    public func getCopilotBaseURL() -> String {
        return cachedResponse?.endpoints?.api ?? "https://api.githubcopilot.com"
    }

    // MARK: - Disk Cache (nonisolated helpers)

    /// Save user response to disk.  Called after every successful network fetch.
    private static func saveToDisk(_ response: CopilotUserResponse) {
        let url = diskCacheURL
        do {
            // Ensure the directory exists
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let envelope = CopilotUserCacheEnvelope(data: response, cachedAt: Date().timeIntervalSince1970)
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: url, options: .atomic)
        } catch {
            // Non-fatal - disk cache is best-effort
        }
    }

    /// Load user response from disk if it exists and is within `maxAge` seconds.
    /// - Returns: `(response, age)` tuple, or `nil` if missing/stale/corrupt.
    private static func loadFromDisk(maxAge: TimeInterval) -> (CopilotUserResponse, TimeInterval)? {
        let url = diskCacheURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(CopilotUserCacheEnvelope.self, from: data) else {
            return nil
        }
        let age = Date().timeIntervalSince1970 - envelope.cachedAt
        guard age <= maxAge else { return nil }
        return (envelope.data, age)
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
