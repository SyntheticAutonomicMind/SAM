func processChatCompletion(_ request: OpenAIChatRequest) async throws -> ServerOpenAIChatResponse
    func processStreamingChatCompletion(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error>
    func getAvailableModels() async throws -> ServerOpenAIModelsResponse
    func supportsModel(_ model: String) -> Bool
    func validateConfiguration() async throws -> Bool
    
    // Local models only
    func loadModel() async throws -> ModelCapabilities
    func getLoadedStatus() async -> Bool
    func unload() async
}
```

**Implementation Classes:**
- `OpenAIProvider` - OpenAI API integration
- `GitHubCopilotProvider` - GitHub Copilot with token-aware truncation and billing
- `DeepSeekProvider` - DeepSeek API (OpenAI-compatible)
- `GeminiProvider` - Google Gemini API with metadata discovery
- `MiniMaxProvider` - MiniMax API with M2/M3 model support and thinking parameter
- `OpenRouterProvider` - OpenRouter multi-model gateway
- `ALICEProvider` - ALICE image and audio generation service
- `MLXProvider` - Local MLX models for Apple Silicon
- `LlamaProvider` - Local GGUF models via llama.cpp
- `RemoteLlamaProvider` - Remote llama.cpp inference servers
- `OllamaCloudProvider` - Ollama Cloud hosted models
- `ZAIProvider` - Z.AI GLM models (Chat and Coding variants)
- `CustomProvider` - Generic OpenAI-compatible providers

> **Note:** There is no direct `AnthropicProvider`. Claude models are accessed through the `OpenRouterProvider`.