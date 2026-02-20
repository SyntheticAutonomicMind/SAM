// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConfigurationSystem
import Logging

// MARK: - OpenRouter Provider

/// Provider for OpenRouter - a unified API gateway for 400+ AI models.
/// OpenRouter uses the OpenAI-compatible API format and requires specific
/// identification headers (HTTP-Referer, X-Title) for app attribution.
/// See: https://openrouter.ai/docs/api-reference/authentication
@MainActor
public class OpenRouterProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration
    private let logger = Logger(label: "com.sam.api.openrouter")

    /// Required identification headers per OpenRouter API docs.
    /// Without HTTP-Referer, OpenRouter falls back to cookie auth which fails with 401.
    private let httpReferer = "https://www.syntheticautonomicmind.org"
    private let appTitle = "SAM"

    public init(config: ProviderConfiguration) {
        self.identifier = config.providerId
        self.config = config
        logger.debug("OpenRouter Provider initialized")
    }

    public func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("OpenRouter API key not configured. Check Preferences -> Endpoints -> OpenRouter.")
        }

        let baseURL = config.baseURL ?? ProviderType.openrouter.defaultBaseURL ?? "https://openrouter.ai/api/v1"

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ProviderError.invalidConfiguration("Invalid OpenRouter base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(httpReferer, forHTTPHeaderField: "HTTP-Referer")
        urlRequest.setValue(appTitle, forHTTPHeaderField: "X-Title")

        let configuredTimeout = TimeInterval(config.timeoutSeconds ?? 300)
        urlRequest.timeoutInterval = max(configuredTimeout, 300)

        let requestBody: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map { message -> [String: Any] in
                var msgDict: [String: Any] = ["role": message.role]
                msgDict["content"] = message.content ?? NSNull()
                return msgDict
            },
            "max_tokens": request.maxTokens ?? config.maxTokens ?? 2048,
            "temperature": request.temperature ?? config.temperature ?? 0.7,
            "stream": true  /// Enable actual SSE streaming from OpenRouter.
        ]

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    if Task.isCancelled {
                        self.logger.debug("TASK_CANCELLED: OpenRouter streaming cancelled before start")
                        continuation.finish()
                        return
                    }

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ProviderError.networkError("Invalid response type"))
                        return
                    }

                    self.logger.debug("OpenRouter streaming response: \(httpResponse.statusCode)")

                    guard 200...299 ~= httpResponse.statusCode else {
                        /// Read error body from the stream.
                        var errorBody = ""
                        for try await byte in bytes {
                            errorBody.append(Character(UnicodeScalar(byte)))
                            if errorBody.count > 2000 { break }
                        }
                        self.logger.error("OpenRouter streaming error [\(httpResponse.statusCode)]: \(errorBody.prefix(500))")

                        var errorMessage = "OpenRouter returned status \(httpResponse.statusCode)"
                        if let errorJson = try? JSONSerialization.jsonObject(with: Data(errorBody.utf8)) as? [String: Any],
                           let error = errorJson["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            errorMessage = "OpenRouter error: \(message)"
                        }

                        if httpResponse.statusCode == 429 {
                            continuation.finish(throwing: ProviderError.rateLimitExceeded(errorMessage))
                        } else if httpResponse.statusCode == 401 {
                            continuation.finish(throwing: ProviderError.authenticationFailed(errorMessage))
                        } else {
                            continuation.finish(throwing: ProviderError.networkError(errorMessage))
                        }
                        return
                    }

                    /// Parse SSE stream: accumulate bytes into lines, decode JSON chunks.
                    var incompleteBuffer = ""
                    var byteBuffer: [UInt8] = []

                    for try await byte in bytes {
                        if Task.isCancelled {
                            self.logger.debug("TASK_CANCELLED: OpenRouter streaming cancelled")
                            continuation.finish()
                            return
                        }

                        byteBuffer.append(byte)

                        /// Try to decode accumulated bytes (handles multi-byte UTF-8).
                        if let char = String(bytes: byteBuffer, encoding: .utf8) {
                            incompleteBuffer.append(char)
                            byteBuffer.removeAll(keepingCapacity: true)
                        }

                        /// Process complete SSE events (ending with double newline).
                        while incompleteBuffer.contains("\n\n") {
                            guard let doubleNewlineRange = incompleteBuffer.range(of: "\n\n") else { break }
                            let completeEvent = String(incompleteBuffer[..<doubleNewlineRange.lowerBound])
                            incompleteBuffer = String(incompleteBuffer[doubleNewlineRange.upperBound...])

                            for line in completeEvent.components(separatedBy: "\n") {
                                guard line.hasPrefix("data: ") else { continue }
                                let jsonString = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)

                                if jsonString == "[DONE]" {
                                    self.logger.debug("OpenRouter SSE: received [DONE]")
                                    continuation.finish()
                                    return
                                }

                                guard !jsonString.isEmpty,
                                      let jsonData = jsonString.data(using: .utf8) else { continue }

                                do {
                                    let streamChunk = try JSONDecoder().decode(ServerOpenAIChatStreamChunk.self, from: jsonData)
                                    continuation.yield(streamChunk)
                                } catch {
                                    self.logger.warning("OpenRouter SSE: failed to decode chunk: \(error)")
                                }
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        let requestId = UUID().uuidString
        logger.debug("Processing chat completion via OpenRouter [req:\(requestId.prefix(8))]")

        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("OpenRouter API key not configured. Check Preferences -> Endpoints -> OpenRouter.")
        }

        let baseURL = config.baseURL ?? ProviderType.openrouter.defaultBaseURL ?? "https://openrouter.ai/api/v1"

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ProviderError.invalidConfiguration("Invalid OpenRouter base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        /// Required by OpenRouter for app identification and rankings.
        /// Without these, OpenRouter falls back to cookie auth which fails with 401.
        urlRequest.setValue(httpReferer, forHTTPHeaderField: "HTTP-Referer")
        urlRequest.setValue(appTitle, forHTTPHeaderField: "X-Title")



        /// Apply any user-configured custom headers (can override defaults above).
        if let customHeaders = config.customHeaders {
            for (key, value) in customHeaders {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        /// Create request body (OpenAI-compatible format).
        let requestBody: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map { message -> [String: Any] in
                var msgDict: [String: Any] = ["role": message.role]
                if let content = message.content {
                    msgDict["content"] = content
                } else {
                    msgDict["content"] = NSNull()
                }
                return msgDict
            },
            "max_tokens": request.maxTokens ?? config.maxTokens ?? 2048,
            "temperature": request.temperature ?? config.temperature ?? 0.7,
            "stream": false
        ]

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        let configuredTimeout = TimeInterval(config.timeoutSeconds ?? 300)
        urlRequest.timeoutInterval = max(configuredTimeout, 300)

        logger.debug("Sending request to OpenRouter [req:\(requestId.prefix(8))]")

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            logger.debug("OpenRouter response [req:\(requestId.prefix(8))]: \(httpResponse.statusCode)")

            guard 200...299 ~= httpResponse.statusCode else {
                var errorMessage = "OpenRouter returned status \(httpResponse.statusCode)"
                if let errorData = String(data: data, encoding: .utf8) {
                    logger.error("OpenRouter error [req:\(requestId.prefix(8))]: \(errorData)")

                    if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = errorJson["error"] as? [String: Any],
                       let message = error["message"] as? String {
                        errorMessage = "OpenRouter error: \(message)"
                    } else {
                        errorMessage = "OpenRouter returned status \(httpResponse.statusCode): \(errorData.prefix(200))"
                    }
                }

                /// Throw specific error types so the orchestrator can handle them properly.
                if httpResponse.statusCode == 429 {
                    throw ProviderError.rateLimitExceeded(errorMessage)
                } else if httpResponse.statusCode == 401 {
                    throw ProviderError.authenticationFailed(errorMessage)
                }
                throw ProviderError.networkError(errorMessage)
            }

            let openrouterResponse = try JSONDecoder().decode(ServerOpenAIChatResponse.self, from: data)
            logger.debug("Successfully processed OpenRouter response [req:\(requestId.prefix(8))]")

            return openrouterResponse

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("OpenRouter request failed [req:\(requestId.prefix(8))]: \(error)")
            throw ProviderError.networkError("Network error: \(error.localizedDescription)")
        }
    }

    public func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        let models = config.models.map { modelId in
            ServerOpenAIModel(
                id: modelId,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: "openrouter"
            )
        }

        return ServerOpenAIModelsResponse(
            object: "list",
            data: models
        )
    }

    public func supportsModel(_ model: String) -> Bool {
        return config.models.contains(model)
    }

    public func validateConfiguration() async throws -> Bool {
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw ProviderError.authenticationFailed("OpenRouter API key is required")
        }
        return true
    }

    // MARK: - Lifecycle

    public func loadModel() async throws -> ModelCapabilities {
        throw ProviderError.invalidRequest("loadModel() not supported for remote providers")
    }

    public func getLoadedStatus() async -> Bool {
        return false
    }

    public func unload() async {
        /// No-op for remote providers.
    }

    // MARK: - Model Capabilities Fetching

    /// Fetch model list from OpenRouter /v1/models endpoint.
    /// OpenRouter models include context_length in the top_provider block.
    public func fetchModelCapabilities() async throws -> [String: Int] {
        logger.debug("Fetching model capabilities from OpenRouter /v1/models API")

        guard let apiKey = config.apiKey else {
            throw ProviderError.authenticationFailed("OpenRouter API key not configured")
        }

        let baseURL = config.baseURL ?? ProviderType.openrouter.defaultBaseURL ?? "https://openrouter.ai/api/v1"

        guard let url = URL(string: "\(baseURL)/models") else {
            throw ProviderError.invalidConfiguration("Invalid OpenRouter models URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(httpReferer, forHTTPHeaderField: "HTTP-Referer")
        urlRequest.setValue(appTitle, forHTTPHeaderField: "X-Title")
        urlRequest.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("OpenRouter /models API error [\(httpResponse.statusCode)]: \(errorText.prefix(200))")
            throw ProviderError.networkError("OpenRouter /models API returned status \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            throw ProviderError.responseNormalizationFailed("Failed to parse OpenRouter /models response")
        }

        var capabilities: [String: Int] = [:]
        for model in models {
            guard let id = model["id"] as? String else { continue }

            /// OpenRouter provides context_length in top_provider block.
            let contextSize: Int
            if let topProvider = model["top_provider"] as? [String: Any],
               let ctxLen = topProvider["context_length"] as? Int {
                contextSize = ctxLen
            } else if let ctxLen = model["context_length"] as? Int {
                contextSize = ctxLen
            } else {
                contextSize = 8192
            }

            capabilities[id] = contextSize
        }

        return capabilities
    }
}
