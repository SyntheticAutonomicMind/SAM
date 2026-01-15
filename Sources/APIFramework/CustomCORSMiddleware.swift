// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import Vapor

/// Custom CORS middleware that manually injects headers into every response
/// This is a workaround for Vapor's CORSMiddleware not working as expected
struct CustomCORSMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Get origin from request
        let origin = request.headers.first(name: "Origin") ?? "*"
        
        // Handle preflight OPTIONS requests
        if request.method == .OPTIONS {
            let response = Response(status: .ok)
            response.headers.replaceOrAdd(name: .accessControlAllowOrigin, value: origin)
            response.headers.replaceOrAdd(name: .accessControlAllowMethods, value: "GET, POST, PUT, DELETE, PATCH, OPTIONS")
            response.headers.replaceOrAdd(name: .accessControlAllowHeaders, value: "Accept, Authorization, Content-Type, Origin, X-Requested-With")
            response.headers.replaceOrAdd(name: .accessControlMaxAge, value: "3600")
            return response
        }
        
        // Process request normally
        let response = try await next.respond(to: request)
        
        // Add CORS headers to response (replaceOrAdd ensures no duplicates)
        response.headers.replaceOrAdd(name: .accessControlAllowOrigin, value: origin)
        response.headers.replaceOrAdd(name: .accessControlAllowMethods, value: "GET, POST, PUT, DELETE, PATCH, OPTIONS")
        response.headers.replaceOrAdd(name: .accessControlAllowHeaders, value: "Accept, Authorization, Content-Type, Origin, X-Requested-With")
        
        return response
    }
}
