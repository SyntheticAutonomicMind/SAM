// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import CoreGraphics
import Logging

/// Service for generating images using Python diffusers library
public class PythonDiffusersService {
    private let logger = Logger(label: "com.sam.sd.python")
    private let pythonPath: String
    private let scriptPath: String

    public enum PythonScheduler: String, CaseIterable {
        case dpmpp = "dpm++"
        case dpmplusKarras = "dpm++_karras"
        case dpmppSDE = "dpm++_sde"
        case dpmppSDEKarras = "dpm++_sde_karras"
        case euler = "euler"
        case eulerA = "euler_a"
        case eulerAncestral = "euler_ancestral"
        case ddim = "ddim"
        case ddimUniform = "ddim_uniform"
        case pndm = "pndm"
        case lms = "lms"

        public var displayName: String {
            switch self {
            case .dpmpp: return "DPM++"
            case .dpmplusKarras: return "DPM++ Karras"
            case .dpmppSDE: return "DPM++ 2M SDE"
            case .dpmppSDEKarras: return "DPM++ 2M SDE Karras"
            case .euler: return "Euler"
            case .eulerA, .eulerAncestral: return "Euler Ancestral"
            case .ddim: return "DDIM"
            case .ddimUniform: return "DDIM Uniform"
            case .pndm: return "PNDM"
            case .lms: return "LMS"
            }
        }
    }

    public enum PythonDiffusersError: Error, LocalizedError {
        case pythonScriptNotFound
        case pythonExecutionFailed(String)
        case modelNotFound(String)
        case invalidResponse
        case missingPythonEnvironment

        public var errorDescription: String? {
            switch self {
            case .pythonScriptNotFound:
                return "Python generation script not found"
            case .pythonExecutionFailed(let message):
                return "Image generation failed: \(message)"
            case .modelNotFound(let path):
                return "Model not found at: \(path)"
            case .invalidResponse:
                return "Invalid response from Python script"
            case .missingPythonEnvironment:
                return "Python environment not configured"
            }
        }
    }

    public struct GenerationResult: @unchecked Sendable {
        public let imagePaths: [URL]
        public let metadata: [String: Any]
    }

    public init() {
        /// Determine the correct app bundle path
        /// When running from .app bundle, Bundle.main.bundlePath is the .app directory
        /// When running the executable directly (development), we need to find the .app bundle
        let bundlePath: String
        let mainBundlePath = Bundle.main.bundlePath

        if mainBundlePath.hasSuffix(".app") {
            /// Running from .app bundle
            bundlePath = mainBundlePath
        } else {
            /// Running executable directly (development mode)
            /// Look for SAM.app in the same directory as the executable
            let appBundlePath = mainBundlePath + "/SAM.app"
            if FileManager.default.fileExists(atPath: appBundlePath) {
                bundlePath = appBundlePath
            } else {
                /// Fall back to main bundle path (scripts may be at source level)
                bundlePath = mainBundlePath
            }
        }

        let bundledScriptPath = "\(bundlePath)/Contents/Resources/scripts/generate_image_diffusers.py"

        /// Fall back to source directory if not in bundle (development mode)
        let sourceScriptPath = "\(FileManager.default.currentDirectoryPath)/scripts/generate_image_diffusers.py"

        /// Choose script location
        if FileManager.default.fileExists(atPath: bundledScriptPath) {
            self.scriptPath = bundledScriptPath
        } else if FileManager.default.fileExists(atPath: sourceScriptPath) {
            self.scriptPath = sourceScriptPath
        } else {
            /// Try one more fallback - relative to executable
            let executablePath = Bundle.main.executablePath ?? ""
            let relativeScriptPath = (executablePath as NSString).deletingLastPathComponent.appending("/../../../scripts/generate_image_diffusers.py")
            self.scriptPath = (relativeScriptPath as NSString).standardizingPath
        }

        self.pythonPath = "\(bundlePath)/Contents/Resources/python_env/bin/python3"

        logger.debug("PythonDiffusersService initialized", metadata: [
            "pythonPath": .string(pythonPath),
            "scriptPath": .string(scriptPath)
        ])
    }

    /// Find model path (directory or single .safetensors file) for a given model name
    private func findModelFile(modelName: String) throws -> URL {
        /// With unified structure: models/stable-diffusion/{model-name}/
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let modelsDir = cacheDir.appendingPathComponent("sam/models/stable-diffusion")
        let modelDir = modelsDir.appendingPathComponent(modelName)

        /// Check if directory exists
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw PythonDiffusersError.modelNotFound("Model directory not found: \(modelName)")
        }

        /// Check for model_index.json (multi-part models like Z-Image, FLUX)
        let modelIndexPath = modelDir.appendingPathComponent("model_index.json")
        if FileManager.default.fileExists(atPath: modelIndexPath.path) {
            logger.debug("Found model_index.json - using directory path for multi-part model")
            return modelDir  /// Return directory for multi-part models
        }

        /// Check for single model.safetensors file (legacy SD models)
        let safetensorsFile = modelDir.appendingPathComponent("model.safetensors")
        if FileManager.default.fileExists(atPath: safetensorsFile.path) {
            logger.debug("Found model.safetensors - using single file path")
            return safetensorsFile  /// Return file for single-file models
        }

        /// Check for Z-Image Turbo format (multiple .safetensors files in root)
        /// Files: z_image_turbo_bf16.safetensors, qwen_3_4b.safetensors, ae.safetensors
        let turboFile = modelDir.appendingPathComponent("z_image_turbo_bf16.safetensors")
        if FileManager.default.fileExists(atPath: turboFile.path) {
            logger.debug("Found z_image_turbo_bf16.safetensors - using Comfy Z-Image format")
            return turboFile  /// Return main model file for Z-Image Turbo
        }

        /// Check for any .safetensors file (fallback for other single-file formats)
        let contents = try? FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
        let safetensorsFiles = contents?.filter { $0.pathExtension == "safetensors" } ?? []
        if safetensorsFiles.count == 1, let file = safetensorsFiles.first {
            logger.debug("Found single .safetensors file: \(file.lastPathComponent)")
            return file
        } else if safetensorsFiles.count > 1 {
            /// Multiple .safetensors - use the largest (usually the main UNet)
            let sorted = safetensorsFiles.sorted { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 >
                                                     (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 }
            if let largest = sorted.first {
                logger.debug("Found multiple .safetensors files, using largest: \(largest.lastPathComponent)")
                return largest
            }
        }

        /// Model files not found
        throw PythonDiffusersError.modelNotFound("No model files found for: \(modelName) (expected model_index.json or .safetensors)")
    }

    /// Generate images using Python diffusers
    /// - Parameters:
    ///   - prompt: Text prompt
    ///   - negativePrompt: Negative prompt
    ///   - modelName: Name of model in staging directory
    ///   - scheduler: Scheduler to use
    ///   - steps: Number of inference steps
    ///   - guidanceScale: Guidance scale (standard SD models)
    ///   - trueCfgScale: True CFG scale (Qwen-Image and similar models, overrides guidanceScale)
    ///   - width: Image width
    ///   - height: Image height
    ///   - seed: Random seed (nil for random)
    ///   - imageCount: Number of images to generate
    ///   - inputImage: Input image path for img2img (nil for text-to-image)
    ///   - strength: Denoising strength for img2img (0.0-1.0)
    ///   - device: Compute device ("auto", "mps", "cpu")
    ///   - loraPaths: Optional list of LoRA file paths
    ///   - loraWeights: Optional list of weights for each LoRA (0.0-1.0)
    ///   - outputPath: Base path for output images
    /// - Returns: Generation result with image paths and metadata
    public func generateImage(
        prompt: String,
        negativePrompt: String? = nil,
        modelName: String,
        scheduler: PythonScheduler = .dpmppSDEKarras,
        steps: Int = 25,
        guidanceScale: Float = 7.5,
        trueCfgScale: Float? = nil,
        width: Int = 512,
        height: Int = 512,
        seed: Int? = nil,
        imageCount: Int = 1,
        inputImage: String? = nil,
        strength: Double = 0.75,
        device: String = "auto",
        loraPaths: [String]? = nil,
        loraWeights: [Double]? = nil,
        outputPath: URL
    ) async throws -> GenerationResult {
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            logger.error("Python generation script not found at: \(scriptPath)")
            throw PythonDiffusersError.pythonScriptNotFound
        }

        guard FileManager.default.fileExists(atPath: pythonPath) else {
            logger.error("Python not found at: \(pythonPath)")
            throw PythonDiffusersError.missingPythonEnvironment
        }

        /// Find model file
        let modelPath = try findModelFile(modelName: modelName)

        logger.info("Starting Python diffusers generation", metadata: [
            "model": .string(modelPath.path),
            "prompt": .string(prompt),
            "scheduler": .string(scheduler.rawValue),
            "steps": .stringConvertible(steps),
            "guidance": .stringConvertible(guidanceScale),
            "trueCfgScale": trueCfgScale != nil ? .stringConvertible(trueCfgScale!) : .string("nil"),
            "size": .string("\(width)×\(height)"),
            "mode": .string(inputImage != nil ? "img2img" : "txt2img")
        ])

        /// Build command arguments
        var args = [
            scriptPath,
            "-m", modelPath.path,
            "-p", prompt,
            "-o", outputPath.path,
            "-s", scheduler.rawValue,
            "--steps", String(steps),
            "--guidance", String(guidanceScale),
            "--width", String(width),
            "--height", String(height),
            "--num-images", String(imageCount)
        ]

        /// Add true-cfg-scale if provided (for Qwen-Image and similar models)
        if let trueCfg = trueCfgScale {
            args.append(contentsOf: ["--true-cfg-scale", String(trueCfg)])
        }

        if let negPrompt = negativePrompt, !negPrompt.isEmpty {
            args.append(contentsOf: ["-n", negPrompt])
        }

        if let seedValue = seed {
            args.append(contentsOf: ["--seed", String(seedValue)])
        }

        /// Add img2img parameters if input image provided
        if let inputImagePath = inputImage {
            args.append(contentsOf: ["-i", inputImagePath])
            args.append(contentsOf: ["--strength", String(strength)])
        }

        /// Add LoRA parameters if provided
        if let paths = loraPaths {
            for (index, path) in paths.enumerated() {
                args.append(contentsOf: ["--lora", path])
                if let weights = loraWeights, index < weights.count {
                    args.append(contentsOf: ["--lora-weight", String(weights[index])])
                }
            }
            logger.info("Added \(paths.count) LoRA(s) to generation")
        }

        /// Determine effective device (defense-in-depth for Z-Image models)
        var effectiveDevice = device
        let modelPathLower = modelPath.path.lowercased()
        let lastComponentLower = modelPath.lastPathComponent.lowercased()
        let isZImageModel = lastComponentLower.contains("z-image") ||
                           modelPathLower.contains("z-image") ||
                           lastComponentLower.contains("zimage") ||
                           modelPathLower.contains("zimage")

        logger.info("Device selection", metadata: [
            "requestedDevice": .string(device),
            "modelPath": .string(modelPath.path),
            "lastComponent": .string(modelPath.lastPathComponent),
            "isZImageModel": .stringConvertible(isZImageModel)
        ])

        /// Z-Image models now work on MPS with bfloat16 (33.6s/step vs 76.5s/step on CPU)
        /// The Python script auto-detects bfloat16 support and uses it on MPS
        /// No need to force CPU anymore - MPS is 2x faster!
        if isZImageModel {
            logger.info("Z-Image model detected - MPS with bfloat16 is now supported (2x faster than CPU)")
        }

        logger.info("Using device: \(effectiveDevice)")

        /// Add device parameter
        args.append(contentsOf: ["--device", effectiveDevice])

        /// Execute Python script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                logger.error("Python generation failed", metadata: [
                    "exitCode": .stringConvertible(process.terminationStatus),
                    "stderr": .string(errorOutput)
                ])
                throw PythonDiffusersError.pythonExecutionFailed(errorOutput)
            }

            logger.debug("Generation output", metadata: [
                "stdout": .string(output)
            ])

            /// Parse JSON result from output
            /// Look for "--- RESULT JSON ---" section
            guard let jsonStart = output.range(of: "--- RESULT JSON ---"),
                  let jsonEnd = output.range(of: "--- END RESULT ---") else {
                logger.error("Could not find JSON result in output")
                throw PythonDiffusersError.invalidResponse
            }

            let jsonString = String(output[jsonStart.upperBound..<jsonEnd.lowerBound])
            guard let jsonData = jsonString.data(using: .utf8),
                  let result = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let imagePaths = result["images"] as? [String] else {
                logger.error("Failed to parse JSON result")
                throw PythonDiffusersError.invalidResponse
            }

            let imageURLs = imagePaths.map { URL(fileURLWithPath: $0) }
            let metadata = result["metadata"] as? [String: Any] ?? [:]

            logger.info("Python generation complete", metadata: [
                "imageCount": .stringConvertible(imageURLs.count),
                "paths": .string(imagePaths.joined(separator: ", "))
            ])

            return GenerationResult(imagePaths: imageURLs, metadata: metadata)

        } catch let error as PythonDiffusersError {
            throw error
        } catch {
            logger.error("Failed to execute Python generation script", metadata: [
                "error": .string(error.localizedDescription)
            ])
            throw PythonDiffusersError.pythonExecutionFailed(error.localizedDescription)
        }
    }

    /// Check if a model is available for Python generation
    /// - Parameter modelName: Name of model in staging directory
    /// - Returns: True if model .safetensors file exists
    public func isModelAvailable(_ modelName: String) -> Bool {
        do {
            _ = try findModelFile(modelName: modelName)
            return true
        } catch {
            return false
        }
    }

    /// List available models with SafeTensors support
    /// - Returns: Array of model names that have model.safetensors files
    public func listAvailableModels() -> [String] {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let modelsDir = cacheDir.appendingPathComponent("sam/models/stable-diffusion")

        guard FileManager.default.fileExists(atPath: modelsDir.path) else {
            return []
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: modelsDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            )

            return contents.compactMap { modelDir in
                guard let isDirectory = try? modelDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                      isDirectory else {
                    return nil
                }

                /// Check for standardized model.safetensors file
                let safetensorsFile = modelDir.appendingPathComponent("model.safetensors")
                let hasSafetensors = FileManager.default.fileExists(atPath: safetensorsFile.path)

                return hasSafetensors ? modelDir.lastPathComponent : nil
            }
        } catch {
            logger.error("Failed to list models with SafeTensors", metadata: [
                "error": .string(error.localizedDescription)
            ])
            return []
        }
    }
}
