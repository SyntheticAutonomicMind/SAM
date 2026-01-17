// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// GGUFTrainingService.swift
/// LoRA training orchestration for GGUF models using Hugging Face Transformers + PEFT + TRL.
/// Unlike MLX training (which creates separate adapters), GGUF training merges LoRA weights
/// into the base model and converts to GGUF format.

import Foundation
import Logging

private let logger = Logger(label: "com.sam.training.gguf_service")

// MARK: - Training Progress

/// Reuse TrainingProgress from MLXTrainingService
/// (Already defined there, just reference it)

// MARK: - Training Configuration

/// Reuse TrainingConfig from MLXTrainingService
/// (Already defined there, same structure)

// MARK: - GGUF Training Service

/// Actor that orchestrates GGUF LoRA training via Python (Transformers + PEFT).
@MainActor
public class GGUFTrainingService {
    private var currentJob: TrainingJob?
    private var progressCallback: (@Sendable (TrainingProgress) -> Void)?
    
    struct TrainingJob {
        let id: String
        let datasetURL: URL
        let ggufModelPath: String
        let huggingFaceModelId: String
        let config: TrainingConfig
        var isCancelled: Bool = false
    }
    
    public init() {
        logger.info("GGUFTrainingService initialized")
    }
    
    /// Start training a LoRA adapter for a GGUF model.
    ///
    /// - Parameters:
    ///   - datasetURL: URL to JSONL dataset file
    ///   - ggufModelPath: Path to GGUF model file
    ///   - huggingFaceModelId: Hugging Face model ID to download for training
    ///   - config: Training configuration
    ///   - modelName: User-provided name for the trained model
    ///   - onProgress: Progress callback for UI updates
    /// - Returns: Path to trained GGUF model
    public func startTraining(
        datasetURL: URL,
        ggufModelPath: String,
        huggingFaceModelId: String,
        config: TrainingConfig,
        modelName: String = "Untitled Model",
        onProgress: @escaping @Sendable (TrainingProgress) -> Void
    ) async throws -> String {
        
        let job = TrainingJob(
            id: UUID().uuidString,
            datasetURL: datasetURL,
            ggufModelPath: ggufModelPath,
            huggingFaceModelId: huggingFaceModelId,
            config: config
        )
        
        currentJob = job
        progressCallback = onProgress
        
        logger.info("Starting GGUF LoRA training", metadata: [
            "dataset": "\(datasetURL.path)",
            "ggufModel": "\(ggufModelPath)",
            "huggingFaceModel": "\(huggingFaceModelId)",
            "rank": "\(config.rank)",
            "epochs": "\(config.epochs)"
        ])
        
        // Get cache directory for models
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let samModelsDir = cacheDir
            .appendingPathComponent("sam", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        
        try FileManager.default.createDirectory(at: samModelsDir, withIntermediateDirectories: true)
        
        // Create unique directory for this training run
        let trainingDir = samModelsDir.appendingPathComponent("training_\(job.id)")
        try FileManager.default.createDirectory(at: trainingDir, withIntermediateDirectories: true)
        
        // Output paths
        let adapterOutputDir = trainingDir.appendingPathComponent("adapter")
        let mergedModelName = "\(modelName.replacingOccurrences(of: " ", with: "_"))_\(Date().timeIntervalSince1970)"
        let ggufOutputPath = samModelsDir
            .appendingPathComponent(mergedModelName + ".gguf")
            .path
        
        // Train using Python script
        let ggufPath = try await trainWithPython(
            huggingFaceModelId: huggingFaceModelId,
            datasetPath: datasetURL.path,
            adapterOutputPath: adapterOutputDir.path,
            ggufOutputPath: ggufOutputPath,
            config: config
        )
        
        // Save metadata for the newly created GGUF model
        let metadata = GGUFModelMetadata(
            modelPath: ggufPath,
            huggingFaceModelId: huggingFaceModelId,
            quantization: "f16",  // Default quantization (can be made configurable)
            notes: "Trained on \(Date()). LoRA rank: \(config.rank), alpha: \(config.alpha)"
        )
        
        try GGUFMetadataManager.shared.saveMetadata(metadata)
        
        logger.info("GGUF training complete", metadata: [
            "outputPath": "\(ggufPath)",
            "modelName": "\(modelName)"
        ])
        
        // Clean up intermediate files (but keep GGUF)
        try? FileManager.default.removeItem(at: trainingDir)
        
        return ggufPath
    }
    
    /// Cancel current training job.
    public func cancelTraining() {
        currentJob?.isCancelled = true
        logger.info("Training cancelled by user")
    }
    
    // MARK: - Private Implementation
    
    /// Execute Python training script and monitor progress.
    private func trainWithPython(
        huggingFaceModelId: String,
        datasetPath: String,
        adapterOutputPath: String,
        ggufOutputPath: String,
        config: TrainingConfig
    ) async throws -> String {
        
        // Get Python path - use bundled Python
        let pythonPath: String
        let scriptPath: String
        
        if let bundlePath = Bundle.main.bundlePath.components(separatedBy: "/Contents").first {
            pythonPath = "\(bundlePath)/Contents/Resources/python_env/bin/python3"
            scriptPath = "\(bundlePath)/Contents/Resources/scripts/train_lora_gguf.py"
        } else {
            // Development fallback
            pythonPath = "/usr/bin/python3"
            scriptPath = "scripts/train_lora_gguf.py"
        }
        
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            logger.error("Training script not found", metadata: ["path": "\(scriptPath)"])
            throw TrainingError.scriptNotFound
        }
        
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            logger.error("Python not found", metadata: ["path": "\(pythonPath)"])
            throw TrainingError.pythonError("Python not found at: \(pythonPath)")
        }
        
        // Build command arguments
        let args = [
            scriptPath,
            "--hf-model-id", huggingFaceModelId,
            "--dataset", datasetPath,
            "--output", adapterOutputPath,
            "--gguf-output", ggufOutputPath,
            "--rank", "\(config.rank)",
            "--alpha", "\(config.alpha)",
            "--lr", "\(config.learningRate)",
            "--batch-size", "\(config.batchSize)",
            "--epochs", "\(config.epochs)",
            "--max-seq-length", "\(config.maxSeqLength)",
            "--gradient-accumulation-steps", "\(config.gradientAccumulationSteps)",
            "--quantization", "f16"  // Can be made configurable: f16, q4_k_m, q8_0, etc.
        ]
        
        logger.info("Launching Python training", metadata: [
            "python": "\(pythonPath)",
            "script": "\(scriptPath)",
            "huggingFaceModel": "\(huggingFaceModelId)"
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
        let errorHandle = errorPipe.fileHandleForReading
        var finalGGUFPath: String?
        
        while process.isRunning || outputHandle.availableData.count > 0 {
            let data = outputHandle.availableData
            if data.count > 0, let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: .newlines) {
                    if line.isEmpty { continue }
                    
                    // Try to parse JSON progress/output
                    if let jsonData = line.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        
                        if let type = json["type"] as? String {
                            switch type {
                            case "progress":
                                if let step = json["step"] as? Int,
                                   let total = json["total_steps"] as? Int,
                                   let loss = json["loss"] as? Double {
                                    
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
                                
                            case "log":
                                if let message = json["message"] as? String {
                                    logger.info("Python: \(message)")
                                }
                                
                            case "error":
                                if let error = json["error"] as? String {
                                    logger.error("Python training error", metadata: ["error": "\(error)"])
                                    throw TrainingError.pythonError(error)
                                }
                                
                            case "complete":
                                if let ggufPath = json["gguf_path"] as? String {
                                    finalGGUFPath = ggufPath
                                    logger.info("Python training completed successfully", metadata: [
                                        "ggufPath": "\(ggufPath)"
                                    ])
                                }
                                
                            default:
                                break
                            }
                        }
                    }
                }
            }
            
            // Also check stderr for log messages
            let errorData = errorHandle.availableData
            if errorData.count > 0, let errorOutput = String(data: errorData, encoding: .utf8) {
                for line in errorOutput.components(separatedBy: .newlines) {
                    if !line.isEmpty {
                        logger.debug("Python stderr: \(line)")
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
            
            logger.error("Python training failed", metadata: [
                "exitCode": "\(process.terminationStatus)",
                "error": "\(errorOutput)"
            ])
            
            // Check for common errors
            if errorOutput.contains("out of memory") || errorOutput.contains("OOM") {
                let suggestion = "Reduce rank to \(config.rank / 2) or batch size to \(max(1, config.batchSize / 2))"
                let errorMessage = """
                Out of memory during training.
                
                Current settings:
                - Rank: \(config.rank)
                - Batch size: \(config.batchSize)
                
                Suggestion: \(suggestion)
                """
                throw TrainingError.pythonError(errorMessage)
            }
            
            throw TrainingError.pythonError(errorOutput)
        }
        
        // Verify GGUF file was created
        guard let ggufPath = finalGGUFPath,
              FileManager.default.fileExists(atPath: ggufPath) else {
            throw TrainingError.pythonError("GGUF file not created")
        }
        
        return ggufPath
    }
}

// MARK: - Training Error
// Note: TrainingError is defined in MLXTrainingService.swift and shared across both training services
