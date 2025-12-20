// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import StableDiffusion
import CoreML
import Logging
import CoreGraphics

/// Service for Stable Diffusion image generation using CoreML
/// Uses actor isolation to prevent concurrent model loading/unloading race conditions
public actor StableDiffusionService {
    private let logger = Logger(label: "com.sam.sd.service")
    private var sdPipeline: StableDiffusionPipeline?
    private var sdxlPipeline: StableDiffusionXLPipeline?
    private var currentModelPath: URL?
    private var currentSafetySetting: Bool = false  // Track current safety setting
    private var isSDXL: Bool = false  // Track if current model is SDXL

    public init() {
        logger.debug("Initializing StableDiffusionService")
    }

    /// Load a Stable Diffusion model from the specified path
    /// - Parameters:
    ///   - path: Path to the model directory
    ///   - disableSafety: If true, disable NSFW safety checker (allows all content)
    public func loadModel(at path: URL, disableSafety: Bool = false) throws {
        /// Detect if this is an SDXL model by checking for TextEncoder2
        let isSDXLModel = FileManager.default.fileExists(atPath: path.appendingPathComponent("TextEncoder2.mlmodelc").path)

        /// Check if we need to reload (different model OR different safety setting OR different model type)
        if currentModelPath == path && currentSafetySetting == disableSafety &&
           isSDXL == isSDXLModel && (sdPipeline != nil || sdxlPipeline != nil) {
            logger.debug("Model already loaded with same safety setting, skipping reload")
            return
        }

        if currentSafetySetting != disableSafety {
            logger.info("Safety setting changed (\(currentSafetySetting) → \(disableSafety)), reloading model")
        }

        logger.info("Loading Stable Diffusion model from: \(path.path) (safety: \(disableSafety ? "disabled" : "enabled"), type: \(isSDXLModel ? "SDXL" : "SD 1.x/2.x"))")

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU

        /// Clear previous pipeline
        sdPipeline = nil
        sdxlPipeline = nil

        if isSDXLModel {
            /// Load SDXL pipeline (no controlNet or disableSafety in SDXL init)
            sdxlPipeline = try StableDiffusionXLPipeline(
                resourcesAt: path,
                configuration: config,
                reduceMemory: false
            )
            try sdxlPipeline?.loadResources()
            isSDXL = true
        } else {
            /// Load SD 1.x/2.x pipeline  
            sdPipeline = try StableDiffusionPipeline(
                resourcesAt: path,
                controlNet: [],
                configuration: config,
                disableSafety: disableSafety,
                reduceMemory: false
            )
            try sdPipeline?.loadResources()
            isSDXL = false
        }

        currentModelPath = path
        currentSafetySetting = disableSafety

        logger.info("Stable Diffusion model loaded successfully (safety: \(disableSafety ? "disabled" : "enabled"), type: \(isSDXLModel ? "SDXL" : "SD 1.x/2.x"))")
    }

    /// Generate image from text prompt
    public func generateImage(
        prompt: String,
        negativePrompt: String? = nil,
        steps: Int = 25,
        guidanceScale: Float = 7.5,
        seed: Int? = nil,
        imageCount: Int = 1,
        scheduler: StableDiffusionScheduler = .dpmSolverMultistepScheduler,
        schedulerTimestepSpacing: TimeStepSpacing = .karras
    ) async throws -> [CGImage] {
        guard sdPipeline != nil || sdxlPipeline != nil else {
            throw SDError.modelNotLoaded
        }

        logger.info("Generating image: prompt='\(prompt)', steps=\(steps), guidance=\(guidanceScale), scheduler=\(scheduler), spacing=\(schedulerTimestepSpacing)")

        /// Handle seed: -1 means random, nil means random, otherwise use provided seed
        let finalSeed: UInt32
        if let seedValue = seed, seedValue >= 0 {
            finalSeed = UInt32(seedValue)
        } else {
            finalSeed = UInt32.random(in: 0..<UInt32.max)
        }

        let images: [CGImage?]

        if isSDXL, let xlPipeline = sdxlPipeline {
            /// Use SDXL pipeline
            var config = StableDiffusionXLPipeline.Configuration(prompt: prompt)
            config.negativePrompt = negativePrompt ?? ""
            config.stepCount = steps
            config.guidanceScale = guidanceScale
            config.seed = finalSeed
            config.imageCount = imageCount
            config.disableSafety = false
            config.schedulerType = scheduler
            config.schedulerTimestepSpacing = schedulerTimestepSpacing

            images = try xlPipeline.generateImages(configuration: config) { progress in
                self.logger.debug("Generation progress: step \(progress.step)/\(progress.stepCount)")
                return true
            }
        } else if let sdPipeline = sdPipeline {
            /// Use SD 1.x/2.x pipeline
            var config = StableDiffusionPipeline.Configuration(prompt: prompt)
            config.negativePrompt = negativePrompt ?? ""
            config.stepCount = steps
            config.guidanceScale = guidanceScale
            config.seed = finalSeed
            config.imageCount = imageCount
            config.disableSafety = false
            config.schedulerType = scheduler
            config.schedulerTimestepSpacing = schedulerTimestepSpacing

            images = try sdPipeline.generateImages(configuration: config) { progress in
                self.logger.debug("Generation progress: step \(progress.step)/\(progress.stepCount)")
                return true
            }
        } else {
            throw SDError.modelNotLoaded
        }

        let validImages = images.compactMap { $0 }

        if validImages.isEmpty {
            throw SDError.generationFailed("No valid images generated (safety check may have failed)")
        }

        logger.info("Successfully generated \(validImages.count) image(s)")
        return validImages
    }

    /// Check if a model is currently loaded
    public var isModelLoaded: Bool {
        return sdPipeline != nil || sdxlPipeline != nil
    }

    /// Get current model path
    public var loadedModelPath: URL? {
        return currentModelPath
    }

    /// Unload the current model to free memory
    public func unloadModel() {
        sdPipeline = nil
        sdxlPipeline = nil
        currentModelPath = nil
        isSDXL = false
        logger.info("Model unloaded")
    }
}

/// Stable Diffusion errors
public enum SDError: Error, LocalizedError {
    case modelNotLoaded
    case generationFailed(String)
    case invalidModel
    case missingRequiredFiles

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No Stable Diffusion model is currently loaded"
        case .generationFailed(let reason):
            return "Image generation failed: \(reason)"
        case .invalidModel:
            return "Invalid Stable Diffusion model format"
        case .missingRequiredFiles:
            return "Model directory is missing required files (TextEncoder.mlmodelc, Unet.mlmodelc, VAEDecoder.mlmodelc, vocab.json, merges.txt)"
        }
    }
}
