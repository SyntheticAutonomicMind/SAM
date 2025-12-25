// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// CivitAI API service for browsing and downloading Stable Diffusion models
public class CivitAIService {
    private let logger = Logger(label: "CivitAIService")
    private let baseURL = "https://civitai.com/api/v1"
    private var apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    /// Update API key
    public func setAPIKey(_ key: String?) {
        self.apiKey = key
    }

    // MARK: - API Methods

    /// Search for models with filters
    public func searchModels(
        query: String? = nil,
        limit: Int = 20,
        page: Int = 1,
        cursor: String? = nil,
        types: [String]? = nil,
        sort: String = "Highest Rated",
        period: String = "AllTime",
        nsfw: Bool? = nil
    ) async throws -> CivitAISearchResponse {
        var components = URLComponents(string: "\(baseURL)/models")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "period", value: period)
        ]

        // CivitAI uses query parameter for authentication, not header
        if let apiKey = apiKey {
            queryItems.append(URLQueryItem(name: "token", value: apiKey))
        } else {
            logger.warning("No CivitAI API key configured - may be rate limited")
        }

        // CivitAI API pagination:
        // - Use cursor for reliable pagination beyond page ~20
        // - Fall back to page-based for initial requests
        if let cursor = cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
            logger.debug("Using cursor pagination: \(cursor.prefix(50))")
        } else {
            // CivitAI API: Cannot use page param with query search
            // Use page-based pagination ONLY when query is empty AND no cursor
            if let query = query, !query.isEmpty {
                queryItems.append(URLQueryItem(name: "query", value: query))
                // Don't include page parameter when using query
            } else {
                // Page-based pagination only works without query
                queryItems.append(URLQueryItem(name: "page", value: "\(page)"))
            }
        }

        if let types = types, !types.isEmpty {
            queryItems.append(URLQueryItem(name: "types", value: types.joined(separator: ",")))
        }

        if let nsfw = nsfw {
            queryItems.append(URLQueryItem(name: "nsfw", value: nsfw ? "true" : "false"))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            logger.error("Failed to construct URL from components")
            throw CivitAIError.invalidURL
        }

        logger.debug("CivitAI search URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        // Note: Authentication is via query parameter, not header

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CivitAIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            /// Try to extract error message from response
            var errorDetail = "Status \(httpResponse.statusCode)"
            if let errorResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = errorResponse["message"] as? String {
                errorDetail += ": \(message)"
            } else if let rawError = String(data: data, encoding: .utf8) {
                errorDetail += ": \(rawError)"
            }
            logger.error("CivitAI API error - \(errorDetail)")
            logger.error("Request URL - \(url)")
            throw CivitAIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CivitAISearchResponse.self, from: data)
    }

    /// Get detailed information about a specific model
    public func getModelDetails(modelId: Int) async throws -> CivitAIModel {
        var components = URLComponents(string: "\(baseURL)/models/\(modelId)")!
        
        // CivitAI uses query parameter for authentication, not header
        if let apiKey = apiKey {
            components.queryItems = [URLQueryItem(name: "token", value: apiKey)]
        }
        
        guard let url = components.url else {
            throw CivitAIError.invalidURL
        }
        
        var request = URLRequest(url: url)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CivitAIError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CivitAIModel.self, from: data)
    }

    /// Test API connection
    public func testConnection() async throws -> Bool {
        let response = try await searchModels(limit: 1)
        return !response.items.isEmpty
    }

    /// Search specifically for LoRA models
    /// Note: Due to CivitAI API limitations, we don't use types or baseModel in the API call.
    /// Caller should filter results client-side.
    public func searchLoRAs(
        query: String? = nil,
        baseModel: String? = nil,
        limit: Int = 100,  /// CivitAI API max is 100, not 200
        page: Int = 1,
        cursor: String? = nil,
        sort: String = "Highest Rated",
        nsfw: Bool? = nil
    ) async throws -> CivitAISearchResponse {
        /// Don't add types or baseModel to API call - causes issues
        /// Caller will filter by type and baseModel client-side
        return try await searchModels(
            query: query,
            limit: limit,
            page: page,
            cursor: cursor,
            types: nil,  /// Don't filter by type in API
            sort: sort,
            period: "AllTime",
            nsfw: nsfw
        )
    }
}

// MARK: - Data Models

/// Search response from CivitAI
public struct CivitAISearchResponse: Codable, Sendable {
    public let items: [CivitAIModel]
    public let metadata: SearchMetadata?

    public struct SearchMetadata: Codable, Sendable {
        public let totalItems: Int?
        public let currentPage: Int?
        public let pageSize: Int?
        public let totalPages: Int?
        public let nextCursor: String?
        public let prevCursor: String?
    }
}

/// CivitAI model information
public struct CivitAIModel: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let description: String?
    public let type: String
    public let nsfw: Bool?
    public let tags: [String]?
    public let creator: Creator?
    public let modelVersions: [ModelVersion]?

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: CivitAIModel, rhs: CivitAIModel) -> Bool {
        lhs.id == rhs.id
    }

    /// Check if model contains NSFW content based on multiple indicators
    public func isNSFW() -> Bool {
        /// 1. Check model-level NSFW flag
        if nsfw == true {
            return true
        }

        /// 2. Check tags for NSFW keywords
        let nsfwKeywords = ["nsfw", "adult", "nude", "explicit", "mature", "sexual", "porn", "hentai", "lewd"]
        if let tags = tags {
            for tag in tags {
                let lowercaseTag = tag.lowercased()
                if nsfwKeywords.contains(where: { lowercaseTag.contains($0) }) {
                    return true
                }
            }
        }

        /// 3. Check name and description for NSFW keywords
        let textToCheck = [name, description ?? ""].joined(separator: " ").lowercased()
        if nsfwKeywords.contains(where: { textToCheck.contains($0) }) {
            return true
        }

        /// 4. Check images for high NSFW levels
        if let versions = modelVersions {
            for version in versions {
                if let images = version.images {
                    for image in images {
                        /// nsfwLevel >= 2 indicates NSFW content
                        if let level = image.nsfwLevel, level >= 2 {
                            return true
                        }
                    }
                }
            }
        }

        return false
    }

    public struct Creator: Codable, Hashable, Sendable {
        public let username: String
        public let image: String?
    }

    public struct ModelVersion: Codable, Identifiable, Hashable, Sendable {
        public let id: Int
        public let name: String
        public let description: String?
        public let trainedWords: [String]?
        public let baseModel: String?
        public let files: [ModelFile]?
        public let publishedAt: String?
        public let downloadUrl: String?
        public let images: [ModelImage]?

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        public static func == (lhs: ModelVersion, rhs: ModelVersion) -> Bool {
            lhs.id == rhs.id
        }

        public struct ModelFile: Codable, Hashable, Sendable {
            public let id: Int?
            public let name: String
            public let sizeKB: Double
            public let type: String
            public let downloadUrl: String
            public let hashes: [String: String]?
            public let metadata: FileMetadata?

            public struct FileMetadata: Codable, Hashable, Sendable {
                public let format: String?
                public let size: String?
                public let fp: String?
            }
        }

        public struct ModelImage: Codable, Identifiable, Hashable, Sendable {
            public let id: Int
            public let url: String
            public let nsfwLevel: Int?
            public let width: Int?
            public let height: Int?
            public let hash: String?

            public func hash(into hasher: inout Hasher) {
                hasher.combine(id)
            }

            public static func == (lhs: ModelImage, rhs: ModelImage) -> Bool {
                lhs.id == rhs.id
            }
        }
    }
}

// MARK: - Errors

public enum CivitAIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case downloadFailed(String)
    case fileSystemError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid CivitAI URL"
        case .invalidResponse:
            return "Invalid response from CivitAI"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .fileSystemError(let message):
            return "File system error: \(message)"
        }
    }
}
