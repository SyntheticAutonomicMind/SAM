<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# Stable Diffusion Generation Flow Diagrams

**Last Updated:** December 1, 2025

This document contains Mermaid flow diagrams for the Stable Diffusion integration subsystem.

---

## Model Discovery Flow

```mermaid
flowchart TD
    A[Scan models/stable-diffusion/] --> B{For each directory}
    B --> C{Skip 'downloads'?}
    C -->|Yes| B
    C -->|No| D{Has model_index.json?}
    
    D -->|Yes| E[Multi-part model]
    D -->|No| F{Has .safetensors?}
    
    E --> G[Check transformer/ or unet/]
    G --> H{Has weights?}
    H -->|Yes| I[Valid multi-part model]
    H -->|No| B
    
    F -->|Yes| J[Single-file model]
    F -->|No| K{Has .mlmodelc files?}
    
    J --> I
    
    K --> L{Has TextEncoder2?}
    L -->|Yes| M[Valid SDXL model]
    L -->|No| N{Has TextEncoder + Unet + VAEDecoder?}
    
    N -->|Yes| O[Valid SD 1.x/2.x model]
    N -->|No| B
    
    M --> P[Create ModelInfo]
    O --> P
    I --> P
    
    P --> Q[Detect pipeline type]
    Q --> R[Determine available engines]
    R --> S[Add to model list]
    S --> B
```

---

## LoRA Discovery Flow

```mermaid
flowchart TD
    A[LoRAManager.loadLoRAs] --> B[Scan loras directory]
    B --> C{For each .safetensors file}
    
    C --> D[Extract filename]
    D --> E{Check civitai_info.json?}
    
    E -->|Yes| F[Parse model info]
    F --> G[Extract base model]
    F --> H[Extract trigger words]
    
    E -->|No| I[Default to 'any' compatibility]
    I --> J[No trigger words]
    
    G --> K[Create LoRAInfo]
    H --> K
    J --> K
    
    K --> L[Add to loraList]
    L --> C
    
    C -->|Done| M[Return all LoRAs]
```

---

## Dynamic LoRA Description Flow

```mermaid
sequenceDiagram
    participant Tool as ImageGenerationTool
    participant LM as LoRAManager
    participant Desc as Description Builder
    participant AI as LLM
    
    Tool->>LM: getAllLoRAs()
    LM-->>Tool: [LoRAInfo]
    
    Tool->>Desc: Build description
    Desc->>Desc: Add base description
    Desc->>Desc: Add dynamic model list
    
    alt LoRAs available
        Desc->>Desc: loraCount > 10?
        alt More than 10
            Desc->>Desc: Show first 10
            Desc->>Desc: Add "Use list_loras for full list"
        else 10 or fewer
            Desc->>Desc: Show all LoRAs
        end
        
        loop Each LoRA
            Desc->>Desc: Add filename
            Desc->>Desc: Add compatibility (SD1.5/SDXL/any)
            Desc->>Desc: Add trigger words if present
        end
    else No LoRAs
        Desc->>Desc: Add "No LoRAs installed"
    end
    
    Desc-->>Tool: Complete description
    Tool-->>AI: Tool definition with LoRA info
```

---

## list_loras Operation Flow

```mermaid
flowchart TD
    A[User/AI calls image_generation] --> B{operation parameter?}
    
    B -->|list_loras| C[listLoRAsOperation]
    B -->|generate/none| D[Normal generation]
    
    C --> E[LoRAManager.getAllLoRAs]
    E --> F{LoRAs found?}
    
    F -->|No| G[Return no LoRAs message]
    
    F -->|Yes| H[Build LoRA list]
    
    loop Each LoRA
        H --> I[Add filename]
        I --> J[Add base model info]
        J --> K{Has trigger words?}
        K -->|Yes| L[Add trigger words]
        K -->|No| M[Skip triggers]
        L --> N[Format entry]
        M --> N
    end
    
    N --> O[Add usage instructions]
    O --> P[Return formatted list]
```

---

## LoRA Path Resolution Flow

```mermaid
flowchart TD
    A[Generation request with lora_paths] --> B{lora_paths provided?}
    
    B -->|No| C[Skip LoRA processing]
    
    B -->|Yes| D[For each path in lora_paths]
    
    D --> E{Is absolute path?}
    E -->|Yes| F{File exists?}
    F -->|Yes| G[Use as-is]
    F -->|No| H[Log warning, skip]
    
    E -->|No| I[Get LoRA directory]
    I --> J[Append filename]
    J --> K{File exists?}
    K -->|Yes| L[Use resolved path]
    K -->|No| M[Log warning, skip]
    
    G --> N[Add to resolved paths]
    L --> N
    
    N --> D
    
    D -->|Done| O[Pass to generation]
    C --> O
```

---

## Compel Prompt Processing Flow

```mermaid
flowchart TD
    A[Prompt with weights] --> B{Compel available?}
    
    B -->|No| C[Use raw prompt]
    
    B -->|Yes| D{Weighted syntax detected?}
    D -->|No| C
    
    D -->|Yes| E[Parse weighted tokens]
    E --> F["(text)+" = emphasis]
    E --> G["(text)-" = de-emphasis]
    E --> H["(text:1.5)" = explicit weight]
    
    F --> I[Build Compel prompt]
    G --> I
    H --> I
    
    I --> J[Get text embeddings]
    J --> K[Return processed embeddings]
    
    C --> L[Standard CLIP encoding]
    K --> L
    
    L --> M[Pass to generation]
```

---

## Image Generation End-to-End Flow

```mermaid
sequenceDiagram
    participant User
    participant ImageGenTool as ImageGenerationTool
    participant Orchestrator as StableDiffusionOrchestrator
    participant CoreML as StableDiffusionService
    participant Python as PythonDiffusersService
    participant Upscale as UpscalingService
    participant UI as ChatWidget
    
    User->>ImageGenTool: Generate image (prompt, params)
    ImageGenTool->>ImageGenTool: Validate parameters
    ImageGenTool->>ImageGenTool: Select model & engine
    ImageGenTool->>ImageGenTool: Auto-correct scheduler if needed
    ImageGenTool->>ImageGenTool: Resolve LoRA paths
    
    ImageGenTool->>Orchestrator: generateImages(config)
    
    alt CoreML Engine
        Orchestrator->>CoreML: loadModel(path)
        CoreML->>CoreML: Load .mlmodelc files
        Orchestrator->>CoreML: generateImage(prompt, steps, ...)
        CoreML->>CoreML: Run inference on Metal
        CoreML-->>Orchestrator: [CGImage]
    else Python Engine
        Orchestrator->>Python: generateImage(prompt, modelName, ...)
        Python->>Python: Find model file (.safetensors or directory)
        Python->>Python: Process Compel weights if present
        Python->>Python: Execute generate_image_diffusers.py
        Note over Python: Auto-detect pipeline type<br/>Select dtype (bfloat16/float32)<br/>Apply scheduler<br/>Load LoRAs
        Python-->>Orchestrator: imagePaths, metadata
    end
    
    alt Upscaling enabled
        Orchestrator->>Upscale: upscaleImages(paths, model, scale)
        Upscale->>Upscale: Run RealESRGAN
        Upscale-->>Orchestrator: upscaledPaths
    end
    
    Orchestrator-->>ImageGenTool: GenerationResult
    ImageGenTool->>ImageGenTool: Post notification
    ImageGenTool->>UI: imageDisplay event
    UI->>UI: Display images in chat
    ImageGenTool-->>User: Success message
```

---

## Device & Dtype Selection Flow

```mermaid
flowchart TD
    A[Device parameter] --> B{device == 'auto'?}
    
    B -->|Yes| C{MPS available?}
    C -->|Yes| D[device = 'mps']
    C -->|No| E{CUDA available?}
    E -->|Yes| F[device = 'cuda']
    E -->|No| G[device = 'cpu']
    
    B -->|No| H{device == 'mps'?}
    H -->|Yes| I{MPS available?}
    I -->|Yes| D
    I -->|No| J[Fallback to 'cpu']
    
    H -->|No| K[Use specified device]
    
    D --> L{Detect model type}
    F --> L
    G --> L
    J --> L
    K --> L
    
    L --> M{Is Z-Image/FLUX?}
    
    M -->|Yes, MPS| N[dtype = bfloat16]
    M -->|Yes, CUDA| O{BF16 supported?}
    O -->|Yes| N
    O -->|No| P[dtype = float16]
    M -->|Yes, CPU| Q{Low memory mode?}
    Q -->|Yes| P
    Q -->|No| R[dtype = float32]
    
    M -->|No, MPS| R
    M -->|No, CUDA| O
    M -->|No, CPU| Q
    
    N --> S[Load pipeline with dtype]
    P --> S
    R --> S
    
    S --> T[Generate image]
```

---

## Download & Conversion Pipeline

```mermaid
flowchart TD
    A[User selects model] --> B{Source?}
    
    B -->|CivitAI| C[CivitAIService.searchModels]
    B -->|HuggingFace| D[HuggingFaceService.searchModels]
    
    C --> E[Display model list]
    D --> E
    
    E --> F[User selects version]
    
    F --> G{Model has base?}
    
    G -->|Yes| H[Hierarchical download]
    G -->|No| I[Standard download]
    
    H --> J[categorizeHierarchicalFiles]
    J --> K[Download variant files]
    J --> L[Download base files]
    K --> M{All downloaded?}
    L --> M
    
    I --> N[Download all files]
    N --> M
    
    M -->|Yes| O[Save to staging/stable-diffusion/]
    M -->|No| P[Retry failed]
    P --> K
    
    O --> Q{Format?}
    
    Q -->|.safetensors| R[Python-ready]
    Q -->|.mlmodelc/.zip| S[Extract CoreML]
    Q -->|Multi-part| T[Organize directories]
    
    R --> U[Move to models/stable-diffusion/]
    S --> U
    T --> U
    
    U --> V[Save metadata]
    V --> W[Refresh model list]
    W --> X[Model available]
```

---

## Class Relationships

```mermaid
classDiagram
    class StableDiffusionOrchestrator {
        +GenerationConfig
        +GenerationResult
        +generateImages(config) async
        -generateWithCoreML()
        -generateWithPython()
        -upscaleImages()
    }
    
    class StableDiffusionModelManager {
        +listInstalledModels() [ModelInfo]
        +isModelInstalled(name) bool
        +deleteModel(name)
        +saveMetadata(metadata, dir)
        -isValidModelDirectory(dir) bool
        -createModelInfo(from) ModelInfo
    }
    
    class PythonDiffusersService {
        +generateImage(...) async GenerationResult
        +isModelAvailable(name) bool
        +listAvailableModels() [String]
        -findModelFile(name) URL
    }
    
    class StableDiffusionService {
        +loadModel(path, disableSafety)
        +generateImage(...) async [CGImage]
        +unloadModel()
        -sdPipeline: StableDiffusionPipeline?
        -sdxlPipeline: StableDiffusionXLPipeline?
    }
    
    class HuggingFaceService {
        +searchModels(...) async [HFModel]
        +listModelFiles(modelId) async [HFFile]
        +downloadFile(...) async URL
        +categorizeHierarchicalFiles()
    }
    
    class CivitAIService {
        +searchModels(...) async CivitAISearchResponse
        +getModelDetails(id) async CivitAIModel
        +searchLoRAs(...) async CivitAISearchResponse
    }
    
    class UpscalingService {
        +upscaleImage(...) async URL
        +upscaleImageInPlace(...) async URL
    }
    
    class LoRAManager {
        +loadLoRAs()
        +deleteLoRA(info)
        +getCompatibleLoRAs(baseModel) [LoRAInfo]
        +registerDownloadedLoRA(...)
        +getAllLoRAs() [LoRAInfo]
    }
    
    class ImageGenerationTool {
        +execute(parameters, context) MCPToolResult
        +listLoRAsOperation() MCPToolResult
        -determineImageSize(model)
        -loraManager: LoRAManager
    }
    
    StableDiffusionOrchestrator --> StableDiffusionService
    StableDiffusionOrchestrator --> PythonDiffusersService
    StableDiffusionOrchestrator --> UpscalingService
    StableDiffusionModelManager --> "manages" ModelInfo
    ImageGenerationTool --> StableDiffusionOrchestrator
    ImageGenerationTool --> StableDiffusionModelManager
    ImageGenerationTool --> LoRAManager
```

---

## Scheduler Auto-Correction Flow

```mermaid
flowchart TD
    A[User requests generation] --> B[Parse scheduler parameter]
    B --> C{Scheduler specified?}
    
    C -->|No| D[Use user preference or default]
    C -->|Yes| E[Parse scheduler name]
    
    D --> F{Engine == CoreML?}
    E --> F
    
    F -->|Yes| G{Is CoreML scheduler?}
    F -->|No| H{Is Python scheduler?}
    
    G -->|Yes| I[Scheduler OK]
    G -->|No| J[Auto-correct to dpm++_karras]
    
    H -->|Yes| I
    H -->|No| K[Auto-correct to dpm++_sde_karras]
    
    J --> L[Log correction warning]
    K --> L
    
    I --> M[Proceed with generation]
    L --> M
    
    M --> N{Model == Z-Image?}
    N -->|Yes| O{Is flow-matching scheduler?}
    O -->|No| P[Warn: Use FlowMatchEuler]
    O -->|Yes| Q[Scheduler compatible]
    N -->|No| Q
    
    P --> Q
    Q --> R[Execute generation]
```

---

## Memory Management Flow (Python)

```mermaid
flowchart TD
    A[Determine model size] --> B[Get system RAM]
    
    B --> C{Model > 75% RAM?}
    
    C -->|Yes| D[use_low_memory = True]
    C -->|No| E[use_low_memory = False]
    
    D --> F{Device == MPS?}
    E --> F
    
    F -->|Yes, low_mem| G[Enable sequential CPU offload]
    F -->|Yes, normal| H[Move to MPS]
    F -->|No, low_mem| I{Device == CPU?}
    F -->|No, normal| J[Move to device]
    
    I -->|Yes| K[Enable attention slicing]
    I -->|No| J
    
    G --> L[Model on CPU, loads to MPS during inference]
    H --> M[Model fully on MPS]
    K --> N[Model on CPU with optimizations]
    J --> O[Model on specified device]
    
    L --> P[Generate]
    M --> P
    N --> P
    O --> P
```

---

## Related Documentation

- [Stable Diffusion Subsystem](../subsystems/STABLE_DIFFUSION.md)
- [API Framework](../subsystems/API_FRAMEWORK.md)
- [Prompt Architecture](../2025-12-01/2100/PROMPT_ARCHITECTURE.md)
