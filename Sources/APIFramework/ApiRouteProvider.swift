// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConfigurationSystem
import Logging

@MainActor
public class ApiRouteProvider: AIProvider {
    public let identifier: String
    public let config: ProviderConfiguration
    private let logger = Logger(label: "com.sam.api.apiroute")

    public init(config: ProviderConfiguration) {
        self.identifier = config.providerId
        self.config = config
    }

    public func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse {
        guard let apiKey = config.apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.authenticationFailed("API Route API key not configured")
        }
        guard let baseURL = config.baseURL ?? ProviderType.apiRoute.defaultBaseURL else {
            throw ProviderError.invalidConfiguration("API Route base URL not configured")
        }

        let requestBody = request.buildOpenAICompatibleRequestBody(cacheControl: true)
        let urlRequest = try RemoteProviderHTTP.buildChatCompletionRequest(
            baseURL: baseURL,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            requestBody: requestBody,
            timeoutSeconds: config.timeoutSeconds
        )
        return try await RemoteProviderHTTP.executeChatCompletion(
            urlRequest: urlRequest,
            providerName: "API Route",
            requestId: UUID().uuidString,
            logger: logger
        )
    }

    public func supportsModel(_ model: String) -> Bool {
        return config.models.contains(model)
    }
}
