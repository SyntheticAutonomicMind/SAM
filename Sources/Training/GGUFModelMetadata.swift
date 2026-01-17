// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// GGUFModelMetadata.swift
/// Metadata system for mapping GGUF model files to Hugging Face model IDs.
/// Required for LoRA training: we need to know the original HF model to download for training.

import Foundation
import Logging

private let logger = Logger(label: "com.sam.training.gguf_metadata")

// MARK: - GGUF Model Metadata

/// Metadata for a GGUF model file, including its Hugging Face origin.
public struct GGUFModelMetadata: Codable, Sendable {
    /// Path to the GGUF model file
    public let modelPath: String
    
    /// Hugging Face model ID (e.g., "TinyLlama/TinyLlama-1.1B-Chat-v1.0")
    public let huggingFaceModelId: String
    
    /// Quantization level (e.g., "Q4_K_M", "Q8_0", "f16")
    public let quantization: String
    
    /// Date the model was added to SAM
    public let addedDate: Date
    
    /// Optional: User-provided notes about the model
    public let notes: String?
    
    public init(
        modelPath: String,
        huggingFaceModelId: String,
        quantization: String,
        addedDate: Date = Date(),
        notes: String? = nil
    ) {
        self.modelPath = modelPath
        self.huggingFaceModelId = huggingFaceModelId
        self.quantization = quantization
        self.addedDate = addedDate
        self.notes = notes
    }
}

// MARK: - Metadata Manager

/// Manages GGUF model metadata storage and retrieval.
@MainActor
public class GGUFMetadataManager {
    
    /// Shared instance
    public static let shared = GGUFMetadataManager()
    
    /// Directory where GGUF models are stored
    private let modelsDirectory: URL
    
    /// In-memory cache of metadata
    private var metadataCache: [String: GGUFModelMetadata] = [:]
    
    private init() {
        // GGUF models are stored in ~/Library/Caches/sam/models/
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.modelsDirectory = cacheDir
            .appendingPathComponent("sam", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        
        // Load existing metadata
        loadAllMetadata()
        
        logger.info("GGUFMetadataManager initialized", metadata: [
            "modelsDirectory": "\(modelsDirectory.path)"
        ])
    }
    
    // MARK: - Metadata File Paths
    
    /// Get metadata file path for a GGUF model
    /// - Parameter modelPath: Path to GGUF model file
    /// - Returns: URL to metadata file (.gguf -> .gguf.metadata.json)
    private func metadataPath(for modelPath: String) -> URL {
        let modelURL = URL(fileURLWithPath: modelPath)
        let metadataFilename = modelURL.lastPathComponent + ".metadata.json"
        return modelURL.deletingLastPathComponent().appendingPathComponent(metadataFilename)
    }
    
    // MARK: - Save/Load Metadata
    
    /// Save metadata for a GGUF model
    /// - Parameter metadata: Metadata to save
    public func saveMetadata(_ metadata: GGUFModelMetadata) throws {
        let metadataURL = metadataPath(for: metadata.modelPath)
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL)
        
        // Update cache
        metadataCache[metadata.modelPath] = metadata
        
        logger.info("Saved GGUF metadata", metadata: [
            "modelPath": "\(metadata.modelPath)",
            "huggingFaceId": "\(metadata.huggingFaceModelId)",
            "metadataFile": "\(metadataURL.path)"
        ])
    }
    
    /// Load metadata for a GGUF model
    /// - Parameter modelPath: Path to GGUF model file
    /// - Returns: Metadata if found, nil otherwise
    public func loadMetadata(for modelPath: String) async -> GGUFModelMetadata? {
        // Check cache first
        if let cached = metadataCache[modelPath] {
            return cached
        }
        
        // Try loading from disk
        let metadataURL = metadataPath(for: modelPath)
        
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            do {
                let data = try Data(contentsOf: metadataURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                
                let metadata = try decoder.decode(GGUFModelMetadata.self, from: data)
                
                // Cache it
                metadataCache[modelPath] = metadata
                
                return metadata
            } catch {
                logger.error("Failed to load GGUF metadata from disk", metadata: [
                    "metadataFile": "\(metadataURL.path)",
                    "error": "\(error.localizedDescription)"
                ])
            }
        }
        
        // No local metadata - try fetching from Hugging Face
        logger.info("No local metadata found, attempting to fetch from Hugging Face", metadata: [
            "modelPath": "\(modelPath)"
        ])
        
        if let hfMetadata = await fetchMetadataFromHuggingFace(modelPath: modelPath) {
            // Save it locally for future use
            do {
                try saveMetadata(hfMetadata)
                return hfMetadata
            } catch {
                logger.error("Failed to save fetched metadata", metadata: [
                    "error": "\(error.localizedDescription)"
                ])
                return hfMetadata // Still return it even if save fails
            }
        }
        
        return nil
    }
    
    /// Synchronous version of loadMetadata for compatibility
    public func loadMetadata(for modelPath: String) -> GGUFModelMetadata? {
        // Check cache only (no async fetch)
        if let cached = metadataCache[modelPath] {
            return cached
        }
        
        // Try loading from disk
        let metadataURL = metadataPath(for: modelPath)
        
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            let metadata = try decoder.decode(GGUFModelMetadata.self, from: data)
            
            // Cache it
            metadataCache[modelPath] = metadata
            
            return metadata
        } catch {
            logger.error("Failed to load GGUF metadata", metadata: [
                "metadataFile": "\(metadataURL.path)",
                "error": "\(error.localizedDescription)"
            ])
            return nil
        }
    }
    
    // MARK: - Hugging Face Integration
    
    /// Fetch metadata from Hugging Face based on model path
    /// - Parameter modelPath: Path to GGUF model file
    /// - Returns: Metadata if successfully fetched from HF
    private func fetchMetadataFromHuggingFace(modelPath: String) async -> GGUFModelMetadata? {
        // Try to extract Hugging Face repo from path
        // Path structure: ~/Library/Caches/sam/models/family/model-name/file.gguf
        // OR: ~/Library/Caches/sam/models/file.gguf
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let filename = modelURL.lastPathComponent
        let modelDir = modelURL.deletingLastPathComponent()
        let modelName = modelDir.lastPathComponent
        let familyDir = modelDir.deletingLastPathComponent()
        let familyName = familyDir.lastPathComponent
        
        // Construct potential HF repo IDs
        var repoIds: [String] = []
        
        // 1. Try family/modelName (e.g., "unsloth/Qwen3-4B-GGUF")
        if familyName != "models" && modelName != familyName {
            repoIds.append("\(familyName)/\(modelName)")
        }
        
        // 2. Try just modelName if it contains a "/"
        if modelName.contains("/") {
            repoIds.append(modelName)
        }
        
        // Try each potential repo ID
        for repoId in repoIds {
            logger.info("Attempting to fetch metadata from Hugging Face", metadata: [
                "repoId": "\(repoId)"
            ])
            
            if let metadata = await fetchHuggingFaceRepoMetadata(repoId: repoId, modelPath: modelPath, filename: filename) {
                return metadata
            }
        }
        
        logger.warning("Could not fetch metadata from Hugging Face", metadata: [
            "modelPath": "\(modelPath)",
            "triedRepos": "\(repoIds.joined(separator: ", "))"
        ])
        
        return nil
    }
    
    /// Fetch metadata from a specific Hugging Face repo
    private func fetchHuggingFaceRepoMetadata(repoId: String, modelPath: String, filename: String) async -> GGUFModelMetadata? {
        // Query Hugging Face API for model info
        let apiURL = "https://huggingface.co/api/models/\(repoId)"
        
        guard let url = URL(string: apiURL) else {
            return nil
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.debug("HF API request failed", metadata: [
                    "repoId": "\(repoId)",
                    "statusCode": "\((response as? HTTPURLResponse)?.statusCode ?? 0)"
                ])
                return nil
            }
            
            // Parse JSON response
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            
            // Extract base model from cardData (if available)
            var baseModelId: String?
            if let cardData = json["cardData"] as? [String: Any],
               let baseModel = cardData["base_model"] as? String {
                baseModelId = baseModel
            }
            
            // If no base_model in cardData, try siblings to find base model
            if baseModelId == nil, let siblings = json["siblings"] as? [[String: Any]] {
                // Look for config.json which might have model info
                for sibling in siblings {
                    if let filename = sibling["rfilename"] as? String, filename == "config.json" {
                        // Found config.json - could fetch it to get more info
                        // For now, infer from repo name
                        baseModelId = inferBaseModelFromRepoName(repoId: repoId)
                        break
                    }
                }
            }
            
            // Fallback: infer from repo name
            if baseModelId == nil {
                baseModelId = inferBaseModelFromRepoName(repoId: repoId)
            }
            
            guard let finalBaseModel = baseModelId else {
                logger.warning("Could not determine base model from HF repo", metadata: [
                    "repoId": "\(repoId)"
                ])
                return nil
            }
            
            // Extract quantization from filename (e.g., "Q8_0.gguf" -> "Q8_0")
            let quantization = extractQuantization(from: filename)
            
            let metadata = GGUFModelMetadata(
                modelPath: modelPath,
                huggingFaceModelId: finalBaseModel,
                quantization: quantization,
                addedDate: Date(),
                notes: "Auto-fetched from Hugging Face: \(repoId)"
            )
            
            logger.info("Successfully fetched metadata from Hugging Face", metadata: [
                "repoId": "\(repoId)",
                "baseModel": "\(finalBaseModel)",
                "quantization": "\(quantization)"
            ])
            
            return metadata
            
        } catch {
            logger.debug("Failed to fetch from HF API", metadata: [
                "repoId": "\(repoId)",
                "error": "\(error.localizedDescription)"
            ])
            return nil
        }
    }
    
    /// Infer base model from GGUF repo name
    /// Example: "unsloth/Qwen3-4B-GGUF" -> "unsloth/Qwen3-4B" or "Qwen/Qwen3-4B"
    private func inferBaseModelFromRepoName(repoId: String) -> String? {
        // Remove "-GGUF" suffix if present
        var baseName = repoId
        if baseName.hasSuffix("-GGUF") {
            baseName = String(baseName.dropLast(5))
        }
        
        // For unsloth repos, try to map to official Qwen model
        if baseName.hasPrefix("unsloth/Qwen") {
            // "unsloth/Qwen3-4B" -> "Qwen/Qwen3-4B"
            let modelName = baseName.replacingOccurrences(of: "unsloth/", with: "")
            return "Qwen/\(modelName)"
        }
        
        // Otherwise return as-is
        return baseName
    }
    
    /// Extract quantization level from filename
    /// Example: "Qwen3-4B-Q8_0.gguf" -> "Q8_0"
    private func extractQuantization(from filename: String) -> String {
        let nameWithoutExt = filename.replacingOccurrences(of: ".gguf", with: "")
        
        // Common quantization patterns
        let quantPatterns = [
            "Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L", "Q4_0", "Q4_1", "Q4_K_S", "Q4_K_M",
            "Q5_0", "Q5_1", "Q5_K_S", "Q5_K_M", "Q6_K", "Q8_0",
            "IQ1_S", "IQ1_M", "IQ2_XXS", "IQ2_XS", "IQ2_S", "IQ2_M",
            "IQ3_XXS", "IQ3_XS", "IQ3_S", "IQ3_M", "IQ4_XS", "IQ4_NL",
            "F16", "F32", "BF16"
        ]
        
        for pattern in quantPatterns {
            if nameWithoutExt.contains(pattern) {
                return pattern
            }
        }
        
        return "unknown"
    }
    
    /// Load all metadata files from models directory
    private func loadAllMetadata() {
        guard let enumerator = FileManager.default.enumerator(
            at: modelsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        
        var loadedCount = 0
        
        for case let fileURL as URL in enumerator {
            // Look for .metadata.json files
            guard fileURL.pathExtension == "json",
                  fileURL.lastPathComponent.contains(".metadata.json") else {
                continue
            }
            
            // Extract model path from metadata filename
            // Example: "model.gguf.metadata.json" -> "model.gguf"
            let metadataFilename = fileURL.lastPathComponent
            let modelFilename = metadataFilename.replacingOccurrences(of: ".metadata.json", with: "")
            let modelPath = fileURL.deletingLastPathComponent().appendingPathComponent(modelFilename).path
            
            // Load metadata
            if let metadata = loadMetadata(for: modelPath) {
                loadedCount += 1
            }
        }
        
        logger.info("Loaded GGUF metadata", metadata: [
            "count": "\(loadedCount)"
        ])
    }
    
    // MARK: - Query Metadata
    
    /// Get Hugging Face model ID for a GGUF model (if available)
    /// - Parameter modelPath: Path to GGUF model file
    /// - Returns: Hugging Face model ID if metadata exists
    public func getHuggingFaceModelId(for modelPath: String) -> String? {
        loadMetadata(for: modelPath)?.huggingFaceModelId
    }
    
    /// Get all GGUF models with metadata
    /// - Returns: Array of metadata for all models with metadata
    public func getAllModelsWithMetadata() -> [GGUFModelMetadata] {
        Array(metadataCache.values)
    }
    
    /// Check if a GGUF model has metadata
    /// - Parameter modelPath: Path to GGUF model file
    /// - Returns: True if metadata exists
    public func hasMetadata(for modelPath: String) -> Bool {
        loadMetadata(for: modelPath) != nil
    }
    
    /// Delete metadata for a GGUF model
    /// - Parameter modelPath: Path to GGUF model file
    public func deleteMetadata(for modelPath: String) throws {
        let metadataURL = metadataPath(for: modelPath)
        
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            try FileManager.default.removeItem(at: metadataURL)
            metadataCache.removeValue(forKey: modelPath)
            
            logger.info("Deleted GGUF metadata", metadata: [
                "modelPath": "\(modelPath)"
            ])
        }
    }
}

// MARK: - Training Error

public enum GGUFTrainingError: Error {
    case noHuggingFaceModelId
    case metadataNotFound(String)
    case invalidModelPath(String)
}

extension GGUFTrainingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noHuggingFaceModelId:
            return "No Hugging Face model ID found for GGUF model. Please specify the original model ID."
        case .metadataNotFound(let path):
            return "Metadata not found for GGUF model at: \(path)"
        case .invalidModelPath(let path):
            return "Invalid model path: \(path)"
        }
    }
}
