// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// AdapterManager.swift
/// Manages persistence and lifecycle of LoRA adapters.
/// Handles saving, loading, listing, and deleting adapters from disk.

import Foundation
@preconcurrency import MLX
import Logging
import MLXLMCommon

private let logger = Logger(label: "com.sam.training.adapter_manager")

/// Notification posted when LoRA adapters list changes
extension Notification.Name {
    public static let loraAdaptersDidChange = Notification.Name("com.sam.loraAdaptersDidChange")
}

/// Manages LoRA adapter persistence and retrieval.
@MainActor
public class AdapterManager {
    public static let shared = AdapterManager()
    
    private let adaptersDirectory: URL
    
    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        
        adaptersDirectory = appSupport
            .appendingPathComponent("SAM")
            .appendingPathComponent("adapters")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(
            at: adaptersDirectory,
            withIntermediateDirectories: true
        )
        
        logger.info("AdapterManager initialized", metadata: [
            "directory": "\(adaptersDirectory.path)"
        ])
    }
    
    /// Save adapter to disk in MLX-compatible format.
    ///
    /// Creates a directory structure:
    /// ```
    /// adapters/<adapter-id>/
    ///   ├── metadata.json        # SAM-specific metadata (training info, etc.)
    ///   ├── adapter_config.json  # MLX LoRA configuration
    ///   └── adapters.safetensors # LoRA weights in safetensors format
    /// ```
    ///
    /// - Parameter adapter: LoRA adapter to save
    public func saveAdapter(_ adapter: LoRAAdapter) async throws {
        let adapterDir = adaptersDirectory.appendingPathComponent(adapter.id)
        
        // Create adapter directory
        try FileManager.default.createDirectory(
            at: adapterDir,
            withIntermediateDirectories: true
        )
        
        logger.info("Saving adapter", metadata: ["id": "\(adapter.id)"])
        
        // Save SAM-specific metadata
        try saveMetadata(adapter, to: adapterDir)
        
        // Save MLX adapter config
        try saveAdapterConfig(adapter, to: adapterDir)
        
        // Save weights in safetensors format
        try await saveWeightsSafetensors(adapter, to: adapterDir)
        
        logger.info("Adapter saved successfully", metadata: [
            "id": "\(adapter.id)",
            "layers": "\(adapter.layers.count)",
            "size": "\(adapter.parameterCount()) parameters"
        ])
        
        // Notify that adapters list changed (EndpointManager will pick this up and register with LocalModelManager)
        NotificationCenter.default.post(name: .loraAdaptersDidChange, object: adapter)
    }
    
    /// Load adapter from disk.
    ///
    /// - Parameter id: Adapter ID to load
    /// - Returns: Loaded LoRA adapter
    public func loadAdapter(id: String) async throws -> LoRAAdapter {
        let adapterDir = adaptersDirectory.appendingPathComponent(id)
        
        guard FileManager.default.fileExists(atPath: adapterDir.path) else {
            logger.error("Adapter not found", metadata: ["id": "\(id)"])
            throw AdapterError.notFound(id)
        }
        
        logger.info("Loading adapter", metadata: ["id": "\(id)"])
        
        // Load metadata
        let metadata = try loadMetadata(from: adapterDir)
        
        // Load weights
        let (baseModelId, rank, alpha, layers) = try loadWeights(from: adapterDir)
        
        let adapter = LoRAAdapter(
            id: id,
            baseModelId: baseModelId,
            rank: rank,
            alpha: alpha,
            layers: layers,
            metadata: metadata
        )
        
        logger.info("Adapter loaded successfully", metadata: [
            "id": "\(id)",
            "layers": "\(adapter.layers.count)"
        ])
        
        return adapter
    }
    
    /// List all available adapters.
    ///
    /// - Returns: Array of adapter info summaries
    public func listAdapters() async throws -> [AdapterInfo] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: adaptersDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        
        var adapters: [AdapterInfo] = []
        
        for url in contents {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            
            do {
                let metadata = try loadMetadata(from: url)
                adapters.append(AdapterInfo(
                    id: url.lastPathComponent,
                    metadata: metadata
                ))
            } catch {
                logger.warning("Failed to load adapter metadata", metadata: [
                    "id": "\(url.lastPathComponent)",
                    "error": "\(error.localizedDescription)"
                ])
            }
        }
        
        logger.debug("Listed adapters", metadata: ["count": "\(adapters.count)"])
        
        return adapters.sorted { $0.metadata.createdAt > $1.metadata.createdAt }
    }
    
    /// Delete adapter from disk.
    ///
    /// - Parameter id: Adapter ID to delete
    public func deleteAdapter(id: String) async throws {
        let adapterDir = adaptersDirectory.appendingPathComponent(id)
        
        guard FileManager.default.fileExists(atPath: adapterDir.path) else {
            logger.error("Adapter not found for deletion", metadata: ["id": "\(id)"])
            throw AdapterError.notFound(id)
        }
        
        try FileManager.default.removeItem(at: adapterDir)
        
        logger.info("Adapter deleted", metadata: ["id": "\(id)"])
        
        // Notify that adapters list changed
        NotificationCenter.default.post(name: .loraAdaptersDidChange, object: id)
    }
    
    // MARK: - Private Implementation
    
    /// Save adapter metadata to JSON.
    private func saveMetadata(_ adapter: LoRAAdapter, to directory: URL) throws {
        let metadataURL = directory.appendingPathComponent("metadata.json")
        
        // Create comprehensive metadata
        let metadataDict: [String: Any] = [
            "baseModelId": adapter.baseModelId,
            "rank": adapter.rank,
            "alpha": adapter.alpha,
            "createdAt": ISO8601DateFormatter().string(from: adapter.metadata.createdAt),
            "trainingDataset": adapter.metadata.trainingDataset,
            "trainingSteps": adapter.metadata.trainingSteps,
            "finalLoss": adapter.metadata.finalLoss,
            "epochs": adapter.metadata.epochs,
            "learningRate": adapter.metadata.learningRate,
            "batchSize": adapter.metadata.batchSize,
            "adapterName": adapter.metadata.adapterName,
            "layerCount": adapter.layers.count,
            "parameterCount": adapter.parameterCount()
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: metadataDict, options: [.prettyPrinted])
        try jsonData.write(to: metadataURL)
        
        logger.debug("Saved metadata", metadata: ["path": "\(metadataURL.path)"])
    }
    
    /// Load adapter metadata from JSON.
    private func loadMetadata(from directory: URL) throws -> LoRAAdapter.AdapterMetadata {
        let metadataURL = directory.appendingPathComponent("metadata.json")
        
        let jsonData = try Data(contentsOf: metadataURL)
        guard let metadataDict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw AdapterError.invalidMetadata
        }
        
        let dateFormatter = ISO8601DateFormatter()
        guard let createdAtString = metadataDict["createdAt"] as? String,
              let createdAt = dateFormatter.date(from: createdAtString) else {
            throw AdapterError.invalidMetadata
        }
        
        return LoRAAdapter.AdapterMetadata(
            createdAt: createdAt,
            trainingDataset: metadataDict["trainingDataset"] as? String ?? "",
            trainingSteps: metadataDict["trainingSteps"] as? Int ?? 0,
            finalLoss: (metadataDict["finalLoss"] as? NSNumber)?.floatValue ?? 0.0,
            epochs: metadataDict["epochs"] as? Int ?? 0,
            learningRate: (metadataDict["learningRate"] as? NSNumber)?.floatValue ?? 0.0,
            batchSize: metadataDict["batchSize"] as? Int ?? 0,
            adapterName: metadataDict["adapterName"] as? String ?? "Untitled Adapter",
            baseModelId: metadataDict["baseModelId"] as? String ?? ""
        )
    }
    
    /// Save MLX adapter configuration (adapter_config.json).
    private func saveAdapterConfig(_ adapter: LoRAAdapter, to directory: URL) throws {
        let configURL = directory.appendingPathComponent("adapter_config.json")
        
        // Determine number of layers (count unique layer indices)
        let layerIndices = Set(adapter.layers.keys.compactMap { layerName -> Int? in
            // Extract layer index from names like "model.layers.0.self_attn.q_proj"
            let components = layerName.components(separatedBy: ".")
            guard components.count > 2, components[0] == "model", components[1] == "layers" else {
                return nil
            }
            return Int(components[2])
        })
        let numLayers = layerIndices.count
        
        // Extract unique target module names (e.g., "self_attn.q_proj")
        let targetKeys = Set(adapter.layers.keys.compactMap { layerName -> String? in
            let components = layerName.components(separatedBy: ".")
            guard components.count > 3 else { return nil }
            // Join components after "model.layers.N" (e.g., "self_attn.q_proj")
            return components.dropFirst(3).joined(separator: ".")
        })
        
        let config: [String: Any] = [
            "fine_tune_type": "lora",
            "num_layers": numLayers,
            "lora_parameters": [
                "rank": adapter.rank,
                "scale": adapter.alpha,  // MLX uses 'scale' for what we call 'alpha'
                "dropout": 0.0,  // CRITICAL: Python mlx_lm requires this key, always 0.0 for inference
                "keys": Array(targetKeys).sorted()
            ] as [String: Any]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: configURL)
        
        logger.debug("Saved adapter config", metadata: [
            "path": "\(configURL.path)",
            "numLayers": "\(numLayers)",
            "rank": "\(adapter.rank)"
        ])
    }
    
    /// Save adapter weights in safetensors format.
    private func saveWeightsSafetensors(_ adapter: LoRAAdapter, to directory: URL) async throws {
        let weightsURL = directory.appendingPathComponent("adapters.safetensors")
        
        // Convert LoRA layers to MLX parameter format
        // Format: "model.layers.N.module.lora_a" and "model.layers.N.module.lora_b"
        var weightsDict = [String: MLXArray]()
        
        for (layerName, layer) in adapter.layers {
            // MLX expects parameter names with .lora_a and .lora_b suffixes
            weightsDict["\(layerName).lora_a"] = layer.matrixA
            weightsDict["\(layerName).lora_b"] = layer.matrixB
        }
        
        // Save using MLX's save function (safetensors format)
        try MLX.save(arrays: weightsDict, url: weightsURL)
        
        logger.debug("Saved weights in safetensors format", metadata: [
            "path": "\(weightsURL.path)",
            "parameters": "\(weightsDict.count)"
        ])
    }
    
    /// Load adapter weights from safetensors format (MLX-compatible).
    ///
    /// This method tries to load from the new safetensors format first,
    /// and falls back to the old JSON format for backward compatibility.
    private func loadWeights(from directory: URL) throws -> (String, Int, Float, [String: LoRALayer]) {
        let safetensorsURL = directory.appendingPathComponent("adapters.safetensors")
        let jsonURL = directory.appendingPathComponent("weights.json")
        
        // Try new format first
        if FileManager.default.fileExists(atPath: safetensorsURL.path) {
            return try loadWeightsSafetensors(from: directory)
        }
        // Fall back to old JSON format
        else if FileManager.default.fileExists(atPath: jsonURL.path) {
            logger.warning("Loading adapter from legacy JSON format", metadata: [
                "directory": "\(directory.lastPathComponent)"
            ])
            return try loadWeightsJSON(from: directory)
        }
        else {
            throw AdapterError.invalidWeights
        }
    }
    
    /// Load weights from safetensors format.
    private func loadWeightsSafetensors(from directory: URL) throws -> (String, Int, Float, [String: LoRALayer]) {
        let safetensorsURL = directory.appendingPathComponent("adapters.safetensors")
        let configURL = directory.appendingPathComponent("adapter_config.json")
        
        // Load adapter config to get rank and alpha
        let configData = try Data(contentsOf: configURL)
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let loraParams = config["lora_parameters"] as? [String: Any],
              let rank = loraParams["rank"] as? Int,
              let scale = (loraParams["scale"] as? NSNumber)?.floatValue else {
            throw AdapterError.invalidWeights
        }
        
        // Load metadata to get baseModelId
        let metadata = try loadMetadata(from: directory)
        let baseModelId = metadata.baseModelId
        
        // Load weights from safetensors
        let weightsDict = try MLX.loadArrays(url: safetensorsURL)
        
        // Parse weights back into LoRALayers
        // Group by layer name (strip .lora_a / .lora_b suffix)
        var layerGroups = [String: (MLXArray?, MLXArray?)]()
        
        for (paramName, array) in weightsDict {
            if paramName.hasSuffix(".lora_a") {
                let layerName = String(paramName.dropLast(7))  // Remove ".lora_a"
                layerGroups[layerName, default: (nil, nil)].0 = array
            } else if paramName.hasSuffix(".lora_b") {
                let layerName = String(paramName.dropLast(7))  // Remove ".lora_b"
                layerGroups[layerName, default: (nil, nil)].1 = array
            }
        }
        
        var layers = [String: LoRALayer]()
        
        for (layerName, (matrixA, matrixB)) in layerGroups {
            guard let matrixA = matrixA, let matrixB = matrixB else {
                logger.warning("Incomplete LoRA layer (missing A or B matrix)", metadata: [
                    "layer": "\(layerName)"
                ])
                continue
            }
            
            // Extract dimensions from matrix shapes
            let aShape = matrixA.shape
            let bShape = matrixB.shape
            
            // MLX expects: lora_a [inputDim, rank], lora_b [rank, outputDim]
            guard aShape.count == 2, bShape.count == 2,
                  aShape[1] == rank, bShape[0] == rank else {
                logger.warning("Invalid LoRA matrix shapes", metadata: [
                    "layer": "\(layerName)",
                    "A_shape": "\(aShape)",
                    "B_shape": "\(bShape)",
                    "expected_rank": "\(rank)"
                ])
                continue
            }
            
            let inputDim = aShape[0]
            let outputDim = bShape[1]
            
            let layer = LoRALayer(
                layerName: layerName,
                inputDim: inputDim,
                outputDim: outputDim,
                rank: rank,
                alpha: scale,  // MLX 'scale' maps to our 'alpha'
                matrixA: matrixA,
                matrixB: matrixB
            )
            
            layers[layerName] = layer
        }
        
        logger.debug("Loaded weights from safetensors", metadata: ["layers": "\(layers.count)"])
        
        return (baseModelId, rank, scale, layers)
    }
    
    /// Load weights from legacy JSON format (backward compatibility).
    private func loadWeightsJSON(from directory: URL) throws -> (String, Int, Float, [String: LoRALayer]) {
        let weightsURL = directory.appendingPathComponent("weights.json")
        
        let jsonData = try Data(contentsOf: weightsURL)
        guard let weightsDict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw AdapterError.invalidWeights
        }
        
        guard let baseModelId = weightsDict["baseModelId"] as? String,
              let rank = weightsDict["rank"] as? Int,
              let alpha = (weightsDict["alpha"] as? NSNumber)?.floatValue,
              let layersDict = weightsDict["layers"] as? [String: Any] else {
            throw AdapterError.invalidWeights
        }
        
        var layers = [String: LoRALayer]()
        
        for (name, layerData) in layersDict {
            guard let layerDict = layerData as? [String: Any],
                  let inputDim = layerDict["inputDim"] as? Int,
                  let outputDim = layerDict["outputDim"] as? Int,
                  let layerRank = layerDict["rank"] as? Int,
                  let layerAlpha = (layerDict["alpha"] as? NSNumber)?.floatValue,
                  let matrixADict = layerDict["matrixA"] as? [String: Any],
                  let matrixBDict = layerDict["matrixB"] as? [String: Any],
                  let matrixAData = matrixADict["data"] as? [Float],
                  let matrixBData = matrixBDict["data"] as? [Float] else {
                logger.warning("Skipping invalid layer", metadata: ["name": "\(name)"])
                continue
            }
            
            // Convert Float arrays back to MLXArray
            let matrixA = MLXArray(matrixAData, [layerRank, inputDim])
            let matrixB = MLXArray(matrixBData, [outputDim, layerRank])
            
            let layer = LoRALayer(
                layerName: name,
                inputDim: inputDim,
                outputDim: outputDim,
                rank: layerRank,
                alpha: layerAlpha,
                matrixA: matrixA,
                matrixB: matrixB
            )
            
            layers[name] = layer
        }
        
        logger.debug("Loaded weights from JSON", metadata: ["layers": "\(layers.count)"])
        
        return (baseModelId, rank, alpha, layers)
    }
    
    /// Convert MLXArray to Float array for JSON serialization.
    private func arrayToFloatArray(_ array: MLXArray) -> [Float] {
        // Use MLXArray's built-in asArray method
        return array.asArray(Float.self)
    }
}

// MARK: - Adapter Info

/// Summary information about an adapter.
public struct AdapterInfo: Identifiable, Sendable {
    public let id: String
    public let metadata: LoRAAdapter.AdapterMetadata
    
    public init(id: String, metadata: LoRAAdapter.AdapterMetadata) {
        self.id = id
        self.metadata = metadata
    }
}

// MARK: - Errors

public enum AdapterError: Error, LocalizedError {
    case notFound(String)
    case invalidMetadata
    case invalidWeights
    case saveFailed(String)
    case loadFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Adapter not found: \(id)"
        case .invalidMetadata:
            return "Invalid or corrupted adapter metadata"
        case .invalidWeights:
            return "Invalid or corrupted adapter weights"
        case .saveFailed(let reason):
            return "Failed to save adapter: \(reason)"
        case .loadFailed(let reason):
            return "Failed to load adapter: \(reason)"
        }
    }
}
