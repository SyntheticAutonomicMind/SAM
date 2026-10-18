// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Shared HTTP helpers for remote API providers.
///
/// Before this utility existed, every remote provider duplicated ~40 lines of
/// URLRequest creation, header setting, timeout configuration, response
/// handling, and error parsing. This struct centralizes that boilerplate so
/// providers only need to describe what's unique (URL construction, request
/// body, custom headers) and delegate the rest.
///
/// Typical usage:
/// ```swift
/// let requestBody = request.buildOpenAICompatibleRequestBody(cacheControl: true)
/// let urlRequest = try RemoteProviderHTTP.buildChatCompletionRequest(
///     baseURL: baseURL, apiKey: apiKey, requestBody: requestBody,
///     timeoutSeconds: config.timeoutSeconds
/// )
/// let response = try await RemoteProviderHTTP.executeChatCompletion(
///     urlRequest: urlRequest, providerName: "DeepSeek",
///     requestId: requestId, logger: logger
/// )
/// ```
public struct RemoteProviderHTTP {

    /// Minimum timeout enforced for all requests (5 minutes).
    /// Tool-enabled requests to 7B models need this headroom.
    public static let minimumTimeout: TimeInterval = 300

    /// Build a standard URLRequest for an OpenAI-compatible `/chat/completions`
    /// endpoint with Bearer token authentication.
    ///
    /// - Parameters:
    ///   - baseURL: The provider's base URL (e.g. `https://api.deepseek.com/v1`).
    ///   - endpointPath: The path after the base URL (defaults to `chat/completions`).
    ///   - apiKey: The API key. If provided, a `Bearer` authorization header is added.
    ///   - requestBody: The request body dictionary to serialize.
    ///   - customHeaders: Additional headers to set (provider-specific identification
    ///     headers like OpenRouter's `HTTP-Referer` / `X-Title`).
    ///   - timeoutSeconds: Configured timeout in seconds. A minimum of 300s is enforced.
    /// - Returns: A configured `URLRequest` ready for `URLSession`.
    /// - Throws: `ProviderError.networkError` if the body can't be serialized or the URL is invalid.
    public static func buildChatCompletionRequest(
        baseURL: String,
        endpointPath: String = "chat/completions",
        apiKey: String?,
        requestBody: [String: Any],
        customHeaders: [String: String]? = nil,
        timeoutSeconds: Int? = nil
    ) throws -> URLRequest {
        let path = endpointPath.hasPrefix("/") ? String(endpointPath.dropFirst()) : endpointPath
        guard let url = URL(string: "\(baseURL)/\(path)") else {
            throw ProviderError.invalidConfiguration("Invalid base URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Apply custom headers after defaults (can override).
        if let customHeaders = customHeaders {
            for (key, value) in customHeaders {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        do {
            urlRequest.httpBody = try deterministicJSONData(from: requestBody)
        } catch {
            throw ProviderError.networkError("Failed to serialize request: \(error.localizedDescription)")
        }

        let configuredTimeout = TimeInterval(timeoutSeconds ?? Int(minimumTimeout))
        urlRequest.timeoutInterval = max(configuredTimeout, minimumTimeout)

        return urlRequest
    }

    /// Execute a chat completion HTTP request and decode the response.
    ///
    /// This centralizes the response-handling pattern that was duplicated across
    /// 7 providers: checking the HTTP status, extracting error messages from
    /// response bodies (with JSON `error.message` parsing), and decoding to
    /// `ServerOpenAIChatResponse`.
    ///
    /// - Parameters:
    ///   - urlRequest: The configured URLRequest.
    ///   - providerName: Human-readable name for log messages.
    ///   - requestId: UUID prefix for request tracing.
    ///   - logger: Logger for diagnostics.
    /// - Returns: Decoded `ServerOpenAIChatResponse`.
    /// - Throws: `ProviderError` with appropriate error type based on status code.
    public static func executeChatCompletion(
        urlRequest: URLRequest,
        providerName: String,
        requestId: String,
        logger: Logger
    ) async throws -> ServerOpenAIChatResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response type")
            }

            logger.debug("\(providerName) API response [req:\(requestId.prefix(8))]: \(httpResponse.statusCode)")

            guard 200...299 ~= httpResponse.statusCode else {
                let (errorMessage, errorType) = extractError(from: data, status: httpResponse.statusCode, providerName: providerName)

                if let errorData = String(data: data, encoding: .utf8) {
                    logger.error("\(providerName) API error [req:\(requestId.prefix(8))]: \(errorData)")
                }

                throw errorType(errorMessage)
            }

            let decodedResponse = try JSONDecoder().decode(ServerOpenAIChatResponse.self, from: data)
            logger.debug("Successfully processed \(providerName) response [req:\(requestId.prefix(8))]")
            return decodedResponse

        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("\(providerName) API request failed [req:\(requestId.prefix(8))]: \(error)")
            throw ProviderError.networkError("Network error: \(error.localizedDescription)")
        }
    }

    /// Build a standard URLRequest for a `GET` request (used for `/models` endpoint).
    public static func buildGetRequest(
        urlString: String,
        apiKey: String?,
        timeoutInterval: TimeInterval = 30
    ) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw ProviderError.invalidConfiguration("Invalid URL: \(urlString)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        urlRequest.timeoutInterval = timeoutInterval
        return urlRequest
    }

    /// Parse an HTTP error response body to extract the error message and
    /// determine the appropriate `ProviderError` case.
    ///
    /// Many OpenAI-compatible APIs return errors in the format:
    /// `{"error": {"message": "...", "code": "rate_limit", "type": "..."}}`
    ///
    /// - Parameters:
    ///   - data: The raw response body data.
    ///   - status: The HTTP status code.
    ///   - providerName: For fallback error messages.
    /// - Returns: A tuple of (errorMessage, errorType) where `errorType` is a
    ///   closure that constructs the appropriate `ProviderError` from a message string.
    public static func extractError(
        from data: Data,
        status: Int,
        providerName: String
    ) -> (message: String, errorType: (String) -> ProviderError) {
        var errorMessage = "\(providerName) returned status \(status)"
        var errorType: (String) -> ProviderError = { ProviderError.networkError($0) }

        if let errorData = String(data: data, encoding: .utf8), !errorData.isEmpty {
            errorMessage = errorData.prefix(200).description
        }

        // Try to parse JSON error response for a useful message.
        if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = errorJson["error"] as? [String: Any],
           let message = error["message"] as? String {
            errorMessage = "\(providerName) error: \(message)"
        }

        // Map status codes to specific ProviderError cases.
        switch status {
        case 401:
            errorType = ProviderError.authenticationFailed
        case 429:
            errorType = ProviderError.rateLimitExceeded
        default:
            errorType = ProviderError.networkError
        }

        return (errorMessage, errorType)
    }

    /// Strip the provider prefix from a model identifier.
    /// Converts `"openai/gpt-4"` -> `"gpt-4"`, `"deepseek/deepseek-chat"` -> `"deepseek-chat"`.
    /// If there's no `/` prefix, returns the model as-is.
    public static func stripProviderPrefix(from model: String) -> String {
        return model.contains("/")
            ? model.components(separatedBy: "/").last ?? model
            : model
    }
}
