// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework
@testable import ConversationEngine
@testable import ConfigurationSystem

@MainActor
final class EndpointManagerTests: XCTestCase {
    
    var conversationManager: MockConversationManager!
    var endpointManager: EndpointManager!
    
    override func setUp() async throws {
        conversationManager = MockConversationManager()
        endpointManager = EndpointManager(conversationManager: conversationManager)
    }
    
    override func tearDown() async throws {
        endpointManager = nil
        conversationManager = nil
    }
    
    // MARK: - Lifecycle
    
    func testEndpointManagerInitialization() throws {
        XCTAssertNotNil(endpointManager)
    }
    
    // MARK: - Provider Selection Tests
    
    /// NOTE: This test now verifies the correct error behavior when no providers are configured In a real environment with configured providers, this would test successful routing.
    func testSAMInternalProviderSelection() async throws {
        let request = OpenAIChatRequest(
            model: "sam-assistant",
            messages: [
                OpenAIChatMessage(role: "user", content: "Hello")
            ],
            temperature: nil,
            maxTokens: nil,
            stream: nil,
            samConfig: nil,
            contextId: nil,
            enableMemory: nil
        )
        
        /// Without configured providers, should throw noProviderAvailable error.
        do {
            _ = try await endpointManager.processChatCompletion(request)
            XCTFail("Should have thrown noProviderAvailable error")
        } catch let error as EndpointManagerError {
            switch error {
            case .noProviderAvailable(let model):
                XCTAssertEqual(model, "sam-assistant")
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    func testModelPatternMatching() async throws {
        /// Test OpenAI model pattern matching Without configured providers with API keys, should throw noProviderAvailable.
        let openAIRequest = OpenAIChatRequest(
            model: "gpt-4",
            messages: [
                OpenAIChatMessage(role: "user", content: "Hello GPT-4")
            ],
            temperature: nil,
            maxTokens: nil,
            stream: nil,
            samConfig: nil,
            contextId: nil,
            enableMemory: nil
        )
        
        /// Without configured providers, should throw noProviderAvailable error.
        do {
            _ = try await endpointManager.processChatCompletion(openAIRequest)
            XCTFail("Should have thrown noProviderAvailable error")
        } catch let error as EndpointManagerError {
            switch error {
            case .noProviderAvailable(let model):
                XCTAssertEqual(model, "gpt-4")
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    func testNoProviderAvailableError() async throws {
        let request = OpenAIChatRequest(
            model: "nonexistent-model",
            messages: [
                OpenAIChatMessage(role: "user", content: "Hello")
            ],
            temperature: nil,
            maxTokens: nil,
            stream: nil,
            samConfig: nil,
            contextId: nil,
            enableMemory: nil
        )
        
        do {
            _ = try await endpointManager.processChatCompletion(request)
            XCTFail("Should have thrown no provider available error")
        } catch let error as EndpointManagerError {
            switch error {
            case .noProviderAvailable(let model):
                XCTAssertEqual(model, "nonexistent-model")
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    // MARK: - Models List Tests
    
    func testGetAvailableModels() async throws {
        let modelsResponse = try await endpointManager.getAvailableModels()
        
        XCTAssertEqual(modelsResponse.object, "list")
        /// Note: In test environment without configured providers, may have no models The test verifies the method doesn't crash and returns valid response structure.
        XCTAssertNotNil(modelsResponse.data)
    }
    
    // MARK: - Configuration Tests
    
    func testProviderConfigurationUpdate() throws {
        let config = ProviderConfiguration(
            providerId: "test-openai",
            providerType: .openai,
            isEnabled: true,
            apiKey: "test-key",
            baseURL: "https://api.openai.com/v1",
            models: ["gpt-3.5-turbo", "gpt-4"]
        )
        
        endpointManager.updateProviderConfiguration(config, for: "test-openai")
        
        /// Configuration should be saved to UserDefaults.
        let key = "provider_config_test-openai"
        let savedData = UserDefaults.standard.data(forKey: key)
        XCTAssertNotNil(savedData)
        
        let savedConfig = try? JSONDecoder().decode(ProviderConfiguration.self, from: savedData!)
        XCTAssertEqual(savedConfig?.providerId, "test-openai")
        XCTAssertEqual(savedConfig?.apiKey, "test-key")
    }
}

// MARK: - Provider Tests

@MainActor
final class AIProviderTests: XCTestCase {
    
    var conversationManager: MockConversationManager!
    
    override func setUp() async throws {
        conversationManager = MockConversationManager()
    }
    
    // MARK: - SAM Internal Provider Tests
    
    /// FIXME: SAMInternalProvider class doesn't exist in current codebase These tests are commented out until the provider is implemented func testSAMInternalProvider() async throws { let config = ProviderConfiguration( providerId: "sam-internal", providerType: .sam, isEnabled: true, models: ["sam-assistant"] ) let provider = SAMInternalProvider(config: config, conversationManager: conversationManager) XCTAssertEqual(provider.identifier, "sam-internal") XCTAssertTrue(provider.supportsModel("sam-assistant")) XCTAssertTrue(provider.supportsModel("sam-default")) XCTAssertFalse(provider.supportsModel("gpt-4")) let isValid = try await provider.validateConfiguration() XCTAssertTrue(isValid) } func testSAMProviderChatCompletion() async throws { let config = ProviderConfiguration( providerId: "sam-internal", providerType: .sam, isEnabled: true, models: ["sam-assistant"] ) let provider = SAMInternalProvider(config: config, conversationManager: conversationManager) let request = OpenAIChatRequest( model: "sam-assistant", messages: [ OpenAIChatMessage(role: "user", content: "Test message") ], temperature: nil, maxTokens: nil, stream: nil, samConfig: nil, contextId: nil, enableMemory: nil ) let response = try await provider.processChatCompletion(request) XCTAssertTrue(response.id.hasPrefix("chatcmpl-sam-")) XCTAssertEqual(response.model, "sam-assistant") XCTAssertEqual(response.choices.count, 1) XCTAssertEqual(response.choices.first?.message.role, "assistant") }.
    
    // MARK: - Provider Configuration Tests
    
    func testProviderConfigurationCoding() throws {
        let config = ProviderConfiguration(
            providerId: "test-provider",
            providerType: .openai,
            isEnabled: true,
            apiKey: "test-key",
            baseURL: "https://test.com",
            models: ["model1", "model2"],
            maxTokens: 1000,
            temperature: 0.7,
            timeoutSeconds: 30,
            retryCount: 3
        )
        
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: encoded)
        
        XCTAssertEqual(decoded.providerId, config.providerId)
        XCTAssertEqual(decoded.providerType, config.providerType)
        XCTAssertEqual(decoded.isEnabled, config.isEnabled)
        XCTAssertEqual(decoded.apiKey, config.apiKey)
        XCTAssertEqual(decoded.baseURL, config.baseURL)
        XCTAssertEqual(decoded.models, config.models)
        XCTAssertEqual(decoded.maxTokens, config.maxTokens)
        XCTAssertEqual(decoded.temperature, config.temperature)
        XCTAssertEqual(decoded.timeoutSeconds, config.timeoutSeconds)
        XCTAssertEqual(decoded.retryCount, config.retryCount)
    }
    
    // MARK: - Load Balancer Tests
    
    func testRoundRobinLoadBalancer() async throws {
        let loadBalancer = RoundRobinLoadBalancer()
        
        let config1 = ProviderConfiguration(providerId: "provider1", providerType: .openai, models: ["model1"])
        let config2 = ProviderConfiguration(providerId: "provider2", providerType: .anthropic, models: ["model2"])
        
        let provider1 = OpenAIProvider(config: config1)
        let provider2 = AnthropicProvider(config: config2)
        
        let providers: [any AIProvider] = [provider1, provider2]
        
        let selected1 = await loadBalancer.selectProvider(from: providers)
        let selected2 = await loadBalancer.selectProvider(from: providers)
        let selected3 = await loadBalancer.selectProvider(from: providers)
        
        /// Should cycle through providers.
        XCTAssertEqual(selected1.identifier, "provider1")
        XCTAssertEqual(selected2.identifier, "provider2")
        XCTAssertEqual(selected3.identifier, "provider1")
    }
}

// MARK: - Mock Classes

@MainActor
class MockConversationManager: ConversationManager {
    init() {
        super.init(aiProvider: nil)
        createNewConversation()
    }
    
    /// Add a mock response for testing purposes.
    func addMockResponse(_ message: String) {
        if let conversation = activeConversation,
           let messageBus = conversation.messageBus {
            messageBus.addAssistantMessage(content: message)
        }
    }
}