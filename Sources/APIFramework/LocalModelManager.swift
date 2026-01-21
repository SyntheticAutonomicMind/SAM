// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

private let modelLogger = Logger(label: "com.sam.llama.LocalModelManager")

/// Notification posted when local models list changes
extension Notification.Name {
    static let localModelsDidChange = Notification.Name("com.sam.localModelsDidChange")
}

/// Model registry entry with metadata.
public struct ModelRegistryEntry: Codable {
    public let provider: String
    public let modelName: String
    public let path: String
    public let installedDate: Date
    public let sizeBytes: Int64?
    public let quantization: String?

    public init(provider: String, modelName: String, path: String, installedDate: Date = Date(), sizeBytes: Int64? = nil, quantization: String? = nil) {
        self.provider = provider
        self.modelName = modelName
        self.path = path
        self.installedDate = installedDate
        self.sizeBytes = sizeBytes
        self.quantization = quantization
    }

    /// Model identifier in provider/model format.
    public var identifier: String {
        return "\(provider)/\(modelName)"
    }
}

/// Model registry for tracking installed models.
public struct ModelRegistry: Codable {
    public var models: [String: ModelRegistryEntry] = [:]

    public mutating func registerModel(_ entry: ModelRegistryEntry) {
        let key = entry.identifier
        models[key] = entry
        modelLogger.info("Registered model: \(key)")
    }

    public func getModel(provider: String, modelName: String) -> ModelRegistryEntry? {
        let key = "\(provider)/\(modelName)"
        return models[key]
    }

    public func listModels() -> [ModelRegistryEntry] {
        return Array(models.values)
    }
}

/// Manages local GGUF model discovery and metadata.
public class LocalModelManager {
    /// Standard model cache directory.
    public static let modelsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/sam/models")

    /// Registry file location.
    private static let registryPath = modelsDirectory.appendingPathComponent(".managed/model_registry.json")

    /// Discovered local models.
    private var cachedModels: [LocalModel] = []

    /// Model registry.
    private var registry: ModelRegistry

    /// File system watcher for models directory.
    private var fileSystemSource: DispatchSourceFileSystemObject?

    /// Debounce timer for file system events.
    private var debounceTimer: DispatchSourceTimer?
    private let debounceInterval: TimeInterval = 2.0

    public init() {
        self.registry = Self.loadRegistry()
        scanForModels()
        startWatchingModelsDirectory()
    }

    deinit {
        stopWatchingModelsDirectory()
    }

    // MARK: - Registry Management

    private static func loadRegistry() -> ModelRegistry {
        guard FileManager.default.fileExists(atPath: registryPath.path) else {
            modelLogger.debug("No registry found, creating new registry")
            return ModelRegistry()
        }

        do {
            let data = try Data(contentsOf: registryPath)
            let registry = try JSONDecoder().decode(ModelRegistry.self, from: data)
            modelLogger.debug("Loaded registry with \(registry.models.count) models")
            return registry
        } catch {
            modelLogger.error("Failed to load registry: \(error.localizedDescription), creating new")
            return ModelRegistry()
        }
    }

    private func saveRegistry() {
        do {
            /// Ensure .managed directory exists.
            let managedDir = Self.registryPath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: managedDir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self.registry)
            try data.write(to: Self.registryPath, options: .atomic)
            modelLogger.debug("Saved registry with \(self.registry.models.count) models")
        } catch {
            modelLogger.error("Failed to save registry: \(error.localizedDescription)")
        }
    }

    /// Register a model in the registry.
    public func registerModel(provider: String, modelName: String, path: String, sizeBytes: Int64? = nil, quantization: String? = nil) {
        let entry = ModelRegistryEntry(
            provider: provider,
            modelName: modelName,
            path: path,
            installedDate: Date(),
            sizeBytes: sizeBytes,
            quantization: quantization
        )
        registry.registerModel(entry)
        saveRegistry()
    }

    /// Unregister a model from the registry.
    public func unregisterModel(provider: String, modelName: String) {
        let key = "\(provider)/\(modelName)"
        if registry.models.removeValue(forKey: key) != nil {
            saveRegistry()
            modelLogger.info("Unregistered model: \(key)")
        } else {
            modelLogger.warning("Model not found in registry: \(key)")
        }
    }

    /// Get model path from registry or scan results.
    public func getModelPath(provider: String, modelName: String) -> String? {
        /// Try registry first (new structure).
        if let entry = registry.getModel(provider: provider, modelName: modelName) {
            return entry.path
        }

        /// Fall back to scanned models (legacy structure).
        return cachedModels.first { $0.name == modelName }?.path
    }

    /// Scan the models directory for model files in type/provider/model structure.
    public func scanForModels() {
        modelLogger.info("Scanning for local models in: \(Self.modelsDirectory.path)")

        guard FileManager.default.fileExists(atPath: Self.modelsDirectory.path) else {
            modelLogger.warning("Models directory does not exist: \(Self.modelsDirectory.path)")
            cachedModels = []
            return
        }

        /// Track previous model state to detect actual changes
        let previousModelPaths = Set(cachedModels.map { $0.path })
        
        var scannedModels: [LocalModel] = []

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: Self.modelsDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            for providerURL in contents {
                /// Skip .managed directory.
                if providerURL.lastPathComponent == ".managed" {
                    continue
                }

                /// Check for flat structure: direct .gguf files (legacy - ignore).
                if providerURL.pathExtension.lowercased() == "gguf" {
                    modelLogger.warning("Ignoring flat .gguf file (legacy): \(providerURL.lastPathComponent)")
                    continue
                }

                /// Check for 2-level structure: provider/model.
                if providerURL.hasDirectoryPath {
                    let provider = providerURL.lastPathComponent

                    /// Skip stable-diffusion directory (handled separately by scanForStableDiffusionModels)
                    if provider == "stable-diffusion" {
                        continue
                    }

                    /// Skip loras directory (not a model provider)
                    if provider.lowercased() == "loras" {
                        modelLogger.debug("Skipping LoRAs directory in model scan")
                        continue
                    }

                    /// Scan for model directories.
                    if let modelDirs = try? FileManager.default.contentsOfDirectory(at: providerURL, includingPropertiesForKeys: nil) {
                        for modelURL in modelDirs where modelURL.hasDirectoryPath {
                            let modelName = modelURL.lastPathComponent

                            /// Look for model files in model subdirectory
                            /// Also validates multi-part models to ensure all parts are present
                            if let primaryModelFile = findPrimaryModelFile(in: modelURL) {
                                if let model = parseModelInfo(from: primaryModelFile, provider: provider, modelName: modelName) {
                                    scannedModels.append(model)
                                }
                            }
                        }
                    }
                }
            }

            self.cachedModels = scannedModels
            modelLogger.info("Found \(self.cachedModels.count) local models")
            for model in self.cachedModels {
                modelLogger.debug("  - \(model.provider ?? "?")/\(model.name) (\(model.quantization ?? "unknown quant"))")
            }

            /// Also scan for Stable Diffusion models
            scanForStableDiffusionModels()

            /// Sync with registry: register any new models found during scan.
            let registryChanges = syncWithRegistry()

            /// Detect if model list actually changed (new models added or models removed)
            let currentModelPaths = Set(cachedModels.map { $0.path })
            let modelsChanged = previousModelPaths != currentModelPaths
            
            /// Post notifications if registry changed OR actual model list changed
            /// This fixes the bug where downloaded models were pre-registered, so registryChanges=false
            /// even though the actual model list changed (new model downloaded)
            if registryChanges || modelsChanged {
                NotificationCenter.default.post(name: .localModelsDidChange, object: self)
                NotificationCenter.default.post(name: .endpointManagerDidUpdateModels, object: self)
                if modelsChanged && !registryChanges {
                    modelLogger.info("Model list changed (downloaded model) - posted update notifications")
                } else {
                    modelLogger.info("Models changed - posted update notifications")
                }
            }
        } catch {
            modelLogger.error("Failed to scan models directory: \(error.localizedDescription)")
            cachedModels = []
        }
    }

    /// Scan for Stable Diffusion models in stable-diffusion directory
    private func scanForStableDiffusionModels() {
        let sdModelsDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("sam/models/stable-diffusion")

        guard FileManager.default.fileExists(atPath: sdModelsDir.path) else {
            modelLogger.debug("No stable-diffusion directory found")
            return
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: sdModelsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for modelDir in contents {
                guard let isDirectory = try? modelDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                      isDirectory else { continue }

                /// Skip the downloads directory (used for temporary .safetensors files)
                if modelDir.lastPathComponent == "downloads" {
                    continue
                }

                /// Skip LoRAs directory (not a Stable Diffusion model)
                if modelDir.lastPathComponent.lowercased() == "loras" {
                    modelLogger.debug("Skipping LoRAs directory in SD model scan")
                    continue
                }

                /// Check if this is a valid SD model directory
                if isValidSDModelDirectory(modelDir) {
                    let modelId = modelDir.lastPathComponent

                    /// Read friendly name from metadata, fall back to formatted directory name
                    var displayName = modelId
                    let metadataPath = modelDir.appendingPathComponent(".sam_metadata.json")
                    if FileManager.default.fileExists(atPath: metadataPath.path),
                       let data = try? Data(contentsOf: metadataPath),
                       let json = try? JSONDecoder().decode([String: String].self, from: data),
                       let originalName = json["originalName"] {
                        displayName = originalName
                    } else {
                        /// Format the directory name for display
                        displayName = modelId
                            .replacingOccurrences(of: "-", with: " ")
                            .replacingOccurrences(of: "coreml ", with: "")
                            .split(separator: " ")
                            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                            .joined(separator: " ")
                    }

                    /// Check what files exist - find actual safetensors file
                    var safetensorsPath: URL?

                    /// First check for model_index.json (diffusers format)
                    let modelIndexPath = modelDir.appendingPathComponent("model_index.json")
                    let hasDiffusersStructure = FileManager.default.fileExists(atPath: modelIndexPath.path)

                    if hasDiffusersStructure {
                        /// Diffusers format - check in subdirectories
                        /// Priority: transformer/ (FLUX, Z-Image), unet/ (SD 1.5, SDXL)
                        let possibleSubdirs = ["transformer", "unet"]
                        for subdir in possibleSubdirs {
                            let subdirPath = modelDir.appendingPathComponent(subdir)
                            if FileManager.default.fileExists(atPath: subdirPath.path) {
                                do {
                                    let contents = try FileManager.default.contentsOfDirectory(
                                        at: subdirPath,
                                        includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles]
                                    )
                                    /// Look for any .safetensors or .bin file
                                    if let foundFile = contents.first(where: {
                                        $0.path.hasSuffix(".safetensors") || $0.path.hasSuffix(".bin")
                                    }) {
                                        safetensorsPath = foundFile
                                        break
                                    }
                                } catch {
                                    /// Continue to next subdirectory
                                }
                            }
                        }
                    } else {
                        /// Traditional format - check root directory
                        do {
                            let contents = try FileManager.default.contentsOfDirectory(
                                at: modelDir,
                                includingPropertiesForKeys: nil,
                                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                            )
                            safetensorsPath = contents.first(where: { $0.path.hasSuffix(".safetensors") })
                        } catch {
                            /// Continue without safetensors
                        }
                    }

                    /// Check for CoreML in all possible locations
                    var coremlPath: URL?
                    let possiblePaths = [
                        modelDir.appendingPathComponent("original/compiled"),
                        modelDir.appendingPathComponent("split_einsum/compiled"),
                        modelDir
                    ]

                    for basePath in possiblePaths {
                        let unetPath = basePath.appendingPathComponent("Unet.mlmodelc")
                        if FileManager.default.fileExists(atPath: unetPath.path) {
                            coremlPath = unetPath
                            break
                        }
                    }

                    let hasSafeTensors = safetensorsPath != nil
                    let hasCoreML = coremlPath != nil

                    /// Create ONE entry per model
                    /// Prefer CoreML path if available, otherwise use SafeTensors/diffusers
                    /// The generation code will check both paths and use based on CoreML/Python switch
                    if hasCoreML || hasSafeTensors || hasDiffusersStructure {
                        let modelPath: String
                        let modelQuantization: String
                        let modelSize: Int64

                        if let coremlPath = coremlPath {
                            /// Prefer CoreML when available
                            modelPath = coremlPath.path
                            modelQuantization = "coreml"
                            /// Calculate size of parent directory (contains all CoreML files)
                            let coremlDir = coremlPath.deletingLastPathComponent()
                            modelSize = calculateDirectorySize(coremlDir)
                        } else if hasDiffusersStructure {
                            /// Diffusers format - use model directory path
                            modelPath = modelDir.path
                            modelQuantization = "diffusers"
                            modelSize = calculateDirectorySize(modelDir)
                        } else if let safetensorsPath = safetensorsPath {
                            /// Fall back to SafeTensors
                            modelPath = safetensorsPath.path
                            modelQuantization = "safetensors"
                            modelSize = calculateFileSize(safetensorsPath)
                        } else {
                            /// Should never reach here
                            continue
                        }

                        let model = LocalModel(
                            id: "stable-diffusion/\(modelId)",
                            name: displayName,
                            path: modelPath,
                            provider: "stable-diffusion",
                            quantization: modelQuantization,
                            sizeBytes: modelSize
                        )
                        cachedModels.append(model)

                        /// Also register in registry for EndpointManager to discover
                        /// Uses format: provider=stable-diffusion, modelName=displayName
                        let entry = ModelRegistryEntry(
                            provider: "stable-diffusion",
                            modelName: displayName,
                            path: modelPath,
                            installedDate: Date(),
                            sizeBytes: modelSize,
                            quantization: modelQuantization
                        )
                        registry.registerModel(entry)

                        /// Log what was detected
                        if hasCoreML && hasDiffusersStructure {
                            modelLogger.info("Found SD model: \(displayName) (CoreML + Diffusers)")
                        } else if hasCoreML && hasSafeTensors {
                            modelLogger.info("Found SD model: \(displayName) (CoreML + SafeTensors)")
                        } else if hasCoreML {
                            modelLogger.info("Found SD model: \(displayName) (CoreML)")
                        } else if hasDiffusersStructure {
                            modelLogger.info("Found SD model: \(displayName) (Diffusers)")
                        } else if hasSafeTensors {
                            modelLogger.info("Found SD model: \(displayName) (SafeTensors)")
                        }
                    }
                }
            }
        } catch {
            modelLogger.error("Failed to scan stable-diffusion directory: \(error.localizedDescription)")
        }
    }

    /// Calculate file size
    private func calculateFileSize(_ fileURL: URL) -> Int64 {
        if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return Int64(fileSize)
        }
        return 0
    }

    /// Check if directory contains a valid SD model structure
    private func isValidSDModelDirectory(_ directory: URL) -> Bool {
        /// Check for diffusers format (model_index.json)
        let modelIndexPath = directory.appendingPathComponent("model_index.json")
        if FileManager.default.fileExists(atPath: modelIndexPath.path) {
            return true
        }

        /// Check for SafeTensors file (any .safetensors file, not just "model.safetensors")
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )

            /// Check if any .safetensors file exists
            if contents.contains(where: { $0.path.hasSuffix(".safetensors") }) {
                return true
            }
        } catch {
            /// If we can't read directory, continue to check for CoreML
        }

        /// Check for CoreML models
        let possiblePaths = [
            directory.appendingPathComponent("original/compiled"),
            directory.appendingPathComponent("split_einsum/compiled"),
            directory
        ]

        let requiredFiles = ["TextEncoder.mlmodelc", "Unet.mlmodelc", "VAEDecoder.mlmodelc"]

        for basePath in possiblePaths {
            var allExist = true
            for file in requiredFiles {
                if !FileManager.default.fileExists(atPath: basePath.appendingPathComponent(file).path) {
                    allExist = false
                    break
                }
            }
            if allExist {
                return true
            }
        }

        return false
    }

    /// Calculate total size of directory
    private func calculateDirectorySize(_ directory: URL) -> Int64 {
        var totalSize: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }
        return totalSize
    }

    /// Sync scanned models with registry.
    /// Sync discovered models with registry and return whether changes were made
    private func syncWithRegistry() -> Bool {
        var registryUpdated = false

        for model in cachedModels {
            let provider = model.provider ?? "unknown"
            let modelName = model.name

            /// Check if model is already in registry.
            if registry.getModel(provider: provider, modelName: modelName) == nil {
                /// Register newly discovered model.
                registerModel(
                    provider: provider,
                    modelName: modelName,
                    path: model.path,
                    sizeBytes: model.sizeBytes,
                    quantization: model.quantization
                )
                registryUpdated = true
                modelLogger.info("Auto-registered model: \(provider)/\(modelName)")
            }
        }

        if registryUpdated {
            modelLogger.info("Registry updated with newly discovered models")
        }

        return registryUpdated
    }

    // MARK: - Migration

    /// Extract quantization information from model name.
    private func extractQuantization(from name: String) -> String? {
        let quantizationPattern = "Q\\d+_[KM0-9_]+"
        if let range = name.range(of: quantizationPattern, options: .regularExpression) {
            return String(name[range])
        }
        return nil
    }

    /// Parse model metadata from filename and file info.
    /// Detect and validate multi-part models (e.g., model-00001-of-00006.safetensors)
    /// Returns true only if ALL parts are present
    private func isMultiPartModelComplete(modelDirectory: URL) -> Bool {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: modelDirectory, includingPropertiesForKeys: nil)
            
            /// Look for multi-part pattern: model-XXXXX-of-NNNNN.safetensors or model-XXXXX-of-NNNNN.bin
            let multiPartPattern = try NSRegularExpression(pattern: "model-(\\d+)-of-(\\d+)\\.(safetensors|bin)$", options: [])
            
            var multiPartFiles: [(partNum: Int, totalParts: Int, url: URL)] = []
            
            for file in files {
                let filename = file.lastPathComponent
                let matches = multiPartPattern.matches(in: filename, range: NSRange(filename.startIndex..., in: filename))
                
                if let match = matches.first,
                   let partRange = Range(match.range(at: 1), in: filename),
                   let totalRange = Range(match.range(at: 2), in: filename),
                   let partNum = Int(String(filename[partRange])),
                   let totalParts = Int(String(filename[totalRange])) {
                    multiPartFiles.append((partNum: partNum, totalParts: totalParts, url: file))
                }
            }
            
            /// If this is a multi-part model, check if all parts are present
            if !multiPartFiles.isEmpty {
                guard let firstFile = multiPartFiles.first else { return false }
                let expectedTotal = firstFile.totalParts
                let foundParts = Set(multiPartFiles.map { $0.partNum })
                let expectedParts = Set(1...expectedTotal)
                
                let isComplete = foundParts == expectedParts
                if !isComplete {
                    modelLogger.warning("Multi-part model incomplete: has \(foundParts.count) of \(expectedTotal) parts")
                }
                return isComplete
            }
            
            /// Not a multi-part model, consider it complete
            return true
        } catch {
            modelLogger.warning("Failed to check multi-part model: \(error.localizedDescription)")
            return true  // Assume complete if we can't read directory
        }
    }

    /// Find the best model file in directory, respecting multi-part validation
    private func findPrimaryModelFile(in modelDirectory: URL) -> URL? {
        /// First, validate if this is a multi-part model
        let isMultiPartComplete = isMultiPartModelComplete(modelDirectory: modelDirectory)
        guard isMultiPartComplete else {
            modelLogger.warning("Skipping incomplete multi-part model: \(modelDirectory.path)")
            return nil
        }
        
        /// Find primary model file - prefer model.safetensors over other .safetensors files
        /// This ensures we don't pick tokenizer or config files
        guard let files = try? FileManager.default.contentsOfDirectory(at: modelDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        
        let primaryModelFile = files.first(where: { $0.lastPathComponent == "model.safetensors" })
            ?? files.first(where: { $0.lastPathComponent == "pytorch_model.bin" })
            ?? files.first(where: { $0.pathExtension.lowercased() == "gguf" })
            ?? files.first(where: { $0.pathExtension.lowercased() == "bin" && !$0.lastPathComponent.hasSuffix(".safetensors") })
            ?? files.first(where: { $0.pathExtension.lowercased() == "safetensors" && $0.lastPathComponent.hasPrefix("model-") })
            ?? files.first(where: { $0.pathExtension.lowercased() == "safetensors" })
        
        return primaryModelFile
    }

    private func parseModelInfo(from url: URL, provider: String, modelName: String?) -> LocalModel? {
        let filename = url.deletingPathExtension().lastPathComponent
        let name = modelName ?? filename

        /// Extract quantization using helper method.
        let quantization = extractQuantization(from: name)

        /// Get file size.
        let fileSize: Int64? = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) }

        return LocalModel(
            id: "\(provider)/\(name)",
            name: name,
            path: url.path,
            provider: provider,
            quantization: quantization,
            sizeBytes: fileSize
        )
    }

    /// Get list of available model names.
    public func getAvailableModels() -> [String] {
        return cachedModels.map { $0.name }
    }

    /// Get full model info.
    public func getModels() -> [LocalModel] {
        return cachedModels
    }

    /// Get model path by name.
    public func getModelPath(name: String) -> String? {
        return cachedModels.first { $0.name == name }?.path
    }

    /// Get all registry entries.
    public func getAllRegistryModels() -> [ModelRegistryEntry] {
        return Array(registry.models.values)
    }

    // MARK: - File System Watching

    /// Start watching the models directory for changes.
    private func startWatchingModelsDirectory() {
        let modelsPath = Self.modelsDirectory

        /// Ensure directory exists.
        if !FileManager.default.fileExists(atPath: modelsPath.path) {
            do {
                try FileManager.default.createDirectory(at: modelsPath, withIntermediateDirectories: true)
                modelLogger.info("Created models directory: \(modelsPath.path)")
            } catch {
                modelLogger.error("Failed to create models directory: \(error.localizedDescription)")
                return
            }
        }

        /// Open file descriptor for watching.
        let fileDescriptor = open(modelsPath.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            modelLogger.error("Failed to open models directory for watching")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }

            /// Cancel existing timer if any.
            self.debounceTimer?.cancel()

            /// Create new debounce timer.
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + self.debounceInterval)
            timer.setEventHandler { [weak self] in
                modelLogger.info("Models directory changed (debounced), rescanning...")
                self?.scanForModels()
                self?.debounceTimer?.cancel()
                self?.debounceTimer = nil
            }
            timer.resume()
            self.debounceTimer = timer
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        self.fileSystemSource = source
        source.resume()

        modelLogger.debug("Started watching models directory: \(modelsPath.path)")
    }

    /// Stop watching the models directory.
    private func stopWatchingModelsDirectory() {
        debounceTimer?.cancel()
        debounceTimer = nil
        fileSystemSource?.cancel()
        fileSystemSource = nil
        modelLogger.debug("Stopped watching models directory")
    }

    // MARK: - Memory Validation

    /// Memory requirement estimation for a model.
    public struct MemoryRequirement {
        public let modelSizeGB: Double
        public let estimatedTotalGB: Double
        public let isSafe: Bool
        public let warningMessage: String?

        public init(modelSizeGB: Double, estimatedTotalGB: Double, isSafe: Bool, warningMessage: String?) {
            self.modelSizeGB = modelSizeGB
            self.estimatedTotalGB = estimatedTotalGB
            self.isSafe = isSafe
            self.warningMessage = warningMessage
        }
    }

    /// Estimate memory requirements for loading a model - Parameters: - modelPath: Path to the model file - inferenceLimitGB: Configured inference memory limit in GB (default: 8) - Returns: Memory requirement estimation with safety check.
    public func estimateMemoryRequirement(modelPath: String, inferenceLimitGB: Double = 8.0) -> MemoryRequirement? {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            modelLogger.error("Model file not found: \(modelPath)")
            return nil
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: modelPath)
            guard let fileSizeBytes = attributes[.size] as? Int64 else {
                modelLogger.error("Could not determine file size for: \(modelPath)")
                return nil
            }

            /// Convert to GB.
            let modelSizeGB = Double(fileSizeBytes) / 1_073_741_824.0

            /// Estimate total memory requirement: Model size * 1.5 (covers KV cache + activations) + inference limit.
            let estimatedTotalGB = (modelSizeGB * 1.5) + inferenceLimitGB

            /// Get available system RAM (dynamic measurement) Use mach host statistics to measure currently free/inactive/purgeable pages.
            func getAvailableMemoryBytes() -> UInt64 {
                var pageSize: vm_size_t = 0
                host_page_size(mach_host_self(), &pageSize)

                var stats = vm_statistics64()
                var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
                let result = withUnsafeMutablePointer(to: &stats) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
                        host_statistics64(mach_host_self(), HOST_VM_INFO64, ptr, &count)
                    }
                }

                if result != KERN_SUCCESS {
                    /// Fall back to physical memory conservative heuristic.
                    return UInt64(ProcessInfo.processInfo.physicalMemory / 10) * 6
                }

                /// Components we consider available: free + inactive + speculative + purgeable (if present).
                let free = UInt64(stats.free_count)
                let inactive = UInt64(stats.inactive_count)
                #if os(macOS)
                let speculative = UInt64(stats.speculative_count)
                #else
                let speculative: UInt64 = 0
                #endif
                let purgeable = UInt64(stats.purgeable_count)

                let availablePages = free + inactive + speculative + purgeable
                return availablePages * UInt64(pageSize)
            }

            let availableMemoryBytes = getAvailableMemoryBytes()
            let availableMemoryGB = Double(availableMemoryBytes) / 1_073_741_824.0

            /// Check if we have enough memory.
            let isSafe = estimatedTotalGB <= availableMemoryGB

            var warningMessage: String?
            if !isSafe {
                warningMessage = """
                This model needs about \(String(format: "%.0f", estimatedTotalGB))GB of free memory.
                You currently have \(String(format: "%.0f", availableMemoryGB))GB available.

                To free up memory:
                • Close other applications
                • Use a smaller or more quantized model
                • Reduce inference limit in Preferences (currently \(String(format: "%.0f", inferenceLimitGB))GB)
                """
                modelLogger.warning("Memory check FAILED for \(modelPath):")
                modelLogger.warning("  Estimated need: \(String(format: "%.1f", estimatedTotalGB))GB")
                modelLogger.warning("  Available: \(String(format: "%.1f", availableMemoryGB))GB")
            } else {
                warningMessage = nil
                modelLogger.info("Memory check passed for \(modelPath): \(String(format: "%.1f", estimatedTotalGB))GB estimated, \(String(format: "%.1f", availableMemoryGB))GB available")
            }

            /// Log summary for debugging.
            modelLogger.debug("Memory check: model=\(String(format: "%.1f", modelSizeGB))GB, estimated=\(String(format: "%.1f", estimatedTotalGB))GB, available=\(String(format: "%.1f", availableMemoryGB))GB")

            return MemoryRequirement(
                modelSizeGB: modelSizeGB,
                estimatedTotalGB: estimatedTotalGB,
                isSafe: isSafe,
                warningMessage: warningMessage
            )

        } catch {
            modelLogger.error("Failed to check model memory requirements: \(error.localizedDescription)")
            return nil
        }
    }

    /// Check if a model is safe to load based on available memory - Parameters: - provider: Model provider (e.g., "unsloth") - modelName: Model name (e.g., "Qwen2.5-Coder-7B-Instruct-Q5_K_M") - inferenceLimitGB: Configured inference memory limit in GB - Returns: Memory requirement estimation, or nil if model not found.
    public func checkModelMemory(provider: String, modelName: String, inferenceLimitGB: Double = 8.0) -> MemoryRequirement? {
        guard let modelPath = getModelPath(provider: provider, modelName: modelName) else {
            modelLogger.error("Model not found: \(provider)/\(modelName)")
            return nil
        }

        return estimateMemoryRequirement(modelPath: modelPath, inferenceLimitGB: inferenceLimitGB)
    }
}

/// Local model metadata.
public struct LocalModel: Identifiable {
    public let id: String
    public let name: String
    public let path: String
    public let provider: String?
    public let quantization: String?
    public let sizeBytes: Int64?

    public init(id: String, name: String, path: String, provider: String? = nil, quantization: String? = nil, sizeBytes: Int64? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.provider = provider
        self.quantization = quantization
        self.sizeBytes = sizeBytes
    }

    public var sizeString: String {
        guard let bytes = sizeBytes else { return "Unknown size" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
