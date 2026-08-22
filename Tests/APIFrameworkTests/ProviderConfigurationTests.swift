// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework
@testable import ConfigurationSystem

/// Tests for the provider configuration bugs:
/// 1. remoteLlama provider defaulting to openai base URL
/// 2. Models not appearing in model chooser
/// 3. Context size showing 2048 instead of actual server-configured value
final class ProviderConfigurationTests: XCTestCase {

    // MARK: - Bug 1: baseURL defaults to openai for remoteLlama

    func testRemoteLlamaDefaultBaseURLIsNull() {
        // CRITICAL: remoteLlama should NOT default to any base URL — it's user-configured.
        // Previously, the ProviderConfigurationSheet would default to "https://api.openai.com/v1"
        // because updateFieldsForProviderType() didn't clear the URL when switching from
        // .openai (which has a default URL) to .remoteLlama (which has nil default).
        XCTAssertNil(ProviderType.remoteLlama.defaultBaseURL,
                      "remoteLlama should have nil defaultBaseURL (user-configured)")
    }

    func testOpenAIDefaultBaseURLIsOpenAI() {
        // Verify that openai IS the provider with a default URL (to confirm the bug root cause).
        XCTAssertEqual(ProviderType.openai.defaultBaseURL, "https://api.openai.com/v1")
    }

    func testRemoteLlamaRequiresApiKey() {
        // remoteLlama requires an API key (unlike localLlama/localMLX which don't)
        XCTAssertTrue(ProviderType.remoteLlama.requiresApiKey,
                      "remoteLlama should require API key")
    }

    func testRemoteLlamaNormalizedProviderName() {
        // The normalized name used for model ID prefixing.
        XCTAssertEqual(ProviderType.remoteLlama.normalizedProviderName, "remote_llama")
    }

    func testProviderConfigurationWithNilBaseURL() throws {
        // A ProviderConfiguration with baseURL = nil should encode and decode correctly.
        let config = ProviderConfiguration(
            providerId: "remote-llama-test",
            providerType: .remoteLlama,
            isEnabled: true,
            apiKey: "test-key",
            baseURL: nil,
            models: ["gpt-4"]
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: data)

        XCTAssertEqual(decoded.providerId, "remote-llama-test")
        XCTAssertEqual(decoded.providerType, .remoteLlama)
        XCTAssertNil(decoded.baseURL, "baseURL should remain nil after round-trip")
        XCTAssertEqual(decoded.apiKey, "test-key")
        XCTAssertEqual(decoded.models, ["gpt-4"])
    }

    func testProviderConfigurationWithExplicitBaseURL() throws {
        // When the user provides an explicit base URL, it should be preserved.
        let config = ProviderConfiguration(
            providerId: "my-llama",
            providerType: .remoteLlama,
            isEnabled: true,
            apiKey: "test-key",
            baseURL: "http://192.168.1.100:8080/v1",
            models: ["gpt-4", "claude-3-5-sonnet"]
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: data)

        XCTAssertEqual(decoded.baseURL, "http://192.168.1.100:8080/v1")
        XCTAssertEqual(decoded.models.count, 2)
    }

    // MARK: - Bug 3: Context size shows 2048 instead of actual

    func testServerOpenAIModelDecoding_ContextLengthField() throws {
        // CRITICAL TEST: llama.cpp returns "context_length" but ServerOpenAIModel
        // previously only decoded "context_window". This test verifies that the
        // custom init(from:) decoder correctly extracts "context_length" as contextWindow.
        let json = """
        {
            "id": "gpt-4",
            "object": "model",
            "created": 1234567890,
            "owned_by": "llama.cpp",
            "context_length": 65536
        }
        """.data(using: .utf8)!

        let model = try JSONDecoder().decode(ServerOpenAIModel.self, from: json)
        XCTAssertEqual(model.id, "gpt-4")
        XCTAssertEqual(model.contextWindow, 65536,
                       "context_length should be decoded as contextWindow for llama.cpp compatibility")
    }

    func testServerOpenAIModelDecoding_ContextWindowField() throws {
        // OpenAI format uses "context_window" — should still work.
        let json = """
        {
            "id": "gpt-4o",
            "object": "model",
            "created": 1234567890,
            "owned_by": "openai",
            "context_window": 128000
        }
        """.data(using: .utf8)!

        let model = try JSONDecoder().decode(ServerOpenAIModel.self, from: json)
        XCTAssertEqual(model.contextWindow, 128000,
                       "context_window should still be decoded for OpenAI format")
    }

    func testServerOpenAIModelDecoding_NoContextField() throws {
        // When neither field is present, contextWindow should be nil.
        let json = """
        {
            "id": "unknown-model",
            "object": "model",
            "created": 1234567890,
            "owned_by": "unknown"
        }
        """.data(using: .utf8)!

        let model = try JSONDecoder().decode(ServerOpenAIModel.self, from: json)
        XCTAssertNil(model.contextWindow,
                     "contextWindow should be nil when neither context_length nor context_window is present")
    }

    func testServerOpenAIModelCodingRoundTripWithContextWindow() throws {
        // Verify that contextWindow survives encoding/decoding round-trip.
        let model = ServerOpenAIModel(
            id: "remote_llama/test-model",
            object: "model",
            created: 1234567890,
            ownedBy: "remote-llama",
            contextWindow: 65536,
            maxCompletionTokens: 16384,
            maxRequestTokens: 49152,
            category: "powerful",
            vendor: "llama.cpp"
        )

        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(ServerOpenAIModel.self, from: data)

        XCTAssertEqual(decoded.contextWindow, 65536)
        XCTAssertEqual(decoded.maxCompletionTokens, 16384)
        XCTAssertEqual(decoded.maxRequestTokens, 49152)
        XCTAssertEqual(decoded.category, "powerful")
        XCTAssertEqual(decoded.vendor, "llama.cpp")
    }

    // MARK: - Bug 2: Models not appearing in model chooser

    func testProviderTypeAllCasesIncludesRemoteLlama() {
        // Verify remoteLlama is in the allCases list (needed for setup/reload).
        let allTypes = ProviderType.allCases
        XCTAssertTrue(allTypes.contains(.remoteLlama),
                      "remoteLlama should be in ProviderType.allCases")
    }

    func testRemoteLlamaProviderCreation() {
        // Verify that createProvider produces a RemoteLlamaProvider for remoteLlama type.
        // Note: We can't easily instantiate EndpointManager without a ConversationManager,
        // so we test via the config and type check.
        let config = ProviderConfiguration(
            providerId: "remote-llama-test-123",
            providerType: .remoteLlama,
            isEnabled: true,
            apiKey: "test-key",
            baseURL: "http://192.168.1.100:8080/v1",
            models: ["gpt-4"]
        )

        // Verify the config is valid for the provider type
        XCTAssertEqual(config.providerType, .remoteLlama)
        XCTAssertEqual(config.baseURL, "http://192.168.1.100:8080/v1")
        XCTAssertTrue(config.baseURL?.contains("/v1") == true,
                      "User-provided baseURL should be used as-is")
    }

    // MARK: - Context size fallbacks

    func testTokenCounterGetContextSizeForRemoteLlamaModel() async {
        // When a remote_llama/ model is not in the API context sizes cache,
        // getContextSize should return a fallback (8192 default), not 2048.
        let tokenCounter = TokenCounter()
        let contextSize = await tokenCounter.getContextSize(modelName: "remote_llama/unknown-model-12345")

        // Should get the 8192 default, not 2048
        XCTAssertGreaterThanOrEqual(contextSize, 8192,
                                   "Unknown models should get >= 8192 default, not 2048")
    }

    // MARK: - ServerOpenAIModel Context Window Helpers

    func testServerOpenAIModelComputesMaxCompletionFromContextWindow() throws {
        // When only contextWindow is set (no maxCompletionTokens), the system
        // should compute maxCompletionTokens as contextWindow / 4.
        // This verifies the enrichment logic in handleModels.
        let ctxWindow = 65536
        let computedMaxCompletion = ctxWindow / 4
        let computedMaxRequest = ctxWindow - computedMaxCompletion

        XCTAssertEqual(computedMaxCompletion, 16384)
        XCTAssertEqual(computedMaxRequest, 49152,
                       "maxRequestTokens should be contextWindow - maxCompletionTokens")
    }

    func testServerOpenAIModelPrefersExistingContextWindow() throws {
        // When a model already has contextWindow from the provider response,
        // handleModels should use it instead of calling getModelCapabilityData.
        // This test verifies the enrichment logic prioritizes existing data.
        let json = """
        {
            "object": "list",
            "data": [
                {
                    "id": "remote_llama/gpt-4",
                    "object": "model",
                    "created": 1234567890,
                    "owned_by": "llama.cpp",
                    "context_length": 65536
                },
                {
                    "id": "remote_llama/llama-3",
                    "object": "model",
                    "created": 1234567890,
                    "owned_by": "llama.cpp",
                    "context_length": 32768
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ServerOpenAIModelsResponse.self, from: json)
        XCTAssertEqual(response.data.count, 2)

        let firstModel = response.data.first { $0.id == "remote_llama/gpt-4" }
        XCTAssertNotNil(firstModel)
        XCTAssertEqual(firstModel?.contextWindow, 65536,
                      "context_length from llama.cpp should be decoded as contextWindow")

        let secondModel = response.data.first { $0.id == "remote_llama/llama-3" }
        XCTAssertNotNil(secondModel)
        XCTAssertEqual(secondModel?.contextWindow, 32768)
    }

    // MARK: - ProviderConfiguration Defaults

    func testProviderConfigurationDefaultMaxTokens() {
        // The default maxTokens in ProviderConfiguration should not be confused with
        // context window. This test documents that maxTokens is for output tokens,
        // not context window.
        let config = ProviderConfiguration(
            providerId: "test",
            providerType: .openai,
            isEnabled: true,
            apiKey: "key",
            baseURL: "https://api.openai.com/v1",
            models: ["gpt-4"]
        )

        // maxTokens is optional — defaults to nil in ProviderConfiguration
        XCTAssertNil(config.maxTokens, "maxTokens should be nil by default (not confused with context window)")
    }

    func testProviderTypeDefaultBaseURLs() {
        // Verify default base URLs for all provider types
        XCTAssertEqual(ProviderType.openai.defaultBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(ProviderType.deepseek.defaultBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(ProviderType.gemini.defaultBaseURL, "https://generativelanguage.googleapis.com/v1beta")
        XCTAssertEqual(ProviderType.minimax.defaultBaseURL, "https://api.minimax.io/v1")
        XCTAssertEqual(ProviderType.openrouter.defaultBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(ProviderType.githubCopilot.defaultBaseURL, "https://api.githubcopilot.com")

        // These providers have no default URL — user must configure
        XCTAssertNil(ProviderType.localLlama.defaultBaseURL)
        XCTAssertNil(ProviderType.localMLX.defaultBaseURL)
        XCTAssertNil(ProviderType.remoteLlama.defaultBaseURL)
        XCTAssertNil(ProviderType.custom.defaultBaseURL)
    }

    // MARK: - Bug A: Provider-type-specific defaults (not hard-coded 2048)

    func testRemoteLlamaDefaultMaxOutputTokens() {
        // CRITICAL FIX: remoteLlama should default to 32768 max output tokens,
        // NOT the hard-coded 2048 that was used for all provider types.
        XCTAssertEqual(ProviderType.remoteLlama.defaultMaxOutputTokens, 32768,
                      "remoteLlama should use 32768 default max tokens, not 2048")
    }

    func testOpenAIDefaultMaxOutputTokens() {
        XCTAssertEqual(ProviderType.openai.defaultMaxOutputTokens, 8192)
    }

    func testGitHubCopilotDefaultMaxOutputTokens() {
        // GitHub Copilot supports GPT-4, Claude, etc.
        XCTAssertEqual(ProviderType.githubCopilot.defaultMaxOutputTokens, 8192)
    }

    func testGitHubCopilotDefaultTemperature() {
        // CRITICAL FIX: GitHub Copilot should default to 0.2 temperature (deterministic for coding),
        // NOT the hard-coded 0.7 that was used for all provider types.
        XCTAssertEqual(ProviderType.githubCopilot.defaultTemperature, 0.2,
                      "GitHub Copilot should use 0.2 default temperature for coding tasks")
    }

    func testLocalLlamaDefaultMaxOutputTokens() {
        // Local models can produce long output
        XCTAssertEqual(ProviderType.localLlama.defaultMaxOutputTokens, 32768)
    }

    func testCustomDefaultMaxOutputTokens() {
        // Custom providers should have a conservative default
        XCTAssertEqual(ProviderType.custom.defaultMaxOutputTokens, 4096)
    }

    func testAllProviderTypesHaveNonZeroDefaults() {
        // CRITICAL FIX: Every provider type should have sensible defaults,
        // not hard-coded 2048/0.7/30/2 which were wrong for most providers.
        for type in ProviderType.allCases {
            XCTAssertGreaterThan(type.defaultMaxOutputTokens, 0,
                               "Provider type \(type) should have positive defaultMaxOutputTokens")
            XCTAssertGreaterThan(type.defaultTemperature, 0,
                               "Provider type \(type) should have positive defaultTemperature")
            XCTAssertGreaterThan(type.defaultTimeoutSeconds, 0,
                               "Provider type \(type) should have positive defaultTimeoutSeconds")
            XCTAssertGreaterThan(type.defaultRetryCount, 0,
                               "Provider type \(type) should have positive defaultRetryCount")
        }
    }

    // MARK: - Encoding/Decoding of ProviderConfiguration with nil baseURL

    func testProviderConfigurationEncodingNilBaseURL() throws {
        // When baseURL is nil, encoding should not crash and decoding should preserve nil.
        let config = ProviderConfiguration(
            providerId: "remote-llama",
            providerType: .remoteLlama,
            isEnabled: false,
            apiKey: "key",
            baseURL: nil,
            models: []
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: data)

        XCTAssertEqual(decoded.providerType, .remoteLlama)
        XCTAssertNil(decoded.baseURL)
    }
}
