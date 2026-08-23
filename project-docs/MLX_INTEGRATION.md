<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# MLX Integration

**Version:** 3.0  
**Last Updated:** August 23, 2026  
**Location:** `Sources/MLXIntegration/`

---

## Overview

The MLX Integration provides a Swift wrapper around Apple's MLX framework for efficient on-device machine learning inference. It manages MLX model lifecycle, caching, performance monitoring, and Metal GPU acceleration for local language models. Additionally, SAM now supports **CachyLLama** - a high-performance fork of llama.cpp optimized for Apple Silicon.

**Key Responsibilities:**
- MLX framework Swift bindings
- Model caching and lifecycle management
- Metal GPU acceleration configuration
- Performance monitoring and optimization
- Memory management for large models
- Model loading and unloading
- Inference request handling
- **CachyLLama integration** - optimized GGUF inference on Apple Silicon

**Design Philosophy:**
- Minimal overhead Swift wrapper over MLX
- Efficient memory management (lazy loading, LRU cache)
- Metal-first architecture (GPU by default, CPU fallback)
- Performance monitoring at every layer
- Graceful degradation on errors

---

## Architecture

```mermaid
classDiagram
    class AppleMLXAdapter {
        -logger: Logger
        -modelCache: MLXModelCache
        -performanceMonitor: MLXPerformanceMonitor
        +initialize() async throws
        +loadModel(path: URL) async throws
        +unloadModel(modelId: String) async
        +generateText(prompt: String, options: GenerationOptions) async throws
        +getModelInfo(modelId: String) -> ModelInfo
    }
    
    class MLXModelCache {
        -logger: Logger
        -fileManager: FileManager
        -modelsDirectory: URL
        -loadedModels: [String: LoadedModel]
        -maxCacheSize: Int
        +initialize() async throws
        +cacheModel(path: URL) async throws
        +getCachedModel(modelId: String) -> LoadedModel?
        +evictLRU() async
        +clearCache() async
    }
    
    class MLXPerformanceMonitor {
        -metrics: [String: PerformanceMetric]
        +recordModelLoad(duration: TimeInterval)
        +recordInference(duration: TimeInterval, tokens: Int)
        +getMetrics() -> [PerformanceMetric]
        +reset()
    }
    
    class MLXConfig {
        +metalDevice: MTLDevice?
        +maxMemoryUsage: Int64
        +enableGPU: Bool
        +batchSize: Int
        +contextLength: Int
    }
    
    class CachyLLamaManager {
        -logger: Logger
        -serverProcess: Process?
        -modelCache: CachyLLamaModelCache
        +initialize() async throws
        +loadModel(path: URL) async throws
        +generateText(prompt: String, options: GenerationOptions) async throws
        +getServerStatus() -> ServerStatus
    }
    
    AppleMLXAdapter --> MLXModelCache
    AppleMLXAdapter --> MLXPerformanceMonitor
    AppleMLXAdapter --> MLXConfig
    CachyLLamaManager --> CachyLLamaModelCache
```

---

## Core Components

### AppleMLXAdapter

**File:** `AppleMLXAdapter.swift`  
**Type:** Main facade for MLX operations  
**Purpose:** Primary interface for MLX model loading and inference

**Key Features:**
- Lazy model loading (load on first use)
- Automatic model caching
- Performance tracking
- Metal GPU acceleration
- Error handling and recovery

**Public Interface:**

```swift
@MainActor
public class AppleMLXAdapter {
    public static let shared = AppleMLXAdapter()
    
    private let logger = Logger(label: "com.sam.mlx")
    private let modelCache = MLXModelCache()
    private let performanceMonitor = MLXPerformanceMonitor()
    private var config: MLXConfig
    
    // Initialization
    public func initialize() async throws
    
    // Model Management
    public func loadModel(path: URL, modelId: String) async throws -> LoadedModel
    public func unloadModel(modelId: String) async
    public func isModelLoaded(modelId: String) -> Bool
    public func getModelInfo(modelId: String) -> ModelInfo?
    
    // Inference
    public func generateText(
        modelId: String,
        prompt: String,
        options: GenerationOptions
    ) async throws -> String
    
    public func generateTextStreaming(
        modelId: String,
        prompt: String,
        options: GenerationOptions,
        onToken: @escaping (String) -> Void
    ) async throws
    
    // Configuration
    public func updateConfig(_ config: MLXConfig)
    public func getConfig() -> MLXConfig
}
```

**Generation Options:**

```swift
public struct GenerationOptions {
    public var temperature: Double = 0.7
    public var topP: Double = 0.9
    public var maxTokens: Int = 512
    public var stopSequences: [String] = []
    public var repetitionPenalty: Double = 1.0
    public var seed: Int? = nil
}
```

---

### MLXModelCache

**File:** `MLXModelCache.swift`  
**Purpose:** Manage in-memory cache of loaded MLX models

**Key Features:**
- LRU eviction policy
- Configurable cache size
- Model validation before caching
- SHA-256 model verification
- Automatic eviction on memory pressure

**Cache Structure:**

```swift
private struct CachedModel {
    let modelId: String
    let path: URL
    let mlxModel: Any  // Actual MLX model object
    let metadata: ModelMetadata
    let loadedAt: Date
    var lastAccessedAt: Date
    var accessCount: Int
}
```

**Public Interface:**

```swift
public class MLXModelCache {
    private let logger = Logger(label: "com.sam.mlx.cache")
    private let fileManager = FileManager.default
    
    private var modelsDirectory: URL?
    private var cache: [String: CachedModel] = [:]
    private let maxCacheSize: Int = 3  // Max models in memory
    
    // Initialization
    public func initialize() async throws
    
    // Caching
    public func cacheModel(path: URL, modelId: String) async throws -> CachedModel
    public func getCachedModel(modelId: String) -> CachedModel?
    public func evictModel(modelId: String) async
    public func evictLRU() async  // Evict least recently used
    public func clearCache() async
    
    // Validation
    func validateModel(at path: URL) throws -> Bool
    func calculateChecksum(for path: URL) throws -> String
}
```

**LRU Eviction Logic:**

```swift
private func evictLRU() async {
    guard cache.count >= maxCacheSize else { return }
    
    // Find least recently used model
    let lru = cache.values.min { 
        $0.lastAccessedAt < $1.lastAccessedAt 
    }
    
    if let modelToEvict = lru {
        logger.info("Evicting LRU model: \(modelToEvict.modelId)")
        await evictModel(modelId: modelToEvict.modelId)
    }
}
```

---

### MLXPerformanceMonitor

**File:** `MLXPerformanceMonitor.swift`  
**Purpose:** Track and report MLX performance metrics

**Tracked Metrics:**
- Model load time (initialization duration)
- Inference latency (time per request)
- Token generation rate (tokens/second)
- Memory usage (peak and current)
- GPU utilization (Metal performance)
- Cache hit rate

**Public Interface:**

```swift
public class MLXPerformanceMonitor {
    private var metrics: [String: PerformanceMetric] = [:]
    
    // Recording
    public func recordModelLoad(modelId: String, duration: TimeInterval)
    public func recordInference(modelId: String, duration: TimeInterval, tokens: Int)
    public func recordMemoryUsage(bytes: Int64)
    public func recordGPUUtilization(percent: Double)
    
    // Retrieval
    public func getMetrics(for modelId: String) -> PerformanceMetric?
    public func getAllMetrics() -> [String: PerformanceMetric]
    public func getAverageInferenceTime() -> TimeInterval
    public func getTokensPerSecond() -> Double
    
    // Management
    public func reset()
    public func resetForModel(_ modelId: String)
}
```

**Performance Metric:**

```swift
public struct PerformanceMetric {
    public var modelId: String
    public var loadTime: TimeInterval
    public var inferenceCount: Int
    public var totalInferenceTime: TimeInterval
    public var totalTokensGenerated: Int
    public var averageTokensPerSecond: Double
    public var peakMemoryUsage: Int64
    public var averageGPUUtilization: Double
    
    public var averageInferenceTime: TimeInterval {
        totalInferenceTime / Double(max(inferenceCount, 1))
    }
}
```

---

### MLXConfig

**File:** `MLXConfig.swift`  
**Purpose:** Configuration for MLX runtime behavior

**Configuration Options:**

```swift
public struct MLXConfig {
    // Metal/GPU Configuration
    public var enableGPU: Bool = true
    public var metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    public var preferredDeviceType: MLXDeviceType = .gpu
    
    // Memory Management
    public var maxMemoryUsage: Int64 = 8 * 1024 * 1024 * 1024  // 8GB
    public var enableMemoryMapping: Bool = true
    public var maxCacheSize: Int = 3  // Max models in memory
    
    // Performance
    public var batchSize: Int = 1
    public var maxContextLength: Int = 4096
    public var enableKVCache: Bool = true
    
    // Inference
    public var defaultTemperature: Double = 0.7
    public var defaultTopP: Double = 0.9
    public var defaultMaxTokens: Int = 512
}

public enum MLXDeviceType {
    case gpu
    case cpu
    case auto  // Select based on availability
}
```

---

### CachyLLamaManager (New: 2026-06)

**File:** `CachyLLamaManager.swift`  
**Type:** Main facade for CachyLLama operations  
**Purpose:** Primary interface for CachyLLama server management and inference

**Key Features:**
- Runs CachyLLama as a child process (llama-server)
- High-performance GGUF inference with Metal optimizations
- Advanced sampler chain (top-K, min-P, temperature, top-P, typical-P)
- Improved KV cache handling
- Automatic server lifecycle management

**Public Interface:**

```swift
@MainActor
public class CachyLLamaManager {
    public static let shared = CachyLLamaManager()
    
    private let logger = Logger(label: "com.sam.cachyllama")
    private let serverManager = CachyLLamaServerManager()
    private let modelCache = CachyLLamaModelCache()
    private var config: CachyLLamaConfig
    
    // Initialization
    public func initialize() async throws
    
    // Model Management
    public func loadModel(path: URL, modelId: String) async throws -> CachyLLamaModel
    public func unloadModel(modelId: String) async
    public func isModelLoaded(modelId: String) -> Bool
    public func getModelInfo(modelId: String) -> CachyLLamaModelInfo?
    
    // Inference
    public func generateText(
        modelId: String,
        prompt: String,
        options: CachyLLamaGenerationOptions
    ) async throws -> String
    
    public func generateTextStreaming(
        modelId: String,
        prompt: String,
        options: CachyLLamaGenerationOptions,
        onToken: @escaping (String) -> Void
    ) async throws
    
    // Server Management
    public func getServerStatus() -> CachyLLamaServerStatus
    public func restartServer() async throws
    
    // Configuration
    public func updateConfig(_ config: CachyLLamaConfig)
    public func getConfig() -> CachyLLamaConfig
}
```

**CachyLLama Generation Options:**

```swift
public struct CachyLLamaGenerationOptions {
    // Standard parameters
    public var temperature: Double = 0.7
    public var topP: Double = 0.9
    public var maxTokens: Int = 512
    public var stopSequences: [String] = []
    public var repetitionPenalty: Double = 1.1
    
    // CachyLLama-specific sampler chain
    public var topK: Int = 40
    public var minP: Double = 0.05
    public var typicalP: Double = 1.0
    public var tfsZ: Double = 1.0
    
    // Performance
    public var seed: Int? = nil
    public var nPredict: Int = -1
    public var nKeep: Int = 0
}
```

**Server Status:**

```swift
public struct CachyLLamaServerStatus {
    public let isRunning: Bool
    public let modelId: String?
    public let port: Int
    public let pid: Int32?
    public let memoryUsage: Int64
    public let uptime: TimeInterval
}
```

**Usage Example:**

```swift
let manager = CachyLLamaManager.shared
try await manager.initialize()

// Load model (GGUF format from Hugging Face)
let model = try await manager.loadModel(
    path: URL(fileURLWithPath: "~/Library/Caches/sam/models/cachy-model.gguf"),
    modelId: "llama-3.1-8b-instruct"
)

// Generate text with CachyLLama sampler chain
let options = CachyLLamaGenerationOptions(
    temperature: 0.7,
    topK: 40,
    minP: 0.05
)
let response = try await manager.generateText(
    modelId: "llama-3.1-8b-instruct",
    prompt: "Hello, how are you?",
    options: options
)

// Clean up
await manager.unloadModel(modelId: "llama-3.1-8b-instruct")
```

---

### CachyLLamaServerManager

**File:** `CachyLLamaServerManager.swift`  
**Purpose:** Manages the llama-server child process lifecycle

**Key Features:**
- Automatic server startup on first request
- Health monitoring and restart on failure
- Port management (default: 8081)
- Graceful shutdown on app termination

**Server Configuration:**

```swift
public struct CachyLLamaServerConfig {
    public var host: String = "127.0.0.1"
    public var port: Int = 8081
    public var modelPath: String?
    public var nCtx: Int = 8192
    public var nGpuLayers: Int = -1  // All layers on GPU
    public var flashAttn: Bool = true
    public var threads: Int = 0  // Auto
    public var batchSize: Int = 512
    public var ubatchSize: Int = 512
}
```

---

### CachyLLamaModelCache

**File:** `CachyLLamaModelCache.swift`  
**Purpose:** Manage downloaded CachyLLama models (GGUF files)

**Cache Location:**
```
~/Library/Caches/sam-rewritten/models/cachy/
```

---

## Metal GPU Integration

### Device Selection

```swift
private func selectMetalDevice() -> MTLDevice? {
    switch config.preferredDeviceType {
    case .gpu:
        return MTLCreateSystemDefaultDevice()
    case .cpu:
        return nil  // Force CPU
    case .auto:
        // Check if Metal is available
        if let device = MTLCreateSystemDefaultDevice() {
            logger.info("Using Metal GPU: \(device.name)")
            return device
        } else {
            logger.warning("Metal GPU not available, falling back to CPU")
            return nil
        }
    }
}
```

### Performance Optimization

**GPU Acceleration:**
- Matrix operations run on Metal GPU
- Automatic batching for efficiency
- KV cache for faster inference
- Memory-mapped model weights

**Fallback Strategy:**
1. Try Metal GPU (preferred)
2. If unavailable, use CPU with reduced batch size
3. Log performance warnings if using CPU

---

## Model Loading Flow

```mermaid
flowchart TB
    Start[loadModel Request] --> CheckCache{Model in Cache?}
    CheckCache -->|Yes| UpdateAccess[Update Last Accessed]
    CheckCache -->|No| CheckEvict{Cache Full?}
    
    CheckEvict -->|Yes| EvictLRU[Evict LRU Model]
    CheckEvict -->|No| LoadModel[Load Model from Disk]
    EvictLRU --> LoadModel
    
    LoadModel --> Validate[Validate Model]
    Validate -->|Invalid| Error[Throw Error]
    Validate -->|Valid| InitMLX[Initialize MLX Model]
    
    InitMLX --> ConfigGPU[Configure Metal GPU]
    ConfigGPU --> AddCache[Add to Cache]
    AddCache --> RecordMetrics[Record Load Time]
    RecordMetrics --> Return[Return Model]
    
    UpdateAccess --> Return
    
    style CheckCache fill:#4A90E2
    style EvictLRU fill:#F5A623
    style Validate fill:#7ED321
    style Error fill:#D0021B
```

---

## Inference Flow (MLX)

```mermaid
sequenceDiagram
    participant Client
    participant Adapter as AppleMLXAdapter
    participant Cache as MLXModelCache
    participant MLX as MLX Framework
    participant Metal as Metal GPU
    
    Client->>Adapter: generateText(modelId, prompt, options)
    Adapter->>Cache: getCachedModel(modelId)
    
    alt Model in Cache
        Cache-->>Adapter: Return CachedModel
    else Model Not in Cache
        Adapter->>Adapter: loadModel(modelId)
        Adapter->>Cache: cacheModel(modelId)
        Cache-->>Adapter: Return CachedModel
    end
    
    Adapter->>MLX: prepare_inference(prompt, options)
    MLX->>Metal: Allocate GPU buffers
    Metal-->>MLX: Buffers ready
    
    loop Token Generation
        MLX->>Metal: Run matrix ops
        Metal-->>MLX: Token logits
        MLX->>MLX: Sample token
        MLX-->>Adapter: Token
        Adapter-->>Client: Stream token
    end
    
    MLX-->>Adapter: Generation complete
    Adapter->>Adapter: Record metrics
    Adapter-->>Client: Final response
```

---

## Inference Flow (CachyLLama)

```mermaid
sequenceDiagram
    participant Client
    participant Manager as CachyLLamaManager
    participant Server as llama-server
    participant Metal as Metal GPU
    
    Client->>Manager: generateText(modelId, prompt, options)
    Manager->>Server: Check if running
    
    alt Server Running
        Server-->>Manager: Ready
    else Server Stopped
        Manager->>Server: Start llama-server
        Server-->>Manager: Server ready
    end
    
    Manager->>Server: POST /completion (prompt + options)
    Server->>Metal: Run inference (Metal kernels)
    Metal-->>Server: Tokens
    
    loop Streaming
        Server-->>Manager: Token (SSE)
        Manager-->>Client: Stream token
    end
    
    Server-->>Manager: Completion
    Manager->>Manager: Record metrics
    Manager-->>Client: Final response
```

---

## Memory Management

### Lazy Loading
- Models loaded on first use (not at startup)
- Automatic unloading when memory pressure detected
- LRU eviction for cache management

### Memory Mapping
- Large model weights memory-mapped from disk
- Reduces RAM usage for multi-GB models
- OS handles paging automatically

### Cache Management

```swift
// Monitor memory usage
func checkMemoryPressure() async {
    let currentUsage = getMemoryUsage()
    
    if currentUsage > config.maxMemoryUsage * 0.8 {
        logger.warning("Memory pressure detected, evicting LRU model")
        await modelCache.evictLRU()
    }
}
```

---

## Error Handling

### Common Errors (MLX)

```swift
public enum MLXError: LocalizedError {
    case modelNotFound(String)
    case invalidModelFormat(String)
    case loadFailure(String)
    case inferenceFailure(String)
    case metalNotAvailable
    case outOfMemory
    case modelValidationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Model not found at path: \(path)"
        case .invalidModelFormat(let reason):
            return "Invalid model format: \(reason)"
        case .loadFailure(let message):
            return "Failed to load model: \(message)"
        case .inferenceFailure(let message):
            return "Inference failed: \(message)"
        case .metalNotAvailable:
            return "Metal GPU not available on this device"
        case .outOfMemory:
            return "Insufficient memory to load model"
        case .modelValidationFailed(let reason):
            return "Model validation failed: \(reason)"
        }
    }
}
```

### Common Errors (CachyLLama)

```swift
public enum CachyLLamaError: LocalizedError {
    case serverNotRunning
    case serverStartFailed(String)
    case modelNotLoaded(String)
    case inferenceFailed(String)
    case invalidSamplerConfig(String)
    case outOfMemory
    case metalNotAvailable
    
    public var errorDescription: String? { ... }
}
```

### Recovery Strategies

```swift
func loadModelWithRetry(path: URL, modelId: String, retries: Int = 3) async throws -> LoadedModel {
    var lastError: Error?
    
    for attempt in 1...retries {
        do {
            return try await loadModel(path: path, modelId: modelId)
        } catch MLXError.outOfMemory {
            // Try to free memory and retry
            logger.warning("Out of memory on attempt \(attempt), evicting cache")
            await modelCache.evictLRU()
            lastError = error
        } catch {
            throw error  // Don't retry other errors
        }
    }
    
    throw lastError ?? MLXError.loadFailure("Failed after \(retries) attempts")
}
```

---

## Integration with Other Subsystems

### APIFramework
- `MLXProvider` calls `AppleMLXAdapter` for MLX models
- `CachyLLamaProvider` calls `CachyLLamaManager` for CachyLLama models
- Model registry includes both MLX and CachyLLama model metadata
- Inference requests routed through appropriate manager

### ConversationEngine
- AgentOrchestrator requests inference via providers
- Streaming responses sent via MessageBus
- Performance metrics tracked per conversation

### ConfigurationSystem
- MLXConfig / CachyLLamaConfig stored in ApplicationPreferences
- Model paths configured in WorkingDirectoryConfiguration
- Cache settings managed by ConfigurationManager

---

## Performance Comparison

### Typical Metrics (Apple Silicon M1/M2/M3/M4)

| Model Size | Engine | Load Time | Tokens/sec (7B) | Memory (7B) | Best For |
|------------|--------|-----------|-----------------|-------------|----------|
| 7B Q4_K_M | MLX | ~3-5s | 25-35 | 5-6 GB | Quality, compatibility |
| 7B Q4_K_M | CachyLLama | ~2-4s | 35-50 | 4-5 GB | Speed, efficiency |
| 13B Q4_K_M | MLX | ~5-8s | 15-25 | 9-11 GB | Quality |
| 13B Q4_K_M | CachyLLama | ~4-6s | 20-35 | 8-10 GB | Speed |
| 70B Q4_K_M | MLX | ~15-25s | 3-8 | 40-48 GB | Maximum capability |
| 70B Q4_K_M | CachyLLama | ~12-20s | 5-12 | 35-42 GB | Large model speed |

**Notes:**
- CachyLLama typically 20-40% faster than MLX on Apple Silicon
- MLX has slightly better quality on some benchmarks
- Both use Metal GPU acceleration
- Memory usage includes KV cache and model weights

---

## Best Practices

### 1. Initialize Once
```swift
// [FAIL] WRONG: Multiple initializations
let adapter1 = AppleMLXAdapter()
let adapter2 = AppleMLXAdapter()

// [OK] RIGHT: Use singleton
let adapter = AppleMLXAdapter.shared
try await adapter.initialize()

let cachy = CachyLLamaManager.shared
try await cachy.initialize()
```

### 2. Unload Models When Done
```swift
// Generate text
let response = try await adapter.generateText(...)

// Clean up
await adapter.unloadModel(modelId: "llama-3-8b")
await cachy.unloadModel(modelId: "llama-3.1-8b")
```

### 3. Monitor Performance
```swift
let monitor = MLXPerformanceMonitor()

// Record metrics
monitor.recordInference(modelId: "model-1", duration: 2.5, tokens: 128)

// Check performance
let avgTime = monitor.getAverageInferenceTime()
let tokensPerSec = monitor.getTokensPerSecond()
logger.info("Average: \(avgTime)s, \(tokensPerSec) tokens/sec")
```

### 4. Handle Errors Gracefully
```swift
do {
    let model = try await adapter.loadModel(...)
} catch MLXError.metalNotAvailable {
    logger.warning("Metal not available, using CPU")
    config.preferredDeviceType = .cpu
} catch MLXError.outOfMemory {
    logger.error("Out of memory, try smaller model")
} catch {
    logger.error("Unexpected error: \(error)")
}
```

### 5. Choose Right Engine for Task
```swift
// For best quality/compatibility
let provider = MLXProvider()

// For best speed on Apple Silicon
let provider = CachyLLamaProvider()

// For Intel Macs or specific GGUF models
let provider = LlamaProvider()
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 3.0 | 2026-08-23 | Added CachyLLamaManager, CachyLLamaServerManager, CachyLLamaModelCache; performance comparison table; dual-engine support |
| 2.2 | 2025-12-01 | MLX 0.22+ compatibility, Swift 6 concurrency |
| 2.0 | 2025-10-15 | Major refactor for Swift 6, actor isolation |
| 1.0 | 2025-08-01 | Initial MLX integration |

---

## See Also

- [API Framework](API_FRAMEWORK.md) - Provider integration
- [Conversation Engine](CONVERSATION_ENGINE.md) - Context management
- [Configuration System](CONFIGURATION_SYSTEM.md) - Model configuration
- [Performance](PERFORMANCE.md) - Optimization guidance