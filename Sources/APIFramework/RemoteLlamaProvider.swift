// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConfigurationSystem
import Logging

private let logger = Logger(label: "com.sam.api.remoteLlama")

/// Provider for remote llama.cpp server instances (OpenAI-compatible API).
///
/// Connects to llama.cpp server, text-generation-inference, vLLM, LM Studio,
/// and other OpenAI-compatible inference servers running on remote hardware.
///
/// Key features:
/// - OpenAI-compatible chat completions API
/// - Streaming support via SSE
/// - Tool calling (for models that support it)
/// - Deterministic serialization for prompt caching
/// - Configurable base URL and API key
public class RemoteLlamaProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration

    private let requestId: String

    public init(config: ProviderConfiguration) {
        self.identifier = config.providerId
        self.config = config
        self.requestId = UUID().uuidString.prefix(8).lowercased()
        logger.info("RemoteLlamaProvider initialized for \(config.providerId)")
    }

    // MARK: - AIProvider Protocol

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        guard let baseURL = config.baseURL else {
            throw ProviderError.invalidConfiguration("Remote llama.cpp server requires a base URL (e.g., http://192.168.1.100:8080)")
        }

        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("API key required for remote llama.cpp server")
        }

        let endpoint = buildEndpointURL(baseURL: baseURL, path: "chat/completions")
        guard let url = URL(string: endpoint) else {
            throw ProviderError.invalidConfiguration("Invalid base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Build request using shared builder with deterministic serialization and cache_control
        let requestBody = request.buildOpenAICompatibleRequestBody(cacheControl: true)

        do {
            urlRequest.httpBody = try deterministicJSONData(from: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        let configuredTimeout = TimeInterval(config.timeoutSeconds ?? 300)
        urlRequest.timeoutInterval = max(configuredTimeout, 300)

        logger.debug("Sending request to remote llama.cpp server [req:\(requestId)]")

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            logger.debug("Remote llama.cpp response [req:\(requestId)]: \(httpResponse.statusCode)")

            guard 200...299 ~= httpResponse.statusCode else {
                if let errorData = String(data: data, encoding: .utf8) {
                    logger.error("Remote llama.cpp error [req:\(requestId)]: \(errorData)")
                }
                throw ProviderError.networkError("Remote llama.cpp server returned status \(httpResponse.statusCode)")
            }

            let serverResponse = try JSONDecoder().decode(ServerOpenAIChatResponse.self, from: data)
            logger.debug("Successfully processed remote llama.cpp response [req:\(requestId)]")

            return serverResponse

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("Remote llama.cpp request failed [req:\(requestId)]: \(error)")
            throw ProviderError.networkError("Network error: \(error.localizedDescription)")
        }
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        guard let baseURL = config.baseURL else {
            throw ProviderError.invalidConfiguration("Remote llama.cpp server requires a base URL")
        }

        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("API key required for remote llama.cpp server")
        }

        let endpoint = buildEndpointURL(baseURL: baseURL, path: "chat/completions")
        guard let url = URL(string: endpoint) else {
            throw ProviderError.invalidConfiguration("Invalid base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Build request with streaming enabled, deterministic serialization, and cache_control
        let requestBody = request.buildOpenAICompatibleRequestBody(streamEnabled: true, cacheControl: true)

        do {
            urlRequest.httpBody = try deterministicJSONData(from: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        let configuredTimeout = TimeInterval(config.timeoutSeconds ?? 300)
        urlRequest.timeoutInterval = max(configuredTimeout, 300)

        logger.debug("Sending streaming request to remote llama.cpp server [req:\(requestId)]")

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ProviderError.networkError("Invalid response type"))
                        return
                    }

                    guard 200...299 ~= httpResponse.statusCode else {
                        continuation.finish(throwing: ProviderError.networkError("Remote llama.cpp server returned status \(httpResponse.statusCode)"))
                        return
                    }

                    var buffer = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let dataString = String(line.dropFirst(6))

                        if dataString == "[DONE]" {
                            break
                        }

                        buffer += dataString
                        guard let jsonData = buffer.data(using: .utf8) else { continue }

                        if let chunk = try? JSONDecoder().decode(ServerOpenAIChatStreamChunk.self, from: jsonData) {
                            buffer = ""
                            continuation.yield(chunk)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - URL Helpers

    /// Build a fully-qualified URL for the llama.cpp OpenAI-compatible API.
    /// CRITICAL FIX: Handles baseURL that may or may not include a /v1 suffix.
    /// Previously: "\(baseURL)/v1/models" would produce "http://host/v1/v1/models"
    /// when baseURL already included "/v1". Now properly normalizes.
    private func buildEndpointURL(baseURL: String, path: String) -> String {
        let cleanBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        if cleanBase.hasSuffix("/v1") {
            return "\(cleanBase)/\(path)"
        }
        return "\(cleanBase)/v1/\(path)"
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        guard let baseURL = config.baseURL else {
            throw ProviderError.invalidConfiguration("Remote llama.cpp server requires a base URL (e.g., http://192.168.1.100:8080)")
        }

        // CRITICAL FIX: Use buildEndpointURL to handle baseURL with/without /v1 suffix
        let modelsURL = buildEndpointURL(baseURL: baseURL, path: "models")

        guard let url = URL(string: modelsURL) else {
            throw ProviderError.invalidConfiguration("Invalid base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = config.apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        urlRequest.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        guard 200...299 ~= httpResponse.statusCode else {
            if let errorData = String(data: data, encoding: .utf8) {
                logger.error("Remote llama.cpp models fetch error [req:\(requestId)]: \(errorData)")
            }
            throw ProviderError.networkError("Remote llama.cpp server returned status \(httpResponse.statusCode) when fetching models")
        }

        // CRITICAL FIX: llama.cpp's /v1/models returns "context_length" per model,
        // but ServerOpenAIModel's CodingKeys expect "context_window". We parse the
        // JSON manually to extract context_length (and context_window for OpenAI compat)
        // before decoding, then inject the values into the decoded models.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.responseNormalizationFailed("Failed to parse remote llama.cpp /models response")
        }

        // Extract context sizes from raw JSON before decoding.
        var contextLengths: [String: Int] = [:]
        if let modelsArray = json["data"] as? [[String: Any]] {
            for model in modelsArray {
                if let id = model["id"] as? String {
                    let ctxLen = model["context_length"] as? Int ??
                                 model["context_window"] as? Int
                    if let ctxLen = ctxLen {
                        contextLengths[id] = ctxLen
                    }
                }
            }
        }

        // Decode using ServerOpenAIModelsResponse
        let modelsResponse = try JSONDecoder().decode(ServerOpenAIModelsResponse.self, from: data)

        // Re-inject context_length into the decoded models (CodingKey mismatch fix).
        let enrichedModels = modelsResponse.data.map { model -> ServerOpenAIModel in
            if let ctxLen = contextLengths[model.id] {
                return ServerOpenAIModel(
                    id: model.id,
                    object: model.object,
                    created: model.created,
                    ownedBy: model.ownedBy,
                    contextWindow: ctxLen,
                    maxCompletionTokens: model.maxCompletionTokens,
                    maxRequestTokens: model.maxRequestTokens,
                    category: model.category,
                    vendor: model.vendor
                )
            }
            return model
        }

        return ServerOpenAIModelsResponse(
            object: modelsResponse.object,
            data: enrichedModels
        )
    }

    // MARK: - Model Capabilities Fetching

    /// Fetch model capabilities (context sizes) from the remote llama.cpp server.
    /// llama.cpp's /v1/models endpoint includes `context_length` per model.
    /// This method extracts those values for use by TokenCounter and getModelCapabilityData.
    /// CRITICAL FIX: Previously RemoteLlamaProvider had NO fetchModelCapabilities method,
    /// so context sizes were never learned from the server — they defaulted to 8192 or
    /// the hardcoded 2048 fallback, ignoring the server's actual configured context.
    public func fetchModelCapabilities() async throws -> [String: Int] {
        guard let baseURL = config.baseURL else {
            throw ProviderError.invalidConfiguration("Remote llama.cpp server requires a base URL")
        }

        let modelsURL = buildEndpointURL(baseURL: baseURL, path: "models")

        guard let url = URL(string: modelsURL) else {
            throw ProviderError.invalidConfiguration("Invalid base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = config.apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        urlRequest.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        guard 200...299 ~= httpResponse.statusCode else {
            throw ProviderError.networkError("Remote llama.cpp server returned status \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.responseNormalizationFailed("Failed to parse remote llama.cpp /models response")
        }

        var capabilities: [String: Int] = [:]

        // Try OpenAI-compatible format (data array) — llama.cpp returns this from /v1/models
        if let modelsArray = json["data"] as? [[String: Any]] {
            for model in modelsArray {
                guard let id = model["id"] as? String else { continue }
                // llama.cpp returns "context_length", OpenAI uses "context_window"
                let contextSize = model["context_length"] as? Int ??
                                  model["context_window"] as? Int ??
                                  8192  // Conservative fallback if not provided
                capabilities[id] = contextSize
                logger.debug("Remote llama.cpp model '\(id)': \(contextSize) tokens")
            }
        }
        // Try llama.cpp native format (models array)
        else if let modelsArray = json["models"] as? [[String: Any]] {
            for model in modelsArray {
                let id = model["model"] as? String ?? model["name"] as? String ?? ""
                guard !id.isEmpty else { continue }

                let cleanId = URL(fileURLWithPath: id).lastPathComponent

                // llama.cpp native format may include context_length
                let contextSize = model["context_length"] as? Int ??
                                  model["context_window"] as? Int ??
                                  8192  // Conservative fallback
                capabilities[cleanId] = contextSize
                logger.debug("Remote llama.cpp model '\(cleanId)': \(contextSize) tokens")
            }
        } else {
            throw ProviderError.responseNormalizationFailed("Unknown /models response format from \(baseURL)")
        }

        logger.debug("Successfully fetched \(capabilities.count) model capabilities from remote llama.cpp server")
        return capabilities
    }

    public func supportsModel(_ model: String) -> Bool {
        // Check configured models first, then accept any model if no models configured
        if config.models.isEmpty {
            return true
        }
        return config.models.contains(model) || model.hasPrefix("remote_llama/")
    }

    public func validateConfiguration() async throws -> Bool {
        guard config.baseURL != nil else {
            throw ProviderError.invalidConfiguration("Base URL is required for remote llama.cpp server")
        }

        // API key is required but can be any non-empty string for some servers
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("API key is required")
        }

        return true
    }

    // MARK: - Lifecycle

    public func loadModel() async throws -> ModelCapabilities {
        throw ProviderError.invalidRequest("loadModel() not supported for remote providers")
    }

    public func getLoadedStatus() async -> Bool {
        // Remote servers are always "loaded" - they manage their own models
        return true
    }

    public func unload() async {
        // No-op for remote providers
    }
}