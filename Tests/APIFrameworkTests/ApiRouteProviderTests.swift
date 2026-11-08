// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework
@testable import ConfigurationSystem

final class ApiRouteProviderTests: XCTestCase {
    func testConfigurationRoundTripPreservesProviderAndSelectedModels() throws {
        let config = ProviderConfiguration(
            providerId: "api-route",
            providerType: .apiRoute,
            isEnabled: false,
            baseURL: ProviderType.apiRoute.defaultBaseURL,
            models: ["deepseek-v4.1-flash"]
        )
        let decoded = try JSONDecoder().decode(
            ProviderConfiguration.self,
            from: JSONEncoder().encode(config)
        )
        XCTAssertEqual(decoded.providerType, .apiRoute)
        XCTAssertEqual(decoded.baseURL, "https://global.api-route.com/v1")
        XCTAssertEqual(decoded.models, ["deepseek-v4.1-flash"])
        XCTAssertFalse(decoded.isEnabled)
        XCTAssertNil(decoded.apiKey)
        XCTAssertTrue(ProviderType.apiRoute.requiresApiKey)
        XCTAssertTrue(ProviderType.apiRoute.defaultModels.isEmpty)
    }

    @MainActor
    func testConfiguredModelsUseApiRouteOwnership() async throws {
        let config = ProviderConfiguration(
            providerId: "api-route",
            providerType: .apiRoute,
            isEnabled: true,
            apiKey: "test-key",
            baseURL: ProviderType.apiRoute.defaultBaseURL,
            models: ["deepseek-v4.1-flash"]
        )
        let provider = ApiRouteProvider(config: config)
        XCTAssertTrue(provider.supportsModel("deepseek-v4.1-flash"))
        XCTAssertFalse(provider.supportsModel("not-selected"))
        let response = try await provider.getAvailableModels()
        XCTAssertEqual(response.data.first?.id, "deepseek-v4.1-flash")
        XCTAssertEqual(response.data.first?.ownedBy, "api-route")
    }

    @MainActor
    func testMissingKeyFailsBeforeMakingARequest() async {
        let config = ProviderConfiguration(
            providerId: "api-route", providerType: .apiRoute, isEnabled: true
        )
        let provider = ApiRouteProvider(config: config)
        do {
            _ = try await provider.processChatCompletion(
                OpenAIChatRequest(model: "deepseek-v4.1-flash", messages: [])
            )
            XCTFail("A missing API key must be rejected")
        } catch ProviderError.authenticationFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
