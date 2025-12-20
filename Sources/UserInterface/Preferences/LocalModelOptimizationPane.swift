// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem

/// Optimization settings section for local model inference engines (MLX and llama.cpp) These settings apply to ALL auto-registered local models.
public struct LocalModelOptimizationSection: View {
    @AppStorage("localModels.mlxPreset") private var mlxPreset: String = "auto"
    @AppStorage("localModels.llamaPreset") private var llamaPreset: String = "auto"

    /// MLX Custom Settings.
    @AppStorage("localModels.mlx.customKVBits") private var mlxCustomKVBits: Int = 8
    @AppStorage("localModels.mlx.customKVGroupSize") private var mlxCustomKVGroupSize: Int = 64
    @AppStorage("localModels.mlx.customMaxKVSize") private var mlxCustomMaxKVSize: Int = 0
    @AppStorage("localModels.mlx.customTopP") private var mlxCustomTopP: Double = 0.95
    @AppStorage("localModels.mlx.customTemperature") private var mlxCustomTemperature: Double = 0.8
    @AppStorage("localModels.mlx.customRepetitionPenalty") private var mlxCustomRepetitionPenalty: Double = 1.1
    @AppStorage("localModels.mlx.customRepetitionContextSize") private var mlxCustomRepetitionContextSize: Int = 20
    @AppStorage("localModels.mlx.customContextLength") private var mlxCustomContextLength: Int = 8192
    @AppStorage("localModels.mlx.customMaxTokens") private var mlxCustomMaxTokens: Int = 2048

    /// llama.cpp Custom Settings.
    @AppStorage("localModels.llama.customNGpuLayers") private var llamaCustomNGpuLayers: Int = -1
    @AppStorage("localModels.llama.customNCtx") private var llamaCustomNCtx: Int = 4096
    @AppStorage("localModels.llama.customNBatch") private var llamaCustomNBatch: Int = 512
    @AppStorage("localModels.llama.customTopP") private var llamaCustomTopP: Double = 0.95
    @AppStorage("localModels.llama.customTemperature") private var llamaCustomTemperature: Double = 0.8
    @AppStorage("localModels.llama.customRepetitionPenalty") private var llamaCustomRepetitionPenalty: Double = 1.1
    @AppStorage("localModels.llama.customMaxTokens") private var llamaCustomMaxTokens: Int = 2048

    @State private var detectedGPUMemory: String = "Detecting..."
    @State private var detectedRAMProfile: RAMProfile = .balanced

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            /// Header.
            HStack {
                Label("Optimization Settings", systemImage: "slider.horizontal.3")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("GPU: \(detectedGPUMemory)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Profile: \(detectedRAMProfile.rawValue.capitalized)")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(6)
            }

            Text("Configure optimization settings for local model inference. These settings apply to all auto-registered models.")
                .font(.caption)
                .foregroundColor(.secondary)

            Form {
            /// MLX Optimization Section.
            Section {
                Picker("Memory Optimization Preset", selection: $mlxPreset) {
                    Text("Auto-Detect (Recommended)").tag("auto")
                    Text("Conservative (8GB RAM)").tag("conservative")
                    Text("Moderate (16GB RAM)").tag("moderate")
                    Text("Balanced (24GB RAM)").tag("balanced")
                    Text("Aggressive (32GB RAM)").tag("aggressive")
                    Text("Maximum (64GB+ RAM)").tag("maximum")
                    Text("Custom").tag("custom")
                }
                .help("Choose preset based on available RAM. Memory optimization uses KV cache quantization to reduce memory usage.")

                if mlxPreset == "custom" {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("KV Cache Quantization:")
                            Spacer()
                            Picker("", selection: $mlxCustomKVBits) {
                                Text("None (Best Quality)").tag(0)
                                Text("4-bit (~75% memory savings)").tag(4)
                                Text("8-bit (~50% memory savings)").tag(8)
                            }
                            .labelsHidden()
                            .frame(width: 250)
                        }

                        if mlxCustomKVBits > 0 {
                            HStack {
                                Text("KV Group Size:")
                                Spacer()
                                TextField("", value: $mlxCustomKVGroupSize, formatter: NumberFormatter())
                                    .frame(width: 80)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .help("Group size for quantization (default: 64)")
                        }

                        HStack {
                            Text("Max KV Cache Size:")
                            Spacer()
                            TextField("", value: $mlxCustomMaxKVSize, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                            Text("tokens (0 = unlimited)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .help("Maximum tokens in KV cache before rotation")

                        HStack {
                            Text("Top-P Sampling:")
                            Spacer()
                            TextField("", value: $mlxCustomTopP, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }
                        .help("Nucleus sampling threshold (0.0-1.0, default: 0.95)")

                        HStack {
                            Text("Repetition Penalty:")
                            Spacer()
                            TextField("", value: $mlxCustomRepetitionPenalty, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }
                        .help("Penalty for token repetition (1.0-2.0, default: 1.1)")

                        HStack {
                            Text("Repetition Context Size:")
                            Spacer()
                            TextField("", value: $mlxCustomRepetitionContextSize, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                            Text("tokens")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .help("Number of recent tokens to check for repetition (default: 20)")

                        Divider()

                        HStack {
                            Text("Context Length:")
                            Spacer()
                            TextField("", value: $mlxCustomContextLength, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                            Text("tokens")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .help("Total context window size including conversation history (default: 8192)")

                        HStack {
                            Text("Max Tokens:")
                            Spacer()
                            TextField("", value: $mlxCustomMaxTokens, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                            Text("tokens per response")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .help("Maximum tokens to generate in a single response (default: 2048)")
                    }
                } else {
                    /// Show preset details.
                    let config = getMLXPresetConfig(mlxPreset)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Preset Configuration:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)

                        if let kvBits = config.kvBits {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("KV Cache: \(kvBits)-bit quantization")
                                    .font(.caption)
                            }
                        } else {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("KV Cache: No quantization (highest quality)")
                                    .font(.caption)
                            }
                        }

                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Top-P: \(String(format: "%.2f", config.topP))")
                                .font(.caption)
                        }

                        if let repPenalty = config.repetitionPenalty {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("Repetition Penalty: \(String(format: "%.2f", repPenalty))")
                                    .font(.caption)
                            }
                        }

                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Context: \(config.contextLength) tokens")
                                .font(.caption)
                        }

                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Max Tokens: \(config.maxTokens)")
                                .font(.caption)
                        }

                        if let maxKV = config.maxKVSize {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("Max KV Cache: \(maxKV) tokens")
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Label("MLX Optimization (Apple Silicon)", systemImage: "flame")
            } footer: {
                Text("MLX uses Apple's Metal acceleration for local model inference. Higher memory optimization reduces quality slightly but enables larger models on systems with limited RAM.")
                    .font(.caption)
            }

            /// llama.cpp Optimization Section.
            Section {
                Picker("Performance Preset", selection: $llamaPreset) {
                    Text("Auto-Detect (Recommended)").tag("auto")
                    Text("Conservative (8GB RAM)").tag("conservative")
                    Text("Moderate (16GB RAM)").tag("moderate")
                    Text("Balanced (24GB RAM)").tag("balanced")
                    Text("Aggressive (32GB RAM)").tag("aggressive")
                    Text("Maximum (64GB+ RAM)").tag("maximum")
                    Text("Custom").tag("custom")
                }
                .help("Choose preset based on available RAM and GPU memory.")

                if llamaPreset == "custom" {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("GPU Layers:")
                            Spacer()
                            TextField("", value: $llamaCustomNGpuLayers, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                            Text("(-1 = auto)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .help("Number of model layers to offload to GPU (-1 for automatic)")

                        HStack {
                            Text("Context Size:")
                            Spacer()
                            TextField("", value: $llamaCustomNCtx, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                            Text("tokens")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .help("Maximum context window (default: 4096)")

                        HStack {
                            Text("Batch Size:")
                            Spacer()
                            TextField("", value: $llamaCustomNBatch, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }
                        .help("Prompt processing batch size (default: 512)")

                        HStack {
                            Text("Top-P Sampling:")
                            Spacer()
                            TextField("", value: $llamaCustomTopP, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }
                        .help("Nucleus sampling threshold (0.0-1.0, default: 0.95)")

                        HStack {
                            Text("Repetition Penalty:")
                            Spacer()
                            TextField("", value: $llamaCustomRepetitionPenalty, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }
                        .help("Penalty for token repetition (1.0-2.0, default: 1.1)")

                        Divider()

                        HStack {
                            Text("Max Tokens:")
                            Spacer()
                            TextField("", value: $llamaCustomMaxTokens, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                            Text("tokens per response")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .help("Maximum tokens to generate in a single response (default: 2048)")
                    }
                } else {
                    /// Show preset details.
                    let config = getLlamaPresetConfig(llamaPreset)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Preset Configuration:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)

                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("GPU Layers: \(config.nGpuLayers < 0 ? "Auto" : "\(config.nGpuLayers)")")
                                .font(.caption)
                        }

                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Context Size: \(config.nCtx) tokens")
                                .font(.caption)
                        }

                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Batch Size: \(config.nBatch)")
                                .font(.caption)
                        }

                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Top-P: \(String(format: "%.2f", config.topP))")
                                .font(.caption)
                        }

                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Max Tokens: \(config.maxTokens)")
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Label("llama.cpp Optimization", systemImage: "cpu")
            } footer: {
                Text("llama.cpp provides GGUF model support with CPU and GPU acceleration. Offloading more layers to GPU increases speed but uses more VRAM.")
                    .font(.caption)
            }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
        .onAppear {
            detectGPUMemory()
            detectRAMProfile()
        }
    }

    private func detectRAMProfile() {
        detectedRAMProfile = SystemCapabilities.current.ramProfile
    }

    private func detectGPUMemory() {
        DispatchQueue.global(qos: .userInitiated).async {
            let memoryGB = getGPUMemoryGB()
            DispatchQueue.main.async {
                detectedGPUMemory = String(format: "%.1f GB", memoryGB)
            }
        }
    }

    private func getGPUMemoryGB() -> Double {
        #if os(macOS)
        /// Use Metal to detect GPU memory.
        guard let device = MTLCreateSystemDefaultDevice() else {
            return 0.0
        }

        /// Get recommended working set size (available GPU memory).
        let recommendedMaxWorkingSetSize = device.recommendedMaxWorkingSetSize
        let memoryBytes = Double(recommendedMaxWorkingSetSize)
        let memoryGB = memoryBytes / (1024.0 * 1024.0 * 1024.0)

        return memoryGB
        #else
        return 0.0
        #endif
    }

    private func getMLXPresetConfig(_ preset: String) -> MLXConfiguration {
        switch preset {
        case "auto": return detectedRAMProfile.mlxConfiguration
        case "conservative": return RAMProfile.conservative.mlxConfiguration
        case "moderate": return RAMProfile.moderate.mlxConfiguration
        case "balanced": return RAMProfile.balanced.mlxConfiguration
        case "aggressive": return RAMProfile.aggressive.mlxConfiguration
        case "maximum": return RAMProfile.maximum.mlxConfiguration

        case "custom":
            return MLXConfiguration(
                kvBits: mlxCustomKVBits > 0 ? mlxCustomKVBits : nil,
                kvGroupSize: mlxCustomKVGroupSize,
                quantizedKVStart: 0,
                maxKVSize: mlxCustomMaxKVSize > 0 ? mlxCustomMaxKVSize : nil,
                topP: mlxCustomTopP,
                temperature: mlxCustomTemperature,
                repetitionPenalty: mlxCustomRepetitionPenalty,
                repetitionContextSize: mlxCustomRepetitionContextSize,
                contextLength: mlxCustomContextLength,
                maxTokens: mlxCustomMaxTokens
            )
        default: return detectedRAMProfile.mlxConfiguration
        }
    }

    private func getLlamaPresetConfig(_ preset: String) -> LlamaConfiguration {
        switch preset {
        case "auto": return SystemCapabilities.current.ramProfile.llamaConfiguration
        case "conservative": return RAMProfile.conservative.llamaConfiguration
        case "moderate": return RAMProfile.moderate.llamaConfiguration
        case "balanced": return RAMProfile.balanced.llamaConfiguration
        case "aggressive": return RAMProfile.aggressive.llamaConfiguration
        case "maximum": return RAMProfile.maximum.llamaConfiguration

        case "custom":
            return LlamaConfiguration(
                nGpuLayers: llamaCustomNGpuLayers,
                nCtx: llamaCustomNCtx,
                nBatch: llamaCustomNBatch,
                topP: llamaCustomTopP,
                temperature: llamaCustomTemperature,
                repetitionPenalty: llamaCustomRepetitionPenalty,
                maxTokens: llamaCustomMaxTokens
            )
        default: return SystemCapabilities.current.ramProfile.llamaConfiguration
        }
    }
}

#Preview {
    LocalModelOptimizationSection()
        .frame(width: 700, height: 600)
}
