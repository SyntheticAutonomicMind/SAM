// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import APIFramework

/// Unified local-model optimization settings.
///
/// This single pane is the ONLY place to tune local inference. It merges what
/// were previously two disjoint surfaces — an "optimization" section (preset
/// picker + custom knobs) and a "server" section (lifecycle + operational
/// controls) — so there is no way to configure the same llama.cpp parameter
/// two different ways.
///
/// Architecture: `ModelProfiler` is the single source of truth for sizing
/// (context, GPU layers, KV cache type, cache-ram) and sampler defaults
/// (temperature, topP, topK, minP, repetition penalty). The "Performance
/// Preset" picker is informational under Auto-Detect (it shows the
/// optimizer's tier) and only the "Custom" branch exposes editable fields —
/// and even then, those custom values are merged *onto* the profile inside
/// `getGlobalLlamaConfiguration(modelPath:)`, so the optimizer's KV-cache
/// type and context clamp can never be silently lost.
///
/// The llama.cpp *model* is served in-process by `LlamaProvider` (the C API in
/// `external/llama.cpp`). There is no spawned HTTP server in the SAM
/// architecture — sizing is derived purely from `ModelProfiler` and the
/// preset picker / custom overrides above.
public struct LocalModelOptimizationSection: View {
    @EnvironmentObject private var endpointManager: EndpointManager

    // One preset drives both engine backends. "custom" enables per-field
    // overrides; everything else defers to the ModelProfiler-derived config.
    @AppStorage("localModels.llamaPreset") private var llamaPreset: String = "auto"
    @AppStorage("localModels.mlxPreset") private var mlxPreset: String = "auto"

    /// llama.cpp Custom Settings (only consulted when llamaPreset == "custom").
    @AppStorage("localModels.llama.customNGpuLayers") private var llamaCustomNGpuLayers: Int = -1
    @AppStorage("localModels.llama.customNCtx") private var llamaCustomNCtx: Int = 4096
    @AppStorage("localModels.llama.customNBatch") private var llamaCustomNBatch: Int = 512
    @AppStorage("localModels.llama.customTopP") private var llamaCustomTopP: Double = 0.95
    @AppStorage("localModels.llama.customTopK") private var llamaCustomTopK: Int = 40
    @AppStorage("localModels.llama.customMinP") private var llamaCustomMinP: Double = 0.05
    @AppStorage("localModels.llama.customTemperature") private var llamaCustomTemperature: Double = 0.8
    @AppStorage("localModels.llama.customRepetitionPenalty") private var llamaCustomRepetitionPenalty: Double = 1.1
    @AppStorage("localModels.llama.customMaxTokens") private var llamaCustomMaxTokens: Int = 2048

    /// MLX Custom Settings (only consulted when mlxPreset == "custom").
    @AppStorage("localModels.mlx.customKVBits") private var mlxCustomKVBits: Int = 8
    @AppStorage("localModels.mlx.customKVGroupSize") private var mlxCustomKVGroupSize: Int = 64
    @AppStorage("localModels.mlx.customMaxKVSize") private var mlxCustomMaxKVSize: Int = 0
    @AppStorage("localModels.mlx.customTopP") private var mlxCustomTopP: Double = 0.95
    @AppStorage("localModels.mlx.customTemperature") private var mlxCustomTemperature: Double = 0.8
    @AppStorage("localModels.mlx.customRepetitionPenalty") private var mlxCustomRepetitionPenalty: Double = 1.1
    @AppStorage("localModels.mlx.customRepetitionContextSize") private var mlxCustomRepetitionContextSize: Int = 20
    @AppStorage("localModels.mlx.customContextLength") private var mlxCustomContextLength: Int = 8192
    @AppStorage("localModels.mlx.customMaxTokens") private var mlxCustomMaxTokens: Int = 2048

    @State private var detectedGPUMemory: String = "Detecting..."
    @State private var detectedRAMProfile: RAMProfile = .balanced

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            /// Header.
            HStack {
                Label("Local Model Optimization", systemImage: "slider.horizontal.3")
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
                .font(.caption)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(6)
            }

            Text("Configure local inference optimization. The optimizer derives model-aware defaults (KV cache type, sampler profile, context size) from your hardware and the model's GGUF/MLX header — the preset picker and custom overrides below layer onto that base. Server operational controls (binary path, parallel slots) live at the bottom.")
                .font(.caption)
                .foregroundColor(.secondary)

            Form {
                /// === LLAMA.CPP OPTIMIZATION ===
                /// Single preset picker — this is the ONLY place context/gpu-layer
                /// tuning appears. The server's operational section below does not
                /// let the user re-specify context size or gpu layers.
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
                    .help("Choose preset based on available RAM. Auto-Detect uses the ModelProfiler for model-aware KV cache quantization and sampler defaults. Custom lets you override individual fields.")

                    /// Auto-Detect summary (read-only — tuning lives in Custom).
                    if llamaPreset == "auto" {
                        llamaAutoDetectSummary
                            .padding(.horizontal, 4)
                    }

                    /// Custom override branch — the ONLY place per-field knobs appear.
                    if llamaPreset == "custom" {
                        customLlamaFields
                    } else {
                        presetSummary(config: getLlamaPresetConfig(llamaPreset))
                            .padding(.vertical, 4)
                    }
                } header: {
                    Label("LLAMA.CPP OPTIMIZATION", systemImage: "cpu")
                } footer: {
                    Text("llama.cpp (in-process + spawned server) shares the same profile. The server uses these values directly — see the server lifecycle section below.")
                        .font(.caption)
                }

                /// === MLX OPTIMIZATION ===
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
                    .help("Choose preset for MLX (Apple Silicon). Auto-Detect uses ModelProfiler for KV quantization (q8 below 32GB, none above) and context sizing.")

                    if mlxPreset == "auto" {
                        let config = getMLXPresetConfig(mlxPreset)
                        VStack(alignment: .leading, spacing: 8) {
                            Label("KV Cache: \(config.kvBits?.description ?? "None (f16)") · Context: \(config.contextLength) tokens · Max tokens: \(config.maxTokens)", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Label("Prefill step: \(config.prefillStepSize) · Rep penalty: \(config.repetitionPenalty?.description ?? "nil")", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 4)
                    } else if mlxPreset == "custom" {
                        customMLXFields
                    } else {
                        presetSummary(config: getMLXPresetConfig(mlxPreset))
                            .padding(.vertical, 4)
                    }
                } header: {
                    Label("MLX OPTIMIZATION (APPLE SILICON)", systemImage: "flame")
                } footer: {
                    Text("MLX uses Apple's Metal acceleration. KV cache quantization reduces memory usage to fit larger models.")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .onAppear {
                detectGPUMemory()
                detectRAMProfile()
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    // MARK: - llama.cpp Auto-Detect summary

    @ViewBuilder
    private var llamaAutoDetectSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
                Text("Auto-Detect active: \(detectedRAMProfile.rawValue) RAM tier")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("KV cache: \(kvCacheHint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("· Sampler: \(samplerHint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Custom field editors

    /// Editable per-field overrides for the llama.cpp engine.
    private var customLlamaFields: some View {
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
            .help("Maximum context window (clamped to model training max by the optimizer)")

            HStack {
                Text("Batch Size:")
                Spacer()
                TextField("", value: $llamaCustomNBatch, formatter: NumberFormatter())
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
            }
            .help("Prompt processing batch size")

            HStack {
                Text("Top-P:")
                Spacer()
                TextField("", value: $llamaCustomTopP, formatter: NumberFormatter())
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
            }
            .help("Nucleus sampling threshold (0.0-1.0)")

            HStack {
                Text("Top-K:")
                Spacer()
                TextField("", value: $llamaCustomTopK, formatter: NumberFormatter())
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
            }
            .help("Restrict sampling to K most likely tokens (0 = disabled)")

            HStack {
                Text("Min-P:")
                Spacer()
                TextField("", value: $llamaCustomMinP, formatter: NumberFormatter())
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
            }
            .help("Drop tokens below minP * max probability (0.0-1.0)")

            HStack {
                Text("Repetition Penalty:")
                Spacer()
                TextField("", value: $llamaCustomRepetitionPenalty, formatter: NumberFormatter())
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
            }
            .help("Penalty for token repetition (1.0 = disabled; Qwen3 needs 1.0)")

            HStack {
                Text("Temperature:")
                Spacer()
                TextField("", value: $llamaCustomTemperature, formatter: NumberFormatter())
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
            }
            .help("Sampling temperature (lower = more deterministic)")

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
            .help("Maximum tokens to generate per response")
        }
    }

    /// Editable per-field overrides for the MLX engine.
    private var customMLXFields: some View {
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
                Text("Context Length:")
                Spacer()
                TextField("", value: $mlxCustomContextLength, formatter: NumberFormatter())
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                Text("tokens")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .help("Total context window size")

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
            .help("Maximum tokens to generate per response")

            VStack(alignment: .leading, spacing: 8) {
                Text("Sampler Overrides")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                HStack { Text("Top-P:"); Spacer(); TextField("", value: $mlxCustomTopP, formatter: NumberFormatter()).frame(width: 80).textFieldStyle(.roundedBorder) }
                HStack { Text("Temperature:"); Spacer(); TextField("", value: $mlxCustomTemperature, formatter: NumberFormatter()).frame(width: 80).textFieldStyle(.roundedBorder) }
                HStack { Text("Repetition Penalty:"); Spacer(); TextField("", value: $mlxCustomRepetitionPenalty, formatter: NumberFormatter()).frame(width: 80).textFieldStyle(.roundedBorder) }
                HStack { Text("Repetition Context:"); Spacer(); TextField("", value: $mlxCustomRepetitionContextSize, formatter: NumberFormatter()).frame(width: 80).textFieldStyle(.roundedBorder) }
            }
        }
    }

    /// Render a read-only summary of a preset's effective configuration.
    @ViewBuilder
    private func presetSummary(config: LlamaConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preset Configuration:")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("GPU Layers: \(config.nGpuLayers < 0 ? "Auto" : "\(config.nGpuLayers)")").font(.caption) }
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("Context: \(config.nCtx) tokens").font(.caption) }
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("Batch: \(config.nBatch)").font(.caption) }
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("Top-P: \(String(format: "%.2f", config.topP))").font(.caption) }
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("Top-K: \(config.topK)").font(.caption) }
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("Min-P: \(String(format: "%.2f", config.minP))").font(.caption) }
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("Rep Penalty: \(String(format: "%.2f", config.repetitionPenalty))").font(.caption) }
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("Max Tokens: \(config.maxTokens)").font(.caption) }
        }
    }

    @ViewBuilder
    private func presetSummary(config: MLXConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preset Configuration:")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("KV Cache: \(config.kvBits?.description ?? "None (f16)")").font(.caption) }
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("Context: \(config.contextLength) tokens").font(.caption) }
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("Max Tokens: \(config.maxTokens)").font(.caption) }
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("Top-P: \(String(format: "%.2f", config.topP))").font(.caption) }
            HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("Temperature: \(String(format: "%.2f", config.temperature))").font(.caption) }
            if let rep = config.repetitionPenalty {
                HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption); Text("Rep Penalty: \(String(format: "%.2f", rep))").font(.caption) }
            }
        }
    }

    // MARK: - Helpers

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
        guard let device = MTLCreateSystemDefaultDevice() else { return 0.0 }
        let memoryBytes = Double(device.recommendedMaxWorkingSetSize)
        return memoryBytes / (1024.0 * 1024.0 * 1024.0)
        #else
        return 0.0
        #endif
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
                topK: llamaCustomTopK,
                minP: llamaCustomMinP,
                maxTokens: llamaCustomMaxTokens
            )
        default: return SystemCapabilities.current.ramProfile.llamaConfiguration
        }
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

    // MARK: - Optimizer hints

    private var kvCacheHint: String {
        switch HardwareTier.current {
        case .conservative, .moderate: return "q8_0 (RAM-constrained)"
        case .balanced, .aggressive:   return "q8_0"
        case .maximum:                 return "f16 (ample RAM)"
        }
    }

    private var samplerHint: String {
        "temp=0.8, top_p=0.95, rep=1.1"
    }
}

#Preview {
    LocalModelOptimizationSection()
        .frame(width: 700, height: 600)
}
