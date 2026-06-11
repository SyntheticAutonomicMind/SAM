// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import Vapor
import Logging

/// Custom CORS middleware that restricts cross-origin access to trusted origins.
///
/// **Security:** Only allows requests from localhost origins (SAM-Web and
/// other local integrations). Reflecting the Origin header directly (the
/// previous implementation) allows ANY origin to make cross-origin requests
/// to the API, which combined with an auth bypass enables full remote
/// exploitation from any website.
///
/// **Allowed origins:**
/// - `http://localhost:*` (any port)
/// - `http://127.0.0.1:*` (any port)
/// - `http://[::1]:*` (IPv6 localhost, any port)
/// - Same-origin requests (no Origin header)
struct CustomCORSMiddleware: AsyncMiddleware {
    private let logger = Logger(label: "com.sam.middleware.cors")

    /// Allowed localhost patterns for CORS.
    private static let allowedPatterns: [(prefix: String, hasPort: Bool)] = [
        (prefix: "http://localhost", hasPort: true),
        (prefix: "http://127.0.0.1", hasPort: true),
        (prefix: "http://[::1]", hasPort: true),
        (prefix: "http://localhost", hasPort: false),
        (prefix: "http://127.0.0.1", hasPort: false),
    ]

    /// Check if an origin is a trusted localhost origin.
    private func isAllowedOrigin(_ origin: String) -> Bool {
        // Empty origin means same-origin request (non-browser client)
        if origin.isEmpty { return true }

        for pattern in Self.allowedPatterns {
            if origin == pattern.prefix {
                return true
            }
            if pattern.hasPort && origin.hasPrefix(pattern.prefix + ":") {
                return true
            }
        }
        return false
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let origin = request.headers.first(name: "Origin") ?? ""

        // Handle preflight OPTIONS requests
        if request.method == .OPTIONS {
            let response = Response(status: .ok)
            if isAllowedOrigin(origin) {
                response.headers.replaceOrAdd(name: .accessControlAllowOrigin, value: origin)
                response.headers.replaceOrAdd(name: .accessControlAllowMethods, value: "GET, POST, PUT, DELETE, PATCH, OPTIONS")
                response.headers.replaceOrAdd(name: .accessControlAllowHeaders, value: "Accept, Authorization, Content-Type, X-SAM-Internal, X-Requested-With")
                response.headers.replaceOrAdd(name: .accessControlMaxAge, value: "3600")
                response.headers.replaceOrAdd(name: .accessControlAllowCredentials, value: "true")
            } else if !origin.isEmpty {
                logger.warning("CORS preflight rejected for origin: \(origin) - path: \(request.url.path)")
            }
            return response
        }

        // Process request normally
        let response = try await next.respond(to: request)

        // Add CORS headers only for allowed origins
        if isAllowedOrigin(origin) {
            response.headers.replaceOrAdd(name: .accessControlAllowOrigin, value: origin)
            response.headers.replaceOrAdd(name: .accessControlAllowMethods, value: "GET, POST, PUT, DELETE, PATCH, OPTIONS")
            response.headers.replaceOrAdd(name: .accessControlAllowHeaders, value: "Accept, Authorization, Content-Type, X-SAM-Internal, X-Requested-With")
            response.headers.replaceOrAdd(name: .accessControlAllowCredentials, value: "true")
        } else if !origin.isEmpty {
            logger.warning("CORS request from untrusted origin: \(origin) - path: \(request.url.path)")
        }

        return response
    }
}