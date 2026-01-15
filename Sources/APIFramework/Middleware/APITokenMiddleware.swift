// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Vapor
import ConfigurationSystem
import Logging

/// Middleware for API token authentication.
///
/// This middleware secures API endpoints by requiring either:
/// 1. A valid API token via `Authorization: Bearer TOKEN` header, or
/// 2. An internal request marker via `X-SAM-Internal` header (for UI requests)
///
/// **Authentication Flow:**
/// ```
/// Request → Check X-SAM-Internal → Internal? → Allow
///                                → External? → Check Bearer Token → Valid? → Allow
///                                                                  → Invalid? → 401
/// ```
///
/// **Usage:**
/// ```swift
/// app.middleware.use(APITokenMiddleware())
/// ```
public struct APITokenMiddleware: AsyncMiddleware {
    private let logger = Logger(label: "com.sam.middleware.auth")
    
    /// Thread-safe token cache actor
    private actor TokenCache {
        private var token: String?
        
        func get() -> String? {
            return token
        }
        
        func set(_ value: String?) {
            token = value
        }
    }
    
    private static let tokenCache = TokenCache()
    
    public init() {}
    
    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Check if this is an internal request from SAM UI
        if let internalHeader = request.headers.first(name: "X-SAM-Internal"),
           internalHeader == "SAM-Internal-Communication" {
            logger.debug("Internal request detected, bypassing authentication")
            return try await next.respond(to: request)
        }
        
        // External request - require Bearer token
        guard let authHeader = request.headers[.authorization].first else {
            logger.warning("External API request without Authorization header: \(request.url.path)")
            throw Abort(.unauthorized, reason: "Missing Authorization header. API access requires a Bearer token. Include 'Authorization: Bearer YOUR-TOKEN' in your request headers.")
        }
        
        // Parse Bearer token
        let components = authHeader.split(separator: " ", maxSplits: 1)
        guard components.count == 2,
              components[0].lowercased() == "bearer" else {
            logger.warning("Invalid Authorization header format: \(request.url.path)")
            throw Abort(.unauthorized, reason: "Invalid Authorization header format. Expected 'Authorization: Bearer YOUR-TOKEN'.")
        }
        
        let providedToken = String(components[1])
        
        // Retrieve stored token from UserDefaults (cached to avoid repeated access)
        var cachedToken = await Self.tokenCache.get()
        if cachedToken == nil {
            cachedToken = UserDefaults.standard.string(forKey: "samAPIToken")
            await Self.tokenCache.set(cachedToken)
            logger.debug("Loaded API token from UserDefaults")
        }
        
        guard let storedToken = cachedToken, !storedToken.isEmpty else {
            logger.error("No API token found in UserDefaults")
            throw Abort(.internalServerError, reason: "Server authentication configuration error. Please contact the administrator.")
        }
        
        // Validate token
        guard providedToken == storedToken else {
            logger.warning("Invalid API token provided: \(request.url.path)")
            throw Abort(.unauthorized, reason: "Invalid API token. Please use the correct token from SAM Preferences → API Server.")
        }
        
        logger.debug("Valid API token authenticated for: \(request.url.path)")
        return try await next.respond(to: request)
    }
}
