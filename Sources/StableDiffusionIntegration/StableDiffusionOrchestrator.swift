// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Logging
import StableDiffusion
import APIFramework

/// Generation engine type
public enum GenerationEngine: String, Codable, CaseIterable, Sendable {
    case coreML = "coreml"
    case python = "python"
    case alice = "alice"  /// Remote ALICE server

    public var displayName: String {
        switch self {
        case .coreML:
            return "CoreML (Fast, Apple Silicon)"
        case .python:
            return "Python (More Schedulers)"
        case .alice:
            return "ALICE (Remote Server)"
        }
    }
}

/// Unified scheduler type that works across both engines
public enum UnifiedScheduler: String, Sendable {
    /// CoreML schedulers
    case dpmppKarras = "dpm++_karras"
    case pndm = "pndm"

    /// Python-only schedulers
    case dpmppSDEKarras = "dpm++_sde_karras"
    case dpmppSDE = "dpm++_sde"
    case euler = "euler"
    case eulerAncestral = "euler_a"
    case ddim = "ddim"
    case ddimUniform = "ddim_uniform"
    case lms = "lms"

    public var displayName: String {
        switch self {
        case .dpmppKarras: return "DPM++ 2M Karras"
        case .dpmppSDEKarras: return "DPM++ 2M SDE Karras"
        case .dpmppSDE: return "DPM++ 2M SDE"
        case .euler: return "Euler"
        case .eulerAncestral: return "Euler Ancestral"
        case .ddim: return "DDIM"
        case .ddimUniform: return "DDIM Uniform"
        case .pndm: return "PNDM"
        case .lms: return "LMS"
        }
    }

    /// Check if scheduler is available for given engine
    public func isAvailable(for engine: GenerationEngine) -> Bool {
        switch engine {
        case .coreML:
            return [.dpmppKarras, .pndm].contains(self)
        case .python:
            return true  // All schedulers available in Python
        case .alice:
            return true  // All schedulers available on ALICE (remote server)
        }
    }

    /// Get schedulers available for engine
    public static func available(for engine: GenerationEngine) -> [UnifiedScheduler] {
        switch engine {
        case .coreML:
            return [.dpmppKarras, .pndm]
        case .python:
            return [.dpmppSDEKarras, .dpmppKarras, .dpmppSDE, .euler, .eulerAncestral, .ddim, .ddimUniform, .pndm, .lms]
        case .alice:
            return [.ddim, .euler, .eulerAncestral, .dpmppKarras, .dpmppSDEKarras, .pndm, .lms]
        }
    }

    /// Convert to ALICE scheduler name
    public var aliceSchedulerName: String {
        switch self {
        case .dpmppKarras: return "dpm++_2m_karras"
        case .dpmppSDEKarras: return "dpm++_sde_karras"
        case .dpmppSDE: return "dpm++_sde"
        case .euler: return "euler"
        case .eulerAncestral: return "euler_a"
        case .ddim: return "ddim"
        case .ddimUniform: return "ddim"
        case .pndm: return "pndm"
        case .lms: return "lms"
        }
    }
}

/// Orchestrator for Stable Diffusion generation across CoreML and Python engines
public class StableDiffusionOrchestrator {
    private let logger = Logger(label: "com.sam.sd.orchestrator")
    private let coreMLService: StableDiffusionService
    private let pythonService: PythonDiffusersService
    private let upscalingService: UpscalingService

    public struct GenerationConfig: Sendable {
        public let prompt: String
        public let negativePrompt: String?
        public let modelName: String
        public let modelPath: URL?  /// Optional explicit path to CoreML resources
        public let scheduler: UnifiedScheduler
        public let steps: Int
        public let guidanceScale: Float
        public let width: Int
        public let height: Int
        public let seed: Int?
        public let imageCount: Int
        public let engine: GenerationEngine
        public let enableUpscaling: Bool
        public let upscaleModel: UpscalingService.UpscaleModel
        public let upscaleFactor: Int
        public let workingDirectory: String?  /// Conversation working directory for saving images
        public let inputImage: String?  /// Input image path for img2img
        public let strength: Double  /// Denoising strength for img2img (0.0-1.0)
        public let device: String  /// Compute device for Python engine ("auto", "mps", "cpu")
        public let loraPaths: [String]?  /// Optional LoRA file paths (Python engine only)
        public let loraWeights: [Double]?  /// Optional weights for each LoRA (0.0-1.0)

        /// ALICE remote generation settings
        public let aliceBaseURL: String?  /// ALICE server base URL
        public let aliceApiKey: String?  /// ALICE API key for authentication
        public let aliceModelId: String?  /// ALICE model ID (e.g., "sd/stable-diffusion-v1-5")

        public init(
            prompt: String,
            negativePrompt: String? = nil,
            modelName: String,
            modelPath: URL? = nil,
            scheduler: UnifiedScheduler = .dpmppSDEKarras,
            steps: Int = 25,
            guidanceScale: Float = 7.5,
            width: Int = 512,
            height: Int = 512,
            seed: Int? = nil,
            imageCount: Int = 1,
            engine: GenerationEngine = .coreML,
            enableUpscaling: Bool = false,
            upscaleModel: UpscalingService.UpscaleModel = .general,
            upscaleFactor: Int = 4,
            workingDirectory: String? = nil,
            inputImage: String? = nil,
            strength: Double = 0.75,
            device: String = "auto",
            loraPaths: [String]? = nil,
            loraWeights: [Double]? = nil,
            aliceBaseURL: String? = nil,
            aliceApiKey: String? = nil,
            aliceModelId: String? = nil
        ) {
            self.prompt = prompt
            self.negativePrompt = negativePrompt
            self.modelName = modelName
            self.modelPath = modelPath
            self.scheduler = scheduler
            self.steps = steps
            self.guidanceScale = guidanceScale
            self.width = width
            self.height = height
            self.seed = seed
            self.imageCount = imageCount
            self.engine = engine
            self.enableUpscaling = enableUpscaling
            self.upscaleModel = upscaleModel
            self.upscaleFactor = upscaleFactor
            self.workingDirectory = workingDirectory
            self.inputImage = inputImage
            self.strength = strength
            self.device = device
            self.loraPaths = loraPaths
            self.loraWeights = loraWeights
            self.aliceBaseURL = aliceBaseURL
            self.aliceApiKey = aliceApiKey
            self.aliceModelId = aliceModelId
        }
    }

    public struct GenerationResult: @unchecked Sendable {
        public let images: [CGImage]
        public let imagePaths: [URL]
        public let metadata: [String: Any]
    }

    public init(
        coreMLService: StableDiffusionService,
        pythonService: PythonDiffusersService,
        upscalingService: UpscalingService
    ) {
        self.coreMLService = coreMLService
        self.pythonService = pythonService
        self.upscalingService = upscalingService
    }

    /// Generate images using specified engine and configuration
    public func generateImages(config: GenerationConfig) async throws -> GenerationResult {
        logger.info("Starting generation", metadata: [
            "engine": .string(config.engine.rawValue),
            "scheduler": .string(config.scheduler.rawValue),
            "upscaling": .stringConvertible(config.enableUpscaling)
        ])

        /// Validate scheduler availability
        guard config.scheduler.isAvailable(for: config.engine) else {
            throw GenerationError.schedulerNotAvailable(config.scheduler.rawValue, config.engine.rawValue)
        }

        /// Generate based on engine
        var imagePaths: [URL] = []
        var metadata: [String: Any] = [:]

        switch config.engine {
        case .coreML:
            imagePaths = try await generateWithCoreML(config: config, metadata: &metadata)
        case .python:
            imagePaths = try await generateWithPython(config: config, metadata: &metadata)
        case .alice:
            imagePaths = try await generateWithALICE(config: config, metadata: &metadata)
        }

        /// Upscale if requested
        if config.enableUpscaling {
            imagePaths = try await upscaleImages(
                imagePaths,
                model: config.upscaleModel,
                scale: config.upscaleFactor
            )
            metadata["upscaled"] = true
            metadata["upscale_model"] = config.upscaleModel.rawValue
            metadata["upscale_factor"] = config.upscaleFactor
        }

        /// Load images as CGImage
        let images = imagePaths.compactMap { path -> CGImage? in
            guard let provider = CGDataProvider(url: path as CFURL),
                  let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                return nil
            }
            return image
        }

        return GenerationResult(images: images, imagePaths: imagePaths, metadata: metadata)
    }

    /// Generate using CoreML engine
    private func generateWithCoreML(config: GenerationConfig, metadata: inout [String: Any]) async throws -> [URL] {
        /// Map unified scheduler to CoreML scheduler
        let coreMLScheduler: StableDiffusionScheduler
        let useKarras: Bool

        switch config.scheduler {
        case .dpmppKarras:
            coreMLScheduler = .dpmSolverMultistepScheduler
            useKarras = true
        case .pndm:
            coreMLScheduler = .pndmScheduler
            useKarras = false
        default:
            throw GenerationError.schedulerNotAvailable(config.scheduler.rawValue, "coreml")
        }

        /// Load model (assumes CoreML .mlmodelc format)
        let modelPath: URL
        if let explicitPath = config.modelPath {
            /// Use explicit path if provided (from ModelInfo)
            modelPath = explicitPath
        } else {
            /// Fall back to constructing path from model name (backwards compatibility)
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            modelPath = cacheDir.appendingPathComponent("sam/models/stable-diffusion/\(config.modelName)")
        }

        try await coreMLService.loadModel(at: modelPath, disableSafety: UserDefaults.standard.bool(forKey: "imageGenerationDisableSafety"))

        /// Generate images
        let images = try await coreMLService.generateImage(
            prompt: config.prompt,
            negativePrompt: config.negativePrompt,
            steps: config.steps,
            guidanceScale: config.guidanceScale,
            seed: config.seed,
            imageCount: config.imageCount,
            scheduler: coreMLScheduler,
            schedulerTimestepSpacing: useKarras ? .karras : .linspace
        )

        /// Save images to working directory or temp
        let outputDir: URL
        if let workingDir = config.workingDirectory {
            outputDir = URL(fileURLWithPath: workingDir).appendingPathComponent("images")
        } else {
            outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-gen-\(UUID().uuidString)")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var paths: [URL] = []
        for (i, image) in images.enumerated() {
            let timestamp = Int(Date().timeIntervalSince1970)
            let filename = "sd_\(timestamp)_\(i).png"
            let path = outputDir.appendingPathComponent(filename)
            try saveImage(image, to: path)
            paths.append(path)
        }

        metadata["engine"] = "coreml"
        metadata["scheduler"] = config.scheduler.rawValue

        return paths
    }

    /// Generate using Python diffusers engine
    private func generateWithPython(config: GenerationConfig, metadata: inout [String: Any]) async throws -> [URL] {
        /// Map unified scheduler to Python scheduler
        let pythonScheduler: PythonDiffusersService.PythonScheduler

        switch config.scheduler {
        case .dpmppKarras: pythonScheduler = .dpmplusKarras
        case .dpmppSDEKarras: pythonScheduler = .dpmppSDEKarras
        case .dpmppSDE: pythonScheduler = .dpmppSDE
        case .euler: pythonScheduler = .euler
        case .eulerAncestral: pythonScheduler = .eulerA
        case .ddim: pythonScheduler = .ddim
        case .ddimUniform: pythonScheduler = .ddimUniform
        case .pndm: pythonScheduler = .pndm
        case .lms: pythonScheduler = .lms
        }

        /// Generate output path in working directory or temp
        let outputDir: URL
        if let workingDir = config.workingDirectory {
            outputDir = URL(fileURLWithPath: workingDir).appendingPathComponent("images")
        } else {
            outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-gen-\(UUID().uuidString)")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970)
        let outputPath = outputDir.appendingPathComponent("sd_\(timestamp).png")

        /// Generate using Python
        let result = try await pythonService.generateImage(
            prompt: config.prompt,
            negativePrompt: config.negativePrompt,
            modelName: config.modelName,
            scheduler: pythonScheduler,
            steps: config.steps,
            guidanceScale: config.guidanceScale,
            width: config.width,
            height: config.height,
            seed: config.seed,
            imageCount: config.imageCount,
            inputImage: config.inputImage,
            strength: config.strength,
            device: config.device,
            loraPaths: config.loraPaths,
            loraWeights: config.loraWeights,
            outputPath: outputPath
        )

        metadata["engine"] = "python"
        metadata["scheduler"] = config.scheduler.rawValue
        metadata.merge(result.metadata) { current, _ in current }

        return result.imagePaths
    }

    /// Upscale images
    private func upscaleImages(_ imagePaths: [URL], model: UpscalingService.UpscaleModel, scale: Int) async throws -> [URL] {
        logger.info("Upscaling \(imagePaths.count) image(s)", metadata: [
            "model": .string(model.rawValue),
            "scale": .stringConvertible(scale)
        ])

        var upscaledPaths: [URL] = []

        for (i, imagePath) in imagePaths.enumerated() {
            let outputPath = imagePath.deletingPathExtension().appendingPathExtension("upscaled.png")

            let upscaled = try await upscalingService.upscaleImage(
                at: imagePath,
                outputPath: outputPath,
                model: model,
                scale: scale,
                tile: 400  // Use tiling to reduce memory usage
            )

            upscaledPaths.append(upscaled)
            logger.debug("Upscaled image \(i+1)/\(imagePaths.count)")
        }

        return upscaledPaths
    }

    /// Generate using ALICE remote engine
    private func generateWithALICE(config: GenerationConfig, metadata: inout [String: Any]) async throws -> [URL] {
        guard let baseURL = config.aliceBaseURL else {
            throw GenerationError.engineNotAvailable("ALICE base URL not configured")
        }

        logger.info("Generating via ALICE remote server", metadata: [
            "url": .string(baseURL),
            "model": .string(config.aliceModelId ?? config.modelName)
        ])

        /// Create provider on main actor
        let aliceProvider = await MainActor.run {
            ALICEProvider(baseURL: baseURL, apiKey: config.aliceApiKey)
        }

        /// Check server health first
        let isHealthy = await aliceProvider.isServerHealthy()
        guard isHealthy else {
            throw GenerationError.engineNotAvailable("ALICE server not reachable at \(baseURL)")
        }

        /// Use ALICE model ID if provided, otherwise use model name
        let modelId = config.aliceModelId ?? config.modelName

        /// Generate images via ALICE
        let result = try await aliceProvider.generateImages(
            prompt: config.prompt,
            negativePrompt: config.negativePrompt,
            model: modelId,
            steps: config.steps,
            guidanceScale: config.guidanceScale,
            scheduler: config.scheduler.aliceSchedulerName,
            seed: config.seed,
            width: config.width,
            height: config.height
        )

        /// Download images to local storage
        let outputDir: URL
        if let workingDir = config.workingDirectory {
            outputDir = URL(fileURLWithPath: workingDir).appendingPathComponent("images")
        } else {
            outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("alice-gen-\(UUID().uuidString)")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var localPaths: [URL] = []
        for (i, imageUrl) in result.imageUrls.enumerated() {
            let timestamp = Int(Date().timeIntervalSince1970)
            let localPath = outputDir.appendingPathComponent("alice_\(timestamp)_\(i).png")
            try await aliceProvider.downloadImage(from: imageUrl, to: localPath)
            localPaths.append(localPath)
            logger.debug("Downloaded image \(i+1)/\(result.imageUrls.count) from ALICE")
        }

        metadata["engine"] = "alice"
        metadata["scheduler"] = config.scheduler.aliceSchedulerName
        metadata["remote_urls"] = result.imageUrls
        metadata["alice_model"] = result.model

        return localPaths
    }

    /// Save CGImage to file
    private func saveImage(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw GenerationError.failedToSaveImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw GenerationError.failedToSaveImage
        }
    }
}

/// Generation errors
public enum GenerationError: Error, LocalizedError {
    case schedulerNotAvailable(String, String)
    case failedToSaveImage
    case engineNotAvailable(String)

    public var errorDescription: String? {
        switch self {
        case .schedulerNotAvailable(let scheduler, let engine):
            return "Scheduler '\(scheduler)' is not available for engine '\(engine)'"
        case .failedToSaveImage:
            return "Failed to save generated image"
        case .engineNotAvailable(let engine):
            return "Generation engine '\(engine)' is not available"
        }
    }
}
