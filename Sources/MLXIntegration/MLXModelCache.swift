// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import Crypto

/// Model cache manager for MLX models Handles local storage, validation, and management of downloaded models.
public class MLXModelCache {
    private let logger = Logger(label: "com.sam.mlx.cache")
    private let fileManager = FileManager.default

    private var modelsDirectory: URL?

    public init() {
        logger.debug("Initializing MLX Model Cache")
    }

    // MARK: - Public Interface

    public func initialize() async throws {
        /// Create models directory in user's cache.
        guard let userCacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw MLXCacheError.initializationFailed("Could not find user cache directory")
        }
        modelsDirectory = userCacheDir.appendingPathComponent("sam-rewritten/models")

        guard let directory = modelsDirectory else {
            throw MLXCacheError.initializationFailed("Failed to create models directory path")
        }
        
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        logger.debug("MLX Model Cache initialized at: \(directory.path)")
    }

    public func getModelsDirectory() async throws -> URL {
        guard let dir = modelsDirectory else {
            throw MLXCacheError.notInitialized
        }
        return dir
    }

    public func getModelPath(_ modelId: String) async throws -> URL {
        let dir = try await getModelsDirectory()
        let normalizedId = modelId.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent(normalizedId)
    }

    public func getInstalledModelPaths() async throws -> [String: URL] {
        let dir = try await getModelsDirectory()

        guard fileManager.fileExists(atPath: dir.path) else {
            return [:]
        }

        var modelPaths: [String: URL] = [:]

        let contents = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])

        for item in contents {
            let resourceValues = try item.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues.isDirectory == true {
                /// Check if this is a valid model directory.
                let configPath = item.appendingPathComponent("config.json")
                if fileManager.fileExists(atPath: configPath.path) {
                    /// Convert directory name back to model ID.
                    let modelId = item.lastPathComponent.replacingOccurrences(of: "_", with: "/")
                    modelPaths[modelId] = item
                }
            }
        }

        logger.debug("Found \(modelPaths.count) installed models in cache")
        return modelPaths
    }

    public func isModelInstalled(_ modelId: String) async throws -> Bool {
        let modelPath = try await getModelPath(modelId)
        let configPath = modelPath.appendingPathComponent("config.json")
        return fileManager.fileExists(atPath: configPath.path)
    }

    public func removeModel(_ modelId: String) async throws {
        let modelPath = try await getModelPath(modelId)

        guard fileManager.fileExists(atPath: modelPath.path) else {
            logger.warning("Model directory not found for deletion: \(modelId)")
            return
        }

        try fileManager.removeItem(at: modelPath)
        logger.debug("Removed model from cache: \(modelId)")
    }

    public func getModelInfo(_ modelId: String) async throws -> CachedModelInfo? {
        let modelPath = try await getModelPath(modelId)
        let configPath = modelPath.appendingPathComponent("config.json")

        guard fileManager.fileExists(atPath: configPath.path) else {
            return nil
        }

        /// Read model config.
        let configData = try Data(contentsOf: configPath)
        let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any]

        /// Calculate directory size.
        let size = calculateDirectorySize(modelPath)

        return CachedModelInfo(
            id: modelId,
            path: modelPath,
            size: size,
            config: config ?? [:],
            lastAccessed: Date()
        )
    }

    public func validateModel(_ modelId: String) async throws -> Bool {
        let modelPath = try await getModelPath(modelId)

        /// Check for essential files.
        let requiredFiles = ["config.json"]
        for file in requiredFiles {
            let filePath = modelPath.appendingPathComponent(file)
            if !fileManager.fileExists(atPath: filePath.path) {
                logger.warning("Model \(modelId) missing required file: \(file)")
                return false
            }
        }

        /// Check for model weights (at least one should exist).
        let weightFiles = ["model.safetensors", "pytorch_model.bin", "model.bin"]
        let hasWeights = weightFiles.contains { file in
            let filePath = modelPath.appendingPathComponent(file)
            return fileManager.fileExists(atPath: filePath.path)
        }

        if !hasWeights {
            logger.warning("Model \(modelId) has no weight files")
            return false
        }

        logger.debug("Model \(modelId) validation passed")
        return true
    }

    // MARK: - Helper Methods

    private func calculateDirectorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                totalSize += Int64(resourceValues.fileSize ?? 0)
            } catch {
                continue
            }
        }

        return totalSize
    }
}

// MARK: - Supporting Types

public enum MLXCacheError: LocalizedError {
    case notInitialized
    case initializationFailed(String)
    case modelNotFound(String)
    case validationFailed(String)
    case fileSystemError(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "MLX model cache is not initialized"
        case .initializationFailed(let message):
            return "MLX model cache initialization failed: \(message)"

        case .modelNotFound(let modelId):
            return "Model not found in cache: \(modelId)"

        case .validationFailed(let message):
            return "Model validation failed: \(message)"

        case .fileSystemError(let message):
            return "File system error: \(message)"
        }
    }
}

public struct CachedModelInfo {
    public let id: String
    public let path: URL
    public let size: Int64
    public let config: [String: Any]
    public let lastAccessed: Date

    public var name: String {
        return config["model_type"] as? String ??
               (config["architectures"] as? [String])?.first ??
               id.components(separatedBy: "/").last ??
               id
    }

    public var modelType: String {
        return config["model_type"] as? String ?? "unknown"
    }

    public var hiddenSize: Int? {
        return config["hidden_size"] as? Int
    }

    public var vocabSize: Int? {
        return config["vocab_size"] as? Int
    }
}
