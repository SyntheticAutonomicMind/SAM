// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// MLXTrainingService.swift
/// Training orchestration for LoRA adapters using MLX Swift.
/// Handles dataset loading, training loop, gradient computation, and checkpointing.

import Foundation
@preconcurrency import MLX
@preconcurrency import MLXNN
@preconcurrency import MLXOptimizers
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import Tokenizers
import MLXIntegration
import ConfigurationSystem
import Logging

private let logger = Logger(label: "com.sam.training.service")

// MARK: - Training Configuration

/// Configuration for LoRA training.
public struct TrainingConfig: Sendable {
    /// LoRA rank (typically 4, 8, 16, or 32)
    public let rank: Int
    
    /// LoRA alpha scaling factor
    public let alpha: Float
    
    /// Learning rate
    public let learningRate: Float
    
    /// Batch size for training
    public let batchSize: Int
    
    /// Number of training epochs
    public let epochs: Int
    
    /// Maximum sequence length
    public let maxSeqLength: Int
    
    /// Save checkpoint every N steps
    public let saveSteps: Int
    
    /// Gradient accumulation steps (for larger effective batch size)
    public let gradientAccumulationSteps: Int
    
    /// Target modules to apply LoRA (default: attention projections)
    public let targetModules: [String]
    
    public init(
        rank: Int = 8,
        alpha: Float = 16.0,
        learningRate: Float = 1e-4,
        batchSize: Int = 4,
        epochs: Int = 3,
        maxSeqLength: Int = 2048,
        saveSteps: Int = 100,
        gradientAccumulationSteps: Int = 1,
        targetModules: [String] = ["q_proj", "k_proj", "v_proj", "o_proj"]
    ) {
        self.rank = rank
        self.alpha = alpha
        self.learningRate = learningRate
        self.batchSize = batchSize
        self.epochs = epochs
        self.maxSeqLength = maxSeqLength
        self.saveSteps = saveSteps
        self.gradientAccumulationSteps = gradientAccumulationSteps
        self.targetModules = targetModules
    }
}

// MARK: - Training Progress

/// Progress information for UI updates.
public struct TrainingProgress: Sendable {
    public let epoch: Int
    public let step: Int
    public let totalSteps: Int
    public let loss: Float
    public let learningRate: Float
    public let tokensPerSecond: Float
    
    /// Progress as percentage (0.0 to 1.0)
    public var progress: Double {
        Double(step) / Double(max(totalSteps, 1))
    }
    
    public init(
        epoch: Int,
        step: Int,
        totalSteps: Int,
        loss: Float,
        learningRate: Float,
        tokensPerSecond: Float = 0.0
    ) {
        self.epoch = epoch
        self.step = step
        self.totalSteps = totalSteps
        self.loss = loss
        self.learningRate = learningRate
        self.tokensPerSecond = tokensPerSecond
    }
}

// MARK: - Training Example

/// A single training example.
struct TrainingExample {
    let text: String
    let tokens: [Int]
}

// MARK: - Training Service

/// Actor that orchestrates LoRA training.
@MainActor
public class MLXTrainingService {
    private var currentJob: TrainingJob?
    private var progressCallback: (@Sendable (TrainingProgress) -> Void)?
    private let mlxAdapter: AppleMLXAdapter
    
    struct TrainingJob {
        let id: String
        let datasetURL: URL
        let modelId: String
        let modelPath: String
        let config: TrainingConfig
        var isCancelled: Bool = false
    }
    
    public init() {
        self.mlxAdapter = AppleMLXAdapter()
        logger.info("MLXTrainingService initialized")
    }
    
    /// Start training a LoRA adapter.
    ///
    /// - Parameters:
    ///   - datasetURL: URL to JSONL dataset file
    ///   - modelId: Model identifier (e.g., "Qwen3-4B-MLX-8bit")
    ///   - modelPath: Actual filesystem path to model directory
    ///   - config: Training configuration
    ///   - adapterName: User-provided name for the adapter
    ///   - onProgress: Progress callback for UI updates
    /// - Returns: Trained LoRA adapter
    public func startTraining(
        datasetURL: URL,
        modelId: String,
        modelPath: String,
        config: TrainingConfig,
        adapterName: String = "Untitled Adapter",
        onProgress: @escaping @Sendable (TrainingProgress) -> Void
    ) async throws -> LoRAAdapter {
        
        let job = TrainingJob(
            id: UUID().uuidString,
            datasetURL: datasetURL,
            modelId: modelId,
            modelPath: modelPath,
            config: config
        )
        
        currentJob = job
        progressCallback = onProgress
        
        logger.info("Starting LoRA training", metadata: [
            "dataset": "\(datasetURL.path)",
            "model": "\(modelId)",
            "rank": "\(config.rank)",
            "epochs": "\(config.epochs)"
        ])
        
        // Step 1: Load model and tokenizer
        logger.info("Loading model and tokenizer...")
        let (model, tokenizer) = try await loadModel(modelId: modelId)
        
        // Step 2: Load and tokenize dataset
        logger.info("Loading dataset...")
        let dataset = try await loadDataset(url: datasetURL, tokenizer: tokenizer, config: config)
        
        // Step 3: Initialize LoRA adapter
        logger.info("Initializing LoRA adapter...")
        var adapter = try initializeAdapter(for: model, modelId: modelId, config: config, adapterName: adapterName)
        
        // Step 4: Train
        logger.info("Starting training loop...")
        try await train(
            model: model,
            adapter: &adapter,
            dataset: dataset,
            tokenizer: tokenizer,
            config: config
        )
        
        logger.info("Training complete", metadata: [
            "adapterId": "\(adapter.id)",
            "finalLoss": "\(adapter.metadata.finalLoss)"
        ])
        
        return adapter
    }
    
    /// Cancel current training job.
    public func cancelTraining() {
        currentJob?.isCancelled = true
        logger.info("Training cancelled by user")
    }
    
    // MARK: - Private Implementation
    
    /// Load model and tokenizer from model directory.
    private func loadModel(modelId: String) async throws -> (any LanguageModel, Tokenizer) {
        let modelPath = modelsDirectory.appendingPathComponent(modelId)
        
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            logger.error("Model not found", metadata: ["path": "\(modelPath.path)"])
            throw TrainingError.modelNotFound(modelId)
        }
        
        return try await mlxAdapter.loadModel(from: modelPath)
    }
    
    /// Load and tokenize dataset from JSONL file.
    private func loadDataset(
        url: URL,
        tokenizer: Tokenizer,
        config: TrainingConfig
    ) async throws -> [TrainingExample] {
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("Dataset not found", metadata: ["path": "\(url.path)"])
            throw TrainingError.datasetNotFound(url.path)
        }
        
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw TrainingError.datasetLoadFailed("Unable to read dataset as UTF-8")
        }
        
        let lines = content.components(separatedBy: .newlines)
        var examples: [TrainingExample] = []
        
        for (index, line) in lines.enumerated() where !line.isEmpty {
            guard let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let text = json["text"] as? String else {
                logger.warning("Skipping invalid line \(index + 1)")
                continue
            }
            
            // Tokenize
            let tokens = tokenizer.encode(text: text)
            
            // Truncate to max length
            let truncated = Array(tokens.prefix(config.maxSeqLength))
            
            // Skip very short examples (less than 10 tokens)
            if truncated.count < 10 {
                logger.debug("Skipping short example: \(truncated.count) tokens")
                continue
            }
            
            examples.append(TrainingExample(
                text: text,
                tokens: truncated
            ))
        }
        
        guard !examples.isEmpty else {
            throw TrainingError.datasetLoadFailed("No valid examples found in dataset")
        }
        
        logger.info("Loaded dataset", metadata: [
            "examples": "\(examples.count)",
            "avgLength": "\(examples.map { $0.tokens.count }.reduce(0, +) / examples.count)"
        ])
        
        return examples
    }
    
    /// Initialize LoRA adapter for the model.
    private func initializeAdapter(
        for model: any LanguageModel,
        modelId: String,
        config: TrainingConfig,
        adapterName: String
    ) throws -> LoRAAdapter {
        
        // Get model configuration for layer count
        let modelPath = modelsDirectory.appendingPathComponent(modelId)
        let configPath = modelPath.appendingPathComponent("config.json")
        
        guard let configData = try? Data(contentsOf: configPath),
              let configJSON = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw TrainingError.modelConfigNotFound
        }
        
        // Extract number of layers
        let numLayers = configJSON["num_hidden_layers"] as? Int ?? 32
        
        logger.info("Initializing LoRA adapter", metadata: [
            "num_hidden_layers": "\(numLayers)",
            "model_id": "\(modelId)"
        ])
        
        // Create adapter - extract dimensions from actual model layers
        let layers = LoRAAdapter.createStandardLayers(
            model: model,
            numLayers: numLayers,
            rank: config.rank,
            alpha: config.alpha,
            targetModules: config.targetModules
        )
        
        var adapter = LoRAAdapter(
            id: UUID().uuidString,
            baseModelId: modelId,
            rank: config.rank,
            alpha: config.alpha,
            layers: [:],
            metadata: LoRAAdapter.AdapterMetadata(
                createdAt: Date(),
                trainingDataset: currentJob?.datasetURL.lastPathComponent ?? "",
                epochs: config.epochs,
                learningRate: config.learningRate,
                batchSize: config.batchSize,
                adapterName: adapterName,
                baseModelId: modelId
            )
        )
        
        for layer in layers {
            adapter.addLayer(layer)
        }
        
        logger.info("Initialized LoRA adapter", metadata: [
            "layers": "\(adapter.layers.count)",
            "parameters": "\(adapter.parameterCount())"
        ])
        
        return adapter
    }
    
    /// Main training method using Python MLX for actual training.
    ///
    /// This implementation calls a Python script that uses mlx-lm for training,
    /// which provides battle-tested gradient computation and optimization.
    /// The trained adapter is then loaded back into Swift for inference.
    private func train(
        model: any LanguageModel,
        adapter: inout LoRAAdapter,
        dataset: [TrainingExample],
        tokenizer: Tokenizer,
        config: TrainingConfig
    ) async throws {
        
        let totalSteps = (dataset.count / config.batchSize) * config.epochs
        
        logger.info("Training plan", metadata: [
            "examples": "\(dataset.count)",
            "batchSize": "\(config.batchSize)",
            "epochs": "\(config.epochs)",
            "totalSteps": "\(totalSteps)",
            "method": "Python MLX"
        ])
        
        guard let job = currentJob else {
            throw TrainingError.noActiveJob
        }
        
        // Get adapter output directory
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let adapterDir = appSupport
            .appendingPathComponent("SAM")
            .appendingPathComponent("adapters")
            .appendingPathComponent(adapter.id)
        
        try FileManager.default.createDirectory(at: adapterDir, withIntermediateDirectories: true)
        
        // Use modelPath from job (passed in from UI)
        let modelPath = job.modelPath
        
        // Call Python training script
        try await trainWithPython(
            modelPath: modelPath,
            datasetPath: job.datasetURL.path,
            outputPath: adapterDir.path,
            config: config,
            adapter: &adapter
        )
        
        logger.info("Training complete", metadata: [
            "adapterId": "\(adapter.id)",
            "finalLoss": "\(String(format: "%.4f", adapter.metadata.finalLoss))"
        ])
    }
    
    /// Execute Python training script and monitor progress.
    private func trainWithPython(
        modelPath: String,
        datasetPath: String,
        outputPath: String,
        config: TrainingConfig,
        adapter: inout LoRAAdapter
    ) async throws {
        
        // Get Python path - use bundled Python
        let pythonPath: String
        let scriptPath: String
        
        if let bundlePath = Bundle.main.bundlePath.components(separatedBy: "/Contents").first {
            pythonPath = "\(bundlePath)/Contents/Resources/python_env/bin/python3"
            scriptPath = "\(bundlePath)/Contents/Resources/train_lora.py"
        } else {
            pythonPath = "/usr/bin/python3"  // Fallback
            scriptPath = "scripts/train_lora.py"  // Development fallback
        }
        
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            logger.error("Training script not found", metadata: ["path": "\(scriptPath)"])
            throw TrainingError.scriptNotFound
        }
        
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            logger.error("Python not found", metadata: ["path": "\(pythonPath)"])
            throw TrainingError.pythonError("Python not found at: \(pythonPath)")
        }
        
        // Read model config to determine number of layers
        var numLayers = 16  // Default fallback
        let modelConfigPath = modelPath + "/config.json"
        if let configData = try? Data(contentsOf: URL(fileURLWithPath: modelConfigPath)),
           let configJSON = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
           let layers = configJSON["num_hidden_layers"] as? Int {
            numLayers = layers
            logger.info("Read model config", metadata: [
                "numLayers": "\(numLayers)",
                "modelType": "\(configJSON["model_type"] as? String ?? "unknown")"
            ])
        } else {
            logger.warning("Could not read model config, using default num_layers=\(numLayers)")
        }
        
        // Build command arguments
        let args = [
            scriptPath,
            "--model-path", modelPath,
            "--dataset", datasetPath,
            "--output", outputPath,
            "--rank", "\(config.rank)",
            "--alpha", "\(config.alpha)",
            "--lr", "\(config.learningRate)",
            "--batch-size", "\(config.batchSize)",
            "--epochs", "\(config.epochs)",
            "--max-seq-length", "\(config.maxSeqLength)",
            "--lora-layers", "\(numLayers)",  // CRITICAL FIX: Apply LoRA to ALL model layers
            "--lora-dropout", "0.0"  // Always 0.0 for now (can be made configurable later)
        ]
        
        logger.info("Launching Python training", metadata: [
            "python": "\(pythonPath)",
            "script": "\(scriptPath)",
            "model": "\(modelPath)"
        ])
        
        // Create process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = args
        
        // Setup output pipes
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Launch process
        try process.run()
        
        // Monitor output for progress updates
        let outputHandle = outputPipe.fileHandleForReading
        var finalLoss: Float = 0.0
        var totalSteps = 0
        
        while process.isRunning || outputHandle.availableData.count > 0 {
            let data = outputHandle.availableData
            if data.count > 0, let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: .newlines) {
                    if line.isEmpty { continue }
                    
                    // Try to parse JSON progress
                    if let jsonData = line.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        
                        if let type = json["type"] as? String {
                            switch type {
                            case "progress":
                                if let step = json["step"] as? Int,
                                   let total = json["total_steps"] as? Int,
                                   let loss = json["loss"] as? Double {
                                    
                                    totalSteps = total
                                    finalLoss = Float(loss)
                                    
                                    let progress = TrainingProgress(
                                        epoch: step / max(total / config.epochs, 1),
                                        step: step,
                                        totalSteps: total,
                                        loss: Float(loss),
                                        learningRate: config.learningRate
                                    )
                                    progressCallback?(progress)
                                    
                                    if step % 10 == 0 {
                                        logger.info("Training progress", metadata: [
                                            "step": "\(step)/\(total)",
                                            "loss": "\(String(format: "%.4f", loss))"
                                        ])
                                    }
                                }
                                
                            case "error":
                                if let error = json["error"] as? String {
                                    logger.error("Python training error", metadata: ["error": "\(error)"])
                                    throw TrainingError.pythonError(error)
                                }
                                
                            case "complete":
                                logger.info("Python training completed successfully")
                                
                            default:
                                break
                            }
                        }
                    }
                }
            }
            
            // Check for cancellation
            if currentJob?.isCancelled == true {
                process.terminate()
                throw TrainingError.cancelled
            }
            
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        // Wait for process to finish
        process.waitUntilExit()
        
        // Check exit code
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            
            // Check for OOM errors
            if errorOutput.contains("kIOGPUCommandBufferCallbackErrorOutOfMemory") ||
               errorOutput.contains("Insufficient Memory") {
                logger.error("Training failed: Out of memory", metadata: [
                    "exitCode": "\(process.terminationStatus)",
                    "rank": "\(config.rank)",
                    "batchSize": "\(config.batchSize)"
                ])
                
                let suggestion = "Reduce rank to \(config.rank / 2) or batch size to \(max(1, config.batchSize / 2))"
                let errorMessage = """
                Out of GPU memory during training.
                
                Current settings:
                - Rank: \(config.rank)
                - Batch size: \(config.batchSize)
                
                Suggestion: \(suggestion)
                """
                throw TrainingError.pythonError(errorMessage)
            }
            
            logger.error("Python training failed", metadata: [
                "exitCode": "\(process.terminationStatus)",
                "error": "\(errorOutput)"
            ])
            throw TrainingError.pythonError(errorOutput)
        }
        
        // Update adapter metadata
        adapter.metadata.trainingSteps = totalSteps
        adapter.metadata.finalLoss = finalLoss
    }
    
    /// Get local model path from model ID.
    private func getModelPath(for modelId: String) -> String {
        // Models are cached in ~/Library/Caches/sam/models/
        let modelName = modelId.replacingOccurrences(of: "/", with: "--")
        return modelsDirectory.appendingPathComponent(modelName).path
    }
    
    // MARK: - Helpers
    
    private var modelsDirectory: URL {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        
        return caches
            .appendingPathComponent("sam")
            .appendingPathComponent("models")
    }
}

// MARK: - Errors

public enum TrainingError: Error, LocalizedError {
    case cancelled
    case modelNotFound(String)
    case modelConfigNotFound
    case datasetNotFound(String)
    case datasetLoadFailed(String)
    case trainingFailed(String)
    case pythonError(String)
    case scriptNotFound
    case noActiveJob
    
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Training was cancelled"
        case .modelNotFound(let id):
            return "Model not found: \(id)"
        case .modelConfigNotFound:
            return "Model config.json not found"
        case .datasetNotFound(let path):
            return "Dataset not found: \(path)"
        case .datasetLoadFailed(let reason):
            return "Failed to load dataset: \(reason)"
        case .pythonError(let error):
            return "Python training error: \(error)"
        case .scriptNotFound:
            return "Training script (train_lora.py) not found"
        case .noActiveJob:
            return "No active training job"
        case .trainingFailed(let reason):
            return "Training failed: \(reason)"
        }
    }
}

// MARK: - Future Enhancement: Full LoRA Training Implementation

/*
 IMPLEMENTATION NOTES FOR FUTURE DEVELOPMENT:
 
 The current implementation provides the training orchestration structure
 but uses simulated loss computation. To implement full LoRA training:
 
 1. **Model Injection**: Create a wrapper that injects LoRA layers into the
    model's forward pass. This requires understanding the specific model
    architecture and how to intercept attention layer computations.
 
 2. **Loss Computation**: Implement proper cross-entropy loss:
    ```swift
    func computeLoss(logits: MLXArray, targets: MLXArray) -> MLXArray {
        return crossEntropy(logits: logits, targets: targets, reduction: .mean)
    }
    ```
 
 3. **Gradient Computation**: Use MLX's valueAndGrad to compute gradients:
    ```swift
    func lossFunction(adapter: LoRAAdapter, input: MLXArray, target: MLXArray) -> MLXArray {
        // 1. Apply LoRA deltas to model activations
        // 2. Forward pass through model
        // 3. Compute cross-entropy loss
    }
    
    let vg = valueAndGrad(lossFunction)
    let (loss, grads) = vg(adapter, input, target)
    ```
 
 4. **Parameter Updates**: Apply gradients using AdamW optimizer:
    ```swift
    let optimizer = AdamW(learningRate: config.learningRate)
    optimizer.update(model: &adapter, gradients: grads)
    ```
 
 5. **Model-Specific Integration**: Different model architectures (Llama, Qwen, etc.)
    have different layer structures. The injection strategy must be adapted
    per model type.
 
 References:
 - MLX-LM Python implementation: https://github.com/ml-explore/mlx-lm
 - LoRA paper: https://arxiv.org/abs/2106.09685
 - MLX Swift examples: .build/checkouts/mlx-swift/
 */
