<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# Model Loading Flow

**Version:** 2.2  
**Last Updated:** December 1, 2025

## Overview

This document describes the complete flow for loading and initializing AI models in SAM, covering both remote provider models (OpenAI, Anthropic, GitHub Copilot) and local models (GGUF, MLX, Stable Diffusion).

---

## Model Loading Sequence

```mermaid
sequenceDiagram
    participant UI as Model Picker
    participant EM as EndpointManager
    participant LMM as LocalModelManager
    participant P as Provider
    participant FS as FileSystem

    UI->>EM: User selects model
    EM->>EM: Parse model identifier
    
    alt Remote Model (github_copilot/gpt-4.1)
        EM->>P: Get provider for model
        P-->>EM: GitHubCopilotProvider
        EM->>P: validateConfiguration()
        P->>P: Check API key exists
        P-->>EM: Configuration valid
        EM-->>UI: Model ready (remote)
        
    else Local Model (lmstudio-community/llama-3.2)
        EM->>LMM: getModelPath(provider, modelName)
        LMM->>FS: Check registry
        FS-->>LMM: /path/to/model.gguf
        LMM-->>EM: Model path
        
        EM->>LMM: estimateMemoryRequirement(modelPath)
        LMM->>FS: Get file size
        FS-->>LMM: 3.5GB
        LMM->>LMM: Calculate: 3.5GB × 1.5 + 8GB = 13.25GB
        LMM->>LMM: Check available memory
        
        alt Insufficient Memory
            LMM-->>EM: MemoryRequirement(isSafe: false, warning)
            EM-->>UI: Show warning dialog
            UI-->>EM: User cancels or proceeds
        end
        
        LMM-->>EM: MemoryRequirement(isSafe: true)
        
        EM->>P: loadModel()
        P->>FS: Load model file to memory
        FS-->>P: Model data loaded
        P->>P: Initialize context (llama.cpp/MLX)
        P->>P: Run test inference
        P-->>EM: ModelCapabilities(contextSize: 8192)
        
        EM-->>UI: Model ready (local)
    end
    
    UI->>UI: Enable send button
```

---

## Model Discovery Flow

```mermaid
flowchart TD
    A[SAM Startup] --> B[LocalModelManager.init]
    B --> C[scanForModels]
    
    C --> D{Check ~/Library/Caches/sam/models/}
    
    D --> E[For Each Provider Directory]
    
    E --> F{lmstudio-community/}
    E --> G{stable-diffusion/}
    
    F --> H[Scan for .gguf files]
    G --> I[Scan for .mlmodelc directories]
    
    H --> J{Valid GGUF?}
    I --> K{Valid SD Model?}
    
    J -->|Yes| L[Extract metadata:<br/>- File size<br/>- Quantization<br/>- Model name]
    J -->|No| M[Skip invalid file]
    
    K -->|Yes| N[Verify Core ML files:<br/>- TextEncoder.mlmodelc<br/>- Unet.mlmodelc<br/>- VAEDecoder.mlmodelc]
    K -->|No| O[Skip invalid directory]
    
    L --> P[Create LocalModel entry]
    N --> P
    
    P --> Q{Check Registry}
    Q -->|Not in registry| R[Auto-register model]
    Q -->|Already registered| S[Update last seen time]
    
    R --> T[Save Registry:<br/>.managed/model_registry.json]
    S --> T
    
    T --> U[Post Notification:<br/>.localModelsDidChange]
    
    U --> V[UI Updates Model Picker]
    
    V --> W[Start File System Watcher]
    W --> X[Monitor for changes]
    X -->|File added/removed| C
    
    style R fill:#90EE90
    style U fill:#FFD700
    style M fill:#FFB6C1
    style O fill:#FFB6C1
```

---

## Provider Selection Logic

```mermaid
flowchart TD
    A[Model Request] --> B{Parse Model ID}
    
    B --> C{Contains '/'?}
    C -->|Yes| D[Extract Provider Prefix]
    C -->|No| E[Default Provider Lookup]
    
    D --> F{Provider Type?}
    
    F -->|github_copilot| G[GitHubCopilotProvider]
    F -->|gemini| GEM[GeminiProvider]
    F -->|anthropic| H[AnthropicProvider]
    F -->|openai| I[OpenAIProvider]
    F -->|deepseek| J[DeepSeekProvider]
    F -->|lmstudio-community| K[MLXProvider]
    F -->|sd| L[StableDiffusionPipeline]
    
    G --> M[Process Request]
    GEM --> M
    H --> M
    I --> M
    J --> M
    K --> N[Check Model Loaded]
    L --> O[Check SD Model Ready]
    
    N -->|Loaded| M
    N -->|Not Loaded| P[Load Model to Memory]
    P --> M
    
    O -->|Ready| Q[Generate Image]
    O -->|Not Ready| R[Load SD Model]
    R --> Q
    
    M --> S[Return Response]
    Q --> S
    
    style G fill:#90EE90
    style GEM fill:#FFA07A
    style H fill:#87CEEB
    style I fill:#FFE4B5
    style K fill:#FFB6C1
    style L fill:#DDA0DD
```

---

## Memory Validation Process

```mermaid
flowchart TD
    A[Request to Load Local Model] --> B[Get Model File Size]
    
    B --> C[Calculate Estimated Total Memory]
    C --> D[Formula:<br/>Model Size × 1.5 + Inference Limit]
    
    D --> E{Example Calculation}
    E --> F[Model: 3.5GB GGUF<br/>Inference: 8GB<br/>Total: 3.5 × 1.5 + 8 = 13.25GB]
    
    F --> G[Query System Memory]
    G --> H[Get Available Memory:<br/>Free + Inactive + Purgeable]
    
    H --> I{Available >= Estimated?}
    
    I -->|Yes| J[MemoryRequirement:<br/>isSafe = true]
    I -->|No| K[MemoryRequirement:<br/>isSafe = false<br/>warningMessage]
    
    J --> L[Proceed with Loading]
    K --> M[Show Warning Dialog]
    
    M --> N{User Choice}
    N -->|Proceed Anyway| L
    N -->|Cancel| O[Abort Load]
    
    L --> P[Load Model to Memory]
    P --> Q[Initialize Context]
    Q --> R[Model Ready]
    
    style J fill:#90EE90
    style K fill:#FFB6C1
    style R fill:#90EE90
```

---

## Local Model Lifecycle States

```mermaid
stateDiagram-v2
    [*] --> Discovered: Model file detected
    
    Discovered --> Registered: Auto-register in registry
    Registered --> Unloaded: Initial state
    
    Unloaded --> LoadingValidation: User selects model
    LoadingValidation --> MemoryCheck: Check requirements
    
    MemoryCheck --> InsufficientMemory: Memory < Required
    MemoryCheck --> Loading: Memory >= Required
    
    InsufficientMemory --> LoadingWarning: User chooses to proceed
    InsufficientMemory --> Unloaded: User cancels
    
    LoadingWarning --> Loading: Force load
    
    Loading --> Loaded: Success
    Loading --> LoadError: Failure
    
    LoadError --> Unloaded: Retry available
    
    Loaded --> Inferencing: Request received
    Inferencing --> Loaded: Request complete
    
    Loaded --> Unloading: User switches model
    Unloading --> Unloaded: Memory freed
    
    Unloaded --> Removed: Model file deleted
    Removed --> [*]
```

---

## Stable Diffusion Model Loading

```mermaid
sequenceDiagram
    participant UI
    participant SDMM as SDModelManager
    participant SDP as SDPipeline
    participant CML as CoreML Framework
    participant FS

    UI->>SDMM: Select SD model (sd/stable-diffusion-v1-5)
    SDMM->>FS: Check model path
    FS-->>SDMM: ~/Library/Caches/sam/models/stable-diffusion/coreml-stable-diffusion-v1-5/
    
    SDMM->>SDMM: Validate Core ML files:<br/>- TextEncoder.mlmodelc<br/>- Unet.mlmodelc<br/>- VAEDecoder.mlmodelc
    
    SDMM->>SDP: loadModel(modelPath)
    
    SDP->>CML: Load TextEncoder.mlmodelc
    CML-->>SDP: TextEncoder model
    
    SDP->>CML: Load Unet.mlmodelc
    CML-->>SDP: Unet model
    
    SDP->>CML: Load VAEDecoder.mlmodelc
    CML-->>SDP: VAEDecoder model
    
    SDP->>SDP: Initialize pipeline configuration
    SDP->>SDP: Set default parameters:<br/>- Steps: 25<br/>- Guidance: 8.0<br/>- Scheduler: DPM++
    
    SDP-->>SDMM: Pipeline ready
    SDMM-->>UI: Model loaded
    
    UI->>UI: Enable image generation
```

---

## Model Registry Structure

```json
{
  "version": "2.2",
  "models": [
    {
      "provider": "lmstudio-community",
      "modelName": "Llama-3.2-3B-Instruct-GGUF",
      "path": "/Users/user/Library/Caches/sam/models/lmstudio-community/Llama-3.2-3B-Instruct-GGUF/model.gguf",
      "installedDate": "2025-11-30T10:00:00Z",
      "sizeBytes": 3758096384,
      "quantization": "Q8_0",
      "identifier": "lmstudio-community/Llama-3.2-3B-Instruct-GGUF"
    },
    {
      "provider": "stable-diffusion",
      "modelName": "coreml-stable-diffusion-v1-5",
      "path": "/Users/user/Library/Caches/sam/models/stable-diffusion/coreml-stable-diffusion-v1-5/",
      "installedDate": "2025-11-28T15:30:00Z",
      "sizeBytes": 2147483648,
      "quantization": "float16",
      "identifier": "sd/coreml-stable-diffusion-v1-5"
    }
  ]
}
```

---

## Error Handling

### Memory Validation Failures

**Scenario:** Model requires more memory than available

**Flow:**
1. Calculate memory requirement
2. Check available memory
3. If insufficient:
   - Show warning dialog with details
   - Offer options:
     - Cancel load
     - Proceed anyway (risky)
     - Suggest smaller model
4. If user proceeds anyway:
   - Log warning
   - Attempt load
   - Monitor for OOM errors

**User Message Example:**
```
⚠️ Insufficient Memory

Model: Llama-3.2-3B-Instruct-GGUF
Required: 13.25 GB
Available: 8.5 GB

Loading this model may cause system instability.

[Cancel] [Suggest Smaller Model] [Proceed Anyway]
```

### Model File Corruption

**Scenario:** Model file exists but is corrupted

**Flow:**
1. Attempt to load model
2. Loading fails with error
3. LocalModelManager marks model as invalid
4. Notify user
5. Offer to re-download (if from hub)

---

## Performance Considerations

### Loading Times (Approximate)

| Model Type | Size | Load Time (M1 Max) | Load Time (M1) |
|-----------|------|-------------------|----------------|
| GGUF 3B Q8 | 3.5GB | 5-8 seconds | 10-15 seconds |
| GGUF 7B Q4 | 4.1GB | 8-12 seconds | 15-20 seconds |
| MLX 3B | 6.5GB | 3-5 seconds | 6-10 seconds |
| SD 1.5 CoreML | 2.1GB | 10-15 seconds | 20-30 seconds |
| SD XL CoreML | 6.6GB | 30-45 seconds | 60-90 seconds |

### Memory Usage (Approximate)

| Model Type | File Size | RAM Usage | Notes |
|-----------|-----------|-----------|-------|
| GGUF Q8 | 3.5GB | ~5.25GB | 1.5× file size |
| GGUF Q4 | 4.1GB | ~6.15GB | 1.5× file size |
| MLX | 6.5GB | ~9.75GB | 1.5× file size |
| SD CoreML | 2.1GB | ~3.2GB | GPU memory |

---

## Model Metadata Discovery

SAM dynamically discovers model capabilities from provider APIs to ensure accurate context sizes and pricing information.

### Remote Model Metadata Flow

```mermaid
flowchart TD
    A[ChatWidget Loads] --> B[Select Model]
    
    B --> C{Check Provider}
    
    C -->|gemini/*| D[Query Gemini API]
    C -->|github_copilot/*| E[Query GitHub Copilot API]
    C -->|Other| F[Fallback: model_config.json]
    
    D --> G[GET /v1beta/models?key=API_KEY]
    G --> H[Parse Response JSON]
    H --> I[Extract inputTokenLimit]
    I --> J[Filter Non-Chat Models<br/>imagen*, veo*, gemma*]
    J --> K[Cache Capabilities]
    
    E --> L[GET /models]
    L --> M[Parse max_input_tokens]
    M --> K
    
    F --> N[Read model_config.json]
    N --> O[Lookup context_window]
    O --> K
    
    K --> P[Update UI with Context Size]
    P --> Q[Set maxContextWindowSize]
    Q --> R[Enable Chat Interface]
    
    style D fill:#FFA07A
    style E fill:#90EE90
    style F fill:#FFD700
    style J fill:#FFB6C1
```

### Pricing Discovery Flow

```mermaid
flowchart TD
    A[Model Selected in Picker] --> B{Provider?}
    
    B -->|GitHub Copilot| C[Query Billing API]
    B -->|Gemini| D[Lookup model_config.json]
    B -->|Other| D
    
    C --> E[Get Multiplier<br/>0x = free<br/>1x-3x = premium]
    E --> F[Cache for 10 minutes]
    
    D --> G[Get costPerMillionInputTokens<br/>+ costPerMillionOutputTokens]
    G --> H[Format: $X/$Y]
    
    F --> I[Display in ChatWidget Header]
    H --> I
    
    I --> J[Show Tooltip:<br/>"Cost per million tokens"]
    
    style C fill:#90EE90
    style D fill:#FFD700
    style I fill:#87CEEB
```

### Rate Limit Notification Flow

```mermaid
flowchart TD
    A[Send Request to Provider] --> B[Provider Returns HTTP 429]
    
    B --> C[Parse retryAfterSeconds]
    C --> D[Post .providerRateLimitHit<br/>notification]
    
    D --> E[ChatWidget Shows Alert:<br/>"Rate Limited - Retrying in Xs"]
    
    E --> F[Wait for retryAfterSeconds]
    
    F --> G[Post .providerRateLimitRetrying<br/>notification]
    
    G --> H[ChatWidget Dismisses Alert]
    
    H --> I[Retry Original Request]
    
    I --> J{Success?}
    J -->|Yes| K[Return Response]
    J -->|No, 429 again| C
    
    style D fill:#FFB6C1
    style E fill:#FFA07A
    style G fill:#90EE90
```

**Key Features:**

1. **Provider-Based Routing**: Models query their own provider's API for metadata
   - `gemini/gemini-2.5-pro` → Gemini API
   - `github_copilot/gpt-4.1` → GitHub Copilot API
   
2. **Fallback Chain**: 
   - Try provider API first
   - Fall back to `model_config.json`
   - Final fallback to safe defaults (32k/16k)

3. **Smart Caching**:
   - Gemini capabilities cached per session
   - GitHub Copilot billing cached for 10 minutes
   - Reduces API calls and improves responsiveness

4. **User Notifications**:
   - Rate limits show countdown timer
   - Alerts auto-dismiss when retry begins
   - Clear visibility into provider behavior

---

## Related Documentation

- [API Framework Subsystem](../API_FRAMEWORK.md)
- [Local Model Manager Specification](../MLX_AND_MODEL_MANAGEMENT_SPECIFICATION.md)
- [Provider Configuration Guide](../DEVELOPER_GUIDE.md#provider-configuration)
