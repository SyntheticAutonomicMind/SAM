// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// LoRAAdapter.swift
/// Low-Rank Adaptation (LoRA) implementation for efficient model fine-tuning.
/// LoRA enables training large models by only updating small adapter matrices
/// instead of the full model weights.

import Foundation
@preconcurrency import MLX
@preconcurrency import MLXNN
@preconcurrency import MLXLMCommon
import Logging

private let logger = Logger(label: "com.sam.training.lora_adapter")

// MARK: - LoRA Layer

/// A single LoRA layer containing low-rank adaptation matrices.
///
/// LoRA decomposes weight updates into two smaller matrices:
/// - Matrix A: [input_dim × rank] - initialized with random values
/// - Matrix B: [rank × output_dim] - initialized with zeros
///
/// The forward pass computes: output = input + (B @ A @ input) * scaling
/// where scaling = alpha / rank
///
/// **Note:** Matrix dimensions follow MLX conventions:
/// - lora_a: [inputDim, rank]
/// - lora_b: [rank, outputDim]
public struct LoRALayer {
    /// Name of the layer this LoRA adapts (e.g., "model.layers.0.self_attn.q_proj")
    public let layerName: String
    
    /// Rank of the low-rank decomposition (typically 4, 8, 16, or 32)
    public let rank: Int
    
    /// Scaling factor for LoRA updates (typically equal to rank or 2*rank)
    public let alpha: Float
    
    /// Input dimension of the original layer
    public let inputDim: Int
    
    /// Output dimension of the original layer
    public let outputDim: Int
    
    /// Matrix A: [inputDim × rank] - low-rank down-projection
    public var matrixA: MLXArray
    
    /// Matrix B: [rank × outputDim] - low-rank up-projection
    public var matrixB: MLXArray
    
    /// Computed scaling factor: alpha / rank
    public var scaling: Float {
        alpha / Float(rank)
    }
    
    /// Initialize a LoRA layer with random A and zero B (standard LoRA initialization).
    ///
    /// - Parameters:
    ///   - layerName: Name of the layer to adapt
    ///   - inputDim: Input dimension
    ///   - outputDim: Output dimension
    ///   - rank: Rank of decomposition
    ///   - alpha: Scaling factor
    public init(
        layerName: String,
        inputDim: Int,
        outputDim: Int,
        rank: Int,
        alpha: Float
    ) {
        self.layerName = layerName
        self.inputDim = inputDim
        self.outputDim = outputDim
        self.rank = rank
        self.alpha = alpha
        
        // Initialize A with small random values (Gaussian)
        // MLX expects: [inputDim, rank] not [rank, inputDim]
        // Using 0.01 stddev following common LoRA practice
        let key = MLXRandom.key(UInt64(abs(layerName.hashValue)))
        self.matrixA = MLXRandom.normal([inputDim, rank], key: key) * 0.01
        
        // Initialize B with zeros (ensures LoRA starts with no effect)
        // MLX expects: [rank, outputDim] not [outputDim, rank]
        self.matrixB = MLXArray.zeros([rank, outputDim])
        
        logger.debug("Initialized LoRA layer", metadata: [
            "layer": "\(layerName)",
            "rank": "\(rank)",
            "dims": "\(inputDim)x\(outputDim)"
        ])
    }
    
    /// Initialize from existing matrices (for loading saved adapters).
    public init(
        layerName: String,
        inputDim: Int,
        outputDim: Int,
        rank: Int,
        alpha: Float,
        matrixA: MLXArray,
        matrixB: MLXArray
    ) {
        self.layerName = layerName
        self.inputDim = inputDim
        self.outputDim = outputDim
        self.rank = rank
        self.alpha = alpha
        self.matrixA = matrixA
        self.matrixB = matrixB
    }
    
    /// Compute LoRA forward pass.
    ///
    /// For input x: delta = (x @ A^T @ B^T) * scaling
    ///
    /// - Parameter input: Input tensor [batch_size, input_dim]
    /// - Returns: LoRA delta [batch_size, output_dim]
    public func forward(_ input: MLXArray) -> MLXArray {
        // input: [batch_size, input_dim]
        // A^T: [input_dim, rank]
        // B^T: [rank, output_dim]
        
        let aOut = matmul(input, matrixA.T)  // [batch_size, rank]
        let bOut = matmul(aOut, matrixB.T)   // [batch_size, output_dim]
        return bOut * scaling
    }
}

// MARK: - LoRA Adapter

/// A collection of LoRA layers forming a complete adapter.
///
/// An adapter contains multiple LoRA layers that target specific layers
/// in the base model (typically attention query, key, value, and output projections).
public struct LoRAAdapter {
    /// Unique identifier for this adapter
    public let id: String
    
    /// Base model this adapter was trained for
    public let baseModelId: String
    
    /// Rank used for all layers
    public let rank: Int
    
    /// Alpha scaling factor
    public let alpha: Float
    
    /// Dictionary of LoRA layers indexed by layer name
    public var layers: [String: LoRALayer]
    
    /// Metadata about this adapter
    public var metadata: AdapterMetadata
    
    /// Initialize a new adapter.
    public init(
        id: String,
        baseModelId: String,
        rank: Int,
        alpha: Float,
        layers: [String: LoRALayer],
        metadata: AdapterMetadata
    ) {
        self.id = id
        self.baseModelId = baseModelId
        self.rank = rank
        self.alpha = alpha
        self.layers = layers
        self.metadata = metadata
    }
    
    /// Add a LoRA layer to this adapter.
    public mutating func addLayer(_ layer: LoRALayer) {
        layers[layer.layerName] = layer
        logger.debug("Added LoRA layer to adapter", metadata: [
            "adapter": "\(id)",
            "layer": "\(layer.layerName)"
        ])
    }
    
    /// Get all trainable parameters as name-array pairs.
    ///
    /// Returns pairs like:
    /// - ("model.layers.0.self_attn.q_proj.lora_A", matrixA)
    /// - ("model.layers.0.self_attn.q_proj.lora_B", matrixB)
    public func parameters() -> [(String, MLXArray)] {
        var params: [(String, MLXArray)] = []
        for (name, layer) in layers.sorted(by: { $0.key < $1.key }) {
            params.append(("\(name).lora_A", layer.matrixA))
            params.append(("\(name).lora_B", layer.matrixB))
        }
        return params
    }
    
    /// Update parameters from gradients.
    ///
    /// - Parameter updates: Dictionary mapping parameter names to updated arrays
    public mutating func updateParameters(_ updates: [String: MLXArray]) {
        for (name, _) in layers {
            if let newA = updates["\(name).lora_A"] {
                layers[name]?.matrixA = newA
            }
            if let newB = updates["\(name).lora_B"] {
                layers[name]?.matrixB = newB
            }
        }
    }
    
    /// Get parameter count (number of trainable parameters).
    public func parameterCount() -> Int {
        var count = 0
        for layer in layers.values {
            count += layer.rank * layer.inputDim  // Matrix A
            count += layer.outputDim * layer.rank  // Matrix B
        }
        return count
    }
}

// MARK: - Adapter Metadata

extension LoRAAdapter {
    /// Metadata about adapter training and usage.
    public struct AdapterMetadata: Sendable, Codable {
        /// When this adapter was created
        public let createdAt: Date
        
        /// Name of the training dataset
        public let trainingDataset: String
        
        /// Total training steps completed
        public var trainingSteps: Int
        
        /// Final training loss
        public var finalLoss: Float
        
        /// Number of training epochs
        public let epochs: Int
        
        /// Learning rate used
        public let learningRate: Float
        
        /// Batch size used
        public let batchSize: Int
        
        /// User-provided name for this adapter
        public let adapterName: String
        
        /// Base model ID this adapter was trained for
        public let baseModelId: String
        
        public init(
            createdAt: Date,
            trainingDataset: String,
            trainingSteps: Int = 0,
            finalLoss: Float = 0.0,
            epochs: Int,
            learningRate: Float,
            batchSize: Int,
            adapterName: String = "Untitled Adapter",
            baseModelId: String
        ) {
            self.createdAt = createdAt
            self.trainingDataset = trainingDataset
            self.trainingSteps = trainingSteps
            self.finalLoss = finalLoss
            self.epochs = epochs
            self.learningRate = learningRate
            self.batchSize = batchSize
            self.adapterName = adapterName
            self.baseModelId = baseModelId
        }
    }
}

// MARK: - Layer Name Patterns

extension LoRAAdapter {
    /// Generate standard LoRA layer names for a transformer model.
    ///
    /// - Parameters:
    ///   - model: The base language model to adapt
    ///   - numLayers: Number of transformer layers to adapt
    ///   - rank: LoRA rank
    ///   - alpha: LoRA alpha
    ///   - targetModules: Which modules to adapt (default: q, k, v, o projections)
    /// - Returns: Array of LoRA layers
    public static func createStandardLayers(
        model: any LanguageModel,
        numLayers: Int,
        rank: Int,
        alpha: Float,
        targetModules: [String] = ["q_proj", "k_proj", "v_proj", "o_proj"]
    ) -> [LoRALayer] {
        guard let loraModel = model as? LoRAModel else {
            logger.error("Model does not conform to LoRAModel protocol")
            return []
        }
        
        var layers: [LoRALayer] = []
        let modelLayers = loraModel.loraLayers
        
        // Only adapt the specified number of layers
        let layersToAdapt = modelLayers.suffix(numLayers)
        
        logger.debug("Inspecting model layers for LoRA", metadata: [
            "total_layers": "\(modelLayers.count)",
            "layers_to_adapt": "\(layersToAdapt.count)"
        ])
        
        for (layerIdx, modelLayer) in layersToAdapt.enumerated() {
            // Get all modules in this layer
            let namedModules = modelLayer.namedModules()
            
            // Debug: log first few module names to understand structure
            if layerIdx == 0 {
                let moduleNames = Array(namedModules.map { $0.0 }.prefix(10))
                logger.debug("Sample module names in layer 0", metadata: [
                    "modules": "\(moduleNames.joined(separator: ", "))"
                ])
            }
            
            for module in targetModules {
                // Find the module in the layer - match by suffix since full path includes "self_attn." or "mlp."
                if let (modulePath, linearModule) = namedModules.first(where: { $0.0.hasSuffix(module) }),
                   let linear = linearModule as? Linear {
                    
                    // Get actual dimensions from the linear layer
                    let (outputDim, inputDim) = linear.shape
                    
                    // Determine full layer path based on module name
                    let fullLayerPath: String
                    if modulePath.contains("self_attn") {
                        fullLayerPath = "model.layers.\(layerIdx).self_attn.\(module)"
                    } else if modulePath.contains("mlp") {
                        fullLayerPath = "model.layers.\(layerIdx).mlp.\(module)"
                    } else {
                        fullLayerPath = "model.layers.\(layerIdx).\(modulePath)"
                    }
                    
                    let layer = LoRALayer(
                        layerName: fullLayerPath,
                        inputDim: inputDim,
                        outputDim: outputDim,
                        rank: rank,
                        alpha: alpha
                    )
                    
                    logger.debug("Initialized LoRA layer from model", metadata: [
                        "layer": "\(fullLayerPath)",
                        "dims": "\(inputDim)x\(outputDim)",
                        "modulePath": "\(modulePath)"
                    ])
                    
                    layers.append(layer)
                }
            }
        }
        
        logger.info("Created LoRA layers from model", metadata: [
            "count": "\(layers.count)",
            "numLayers": "\(numLayers)",
            "targetModules": "\(targetModules.joined(separator: ", "))"
        ])
        
        return layers
    }
}

// MARK: - Helper Extensions

extension MLXArray {
    /// Transpose property for convenience.
    public var T: MLXArray {
        return transposed()
    }
}
