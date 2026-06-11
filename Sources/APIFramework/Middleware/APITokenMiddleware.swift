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
/// **Security:** The internal token is a per-installation random value stored in
/// UserDefaults, NOT a hardcoded secret. Each SAM installation generates a unique
/// token on first launch, making it impossible to guess from source code alone.
///
/// **Authentication Flow:**
/// ```
/// Request -> Check X-SAM-Internal -> Valid internal token? -> Allow
///                                -> Invalid/missing? -> Check Bearer Token -> Valid? -> Allow
///                                                                                  -> Invalid? -> 401
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
        private var apiToken: String?
        private var internalToken: String?
        
        func getAPIToken() -> String? {
            return apiToken
        }
        
        func setAPIToken(_ value: String?) {
            apiToken = value
        }
        
        func getInternalToken() -> String? {
            return internalToken
        }
        
        func setInternalToken(_ value: String?) {
            internalToken = value
        }
    }
    
    private static let tokenCache = TokenCache()
    
    /// UserDefaults key for the per-installation internal communication token.
    private static let internalTokenKey = "samInternalCommunicationToken"
    
    public init() {}
    
    /// Generate or retrieve a per-installation random internal token.
    ///
    /// Each SAM installation gets a unique token generated on first launch.
    /// This token is stored in UserDefaults and can be rotated by deleting
    /// the key. It is NOT discoverable from source code.
    private static func getOrCreateInternalToken() -> String {
        if let existing = UserDefaults.standard.string(forKey: internalTokenKey), !existing.isEmpty {
            return existing
        }
        // Generate a cryptographically random token
        let token = "\(UUID().uuidString)-\(UUID().uuidString)"
        UserDefaults.standard.set(token, forKey: internalTokenKey)
        return token
    }
    
    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Check if this is an internal request from SAM UI
        // Uses per-installation random token instead of hardcoded secret
        if let internalHeader = request.headers.first(name: "X-SAM-Internal"),
           !internalHeader.isEmpty {
            let expectedToken = Self.getOrCreateInternalToken()
            if internalHeader == expectedToken {
                logger.info("Internal request authenticated via X-SAM-Internal header for: \(request.url.path)")
                return try await next.respond(to: request)
            } else {
                logger.warning("Invalid X-SAM-Internal header provided for: \(request.url.path) - possible unauthorized access attempt")
                // Fall through to Bearer token check - don't reveal internal auth exists
            }
        }
        
        // External request - require Bearer token
        guard let authHeader = request.headers[.authorization].first else {
            logger.warning("API request without Authorization header: \(request.url.path)")
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
        var cachedToken = await Self.tokenCache.getAPIToken()
        if cachedToken == nil {
            cachedToken = UserDefaults.standard.string(forKey: "samAPIToken")
            await Self.tokenCache.setAPIToken(cachedToken)
            logger.debug("Loaded API token from UserDefaults")
        }
        
        guard let storedToken = cachedToken, !storedToken.isEmpty else {
            logger.error("No API token found in UserDefaults")
            throw Abort(.internalServerError, reason: "Server authentication configuration error. Please contact the administrator.")
        }
        
        // Validate token
        guard providedToken == storedToken else {
            logger.warning("Invalid API token provided for: \(request.url.path)")
            throw Abort(.unauthorized, reason: "Invalid API token. Please use the correct token from SAM Preferences -> API Server.")
        }
        
        logger.debug("Valid API token authenticated for: \(request.url.path)")
        return try await next.respond(to: request)
    }
}