<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# SAM: API Integration Specification

## Overview

This document defines the comprehensive API integration system for SAM, designed to provide seamless connectivity with multiple AI service providers while maintaining the user-friendly interface and modular architecture principles established in the SAM specifications.

## Core Design Principles

### 1. User-Friendly Configuration
- **Zero-Technical-Knowledge Required**: All API setup through intuitive interfaces
- **Automatic Discovery**: System automatically detects and configures common providers
- **Smart Defaults**: Sensible defaults that work out of the box
- **Visual Status Indicators**: Clear connection status and health monitoring

### 2. Modular Provider Support
- **Plugin-Based Architecture**: Support for custom API providers through plugins
- **Standardized Interface**: Common API interface regardless of underlying provider
- **Hot-Swappable Providers**: Change providers without system restart
- **Graceful Degradation**: Fallback to alternative providers when primary fails

### 3. Intelligent Optimization
- **Automatic Load Balancing**: Distribute requests across multiple endpoints
- **Smart Caching**: Cache responses to reduce API calls and costs
- **Rate Limit Management**: Automatic handling of provider rate limits
- **Cost Optimization**: Route requests to most cost-effective providers

## API Provider Architecture

### Provider Registry System
```swift
class APIProviderRegistry: ObservableObject {
    @Published var availableProviders: [APIProvider] = []
    @Published var activeProviders: [String: APIProvider] = [:]
    @Published var defaultProvider: APIProvider?
    
    func registerProvider(_ provider: APIProvider) async throws {
        // Validate provider capabilities and configuration
        let validation = await validateProvider(provider)
        guard validation.isValid else {
            throw APIError.providerValidationFailed(validation.issues)
        }
        
        availableProviders.append(provider)
        
        // Test connection
        let connectionTest = await testProviderConnection(provider)
        if connectionTest.isSuccessful {
            activeProviders[provider.id] = provider
        }
        
        await updateProviderMetrics(provider, test: connectionTest)
    }
    
    func selectOptimalProvider(for request: ChatRequest) async -> APIProvider? {
        // Intelligent provider selection based on:
        // - Request requirements (model availability, features needed)
        // - Provider health and response times
        // - Rate limits and costs
        // - User preferences
        
        let candidates = activeProviders.values.filter { provider in
            provider.supportsRequest(request)
        }
        
        return await providerSelector.selectOptimal(
            from: candidates,
            request: request
        )
    }
}

protocol APIProvider: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var description: String { get }
    var supportedModels: [AIModel] { get }
    var capabilities: [APICapability] { get }
    var configuration: ProviderConfiguration { get set }
    var status: ProviderStatus { get }
    
    func authenticate() async throws
    func sendRequest(_ request: ChatRequest) async throws -> ChatResponse
    func getAvailableModels() async throws -> [AIModel]
    func testConnection() async throws -> ConnectionTest
    func supportsRequest(_ request: ChatRequest) -> Bool
}
```

### Built-in Provider Implementations

#### OpenAI Provider
```swift
class OpenAIProvider: APIProvider {
    let id = "openai"
    let displayName = "OpenAI"
    let description = "Access to GPT-4, GPT-3.5, and other OpenAI models"
    
    var supportedModels: [AIModel] = [
        AIModel(
            id: "gpt-4-turbo",
            name: "GPT-4 Turbo",
            description: "Most capable model for complex tasks",
            contextLength: 128000,
            capabilities: [.chat, .functionCalling, .jsonMode]
        ),
        AIModel(
            id: "gpt-3.5-turbo",
            name: "GPT-3.5 Turbo",
            description: "Fast and efficient for most tasks",
            contextLength: 16385,
            capabilities: [.chat, .functionCalling]
        )
    ]
    
    var capabilities: [APICapability] = [
        .chatCompletion,
        .streaming,
        .functionCalling,
        .jsonMode,
        .imageInput
    ]
    
    func sendRequest(_ request: ChatRequest) async throws -> ChatResponse {
        // Convert to OpenAI format
        let openAIRequest = try convertToOpenAIRequest(request)
        
        // Execute request with automatic retry
        let response = try await executeWithRetry {
            try await httpClient.send(openAIRequest)
        }
        
        // Convert back to standard format
        return try convertFromOpenAIResponse(response)
    }
    
    private func convertToOpenAIRequest(_ request: ChatRequest) throws -> OpenAIRequest {
        return OpenAIRequest(
            model: request.selectedModel,
            messages: request.messages.map { message in
                OpenAIMessage(
                    role: message.role.rawValue,
                    content: message.content
                )
            },
            temperature: request.temperature,
            maxTokens: request.maxTokens,
            stream: request.streamingEnabled
        )
    }
}
```

#### Anthropic Provider
```swift
class AnthropicProvider: APIProvider {
    let id = "anthropic"
    let displayName = "Anthropic"
    let description = "Access to Claude models for analysis and reasoning"
    
    var supportedModels: [AIModel] = [
        AIModel(
            id: "claude-3-opus",
            name: "Claude 3 Opus",
            description: "Most powerful model for complex analysis",
            contextLength: 200000,
            capabilities: [.chat, .analysis, .longContext]
        ),
        AIModel(
            id: "claude-3-sonnet",
            name: "Claude 3 Sonnet",
            description: "Balanced performance and speed",
            contextLength: 200000,
            capabilities: [.chat, .analysis, .longContext]
        )
    ]
    
    func sendRequest(_ request: ChatRequest) async throws -> ChatResponse {
        // Anthropic-specific request format
        let anthropicRequest = try convertToAnthropicRequest(request)
        
        let response = try await executeWithRetry {
            try await httpClient.send(anthropicRequest)
        }
        
        return try convertFromAnthropicResponse(response)
    }
}
```

#### Local Model Provider
```swift
class LocalModelProvider: APIProvider {
    let id = "local"
    let displayName = "Local Models"
    let description = "Privacy-focused local AI models"
    
    private let mlxManager: MLXModelManager
    
    var supportedModels: [AIModel] {
        return mlxManager.availableModels.map { mlxModel in
            AIModel(
                id: mlxModel.id,
                name: mlxModel.displayName,
                description: "Local \(mlxModel.size) model",
                contextLength: mlxModel.contextLength,
                capabilities: [.chat, .offline, .privacy]
            )
        }
    }
    
    func sendRequest(_ request: ChatRequest) async throws -> ChatResponse {
        // Use MLX for local inference
        guard let model = mlxManager.loadedModel(request.selectedModel) else {
            throw APIError.modelNotLoaded(request.selectedModel)
        }
        
        let response = try await model.generateResponse(
            for: request.messages,
            temperature: request.temperature,
            maxTokens: request.maxTokens
        )
        
        return ChatResponse(
            id: UUID().uuidString,
            model: request.selectedModel,
            choices: [
                ChatChoice(
                    index: 0,
                    message: ChatMessage(
                        role: .assistant,
                        content: response.text
                    ),
                    finishReason: response.finishReason
                )
            ],
            usage: response.tokenUsage
        )
    }
}
```

### Plugin Provider Support
```swift
class PluginAPIProvider: APIProvider {
    let plugin: SAMPlugin
    private let pluginAPIHandler: PluginAPIHandler
    
    init(plugin: SAMPlugin) {
        self.plugin = plugin
        self.pluginAPIHandler = PluginAPIHandler(plugin: plugin)
    }
    
    var id: String { "plugin_\(plugin.id)" }
    var displayName: String { plugin.metadata.name }
    var description: String { plugin.metadata.description }
    
    var supportedModels: [AIModel] {
        return pluginAPIHandler.getAvailableModels()
    }
    
    func sendRequest(_ request: ChatRequest) async throws -> ChatResponse {
        // Delegate to plugin's API handler
        return try await pluginAPIHandler.processRequest(request)
    }
}

protocol PluginAPIHandler {
    func getAvailableModels() -> [AIModel]
    func processRequest(_ request: ChatRequest) async throws -> ChatResponse
    func testConnection() async throws -> ConnectionTest
    func configure(settings: [String: Any]) async throws
}
```

## User-Friendly Configuration Interface

### Provider Setup Wizard
```swift
struct ProviderSetupView: View {
    @StateObject private var setupManager = ProviderSetupManager()
    @State private var selectedProvider: ProviderTemplate?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Add AI Provider")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Choose from popular AI services or add a custom provider")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2)) {
                    ForEach(setupManager.availableProviders) { provider in
                        ProviderOptionCard(
                            provider: provider,
                            isSelected: selectedProvider?.id == provider.id,
                            onSelect: { selectedProvider = provider }
                        )
                    }
                }
                
                if let selected = selectedProvider {
                    NavigationLink(destination: ProviderConfigurationView(provider: selected)) {
                        Text("Continue with \(selected.name)")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .cornerRadius(12)
                    }
                }
                
                Spacer()
            }
            .padding()
        }
    }
}

struct ProviderOptionCard: View {
    let provider: ProviderTemplate
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: provider.icon)
                .font(.largeTitle)
                .foregroundColor(provider.brandColor)
            
            Text(provider.name)
                .font(.headline)
                .fontWeight(.semibold)
            
            Text(provider.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            
            if provider.isPremium {
                Text("Premium")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(4)
            }
        }
        .padding()
        .frame(height: 140)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .cornerRadius(12)
        .onTapGesture(perform: onSelect)
    }
}
```

### Configuration Interface
```swift
struct ProviderConfigurationView: View {
    let provider: ProviderTemplate
    @StateObject private var configManager = ConfigurationManager()
    @State private var apiKey: String = ""
    @State private var isTestingConnection = false
    @State private var connectionResult: ConnectionTest?
    
    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: provider.icon)
                        .foregroundColor(provider.brandColor)
                    Text(provider.name)
                        .font(.headline)
                }
                
                Text(provider.description)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            
            Section("API Configuration") {
                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)
                
                if !provider.defaultBaseURL.isEmpty {
                    HStack {
                        Text("Endpoint")
                        Spacer()
                        Text(provider.defaultBaseURL)
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
                
                Button(action: testConnection) {
                    HStack {
                        if isTestingConnection {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "network")
                        }
                        Text("Test Connection")
                    }
                }
                .disabled(apiKey.isEmpty || isTestingConnection)
            }
            
            if let result = connectionResult {
                Section("Connection Test") {
                    ConnectionResultView(result: result)
                }
            }
            
            Section {
                Button("Add Provider") {
                    saveProvider()
                }
                .disabled(!canSave)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Configure \(provider.name)")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var canSave: Bool {
        !apiKey.isEmpty && connectionResult?.isSuccessful == true
    }
    
    private func testConnection() {
        isTestingConnection = true
        
        Task {
            let result = await configManager.testConnection(
                provider: provider,
                apiKey: apiKey
            )
            
            await MainActor.run {
                connectionResult = result
                isTestingConnection = false
            }
        }
    }
    
    private func saveProvider() {
        Task {
            await configManager.saveProvider(
                template: provider,
                apiKey: apiKey
            )
        }
    }
}
```

## Request Routing and Load Balancing

### Intelligent Request Router
```swift
class RequestRouter {
    private let providerRegistry: APIProviderRegistry
    private let loadBalancer: LoadBalancer
    private let costOptimizer: CostOptimizer
    
    func routeRequest(_ request: ChatRequest) async throws -> ChatResponse {
        // 1. Analyze request requirements
        let requirements = analyzeRequestRequirements(request)
        
        // 2. Find suitable providers
        let suitableProviders = await findSuitableProviders(requirements)
        
        // 3. Select optimal provider
        let selectedProvider = await selectOptimalProvider(
            from: suitableProviders,
            requirements: requirements
        )
        
        // 4. Execute request with failover
        return try await executeWithFailover(request, provider: selectedProvider)
    }
    
    private func analyzeRequestRequirements(_ request: ChatRequest) -> RequestRequirements {
        return RequestRequirements(
            modelRequired: request.selectedModel,
            featuresRequired: extractRequiredFeatures(request),
            latencyPreference: .balanced, // or .fast, .quality
            costPreference: .balanced,    // or .low, .quality
            privacyLevel: .standard       // or .high, .maximum
        )
    }
    
    private func selectOptimalProvider(
        from providers: [APIProvider],
        requirements: RequestRequirements
    ) async -> APIProvider {
        // Score providers based on multiple factors
        let scoredProviders = providers.map { provider in
            ScoredProvider(
                provider: provider,
                score: calculateProviderScore(provider, requirements: requirements)
            )
        }.sorted { $0.score > $1.score }
        
        return scoredProviders.first?.provider ?? providers.first!
    }
    
    private func calculateProviderScore(
        _ provider: APIProvider,
        requirements: RequestRequirements
    ) -> Double {
        var score: Double = 0.0
        
        // Model availability (40% weight)
        if provider.supportedModels.contains(where: { $0.id == requirements.modelRequired }) {
            score += 40.0
        }
        
        // Performance metrics (20% weight)
        let performanceScore = getPerformanceScore(provider)
        score += performanceScore * 0.2
        
        // Cost efficiency (20% weight)
        let costScore = getCostScore(provider, requirements: requirements)
        score += costScore * 0.2
        
        // Reliability (20% weight)
        let reliabilityScore = getReliabilityScore(provider)
        score += reliabilityScore * 0.2
        
        return score
    }
}
```

### Failover and Retry Logic
```swift
class FailoverManager {
    func executeWithFailover(
        _ request: ChatRequest,
        provider: APIProvider
    ) async throws -> ChatResponse {
        var lastError: Error?
        let maxAttempts = 3
        
        // Try primary provider
        for attempt in 1...maxAttempts {
            do {
                return try await provider.sendRequest(request)
            } catch {
                lastError = error
                
                if shouldRetry(error, attempt: attempt) {
                    let delay = calculateBackoffDelay(attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } else {
                    break
                }
            }
        }
        
        // Try fallback providers
        let fallbackProviders = await findFallbackProviders(for: request, excluding: provider)
        
        for fallbackProvider in fallbackProviders {
            do {
                return try await fallbackProvider.sendRequest(request)
            } catch {
                lastError = error
                continue
            }
        }
        
        throw lastError ?? APIError.allProvidersFailed
    }
    
    private func shouldRetry(_ error: Error, attempt: Int) -> Bool {
        guard attempt < 3 else { return false }
        
        switch error {
        case APIError.rateLimitExceeded,
             APIError.networkError,
             APIError.serverError(let code, _) where code >= 500:
            return true
        default:
            return false
        }
    }
}
```

## Cost Optimization and Monitoring

### Cost Tracking System
```swift
class CostTracker: ObservableObject {
    @Published var dailyCosts: [String: Double] = [:]  // Provider ID -> Cost
    @Published var monthlyCosts: [String: Double] = [:]
    @Published var totalTokensUsed: [String: Int] = [:]
    
    func recordUsage(provider: String, tokens: TokenUsage, cost: Double) {
        let today = DateFormatter.dayKey.string(from: Date())
        let month = DateFormatter.monthKey.string(from: Date())
        
        dailyCosts[provider, default: 0.0] += cost
        monthlyCosts[provider, default: 0.0] += cost
        totalTokensUsed[provider, default: 0] += tokens.totalTokens
        
        // Check budget limits
        checkBudgetLimits(provider: provider, dailyCost: dailyCosts[provider, default: 0.0])
    }
    
    private func checkBudgetLimits(provider: String, dailyCost: Double) {
        if let limit = UserDefaults.standard.dailyBudgetLimit(for: provider),
           dailyCost > limit {
            // Send notification about budget exceeded
            NotificationCenter.default.post(
                name: .budgetExceeded,
                object: BudgetAlert(provider: provider, limit: limit, actual: dailyCost)
            )
        }
    }
}

struct CostDashboardView: View {
    @ObservedObject var costTracker: CostTracker
    
    var body: some View {
        VStack(spacing: 20) {
            Text("API Usage & Costs")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            // Today's usage
            VStack(alignment: .leading, spacing: 12) {
                Text("Today's Usage")
                    .font(.headline)
                
                ForEach(Array(costTracker.dailyCosts.keys), id: \.self) { provider in
                    HStack {
                        Text(provider.capitalized)
                        Spacer()
                        Text("$\(costTracker.dailyCosts[provider, default: 0.0], specifier: "%.2f")")
                    }
                }
                
                Divider()
                
                HStack {
                    Text("Total Today")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("$\(costTracker.dailyCosts.values.reduce(0, +), specifier: "%.2f")")
                        .fontWeight(.semibold)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            
            // Usage chart
            CostChartView(data: costTracker.monthlyCosts)
            
            Spacer()
        }
        .padding()
    }
}
```

## Streaming and Real-time Features

### Streaming Response Handler
```swift
class StreamingResponseHandler: ObservableObject {
    @Published var currentResponse: String = ""
    @Published var isStreaming: Bool = false
    
    func handleStreamingRequest(_ request: ChatRequest, provider: APIProvider) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                await MainActor.run {
                    isStreaming = true
                    currentResponse = ""
                }
                
                do {
                    for try await chunk in provider.streamRequest(request) {
                        await MainActor.run {
                            currentResponse += chunk.content
                        }
                        continuation.yield(chunk.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                } finally {
                    await MainActor.run {
                        isStreaming = false
                    }
                }
            }
        }
    }
}

struct StreamingMessageView: View {
    @ObservedObject var streamingHandler: StreamingResponseHandler
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(streamingHandler.currentResponse)
                .font(.body)
                .textSelection(.enabled)
            
            if streamingHandler.isStreaming {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("SAM is responding...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
```

## Error Handling and User Feedback

### User-Friendly Error Management
```swift
class APIErrorHandler {
    func handleAPIError(_ error: Error) -> UserFriendlyError {
        switch error {
        case APIError.authenticationFailed:
            return UserFriendlyError(
                title: "Authentication Issue",
                message: "There's a problem with your API key. Let me help you fix it.",
                suggestedActions: [
                    "Check API key",
                    "Re-enter credentials",
                    "Contact support"
                ],
                severity: .warning
            )
            
        case APIError.rateLimitExceeded(let retryAfter):
            return UserFriendlyError(
                title: "Taking a Break",
                message: "I've reached the rate limit for this service. I'll try again in a moment.",
                suggestedActions: [
                    "Wait \(retryAfter?.formatted() ?? "a moment")",
                    "Try different provider",
                    "Upgrade plan"
                ],
                severity: .info
            )
            
        case APIError.networkError:
            return UserFriendlyError(
                title: "Connection Issue",
                message: "I'm having trouble connecting to the AI service. This is usually temporary.",
                suggestedActions: [
                    "Check internet connection",
                    "Try again in a moment",
                    "Use different provider"
                ],
                severity: .warning
            )
            
        default:
            return UserFriendlyError(
                title: "Something Went Wrong",
                message: "I encountered an unexpected issue, but I can try a different approach.",
                suggestedActions: [
                    "Try again",
                    "Use different approach",
                    "Report issue"
                ],
                severity: .error
            )
        }
    }
}

struct ErrorRecoveryView: View {
    let error: UserFriendlyError
    let onAction: (String) -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: error.severity.icon)
                .font(.largeTitle)
                .foregroundColor(error.severity.color)
            
            Text(error.title)
                .font(.headline)
            
            Text(error.message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                ForEach(error.suggestedActions, id: \.self) { action in
                    Button(action) {
                        onAction(action)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(error.severity.backgroundColor)
        .cornerRadius(12)
    }
}
```

## Performance Optimization

### Response Caching
```swift
class ResponseCache {
    private let cache = NSCache<NSString, CachedResponse>()
    private let expirationInterval: TimeInterval = 300 // 5 minutes
    
    func getCachedResponse(for request: ChatRequest) -> ChatResponse? {
        let key = generateCacheKey(request)
        
        guard let cached = cache.object(forKey: key),
              !cached.isExpired else {
            return nil
        }
        
        return cached.response
    }
    
    func cacheResponse(_ response: ChatResponse, for request: ChatRequest) {
        let key = generateCacheKey(request)
        let cached = CachedResponse(
            response: response,
            timestamp: Date(),
            expirationInterval: expirationInterval
        )
        cache.setObject(cached, forKey: key)
    }
    
    private func generateCacheKey(_ request: ChatRequest) -> NSString {
        // Create a deterministic key based on request content
        let keyComponents = [
            request.messages.map(\.content).joined(),
            request.selectedModel,
            "\(request.temperature ?? 0.7)",
            "\(request.maxTokens ?? 1000)"
        ]
        return keyComponents.joined(separator: "|") as NSString
    }
}
```

### Connection Pooling
```swift
class ConnectionPool {
    private var pools: [String: URLSessionPool] = [:]
    
    func getSession(for provider: APIProvider) -> URLSession {
        if let pool = pools[provider.id] {
            return pool.getSession()
        } else {
            let pool = URLSessionPool(maxConnections: 10)
            pools[provider.id] = pool
            return pool.getSession()
        }
    }
}
```

## Security and Privacy

### Secure Credential Storage
```swift
class SecureCredentialsManager {
    private let keychain = Keychain(service: "com.sam.api-credentials")
    
    func storeAPIKey(_ key: String, for provider: String) throws {
        try keychain.set(key, key: provider)
    }
    
    func retrieveAPIKey(for provider: String) throws -> String? {
        return try keychain.get(provider)
    }
    
    func deleteAPIKey(for provider: String) throws {
        try keychain.remove(provider)
    }
}
```

### Data Privacy
```swift
class PrivacyManager {
    func shouldSendToProvider(_ request: ChatRequest, provider: APIProvider) -> Bool {
        // Check privacy settings and provider trust level
        let privacyLevel = UserDefaults.standard.privacyLevel
        let providerTrustLevel = provider.trustLevel
        
        switch privacyLevel {
        case .maximum:
            return provider.isLocal
        case .high:
            return providerTrustLevel >= .high
        case .standard:
            return providerTrustLevel >= .standard
        }
    }
    
    func sanitizeRequest(_ request: ChatRequest) -> ChatRequest {
        // Remove or redact sensitive information if needed
        var sanitized = request
        sanitized.messages = sanitized.messages.map { message in
            var sanitizedMessage = message
            sanitizedMessage.content = redactSensitiveData(message.content)
            return sanitizedMessage
        }
        return sanitized
    }
}
```

## Success Metrics

### Integration Quality Metrics
- **Provider Uptime**: >99.5% availability across all active providers
- **Response Time**: <2s average for standard requests
- **Error Rate**: <2% of requests fail
- **Cost Efficiency**: Automatic routing saves >20% on API costs
- **Failover Success**: >95% of failed requests recovered through failover

### User Experience Metrics
- **Setup Time**: <5 minutes to configure first provider
- **Configuration Success**: >95% of users successfully set up providers
- **Error Understanding**: >90% of users understand error messages
- **Provider Switching**: Users can switch providers without losing context

This specification ensures SAM provides robust, user-friendly API integration that abstracts technical complexity while delivering powerful multi-provider capabilities.