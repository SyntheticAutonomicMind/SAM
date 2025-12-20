// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import Combine

/// Manages Stable Diffusion model storage and organization
@MainActor
public class StableDiffusionModelManager: ObservableObject {
    private let logger = Logger(label: "com.sam.sd.models")
    public let modelsDirectory: URL

    /// Model metadata saved alongside each model
    public struct ModelMetadata: Codable {
        public let originalName: String
        public let source: String  /// "civitai", "huggingface", or "manual"
        public let downloadDate: String?
        public let version: String?
        public let baseModel: String?  /// Base model ID for hierarchical downloads
        public let downloadType: String?  /// "standard" or "hierarchical"

        public init(
            originalName: String,
            source: String,
            downloadDate: String? = nil,
            version: String? = nil,
            baseModel: String? = nil,
            downloadType: String? = nil
        ) {
            self.originalName = originalName
            self.source = source
            self.downloadDate = downloadDate
            self.version = version
            self.baseModel = baseModel
            self.downloadType = downloadType
        }
    }

    /// Model information structure
    public struct ModelInfo: Codable, Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let path: URL
        public let variant: String
        public let sizeGB: Double
        public let safetensorsPath: URL?  /// Path to .safetensors file (for Python engine)
        public let hasCoreML: Bool  /// Whether CoreML (.mlmodelc) files are available
        public let hasSafeTensors: Bool  /// Whether .safetensors file is available
        public let coreMLPath: URL?  /// Path to CoreML original/compiled directory
        public let pipelineType: String  /// Pipeline class name (e.g., "StableDiffusion", "ZImage")

        /// Remote model support (ALICE)
        public let isRemote: Bool  /// True if model is on remote server
        public let remoteSource: String?  /// Remote source identifier (e.g., "alice")
        public let aliceModelId: String?  /// ALICE model ID (e.g., "sd/stable-diffusion-v1-5")

        /// Engines available for this model
        public var availableEngines: [String] {
            var engines: [String] = []
            if isRemote { engines.append("alice") }
            if hasCoreML { engines.append("coreml") }
            if hasSafeTensors { engines.append("python") }
            return engines
        }

        public init(
            id: String,
            name: String,
            path: URL,
            variant: String,
            sizeGB: Double,
            safetensorsPath: URL? = nil,
            hasCoreML: Bool = false,
            hasSafeTensors: Bool = false,
            coreMLPath: URL? = nil,
            pipelineType: String = "StableDiffusion",
            isRemote: Bool = false,
            remoteSource: String? = nil,
            aliceModelId: String? = nil
        ) {
            self.id = id
            self.name = name
            self.path = path
            self.variant = variant
            self.sizeGB = sizeGB
            self.safetensorsPath = safetensorsPath
            self.hasCoreML = hasCoreML
            self.hasSafeTensors = hasSafeTensors
            self.coreMLPath = coreMLPath
            self.pipelineType = pipelineType
            self.isRemote = isRemote
            self.remoteSource = remoteSource
            self.aliceModelId = aliceModelId
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        public static func == (lhs: ModelInfo, rhs: ModelInfo) -> Bool {
            lhs.id == rhs.id
        }
    }

    public init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        modelsDirectory = cachesDir.appendingPathComponent("sam/models/stable-diffusion")
        createDirectoryIfNeeded()
    }

    /// Create models directory if it doesn't exist
    private func createDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            logger.info("Stable Diffusion models directory: \(modelsDirectory.path)")
        } catch {
            logger.error("Failed to create models directory: \(error.localizedDescription)")
        }
    }

    /// List all installed Stable Diffusion models
    nonisolated public func listInstalledModels() -> [ModelInfo] {
        var models: [ModelInfo] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return models
        }

        for modelDir in contents {
            guard let isDirectory = try? modelDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDirectory else { continue }

            /// Skip the downloads directory (used for temporary .safetensors files)
            if modelDir.lastPathComponent == "downloads" {
                continue
            }

            if isValidModelDirectory(modelDir) {
                let modelInfo = createModelInfo(from: modelDir)
                models.append(modelInfo)
            }
        }

        return models
    }

    /// Check if a directory contains valid Stable Diffusion model files
    nonisolated private func isValidModelDirectory(_ directory: URL) -> Bool {
        /// Check for SafeTensors file (Python-only models)
        if hasSafeTensorsFile(directory) {
            return true
        }

        /// Check SDXL first (more specific with 2 text encoders)
        if isValidSDXLDirectory(directory) {
            return true
        }

        /// Fall back to SD 1.x/2.x detection
        if isValidSD1or2Directory(directory) {
            return true
        }

        return false
    }

    /// Check if directory contains a .safetensors file (Python diffusers models)
    nonisolated private func hasSafeTensorsFile(_ directory: URL) -> Bool {
        guard directory.isFileURL,
              FileManager.default.fileExists(atPath: directory.path) else {
            return false
        }

        /// Check if this is a multi-part diffusers model (has model_index.json)
        let modelIndexPath = directory.appendingPathComponent("model_index.json")
        if FileManager.default.fileExists(atPath: modelIndexPath.path) {
            /// Multi-part model - check for transformer/ or unet/ directories with weights
            let hasTransformer = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("transformer").path
            )
            let hasUnet = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("unet").path
            )

            if hasTransformer || hasUnet {
                logger.debug("Found multi-part diffusers model: \(directory.lastPathComponent)")
                return true
            }
        }

        /// Single-file model - check root directory for .safetensors
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            let hasSafeTensors = contents.contains(where: { $0.path.hasSuffix(".safetensors") })
            if hasSafeTensors {
                logger.debug("Found SafeTensors file in: \(directory.lastPathComponent)")
            }
            return hasSafeTensors
        } catch {
            return false
        }
    }

    /// Check if directory contains SDXL model (has TextEncoder2)
    nonisolated private func isValidSDXLDirectory(_ directory: URL) -> Bool {
        /// SAFETY: Validate URL before path operations (prevent crashes from malformed URLs)
        guard directory.isFileURL,
              FileManager.default.fileExists(atPath: directory.path) else {
            logger.warning("Invalid or non-existent directory: \(directory.path)")
            return false
        }

        /// SDXL models typically have simpler structure: just compiled/
        let possiblePaths: [URL]
        do {
            possiblePaths = [
                directory.appendingPathComponent("compiled"),
                directory.appendingPathComponent("original/compiled"),
                directory.appendingPathComponent("split_einsum/compiled"),
                directory
            ]
        } catch {
            logger.error("Failed to create paths for directory \(directory.path): \(error)")
            return false
        }

        let requiredFiles = [
            "TextEncoder.mlmodelc",
            "TextEncoder2.mlmodelc",  // SDXL specific
            "Unet.mlmodelc",
            "VAEDecoder.mlmodelc",
            "vocab.json",
            "merges.txt"
        ]

        for basePath in possiblePaths {
            var allFilesExist = true
            for file in requiredFiles {
                let filePath = basePath.appendingPathComponent(file)
                if !FileManager.default.fileExists(atPath: filePath.path) {
                    allFilesExist = false
                    break
                }
            }

            if allFilesExist {
                logger.debug("Found valid SDXL model at: \(basePath.path)")
                return true
            }
        }

        return false
    }

    /// Check if directory contains SD 1.x/2.x model (single text encoder)
    nonisolated private func isValidSD1or2Directory(_ directory: URL) -> Bool {
        /// SAFETY: Validate URL before path operations (prevent crashes from malformed URLs)
        guard directory.isFileURL,
              FileManager.default.fileExists(atPath: directory.path) else {
            logger.warning("Invalid or non-existent directory: \(directory.path)")
            return false
        }

        /// SD 1.x/2.x models have subdirectory structure
        let possiblePaths: [URL]
        do {
            possiblePaths = [
                directory.appendingPathComponent("original/compiled"),
                directory.appendingPathComponent("split_einsum/compiled"),
                directory
            ]
        } catch {
            logger.error("Failed to create paths for directory \(directory.path): \(error)")
            return false
        }

        let requiredFiles = [
            "TextEncoder.mlmodelc",
            "Unet.mlmodelc",
            "VAEDecoder.mlmodelc",
            "vocab.json",
            "merges.txt"
        ]

        for basePath in possiblePaths {
            var allFilesExist = true
            for file in requiredFiles {
                let filePath = basePath.appendingPathComponent(file)
                if !FileManager.default.fileExists(atPath: filePath.path) {
                    allFilesExist = false
                    break
                }
            }

            /// Make sure it's NOT SDXL (doesn't have TextEncoder2)
            let textEncoder2Path = basePath.appendingPathComponent("TextEncoder2.mlmodelc")
            if FileManager.default.fileExists(atPath: textEncoder2Path.path) {
                continue  // This is SDXL, skip it
            }

            if allFilesExist {
                logger.debug("Found valid SD 1.x/2.x model at: \(basePath.path)")
                return true
            }
        }

        return false
    }

    /// Create ModelInfo from a model directory
    nonisolated private func createModelInfo(from directory: URL) -> ModelInfo {
        let modelName = directory.lastPathComponent
        let variant = extractVariant(from: directory)
        let sizeGB = calculateDirectorySize(directory)

        /// Read metadata for friendly display name
        let metadata = readMetadata(from: directory)
        if let metadata = metadata {
            logger.debug("Using friendly name from metadata: '\(metadata.originalName)' for model: \(modelName)")
        } else {
            logger.warning("No metadata found for model: \(modelName), using formatted directory name")
        }
        let displayName = metadata?.originalName ?? formatModelName(modelName)

        /// Detect CoreML availability and find resources path
        var coreMLPath: URL?
        var hasCoreML = false

        /// CRITICAL FIX: Use comprehensive validation functions instead of just checking Unet.mlmodelc
        /// This ensures ALL required files exist (including merges.txt, vocab.json, etc.)
        /// Prevents "merges.txt not found" errors when using CoreML engine with incomplete models
        if isValidSDXLDirectory(directory) || isValidSD1or2Directory(directory) {
            hasCoreML = true

            /// Find the actual CoreML path for loading
            let possibleCoreMLPaths = [
                directory.appendingPathComponent("compiled"),  /// SDXL from HF
                directory.appendingPathComponent("original/compiled"),  /// SD 1.x/2.x with original variant
                directory.appendingPathComponent("split_einsum/compiled"),  /// SD 1.x/2.x with split_einsum variant
                directory  /// Direct in model directory (some models)
            ]

            for path in possibleCoreMLPaths {
                if FileManager.default.fileExists(atPath: path.appendingPathComponent("Unet.mlmodelc").path) {
                    coreMLPath = path
                    break
                }
            }
        }

        /// Detect SafeTensors availability
        var safetensorsPath: URL?
        var hasSafeTensors = false

        /// Check if this is a multi-part diffusers model (has model_index.json)
        let modelIndexPath = directory.appendingPathComponent("model_index.json")
        let isMultiPartModel = FileManager.default.fileExists(atPath: modelIndexPath.path)

        if isMultiPartModel {
            /// For multi-part models, check for safetensors in subdirectories OR root
            let hasTransformerWeights = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("transformer").path
            ) || FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("unet").path
            )

            /// Also check root directory for .safetensors file (for variant files)
            var hasRootSafetensors = false
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )
                hasRootSafetensors = contents.contains(where: { $0.path.hasSuffix(".safetensors") })
            } catch {
                /// Continue
            }

            if hasTransformerWeights || hasRootSafetensors {
                /// Use directory path for multi-part models
                safetensorsPath = directory
                hasSafeTensors = true
                logger.debug("Multi-part diffusers model detected: \(directory.lastPathComponent)")
            }
        } else {
            /// For single-file models, check root directory for .safetensors file
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )
                safetensorsPath = contents.first(where: { $0.path.hasSuffix(".safetensors") })
                hasSafeTensors = safetensorsPath != nil
            } catch {
                /// Continue without SafeTensors
            }
        }

        /// Detect pipeline type from model_index.json
        let pipelineType = detectPipelineType(from: directory)

        return ModelInfo(
            id: modelName,
            name: displayName,  /// Use friendly name from metadata or formatted directory name
            path: coreMLPath ?? directory,  /// Path to resources (compiled dir) for backwards compatibility
            variant: variant,
            sizeGB: sizeGB,
            safetensorsPath: safetensorsPath,
            hasCoreML: hasCoreML,
            hasSafeTensors: hasSafeTensors,
            coreMLPath: coreMLPath,
            pipelineType: pipelineType
        )
    }

    /// Detect pipeline type from model_index.json
    nonisolated private func detectPipelineType(from directory: URL) -> String {
        let modelIndexPath = directory.appendingPathComponent("model_index.json")

        /// If no model_index.json, assume Stable Diffusion
        guard FileManager.default.fileExists(atPath: modelIndexPath.path) else {
            logger.debug("No model_index.json found, assuming StableDiffusion")
            return "StableDiffusion"
        }

        do {
            let data = try Data(contentsOf: modelIndexPath)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            if let className = json?["_class_name"] as? String {
                /// Extract base pipeline type (remove "Pipeline" suffix)
                let pipelineType = className.replacingOccurrences(of: "Pipeline", with: "")
                logger.debug("Detected pipeline type: \(pipelineType) from _class_name: \(className)")
                return pipelineType
            }

            logger.debug("No _class_name in model_index.json, assuming StableDiffusion")
            return "StableDiffusion"
        } catch {
            logger.warning("Failed to read model_index.json: \(error.localizedDescription)")
            return "StableDiffusion"
        }
    }

    /// Extract variant from model directory (check for SDXL via TextEncoder2)
    nonisolated private func extractVariant(from directory: URL) -> String {
        /// Check for SDXL by looking for TextEncoder2
        let possiblePaths = [
            directory.appendingPathComponent("compiled"),
            directory.appendingPathComponent("original/compiled"),
            directory.appendingPathComponent("split_einsum/compiled"),
            directory
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path.appendingPathComponent("TextEncoder2.mlmodelc").path) {
                return "SDXL"
            }
        }

        /// Fall back to name-based detection for SD 1.x/2.x
        let modelName = directory.lastPathComponent
        if modelName.contains("xl") {
            return "SDXL"
        } else if modelName.contains("v2") {
            return "SD 2.x"
        } else if modelName.contains("v1-5") || modelName.contains("v1.5") {
            return "SD 1.5"
        } else if modelName.contains("v1-4") || modelName.contains("v1.4") {
            return "SD 1.4"
        } else {
            return "Unknown"
        }
    }

    /// Format model name for display
    nonisolated private func formatModelName(_ modelName: String) -> String {
        let cleaned = modelName
            .replacingOccurrences(of: "coreml-", with: "")
            .replacingOccurrences(of: "-", with: " ")

        /// Handle special cases before capitalization
        let formatted = cleaned
            .replacingOccurrences(of: " xl ", with: " XL ", options: .caseInsensitive)
            .replacingOccurrences(of: " xl", with: " XL", options: .caseInsensitive)
            .replacingOccurrences(of: "xl ", with: "XL ", options: .caseInsensitive)

        return formatted.capitalized
    }

    /// Calculate directory size in GB
    nonisolated private func calculateDirectorySize(_ directory: URL) -> Double {
        var totalSize: Int64 = 0

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(fileSize)
            }
        }

        return Double(totalSize) / 1_073_741_824.0 // Convert bytes to GB
    }

    /// Move SafeTensors file from staging to model directory
    /// Call this after downloading to organize files properly
    public func moveSafeTensorsToModelDirectory(
        safetensorsPath: URL,
        modelDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        let destination = modelDirectory.appendingPathComponent("model.safetensors")

        /// Skip if file already in correct location
        if safetensorsPath == destination {
            logger.debug("SafeTensors already in correct location: \(destination.path)")
            return
        }

        /// Remove destination if it exists
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
            logger.debug("Removed existing SafeTensors at destination")
        }

        /// Move the file
        try fileManager.moveItem(at: safetensorsPath, to: destination)
        logger.info("Moved SafeTensors from \(safetensorsPath.path) to \(destination.path)")
    }

    /// Get path for a specific model
    public func modelPath(named: String) -> URL {
        return modelsDirectory.appendingPathComponent(named)
    }

    /// Check if a model is installed
    public func isModelInstalled(_ modelName: String) -> Bool {
        let modelPath = self.modelPath(named: modelName)
        return isValidModelDirectory(modelPath)
    }

    /// Delete a model
    public func deleteModel(_ modelName: String) throws {
        let modelPath = self.modelPath(named: modelName)
        try FileManager.default.removeItem(at: modelPath)
        logger.info("Deleted Stable Diffusion model: \(modelName)")
    }

    /// Save metadata for a model
    public func saveMetadata(_ metadata: ModelMetadata, for modelDirectory: URL) throws {
        let metadataPath = modelDirectory.appendingPathComponent(".sam_metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(metadata)
        try data.write(to: metadataPath)
        logger.debug("Saved metadata for model: \(modelDirectory.lastPathComponent)")
    }

    /// Read metadata for a model
    nonisolated public func readMetadata(from modelDirectory: URL) -> ModelMetadata? {
        let metadataPath = modelDirectory.appendingPathComponent(".sam_metadata.json")

        guard FileManager.default.fileExists(atPath: metadataPath.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: metadataPath)
            let decoder = JSONDecoder()
            return try decoder.decode(ModelMetadata.self, from: data)
        } catch {
            logger.warning("Failed to read metadata: \(error.localizedDescription)")
            return nil
        }
    }

    /// Get friendly display name for a model by its ID
    /// Returns the original friendly name from metadata if available, otherwise returns formatted directory name
    public func getFriendlyName(for modelId: String) -> String? {
        let modelDir = modelsDirectory.appendingPathComponent(modelId)

        /// Try to read from metadata first
        if let metadata = readMetadata(from: modelDir) {
            return metadata.originalName
        }

        /// Fall back to checking if model exists and returning formatted name
        let models = listInstalledModels()
        return models.first(where: { $0.id == modelId })?.name
    }

    // MARK: - Remote Model Support (ALICE)

    /// Create ModelInfo for a remote ALICE model
    nonisolated public static func createRemoteModelInfo(
        aliceModelId: String,
        displayName: String,
        isSDXL: Bool
    ) -> ModelInfo {
        /// Create a unique ID for the remote model
        let id = "alice-\(aliceModelId.replacingOccurrences(of: "/", with: "-"))"
        let variant = isSDXL ? "SDXL" : "SD 1.5"

        return ModelInfo(
            id: id,
            name: displayName,
            path: URL(fileURLWithPath: "/remote/alice"),  /// Placeholder path for remote models
            variant: variant,
            sizeGB: 0,  /// Remote models don't take local space
            safetensorsPath: nil,
            hasCoreML: false,
            hasSafeTensors: false,
            coreMLPath: nil,
            pipelineType: "StableDiffusion",
            isRemote: true,
            remoteSource: "alice",
            aliceModelId: aliceModelId
        )
    }

    /// List all available models (local + remote)
    /// Remote models are fetched from ALICE if configured
    public func listAllModels(aliceModels: [ModelInfo] = []) -> [ModelInfo] {
        var allModels = listInstalledModels()

        /// Add remote models (ensuring no duplicates by ID)
        let localIds = Set(allModels.map { $0.id })
        for remoteModel in aliceModels {
            if !localIds.contains(remoteModel.id) {
                allModels.append(remoteModel)
            }
        }

        /// Sort: local models first, then remote, alphabetically within each group
        return allModels.sorted { lhs, rhs in
            if lhs.isRemote != rhs.isRemote {
                return !lhs.isRemote  /// Local models first
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Create a URL-safe slug from a model name
    /// Examples:
    ///   "Realistic Vision V6.0 B1 - V5.1 Hyper (VAE)" → "realistic-vision-v6-0-b1-v5-1-hyper-vae"
    ///   "DreamShaper 8" → "dreamshaper-8"
    public static func createSlug(from name: String) -> String {
        return name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ";", with: "-")
            .replacingOccurrences(of: ",", with: "-")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "~", with: "-")
            .replacingOccurrences(of: "@", with: "-")
            .replacingOccurrences(of: "#", with: "-")
            .replacingOccurrences(of: "$", with: "-")
            .replacingOccurrences(of: "%", with: "-")
            .replacingOccurrences(of: "^", with: "-")
            .replacingOccurrences(of: "&", with: "-and-")
            .replacingOccurrences(of: "*", with: "-")
            .replacingOccurrences(of: "+", with: "-plus-")
            .replacingOccurrences(of: "=", with: "-")
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: "<", with: "-")
            .replacingOccurrences(of: ">", with: "-")
            /// Clean up multiple dashes
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            /// Trim dashes from start/end
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
