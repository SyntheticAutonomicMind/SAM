# LoRA Training System

## Overview

SAM's LoRA training system enables fine-tuning local MLX models on custom datasets without modifying base model weights. This system uses Low-Rank Adaptation (LoRA) to create lightweight adapter modules that specialize models for specific knowledge domains.

## Architecture

### Components

1. **Training Service** (`Sources/Training/MLXTrainingService.swift`)
   - Manages training lifecycle and progress tracking
   - Interfaces with Python MLX training script
   - Handles parameter validation and error recovery
   - Provides real-time progress updates via Combine publishers

2. **Adapter Manager** (`Sources/Training/AdapterManager.swift`)
   - Loads and manages LoRA adapters
   - Handles safetensors file I/O
   - Validates adapter configurations
   - Provides adapter discovery and listing

3. **Python Training Script** (`scripts/train_lora.py`)
   - Executes actual training using mlx-lm library
   - Handles dataset preparation and tokenization
   - Saves adapters in safetensors format with proper config
   - Reports progress via JSON messages

4. **Training UI** (`Sources/UserInterface/Preferences/TrainingPreferencesPane.swift`)
   - Parameter configuration interface
   - Progress visualization during training
   - Adapter management (view, delete)
   - Model and dataset selection

5. **Provider Integration** (`Sources/APIFramework/EndpointManager.swift`, `MLXProvider.swift`)
   - Creates LoRA-enhanced providers during hot reload
   - Applies LoRA weights during model loading
   - Registers adapters as selectable models
   - Handles split model validation

### Data Flow

```
User configures training → MLXTrainingService validates params
                         ↓
                    Launches Python script
                         ↓
        Python: Load model + dataset → Train LoRA → Save adapter
                         ↓
              Progress updates via stdout (JSON)
                         ↓
    Swift: Parse progress → Update UI → Notify completion
                         ↓
        EndpointManager detects new adapter → Creates provider
                         ↓
            Adapter appears in model picker
```

## Training Process

### 1. Data Preparation

Training data must be in JSONL format with chat template:
```json
{"text": "<|im_start|>user\nQuestion<|im_end|>\n<|im_start|>assistant\nAnswer<|im_end|>\n"}
```

SAM provides two export methods:
- **Conversation Export**: Exports chat history with memories
- **Document Export**: Chunks documents with various strategies

### 2. Parameter Configuration

Critical parameters:
- **Rank**: LoRA matrix rank (8-128, higher = more capacity)
- **Alpha**: Scaling factor (typically 2× rank)
- **Learning Rate**: 1e-4 to 1e-5 typical
- **Epochs**: Number of training passes (3-50)
- **Batch Size**: Samples per iteration (1-4 typical)
- **LoRA Layers**: Number of transformer layers to adapt

### 3. Training Execution

1. MLXTrainingService validates all parameters
2. Python script is launched with bundled MLX environment
3. Model and adapter config are loaded
4. Dataset is tokenized and split (train/validation)
5. Training loop with loss tracking
6. Periodic checkpoints saved
7. Final adapter saved with metadata

### 4. Adapter Registration

After training:
1. Adapter saved to `~/Library/Application Support/SAM/adapters/{UUID}/`
2. EndpointManager's hot reload detects new adapter
3. LoRA provider created with base model + adapter ID
4. Adapter appears in model picker as "lora/{UUID}"

## File Structure

### Adapter Directory
```
~/Library/Application Support/SAM/adapters/{UUID}/
├── adapters.safetensors      # LoRA weights
├── adapter_config.json        # MLX configuration
└── metadata.json              # SAM metadata
```

### adapter_config.json Format
```json
{
  "fine_tune_type": "lora",
  "num_layers": 28,
  "lora_parameters": {
    "rank": 32,
    "scale": 64.0,
    "dropout": 0.0,
    "keys": ["self_attn.q_proj", "self_attn.k_proj", ...]
  }
}
```

**Critical**: Must include `fine_tune_type` and `dropout` fields for Swift MLX compatibility.

### metadata.json Format
```json
{
  "adapterName": "My Custom Adapter",
  "baseModelId": "Qwen/Qwen3-1.7B",
  "createdAt": "2026-01-12T20:00:00Z",
  "trainingDataset": "my_data.jsonl",
  "epochs": 30,
  "rank": 32,
  "alpha": 64,
  "learningRate": 0.0001,
  "batchSize": 1,
  "trainingSteps": 1000,
  "finalLoss": 0.026,
  "layerCount": 112,
  "parameterCount": 15269376
}
```

## Implementation Details

### LoRA Weight Application

When loading a LoRA model, `MLXProvider` applies weights in `applyLoRAWeights()`:

1. Load adapter from AdapterManager
2. Create LoRAModel using MLX.LoRAModel()
3. Apply weights using LoRAContainer
4. Cache the enhanced model for future requests

Key code path:
```swift
// Load base model
let (baseModel, tokenizer) = try await loadModelIfNeeded()

// Apply LoRA if specified
if let adapterId = loraAdapterId {
    let adapter = try await AdapterManager.shared.loadAdapter(id: adapterId)
    finalModel = try applyLoRAWeights(to: baseModel)
}
```

### Split Model Validation

For LoRA adapters, base models may be in split format. Validation checks:
```swift
let modelFile = modelDirectory.appendingPathComponent("model.safetensors")
let splitFile = modelDirectory.appendingPathComponent("model-00001-of-00002.safetensors")
let indexFile = modelDirectory.appendingPathComponent("model.safetensors.index.json")

let isValidModel = FileManager.default.fileExists(atPath: modelFile.path) ||
                   FileManager.default.fileExists(atPath: indexFile) ||
                   FileManager.default.fileExists(atPath: splitFile)
```

### Model Picker Integration

LoRA adapters appear in model picker with friendly names:
- Format: `lora/{UUID}` in model list
- Display: "LoRA: {Adapter Name}" or "LoRA: {UUID prefix}..."
- Location: "Local"
- Provider: Extracted from base model

## Error Handling

### Common Issues

1. **"The data couldn't be read because it is missing"**
   - Cause: Missing `fine_tune_type` or `dropout` in adapter_config.json
   - Fix: Python script updated to include required fields

2. **"No provider found for model lora/..."**
   - Cause: Base model not downloaded or split files not validated
   - Fix: Download base model, ensure split validation enabled

3. **Duplicate adapters in picker**
   - Cause: ModelListManager adding adapters separately from EndpointManager
   - Fix: Removed duplicate addition, adapters come via provider iteration

4. **Training OOM errors**
   - Cause: Batch size or rank too high for available RAM
   - Fix: Reduce batch size to 1, lower rank, or use smaller model

### Progress Tracking

Python script emits JSON progress messages:
```json
{"type": "progress", "step": 10, "total_steps": 100, "loss": 0.234, "progress": 10}
{"type": "validation", "loss": 0.456}
{"type": "complete", "adapter_path": "/path/to/adapter"}
{"type": "error", "error": "Error message"}
```

MLXTrainingService parses these and updates Combine publishers.

## Testing

### Minimal Test

Create 3-example dataset to verify training works:
```bash
cat > /tmp/test.jsonl << 'EOF'
{"text": "<|im_start|>user\nWhat is X?<|im_end|>\n<|im_start|>assistant\nX is Y.<|im_end|>\n"}
{"text": "<|im_start|>user\nTell me about X.<|im_end|>\n<|im_start|>assistant\nX is Y.<|im_end|>\n"}
{"text": "<|im_start|>user\nWhat should I know about X?<|im_end|>\n<|im_start|>assistant\nYou should know X is Y.<|im_end|>\n"}
EOF
```

Train with high epochs (50+) to force memorization. Test with `ask_sam.sh`:
```bash
SAM_API_TOKEN=$SAM_API_KEY scripts/ask_sam.sh --model "lora/{UUID}" "What is X?"
```

Expected: Model recalls "X is Y" exactly.

## Performance Considerations

### Memory Usage
- Base model: ~2-4 GB (depending on size)
- LoRA adapter: ~50-120 MB (depending on rank/layers)
- Training peak: Base model + gradients + optimizer state

### Training Time
- Small dataset (100 samples): ~2-5 minutes
- Medium dataset (1000 samples): ~15-30 minutes
- Large dataset (10000 samples): ~2-4 hours

Factors: Model size, rank, batch size, epochs, hardware.

## Future Enhancements

Potential improvements:
1. Multi-adapter merging
2. Adapter quantization for smaller size
3. Training resume from checkpoint
4. Hyperparameter auto-tuning
5. Training data augmentation
6. Validation during training with early stopping

## Credits

Training implementation inspired by [Silicon Studio](https://github.com/rileycleavenger/Silicon-Studio) by Riley Cleavenger.
