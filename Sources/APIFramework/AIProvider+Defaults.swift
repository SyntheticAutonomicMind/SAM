// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem
import ConversationEngine

// MARK: - AIProvider Default Implementations

/// Protocol extension providing default implementations for AIProvider methods
/// that are identical or nearly-identical across all remote (non-local) providers.
///
/// Before this extension existed, 7 remote providers each copy-pasted:
/// - `loadModel()` / `unload()` / `getLoadedStatus()` lifecycle stubs (7× 3 methods)
/// - `getAvailableModels()` model listing (6×)
/// - `validateConfiguration()` API key validation (7×)
/// - `processStreamingChatCompletion()` fallback streaming (6×, excluding native SSE providers)
/// - `convertToStreamChunks()` streaming chunk conversion (7×, 3 variants)
///
/// Total: ~1,000 lines of pure duplication across 5 files.
///
/// Providers that need different behavior (local providers for `loadModel`,
/// providers with native SSE for `processStreamingChatCompletion`, providers
/// with custom model prefixes for `supportsModel`) simply override the
/// default.
public extension AIProvider {

    // MARK: - Lifecycle (default for remote providers)

    /// Default implementation: all remote providers throw this error.
    /// Local providers (LLamaProvider, MLXProvider) override with real loading.
    func loadModel() async throws -> ModelCapabilities {
        throw ProviderError.invalidRequest("loadModel() not supported for this provider")
    }

    /// Default implementation: returns false (model not loaded in memory).
    /// Override in `RemoteLlamaProvider` (returns true — server manages models)
    /// and in local providers (checks actual model load state).
    func getLoadedStatus() async -> Bool {
        return false
    }

    /// Default implementation: no-op for remote providers.
    func unload() async {
        // No-op.
    }

    // MARK: - Model Listing

    /// Default implementation: maps `config.models` to `ServerOpenAIModel`
    /// objects using the provider type's `modelOwner` string.
    ///
    /// Providers with dynamic model lists (GitHub Copilot, RemoteLlama,
    /// OpenRouter, Gemini) override this to fetch from the API.
    func getAvailableModels() async throws -> ServerOpenAIModelsResponse {
        let models = config.models.map { modelId in
            ServerOpenAIModel(
                id: modelId,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: config.providerType.modelOwner
            )
        }

        return ServerOpenAIModelsResponse(
            object: "list",
            data: models
        )
    }

    // MARK: - Configuration Validation

    /// Default implementation: validates that an API key is present if the
    /// provider type requires one. Some providers (Custom, RemoteLlama)
    /// override to add additional checks (e.g., base URL).
    func validateConfiguration() async throws -> Bool {
        if config.requiresApiKey {
            guard let apiKey = config.apiKey, !apiKey.isEmpty else {
                throw ProviderError.authenticationFailed("\(config.providerType.displayName) API key is required")
            }
        }
        return true
    }

    // MARK: - Fallback Streaming

    /// Default fallback streaming implementation for providers without
    /// native SSE support.
    ///
    /// Calls `processChatCompletion` to get the full response, then converts
    /// it to simulated streaming chunks via `OpenAIStreamConverter`.
    ///
    /// Providers with native SSE streaming (OpenRouter, MiniMax, GitHub Copilot,
    /// RemoteLlama, MLX, Llama) override this with their real SSE implementation.
    func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        let providerName = config.providerType.displayName
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    let response = try await self.processChatCompletion(request)
                    let chunks = OpenAIStreamConverter.convertToStreamChunks(response)

                    for chunk in chunks {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }

                        continuation.yield(chunk)
                        try await Task.sleep(nanoseconds: OpenAIStreamConverter.fallbackStreamDelay)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
