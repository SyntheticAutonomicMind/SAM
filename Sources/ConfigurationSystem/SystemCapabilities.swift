// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Metal

/// System capability detection for dynamic performance optimization.
public struct SystemCapabilities: Sendable {
    /// Shared singleton instance.
    public static let current = SystemCapabilities()

    /// Total physical RAM in bytes.
    public let physicalMemory: UInt64

    /// Total physical RAM in GB (for easier logging/comparison).
    public var physicalMemoryGB: Int {
        Int(physicalMemory / (1024 * 1024 * 1024))
    }

    /// Available CPU processor count.
    public let processorCount: Int

    /// Whether Metal GPU is available.
    public let hasMetalGPU: Bool

    /// Metal GPU name (if available).
    public let metalGPUName: String?

    /// Metal GPU recommended max working set size in bytes (if available).
    public let metalMaxMemory: UInt64?

    /// Recommended RAM profile based on physical memory.
    public var ramProfile: RAMProfile {
        switch physicalMemoryGB {
        case 0..<12:
            return .conservative
        case 12..<20:
            return .moderate
        case 20..<28:
            return .balanced
        case 28..<48:
            return .aggressive
        default:
            return .maximum
        }
    }

    public init() {
        /// Detect physical memory.
        self.physicalMemory = ProcessInfo.processInfo.physicalMemory

        /// Detect CPU cores.
        self.processorCount = ProcessInfo.processInfo.processorCount

        /// Detect Metal GPU.
        if let device = MTLCreateSystemDefaultDevice() {
            self.hasMetalGPU = true
            self.metalGPUName = device.name
            self.metalMaxMemory = device.recommendedMaxWorkingSetSize
        } else {
            self.hasMetalGPU = false
            self.metalGPUName = nil
            self.metalMaxMemory = nil
        }
    }

    /// Get optimal thread count for CPU inference Reserves 2 cores for system, caps at 8 for diminishing returns.
    public var optimalThreadCount: Int {
        max(1, min(8, processorCount - 2))
    }

    /// Get optimal batch size based on RAM profile.
    public var optimalBatchSize: Int32 {
        switch ramProfile {
        case .conservative:
            return 512
        case .moderate:
            return 1024
        case .balanced:
            return 2048
        case .aggressive:
            return 2048
        case .maximum:
            return 2048
        }
    }

    /// Get optimal context window size based on RAM profile.
    public var optimalContextSize: Int32 {
        switch ramProfile {
        case .conservative:
            return 4096
        case .moderate:
            return 8192
        case .balanced:
            return 16384
        case .aggressive:
            return 24576
        case .maximum:
            return 32768
        }
    }

    /// Format system info for logging.
    public var description: String {
        var info = "SystemCapabilities: \(physicalMemoryGB)GB RAM, \(processorCount) CPUs"
        if let gpuName = metalGPUName {
            info += ", Metal GPU: \(gpuName)"
            if let maxMem = metalMaxMemory {
                info += " (\(maxMem/(1024*1024*1024))GB)"
            }
        }
        info += ", Profile: \(ramProfile)"
        return info
    }
}

/// RAM-based optimization profiles.
public enum RAMProfile: String, Codable, CaseIterable {
    case conservative = "Conservative (8GB)"
    case moderate = "Moderate (16GB)"
    case balanced = "Balanced (24GB)"
    case aggressive = "Aggressive (32GB)"
    case maximum = "Maximum (64GB+)"

    /// Get MLX configuration for this profile with proper context/token limits Note: contextLength accounts for tool definitions (reserved ~1024 tokens).
    public var mlxConfiguration: MLXConfiguration {
        switch self {
        case .conservative:
            /// 8GB RAM: Aggressive KV quantization, limited cache Context: 4096 total (3072 usable after tool overhead).
            return MLXConfiguration(
                kvBits: 4,
                kvGroupSize: 64,
                quantizedKVStart: 0,
                maxKVSize: 4096,
                topP: 0.95,
                temperature: 0.8,
                repetitionPenalty: 1.1,
                repetitionContextSize: 20,
                contextLength: 4096,
                maxTokens: 1024
            )

        case .moderate:
            /// 16GB RAM: Moderate KV quantization Context: 8192 total (7168 usable after tool overhead).
            return MLXConfiguration(
                kvBits: 4,
                kvGroupSize: 64,
                quantizedKVStart: 0,
                maxKVSize: 8192,
                topP: 0.95,
                temperature: 0.8,
                repetitionPenalty: 1.1,
                repetitionContextSize: 20,
                contextLength: 8192,
                maxTokens: 1024
            )

        case .balanced:
            /// 24GB RAM: Light KV quantization, large cache Context: 16384 total (15360 usable after tool overhead).
            return MLXConfiguration(
                kvBits: 8,
                kvGroupSize: 64,
                quantizedKVStart: 0,
                maxKVSize: nil,
                topP: 0.95,
                temperature: 0.8,
                repetitionPenalty: 1.1,
                repetitionContextSize: 20,
                contextLength: 16384,
                maxTokens: 2048
            )

        case .aggressive:
            /// 32GB RAM: No KV quantization, unlimited cache Context: 32768 total (31744 usable after tool overhead).
            return MLXConfiguration(
                kvBits: nil,
                kvGroupSize: 64,
                quantizedKVStart: 0,
                maxKVSize: nil,
                topP: 0.95,
                temperature: 0.8,
                repetitionPenalty: 1.1,
                repetitionContextSize: 20,
                contextLength: 32768,
                maxTokens: 4096
            )

        case .maximum:
            /// 64GB+ RAM: Maximum quality, no quantization Context: 65536 total (64512 usable after tool overhead).
            return MLXConfiguration(
                kvBits: nil,
                kvGroupSize: 64,
                quantizedKVStart: 0,
                maxKVSize: nil,
                topP: 0.95,
                temperature: 0.8,
                repetitionPenalty: 1.1,
                repetitionContextSize: 20,
                contextLength: 65536,
                maxTokens: 8192
            )
        }
    }

    /// Get context length for this RAM profile (accounting for tool overhead).
    public var contextLength: Int {
        mlxConfiguration.contextLength
    }

    /// Get max tokens for this RAM profile.
    public var maxTokens: Int {
        mlxConfiguration.maxTokens
    }
}

/// llama.cpp configuration parameters.
public struct LlamaConfiguration: Codable, Equatable {
    /// Number of layers to offload to GPU (-1 = auto/all).
    public var nGpuLayers: Int

    /// Context window size in tokens.
    public var nCtx: Int

    /// Batch size for prompt processing.
    public var nBatch: Int

    /// Top-P sampling threshold.
    public var topP: Double

    /// Temperature for sampling.
    public var temperature: Double

    /// Repetition penalty factor.
    public var repetitionPenalty: Double

    /// Maximum tokens to generate per response.
    public var maxTokens: Int

    public init(
        nGpuLayers: Int = -1,
        nCtx: Int = 8192,
        nBatch: Int = 512,
        topP: Double = 0.95,
        temperature: Double = 0.8,
        repetitionPenalty: Double = 1.1,
        maxTokens: Int = 2048
    ) {
        self.nGpuLayers = nGpuLayers
        self.nCtx = nCtx
        self.nBatch = nBatch
        self.topP = topP
        self.temperature = temperature
        self.repetitionPenalty = repetitionPenalty
        self.maxTokens = maxTokens
    }

    /// Optimized for 8GB-16GB RAM.
    public static var memoryOptimized: LlamaConfiguration {
        LlamaConfiguration(
            nGpuLayers: 20,
            nCtx: 4096,
            nBatch: 256,
            topP: 0.95,
            temperature: 0.8,
            repetitionPenalty: 1.1,
            maxTokens: 512
        )
    }

    /// Balanced for 16GB-24GB RAM.
    public static var balanced: LlamaConfiguration {
        LlamaConfiguration(
            nGpuLayers: -1,
            nCtx: 8192,
            nBatch: 512,
            topP: 0.95,
            temperature: 0.8,
            repetitionPenalty: 1.1,
            maxTokens: 1024
        )
    }

    /// High performance for 32GB+ RAM.
    public static var highPerformance: LlamaConfiguration {
        LlamaConfiguration(
            nGpuLayers: -1,
            nCtx: 16384,
            nBatch: 1024,
            topP: 0.95,
            temperature: 0.8,
            repetitionPenalty: 1.1,
            maxTokens: 2048
        )
    }

    /// Maximum for 64GB+ RAM.
    public static var maximum: LlamaConfiguration {
        LlamaConfiguration(
            nGpuLayers: -1,
            nCtx: 32768,
            nBatch: 2048,
            topP: 0.95,
            temperature: 0.8,
            repetitionPenalty: 1.1,
            maxTokens: 4096
        )
    }
}

/// RAM profile extension for llama.cpp configuration.
extension RAMProfile {
    /// Get llama.cpp configuration for this profile.
    public var llamaConfiguration: LlamaConfiguration {
        switch self {
        case .conservative:
            return .memoryOptimized

        case .moderate:
            return .balanced

        case .balanced:
            return LlamaConfiguration(
                nGpuLayers: -1,
                nCtx: 16384,
                nBatch: 1024,
                topP: 0.95,
                temperature: 0.8,
                repetitionPenalty: 1.1,
                maxTokens: 2048
            )

        case .aggressive:
            return .highPerformance

        case .maximum:
            return .maximum
        }
    }
}

/// Global accessor for llama.cpp configuration from user preferences.
public func getGlobalLlamaConfiguration() -> LlamaConfiguration {
    let preset = UserDefaults.standard.string(forKey: "localModels.llamaPreset") ?? "auto"

    switch preset {
    case "auto": return SystemCapabilities.current.ramProfile.llamaConfiguration
    case "conservative": return RAMProfile.conservative.llamaConfiguration
    case "moderate": return RAMProfile.moderate.llamaConfiguration
    case "balanced": return RAMProfile.balanced.llamaConfiguration
    case "aggressive": return RAMProfile.aggressive.llamaConfiguration
    case "maximum": return RAMProfile.maximum.llamaConfiguration

    case "custom":
        let nGpuLayers = UserDefaults.standard.integer(forKey: "localModels.llama.customNGpuLayers")
        let nCtx = UserDefaults.standard.integer(forKey: "localModels.llama.customNCtx")
        let nBatch = UserDefaults.standard.integer(forKey: "localModels.llama.customNBatch")
        let topP = UserDefaults.standard.double(forKey: "localModels.llama.customTopP")
        let temperature = UserDefaults.standard.double(forKey: "localModels.llama.customTemperature")
        let repPenalty = UserDefaults.standard.double(forKey: "localModels.llama.customRepetitionPenalty")
        let maxTokens = UserDefaults.standard.integer(forKey: "localModels.llama.customMaxTokens")

        return LlamaConfiguration(
            nGpuLayers: nGpuLayers != 0 ? nGpuLayers : -1,
            nCtx: nCtx > 0 ? nCtx : 8192,
            nBatch: nBatch > 0 ? nBatch : 512,
            topP: topP > 0 ? topP : 0.95,
            temperature: temperature > 0 ? temperature : 0.8,
            repetitionPenalty: repPenalty > 0 ? repPenalty : 1.1,
            maxTokens: maxTokens > 0 ? maxTokens : 2048
        )
    default: return SystemCapabilities.current.ramProfile.llamaConfiguration
    }
}

/// Global accessor for MLX configuration from user preferences Falls back to auto-detected profile if not set or set to "auto".
public func getGlobalMLXConfiguration() -> MLXConfiguration {
    let preset = UserDefaults.standard.string(forKey: "localModels.mlxPreset") ?? "auto"

    switch preset {
    case "auto": return SystemCapabilities.current.ramProfile.mlxConfiguration
    case "conservative": return RAMProfile.conservative.mlxConfiguration
    case "moderate": return RAMProfile.moderate.mlxConfiguration
    case "balanced": return RAMProfile.balanced.mlxConfiguration
    case "aggressive": return RAMProfile.aggressive.mlxConfiguration
    case "maximum": return RAMProfile.maximum.mlxConfiguration

    case "custom":
        let kvBits = UserDefaults.standard.integer(forKey: "localModels.mlx.customKVBits")
        let kvGroupSize = UserDefaults.standard.integer(forKey: "localModels.mlx.customKVGroupSize")
        let maxKVSize = UserDefaults.standard.integer(forKey: "localModels.mlx.customMaxKVSize")
        let topP = UserDefaults.standard.double(forKey: "localModels.mlx.customTopP")
        let temperature = UserDefaults.standard.double(forKey: "localModels.mlx.customTemperature")
        let repPenalty = UserDefaults.standard.double(forKey: "localModels.mlx.customRepetitionPenalty")
        let repContext = UserDefaults.standard.integer(forKey: "localModels.mlx.customRepetitionContextSize")
        let contextLength = UserDefaults.standard.integer(forKey: "localModels.mlx.customContextLength")
        let maxTokens = UserDefaults.standard.integer(forKey: "localModels.mlx.customMaxTokens")

        return MLXConfiguration(
            kvBits: kvBits > 0 ? kvBits : nil,
            kvGroupSize: kvGroupSize > 0 ? kvGroupSize : 64,
            quantizedKVStart: 0,
            maxKVSize: maxKVSize > 0 ? maxKVSize : nil,
            topP: topP > 0 ? topP : 0.95,
            temperature: temperature > 0 ? temperature : 0.8,
            repetitionPenalty: repPenalty > 0 ? repPenalty : 1.1,
            repetitionContextSize: repContext > 0 ? repContext : 20,
            contextLength: contextLength > 0 ? contextLength : 8192,
            maxTokens: maxTokens > 0 ? maxTokens : 2048
        )
    default: return SystemCapabilities.current.ramProfile.mlxConfiguration
    }
}
