// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import Combine
import ZIPFoundation

private let downloadLogger = Logger(label: "com.sam.download.ModelDownloadManager")

/// Download errors
public enum DownloadError: LocalizedError {
    case alreadyDownloading
    case invalidURL
    case httpError

    public var errorDescription: String? {
        switch self {
        case .alreadyDownloading:
            return "Download already in progress"
        case .invalidURL:
            return "Invalid download URL"
        case .httpError:
            return "HTTP error during download"
        }
    }
}

/// Manages model lifecycle: search, download, installation, and deletion Integrates with EndpointManager for automatic provider registration.
@MainActor
public class ModelDownloadManager: ObservableObject {
    /// Published state for UI binding.
    @Published public var availableModels: [HFModel] = []
    @Published public var installedModels: [LocalModel] = []
    @Published public var downloadProgress: [String: Double] = [:]
    @Published public var isSearching: Bool = false
    @Published public var isDownloading: Bool = false
    @Published public var errorMessage: String?

    /// Download tracking for API.
    @Published public var activeDownloads: [String: DownloadTask] = [:]

    /// Active download tasks for cancellation.
    private var downloadTasks: [String: Task<URL, Error>] = [:]
    private var downloadCancelHandlers: [String: () -> Void] = [:]

    private let apiClient: HuggingFaceGGUFClient
    private let localModelManager: LocalModelManager
    private let cacheDirectory: URL
    private weak var endpointManager: EndpointManager?

    /// Debounce timer for model refresh to prevent race conditions
    private var refreshDebounceTask: Task<Void, Never>?

    public init(endpointManager: EndpointManager? = nil) {
        self.apiClient = HuggingFaceGGUFClient()
        self.localModelManager = LocalModelManager()
        self.endpointManager = endpointManager

        /// Use the same cache directory as LocalModelManager.
        self.cacheDirectory = LocalModelManager.modelsDirectory

        /// Create cache directory if needed.
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            downloadLogger.info("Models cache directory: \(self.cacheDirectory.path)")
        } catch {
            downloadLogger.error("Failed to create cache directory: \(error.localizedDescription)")
        }

        /// Load installed models.
        refreshInstalledModels()

        /// Observe local model changes for hot reload with debouncing
        NotificationCenter.default.addObserver(
            forName: .localModelsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }

                /// Cancel existing debounce task
                self.refreshDebounceTask?.cancel()

                /// Create new debounced refresh task
                self.refreshDebounceTask = Task { @MainActor in
                    /// Wait 500ms to debounce rapid file system events
                    try? await Task.sleep(nanoseconds: 500_000_000)

                    guard !Task.isCancelled else { return }

                    self.refreshInstalledModels()
                    downloadLogger.info("Hot reload: Refreshed installed models list")
                }
            }
        }
    }

    // MARK: - Download Task Tracking

    /// Represents an active download task.
    public struct DownloadTask: Sendable {
        let id: String
        let repoId: String
        let filename: String
        var status: String
        var progress: Double
        var bytesDownloaded: Int64?
        var totalBytes: Int64?
        var startTime: Date
        var task: Task<Void, Never>?
        var cancellationToken: CancellationToken

        init(id: String, repoId: String, filename: String, task: Task<Void, Never>? = nil) {
            self.id = id
            self.repoId = repoId
            self.filename = filename
            self.status = "downloading"
            self.progress = 0.0
            self.startTime = Date()
            self.task = task
            self.cancellationToken = CancellationToken()
        }
    }

    /// Simple cancellation token.
    public class CancellationToken: @unchecked Sendable {
        private var _isCancelled = false

        var isCancelled: Bool {
            get { _isCancelled }
            set { _isCancelled = newValue }
        }

        func cancel() {
            _isCancelled = true
        }
    }

    // MARK: - Model Search

    /// Search HuggingFace for GGUF/MLX models - Parameters: - query: Search query string - fileExtension: Optional file extension filter (.gguf for GGUF, .safetensors for MLX).
    @MainActor
    public func searchModels(query: String, fileExtension: String? = nil) async {
        guard !query.isEmpty else {
            availableModels = []
            return
        }

        isSearching = true
        errorMessage = nil
        downloadLogger.error("DEBUG: Starting search for: '\(query)' with extension filter: \(fileExtension ?? "none")")

        do {
            let models = try await apiClient.searchModels(query: query, limit: 100, fileExtension: fileExtension)

            downloadLogger.error("DEBUG: API returned \(models.count) total models")

            /// Filter models based on extension:
            /// - GGUF: Must have .gguf files
            /// - MLX: Must have safetensors files
            /// - CoreML: Accept all (directory-based, no specific file check)
            /// - nil: Show ALL models (no filtering) - this is the "All Models" filter
            let filteredModels: [HFModel]
            if fileExtension == ".coreml" {
                /// CoreML models are directory-based, accept all from API
                filteredModels = models
                downloadLogger.error("DEBUG: CoreML filter - accepting all \(models.count) models from API")
            } else if fileExtension == nil {
                /// "All Models" filter - show everything (GGUF + MLX + CoreML + others)
                filteredModels = models
                downloadLogger.error("DEBUG: All Models filter - accepting all \(models.count) models from API")
            } else {
                /// GGUF/MLX models: Filter by file type
                filteredModels = models.filter { model in
                    let hasFiles = model.hasGGUF || model.hasMLX
                    if hasFiles {
                        downloadLogger.error("DEBUG: Model \(model.id) has GGUF=\(model.hasGGUF) MLX=\(model.hasMLX)")
                    }
                    return hasFiles
                }
            }

            availableModels = filteredModels
            downloadLogger.error("DEBUG: After filtering: \(filteredModels.count) compatible models")

            if filteredModels.isEmpty && !models.isEmpty {
                downloadLogger.error("DEBUG: WARNING - API returned models but none had GGUF/MLX files")
            }
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
            downloadLogger.error("DEBUG: Search failed with error: \(error.localizedDescription)")
            availableModels = []
        }

        isSearching = false
    }

    // MARK: - Model Download

    /// Detect provider from HuggingFace model repository ID.
    private func detectInferenceType(from repoId: String) -> String {
        /// Check for known MLX patterns.
        if repoId.lowercased().contains("mlx") {
            return "mlx"
        }
        /// Default to llama for GGUF files.
        return "llama"
    }

    /// Extract HuggingFace provider from repository ID (e.g., "unsloth/model" → "unsloth").
    private func extractHFProvider(from repoId: String) -> String {
        /// Repository ID format: provider/model-name.
        let components = repoId.components(separatedBy: "/")
        if components.count >= 2 {
            return components[0]
        }
        return "unknown"
    }

    /// Extract model name from repository ID and filename.
    private func extractModelName(from repoId: String, filename: String) -> String {
        /// Try to get model name from repository ID (after last /).
        if let lastComponent = repoId.components(separatedBy: "/").last,
           !lastComponent.isEmpty {
            return lastComponent
        }
        /// Fallback to filename without extension.
        return filename.replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: ".safetensors", with: "")
    }

    /// Cancel an active download.
    public func cancelDownload(modelId: String) {
        downloadLogger.info("Cancelling download: \(modelId)")

        /// Cancel the URLSession download task.
        downloadCancelHandlers[modelId]?()

        /// Cancel the Swift Task.
        downloadTasks[modelId]?.cancel()

        /// Cleanup.
        downloadTasks.removeValue(forKey: modelId)
        downloadCancelHandlers.removeValue(forKey: modelId)
        downloadProgress.removeValue(forKey: modelId)
    }

    /// Get all files that should be downloaded together with a given file.
    private func getRelatedFiles(for file: HFModelFile, in model: HFModel) -> [HFModelFile] {
        var relatedFiles: [HFModelFile] = []

        /// Always include the clicked file.
        relatedFiles.append(file)

        /// If this is a safetensors file, look for other parts and config files.
        if file.rfilename.hasSuffix(".safetensors") {
            /// Get all siblings (not just mlxFiles).
            guard let allSiblings = model.siblings else {
                downloadLogger.warning("No siblings array found for model")
                return relatedFiles
            }

            /// Find all other safetensors files with matching base name pattern e.g., model-00001-of-00002.safetensors → also download model-00002-of-00002.safetensors.
            let baseNamePattern = file.rfilename.replacingOccurrences(of: #"-\d{5}-of-\d{5}\.safetensors$"#, with: "", options: .regularExpression)

            for siblingFile in allSiblings {
                /// Skip the file we already added.
                if siblingFile.rfilename == file.rfilename {
                    continue
                }

                /// Add other safetensors files in the series.
                if siblingFile.rfilename.contains(baseNamePattern) && siblingFile.rfilename.hasSuffix(".safetensors") {
                    relatedFiles.append(siblingFile)
                    downloadLogger.info("Adding related safetensors: \(siblingFile.rfilename)")
                }
            }

            /// Also download essential config files.
            let essentialFiles = ["config.json", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "model.safetensors.index.json", "tokenizer_model"]
            for siblingFile in allSiblings {
                if essentialFiles.contains(siblingFile.rfilename) {
                    relatedFiles.append(siblingFile)
                    downloadLogger.info("Adding config file: \(siblingFile.rfilename)")
                }
            }
        }

        downloadLogger.info("Found \(relatedFiles.count) files to download for \(file.rfilename)")
        return relatedFiles
    }

    /// Download a model file and all related files (multi-file models, config files, etc.).
    @MainActor
    public func downloadModelWithRelatedFiles(model: HFModel, file: HFModelFile) async {
        let relatedFiles = getRelatedFiles(for: file, in: model)

        downloadLogger.info("Downloading \(relatedFiles.count) files for model: \(model.id)")

        /// Download all files sequentially (already async).
        for relatedFile in relatedFiles {
            await self.downloadModel(model: model, file: relatedFile)
        }
    }

    /// Download a model file and register provider.
    @MainActor
    public func downloadModel(model: HFModel, file: HFModelFile) async {
        let modelId = "\(model.id)_\(file.rfilename)"

        /// Check if this specific file is already downloading.
        guard downloadProgress[modelId] == nil else {
            downloadLogger.warning("File already downloading: \(file.rfilename)")
            return
        }

        downloadProgress[modelId] = 0.0
        errorMessage = nil
        downloadLogger.info("Starting download: \(file.rfilename) from \(model.id)")

        /// Create cancellable task.
        let task = Task {
            do {
                /// Detect inference type, provider, and model name for hierarchical structure.
                let inferenceType = detectInferenceType(from: model.id)
                let hfProvider = extractHFProvider(from: model.id)
                let modelName = extractModelName(from: model.id, filename: file.rfilename)

                downloadLogger.info("Download target: type=\(inferenceType), provider=\(hfProvider), modelName=\(modelName)")

                /// Create hierarchical directory structure: models/provider/modelName/.
                let providerDir = cacheDirectory.appendingPathComponent(hfProvider)
                let modelDir = providerDir.appendingPathComponent(modelName)

                try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
                downloadLogger.info("Created model directory: \(modelDir.path)")

                /// Prepare destination with atomic .tmp download.
                let tmpDestination = modelDir.appendingPathComponent("\(file.rfilename).tmp")
                let destination = modelDir.appendingPathComponent(file.rfilename)

                /// Check if already exists.
                if FileManager.default.fileExists(atPath: destination.path) {
                    downloadLogger.warning("Model file already exists, removing: \(destination.path)")
                    try FileManager.default.removeItem(at: destination)
                }

                /// Remove any leftover .tmp file.
                if FileManager.default.fileExists(atPath: tmpDestination.path) {
                    try? FileManager.default.removeItem(at: tmpDestination)
                }

                /// Download with progress tracking to .tmp file (atomic operation) Use cancellable version.
                let (downloadTask, cancelHandler) = apiClient.downloadModelCancellable(
                    repoId: model.id,
                    filename: file.rfilename,
                    destination: tmpDestination,
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            self?.downloadProgress[modelId] = progress
                            /// Log progress updates every 10%.
                            let percent = Int(progress * 100)
                            if percent % 10 == 0 {
                                downloadLogger.info("UI progress update: \(modelId) = \(percent)%")
                            }
                        }
                    }
                )

                /// Store cancel handler for this download.
                await MainActor.run {
                    self.downloadCancelHandlers[modelId] = cancelHandler
                }

                let downloadedURL = try await downloadTask.value

                /// Atomic rename: .tmp -> final destination.
                try FileManager.default.moveItem(at: downloadedURL, to: destination)
                downloadLogger.info("Download complete (atomic rename): \(destination.path)")

                return destination
            }
        }

        /// Store task for cancellation.
        downloadTasks[modelId] = task

        do {
            let localURL = try await task.value

            /// Detect inference type, provider, and model name for registration.
            _ = detectInferenceType(from: model.id)
            let hfProvider = extractHFProvider(from: model.id)
            let modelName = extractModelName(from: model.id, filename: file.rfilename)

            /// Register with ModelRegistry.
            let fileSize = try? localURL.resourceValues(forKeys: [URLResourceKey.fileSizeKey]).fileSize.map { Int64($0) }
            localModelManager.registerModel(
                provider: hfProvider,
                modelName: modelName,
                path: localURL.path,
                sizeBytes: fileSize,
                quantization: file.quantization
            )

            downloadLogger.info("Model registered in registry: \(hfProvider)/\(modelName)")

            /// Refresh installed models list (will now include the registered model).
            refreshInstalledModels()

            /// Try to get the registered model for provider registration Note: For multi-file models (like MLX), this might not find it until all files are downloaded.
            if let localModel = installedModels.first(where: { $0.path == localURL.path }) {
                /// Register provider with EndpointManager if available.
                if let endpointManager = endpointManager {
                    await registerProvider(for: localModel, with: endpointManager)
                }
                downloadLogger.info("Model installation complete: \(localModel.name)")
            } else {
                downloadLogger.warning("Model file downloaded and registered, but not yet available (may be multi-file model): \(localURL.path)")
                downloadLogger.debug("Model file downloaded: \(localURL.lastPathComponent)")
            }

            /// Clean up.
            downloadProgress.removeValue(forKey: modelId)
            downloadTasks.removeValue(forKey: modelId)
            downloadCancelHandlers.removeValue(forKey: modelId)
        } catch is CancellationError {
            downloadLogger.info("Download cancelled by user: \(modelId)")
            errorMessage = "Download cancelled by user"
            downloadProgress.removeValue(forKey: modelId)
            downloadTasks.removeValue(forKey: modelId)
            downloadCancelHandlers.removeValue(forKey: modelId)
        } catch {
            /// Check if this is a cancellation error from URLSession.
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                downloadLogger.info("Download cancelled by user: \(modelId)")
                errorMessage = "Download cancelled by user"
            } else {
                errorMessage = "Download failed: \(error.localizedDescription)"
                downloadLogger.error("Download failed: \(error.localizedDescription)")
            }
            downloadProgress.removeValue(forKey: modelId)
            downloadTasks.removeValue(forKey: modelId)
            downloadCancelHandlers.removeValue(forKey: modelId)
        }
    }

    /// Download a model with cancellation support (API-compatible) Returns the download ID for tracking.
    public func startDownload(repoId: String, filename: String) async throws -> String {
        let downloadId = UUID().uuidString
        downloadLogger.info("Starting tracked download: \(downloadId) for \(repoId)/\(filename)")

        /// Create download task tracking.
        var downloadTask = DownloadTask(id: downloadId, repoId: repoId, filename: filename)
        activeDownloads[downloadId] = downloadTask

        /// Start download in background task.
        let task = Task {
            do {
                /// Detect inference type, provider, and model name.
                let inferenceType = detectInferenceType(from: repoId)
                let hfProvider = extractHFProvider(from: repoId)
                let modelName = extractModelName(from: repoId, filename: filename)

                /// Create hierarchical directory structure: provider/model/.
                let providerDir = cacheDirectory.appendingPathComponent(hfProvider)
                let modelDir = providerDir.appendingPathComponent(modelName)

                try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

                /// Prepare destination with atomic .tmp download.
                let tmpDestination = modelDir.appendingPathComponent("\(filename).tmp")
                let destination = modelDir.appendingPathComponent(filename)

                /// Check if already exists.
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }

                /// Remove any leftover .tmp file.
                if FileManager.default.fileExists(atPath: tmpDestination.path) {
                    try? FileManager.default.removeItem(at: tmpDestination)
                }

                /// Download with progress and cancellation support.
                let downloadedURL = try await apiClient.downloadModel(
                    repoId: repoId,
                    filename: filename,
                    destination: tmpDestination,
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            /// Check for cancellation.
                            if let token = self?.activeDownloads[downloadId]?.cancellationToken, token.isCancelled {
                                /// Cancel download by throwing.
                                downloadLogger.info("Download cancelled: \(downloadId)")
                                self?.activeDownloads[downloadId]?.status = "cancelled"
                                throw NSError(domain: "ModelDownloadManager", code: 2,
                                            userInfo: [NSLocalizedDescriptionKey: "Download cancelled"])
                            }

                            self?.activeDownloads[downloadId]?.progress = progress
                        }
                    }
                )

                /// Atomic rename.
                try FileManager.default.moveItem(at: downloadedURL, to: destination)

                /// Register with ModelRegistry.
                let fileSize = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) }

                /// For multi-file models (MLX safetensors), register directory path For single-file models (GGUF), register file path.
                let registrationPath: String
                if inferenceType == "mlx" || destination.pathExtension == "safetensors" {
                    /// Multi-file model: register directory containing all shards.
                    registrationPath = modelDir.path
                    downloadLogger.info("Multi-file model detected, registering directory: \(modelDir.path)")
                } else {
                    /// Single-file model: register file path.
                    registrationPath = destination.path
                    downloadLogger.info("Single-file model detected, registering file: \(destination.path)")
                }

                await MainActor.run {
                    localModelManager.registerModel(
                        provider: hfProvider,
                        modelName: modelName,
                        path: registrationPath,
                        sizeBytes: fileSize,
                        quantization: nil
                    )

                    activeDownloads[downloadId]?.status = "completed"
                    activeDownloads[downloadId]?.progress = 1.0

                    /// Refresh installed models.
                    refreshInstalledModels()

                    downloadLogger.info("Download complete: \(downloadId)")
                }

            } catch {
                await MainActor.run {
                    downloadLogger.error("Download failed: \(downloadId) - \(error.localizedDescription)")
                    activeDownloads[downloadId]?.status = "failed"
                }
            }
        }

        /// Update task reference.
        downloadTask.task = task
        activeDownloads[downloadId] = downloadTask

        return downloadId
    }

    /// Cancel an active download.
    public func cancelDownload(downloadId: String) {
        guard let downloadTask = activeDownloads[downloadId] else {
            downloadLogger.warning("Download not found for cancellation: \(downloadId)")
            return
        }

        downloadLogger.info("Cancelling download: \(downloadId)")
        downloadTask.cancellationToken.cancel()
        activeDownloads[downloadId]?.status = "cancelled"
    }

    /// Get download status.
    public func getDownloadStatus(downloadId: String) -> DownloadTask? {
        return activeDownloads[downloadId]
    }

    // MARK: - Model Deletion

    /// Delete a model from disk and unregister provider.
    public func deleteModel(id: String) {
        guard let model = installedModels.first(where: { $0.id == id }) else {
            downloadLogger.warning("Model not found for deletion: \(id)")
            return
        }

        downloadLogger.info("Deleting model: \(model.name) at \(model.path)")

        do {
            let modelURL = URL(fileURLWithPath: model.path)

            /// Check if model.path is itself a directory (for SD models) or a file (for LLM models)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory) else {
                downloadLogger.warning("Model path does not exist: \(modelURL.path)")
                return
            }

            if isDirectory.boolValue {
                /// Model path is a directory (Stable Diffusion models)

                /// Check for linked .safetensors source file
                let metadataFile = modelURL.appendingPathComponent(".safetensors_source.json")
                if FileManager.default.fileExists(atPath: metadataFile.path),
                   let jsonData = try? Data(contentsOf: metadataFile),
                   let metadata = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String],
                   let safetensorsPath = metadata["safetensorsPath"] {

                    let safetensorsURL = URL(fileURLWithPath: safetensorsPath)
                    if FileManager.default.fileExists(atPath: safetensorsURL.path) {
                        try? FileManager.default.removeItem(at: safetensorsURL)
                        downloadLogger.info("Deleted linked .safetensors file: \(safetensorsPath)")
                    }
                }

                /// Delete CoreML model directory
                try FileManager.default.removeItem(at: modelURL)
                downloadLogger.info("Deleted model directory: \(modelURL.path)")
            } else {
                /// Model path is a file (LLM models)
                /// Check if parent directory structure exists
                let modelDir = modelURL.deletingLastPathComponent()
                let isHierarchical = modelDir.lastPathComponent != "models"

                if isHierarchical {
                    /// Delete entire model directory (provider/modelName/).
                    try FileManager.default.removeItem(at: modelDir)
                    downloadLogger.info("Deleted model directory: \(modelDir.path)")

                    /// Check if provider directory is now empty and remove if so.
                    let providerDir = modelDir.deletingLastPathComponent()
                    let providerContents = try FileManager.default.contentsOfDirectory(at: providerDir, includingPropertiesForKeys: nil)
                    if providerContents.isEmpty {
                        try FileManager.default.removeItem(at: providerDir)
                        downloadLogger.info("Deleted empty provider directory: \(providerDir.path)")
                    }
                } else {
                    /// Flat structure - delete just the file.
                    try FileManager.default.removeItem(at: modelURL)
                    downloadLogger.info("Deleted model file: \(modelURL.path)")
                }
            }

            /// Unregister from ModelRegistry if provider info available.
            if let provider = model.provider {
                localModelManager.unregisterModel(provider: provider, modelName: model.name)
                downloadLogger.info("Unregistered from registry: \(provider)/\(model.name)")
            }

            /// Unregister provider.
            if endpointManager != nil {
                let providerId = "local-llama_\(model.name)"
                downloadLogger.info("Model provider will be cleaned up: \(providerId)")
            }

            /// Refresh list.
            refreshInstalledModels()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
            downloadLogger.error("Delete failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Methods

    /// Refresh the list of installed models.
    private func refreshInstalledModels() {
        localModelManager.scanForModels()
        self.installedModels = localModelManager.getModels()
        downloadLogger.info("Refreshed installed models: \(self.installedModels.count) found")
    }

    /// Register a provider for a newly installed model.
    private func registerProvider(for model: LocalModel, with endpointManager: EndpointManager) async {
        downloadLogger.info("Registering provider for model: \(model.name)")

        /// Provider registration is handled automatically by EndpointManager when it scans the models directory on startup or reload We just need to make sure the model file is in the correct location.

        /// Trigger a provider configuration reload Note: This requires EndpointManager to expose a reload method.
        downloadLogger.info("Model ready for provider registration: \(model.name)")
    }

    // MARK: - Stable Diffusion Support

    /// Download a complete Stable Diffusion model (directory of CoreML files or ZIP archive)
    public func downloadStableDiffusionModel(model: HFModel) async {
        let modelId = model.id

        guard downloadProgress[modelId] == nil else {
            downloadLogger.warning("Model already downloading: \(modelId)")
            return
        }

        downloadProgress[modelId] = 0.0
        errorMessage = nil
        downloadLogger.info("Starting Stable Diffusion model download: \(modelId)")

        let task = Task {
            do {
                /// Determine destination for SD models
                let sdModelsDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("sam/models/stable-diffusion")

                let modelName = modelId.components(separatedBy: "/").last ?? modelId
                let modelDir = sdModelsDir.appendingPathComponent(modelName)

                /// Create directory
                try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
                downloadLogger.info("Created SD model directory: \(modelDir.path)")

                /// Get all files from the model repository
                guard let siblings = model.siblings else {
                    throw NSError(domain: "ModelDownloadManager", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "No files found in model repository"])
                }

                /// Check if model uses ZIP distribution (community models)
                let zipFiles = siblings.filter { $0.rfilename.hasSuffix(".zip") }

                if !zipFiles.isEmpty {
                    /// ZIP-based distribution (community models)
                    downloadLogger.info("Found \(zipFiles.count) ZIP files - using ZIP extraction")

                    /// Prefer split_einsum variant, fallback to original
                    let preferredZip = zipFiles.first { $0.rfilename.contains("split") || $0.rfilename.contains("einsum") }
                        ?? zipFiles.first!

                    downloadLogger.info("Downloading ZIP: \(preferredZip.rfilename)")

                    /// Update progress to 10% (download starting)
                    await MainActor.run { self.downloadProgress[modelId] = 0.1 }

                    /// Download ZIP file
                    let tmpZipPath = modelDir.appendingPathComponent("model.zip.tmp")
                    try? FileManager.default.removeItem(at: tmpZipPath)

                    let (downloadTask, _) = apiClient.downloadModelCancellable(
                        repoId: model.id,
                        filename: preferredZip.rfilename,
                        destination: tmpZipPath,
                        progress: { progress in
                            Task { @MainActor in
                                /// Map download to 10%-80% of total progress
                                self.downloadProgress[modelId] = 0.1 + (progress * 0.7)
                            }
                        }
                    )

                    let zipURL = try await downloadTask.value
                    downloadLogger.info("ZIP downloaded: \(zipURL.path)")

                    /// Update progress to 85% (extraction starting)
                    await MainActor.run { self.downloadProgress[modelId] = 0.85 }

                    /// Determine extraction path based on ZIP structure
                    /// Community models typically have original/ or split_einsum/ subdirs
                    let extractPath: URL
                    if preferredZip.rfilename.contains("split") || preferredZip.rfilename.contains("einsum") {
                        extractPath = modelDir.appendingPathComponent("split_einsum/compiled")
                    } else {
                        extractPath = modelDir.appendingPathComponent("original/compiled")
                    }

                    try FileManager.default.createDirectory(at: extractPath, withIntermediateDirectories: true)
                    downloadLogger.info("Extracting ZIP to: \(extractPath.path)")

                    /// Extract ZIP using ZIPFoundation
                    try FileManager.default.unzipItem(at: zipURL, to: extractPath)

                    /// Clean up ZIP file
                    try? FileManager.default.removeItem(at: zipURL)
                    downloadLogger.info("ZIP extraction complete, cleaned up temp file")

                } else {
                    /// Direct file distribution (Apple official models)
                    downloadLogger.info("Using direct file download (Apple model)")

                    /// Filter for essential Stable Diffusion files
                    let requiredFiles = [
                        "TextEncoder.mlmodelc",
                        "Unet.mlmodelc",
                        "VAEDecoder.mlmodelc",
                        "vocab.json",
                        "merges.txt"
                    ]

                    /// Also include any .mlmodelc directories and config files
                    let filesToDownload = siblings.filter { file in
                        let filename = file.rfilename

                        /// Match required files or .mlmodelc directories
                        if requiredFiles.contains(where: { filename.contains($0) }) {
                            return true
                        }

                        /// Include all files inside .mlmodelc directories
                        if filename.contains(".mlmodelc/") {
                            return true
                        }

                        /// Include configuration files
                        if filename.hasSuffix(".json") || filename.hasSuffix(".txt") || filename.hasSuffix(".plist") {
                            return true
                        }

                        return false
                    }

                    downloadLogger.info("Found \(filesToDownload.count) files to download for SD model")

                    /// Download all files
                    var completedFiles = 0
                    let totalFiles = filesToDownload.count

                    for file in filesToDownload {
                        /// Update progress
                        let fileProgress = Double(completedFiles) / Double(totalFiles)
                        await MainActor.run {
                            self.downloadProgress[modelId] = fileProgress
                        }

                        /// Determine destination (preserve directory structure)
                        let destination = modelDir.appendingPathComponent(file.rfilename)
                        let destinationDir = destination.deletingLastPathComponent()

                        /// Create subdirectory if needed
                        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

                        /// Download file
                        let tmpDestination = destination.appendingPathExtension("tmp")

                        /// Remove existing files
                        try? FileManager.default.removeItem(at: destination)
                        try? FileManager.default.removeItem(at: tmpDestination)

                        downloadLogger.info("Downloading SD file: \(file.rfilename)")

                        let (downloadTask, _) = apiClient.downloadModelCancellable(
                            repoId: model.id,
                            filename: file.rfilename,
                            destination: tmpDestination,
                            progress: { _ in
                                /// Per-file progress would be: fileProgress + (progress / totalFiles)
                            }
                        )

                        let downloadedURL = try await downloadTask.value

                        /// Atomic rename
                        try FileManager.default.moveItem(at: downloadedURL, to: destination)
                        downloadLogger.info("Downloaded: \(file.rfilename)")

                        completedFiles += 1
                    }
                }

                /// Mark complete
                await MainActor.run {
                    self.downloadProgress[modelId] = 1.0
                }

                downloadLogger.info("Stable Diffusion model download complete: \(modelName)")

                /// Notify that a new SD model was installed (triggers tool registration)
                NotificationCenter.default.post(name: .stableDiffusionModelInstalled, object: nil, userInfo: ["modelPath": modelDir.path])

                return modelDir

            } catch {
                downloadLogger.error("SD model download failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.errorMessage = "Failed to download Stable Diffusion model: \(error.localizedDescription)"
                    self.downloadProgress.removeValue(forKey: modelId)
                }
                throw error
            }
        }

        downloadTasks[modelId] = task

        do {
            _ = try await task.value
            /// Don't remove progress - keep at 1.0 so UI shows "100%" until file system check detects installation
            /// This prevents race condition where UI briefly shows "Download" button before isModelInstalled becomes true
            downloadTasks.removeValue(forKey: modelId)
        } catch {
            downloadLogger.error("Download task failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Stable Diffusion Model Download

    /// Download SD model from direct URL (CivitAI, HuggingFace, etc.)
    /// - Parameters:
    ///   - url: Direct download URL
    ///   - filename: Name for the downloaded file
    ///   - destinationDir: Directory where file should be saved
    ///   - progressId: Unique identifier for progress tracking
    /// - Returns: URL of downloaded file
    @MainActor
    public func downloadSDModel(
        from url: String,
        filename: String,
        destinationDir: URL,
        progressId: String
    ) async throws -> URL {
        /// Check if already downloading
        guard downloadProgress[progressId] == nil else {
            downloadLogger.warning("SD model already downloading: \(filename)")
            throw DownloadError.alreadyDownloading
        }

        downloadProgress[progressId] = 0.0
        errorMessage = nil
        downloadLogger.info("Starting SD model download: \(filename)")

        let task = Task {
            do {
                /// Create destination directory
                try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

                let finalDestination = destinationDir.appendingPathComponent(filename)

                /// Remove existing file
                try? FileManager.default.removeItem(at: finalDestination)

                /// Create URLSession with custom delegate for progress tracking
                guard let downloadURL = URL(string: url) else {
                    throw DownloadError.invalidURL
                }

                let delegate = SDDownloadDelegate(
                    destination: finalDestination,  /// Delegate moves file directly here
                    progressHandler: { [weak self] progress, bytesWritten, totalBytes in
                        DispatchQueue.main.async {
                            self?.downloadProgress[progressId] = progress
                            if Int(progress * 100) % 10 == 0 {
                                downloadLogger.info("SD download progress: \(Int(progress * 100))% (\(formatBytes(bytesWritten)) / \(formatBytes(totalBytes)))")
                            }
                        }
                    }
                )

                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

                /// Use downloadTask instead of download(from:) to ensure delegate callbacks fire
                let downloadTask = session.downloadTask(with: downloadURL)
                downloadTask.resume()

                /// Wait for completion - delegate moves file and returns final destination
                let movedDestination = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    delegate.completion = continuation
                }

                guard let httpResponse = downloadTask.response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw DownloadError.httpError
                }

                downloadLogger.info("SD model downloaded successfully: \(movedDestination.path)")

                await MainActor.run {
                    self.downloadProgress[progressId] = 1.0
                }

                return movedDestination
            } catch {
                await MainActor.run {
                    self.downloadProgress.removeValue(forKey: progressId)
                    self.errorMessage = error.localizedDescription
                }
                throw error
            }
        }

        downloadTasks[progressId] = task
        let result = try await task.value
        downloadProgress.removeValue(forKey: progressId)
        downloadTasks.removeValue(forKey: progressId)
        return result
    }

    /// Download delegate for SD models
    private final class SDDownloadDelegate: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
        let destination: URL
        let progressHandler: (Double, Int64, Int64) -> Void
        var completion: CheckedContinuation<URL, Error>?

        init(destination: URL, progressHandler: @escaping (Double, Int64, Int64) -> Void) {
            self.destination = destination
            self.progressHandler = progressHandler
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            if Int(progress * 10) % 1 == 0 { /// Log every 10%
                downloadLogger.debug("SD delegate progress: \(Int(progress * 100))%")
            }
            progressHandler(progress, totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            /// CRITICAL: Must move file HERE before URLSession deletes it!
            /// The temp file at 'location' only exists during this method execution
            do {
                /// Ensure destination directory exists
                let destinationDir = destination.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: destinationDir.path) {
                    try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
                    downloadLogger.info("Created destination directory: \(destinationDir.path)")
                }

                /// Remove existing file if present
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }

                try FileManager.default.moveItem(at: location, to: destination)
                downloadLogger.info("Moved temp file to destination: \(destination.path)")
                completion?.resume(returning: destination)
            } catch {
                downloadLogger.error("Failed to move downloaded file: \(error.localizedDescription)")
                completion?.resume(throwing: error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error {
                completion?.resume(throwing: error)
            }
        }
    }
}

/// Helper to format byte counts
private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
