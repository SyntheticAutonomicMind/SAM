// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Metal
import Logging

private let profilerLogger = Logger(label: "com.sam.config.modelprofiler")

/// Hardware memory tier derived from physical RAM and (on Apple Silicon)
/// the Metal GPU's recommended max working set. The tier drives KV-cache
/// quantization, batch sizing, and cache-ram budgeting for the in-process
/// llama.cpp engine and the spawned llama-server.
///
/// The tiers mirror the RAMProfile presets used by the Settings pane, but
/// are anchored to the physical memory ceiling rather than a fixed guess so
/// the optimizer can size itself correctly on a 128 GB Mac Studio just as it
/// can on a 16 GB MacBook Air.
public enum HardwareTier: String, Codable, CaseIterable, Sendable {
    case conservative = "Conservative"   // 0-12 GB
    case moderate = "Moderate"           // 12-20 GB
    case balanced = "Balanced"           // 20-28 GB
    case aggressive = "Aggressive"       // 28-48 GB
    case maximum = "Maximum"             // 48 GB+

    /// Map a physical-memory figure (in bytes) onto a tier.
    public static func fromRAM(_ physicalMemory: UInt64) -> HardwareTier {
        let gb = physicalMemory / (1024 * 1024 * 1024)
        switch gb {
        case 0..<12:  return .conservative
        case 12..<20: return .moderate
        case 20..<28: return .balanced
        case 28..<48: return .aggressive
        default:      return .maximum
        }
    }

    /// Approximate GPU memory ceiling (bytes) for KV cache budgeting.
    /// On Apple Silicon the GPU pool is the limiting factor for offloaded
    /// KV; elsewhere we fall back to a conservative fraction of RAM.
    public var gpuMemoryBytes: UInt64 {
        #if targetEnvironment(simulator)
        return 2 * 1024 * 1024 * 1024
        #else
        guard let device = MTLCreateSystemDefaultDevice() else {
            return physicalMemoryForTier / 4
        }
        return device.recommendedMaxWorkingSetSize
        #endif
    }

    /// Detect the hardware tier for the current machine (physical RAM +
    /// Metal GPU working set on Apple Silicon). Cached via `SystemCapabilities`
    /// in practice; this is the lightweight static entry point.
    public static var current: HardwareTier {
        #if targetEnvironment(simulator)
        return .balanced
        #else
        let device = MTLCreateSystemDefaultDevice()
        let gpuMem: UInt64 = device?.recommendedMaxWorkingSetSize ?? (4 * 1024 * 1024 * 1024)
        let total = ProcessInfo.processInfo.physicalMemory + gpuMem
        return fromRAM(total)
        #endif
    }

    /// Physical RAM (bytes) represented by this tier — used for cache-ram
    /// sizing on hosts without a Metal device.
    public var physicalMemoryForTier: UInt64 {
        switch self {
        case .conservative: return 8  * 1024 * 1024 * 1024
        case .moderate:     return 16 * 1024 * 1024 * 1024
        case .balanced:     return 24 * 1024 * 1024 * 1024
        case .aggressive:   return 36 * 1024 * 1024 * 1024
        case .maximum:      return 96 * 1024 * 1024 * 1024
        }
    }
}

/// Detected structural properties of a GGUF model. Derived purely from the
/// first few kilobytes of the file header (no weights are read), so it is
/// cheap enough to call on every model load.
///
/// The detection mirrors the heuristics in `llama-ai`'s `llama-run.sh`:
///   - MoE: presence of an `expert_count` KV (> 1) or a `MoE`/`moe` token
///     in the architecture string.
///   - SSM: `mamba`/`mamba2` architecture or `ssm.` tensor names visible
///     in the first tensor-name block of the header.
///   - Qwen3 thinking: `general.architecture == "qwen3"` (or `qwen3moe`),
///     which implies built-in chain-of-thought reasoning.
public struct ModelArchitecture: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let moe          = Self(rawValue: 1 << 0)
    public static let ssm          = Self(rawValue: 1 << 1)
    public static let qwen3        = Self(rawValue: 1 << 2)
    public static let recurrent    = Self(rawValue: 1 << 3)  // Mamba-style (subset/sibling of ssm)
    public static let encoderOnly  = Self(rawValue: 1 << 4)  // BERT-style
    public static let hybrid       = Self(rawValue: 1 << 5)  // SWA + dense attention mix
    public static let needsMinP    = Self(rawValue: 1 << 6)  // Min-p is the stable sampler for this arch

    /// Human-readable summary for logging.
    public var summary: String {
        if self.isEmpty { return "dense" }
        var parts: [String] = []
        if contains(.moe)          { parts.append("MoE") }
        if contains(.ssm)          { parts.append("SSM") }
        if contains(.qwen3)        { parts.append("qwen3-thinking") }
        if contains(.recurrent)    { parts.append("recurrent") }
        if contains(.encoderOnly)  { parts.append("encoder-only") }
        if contains(.hybrid)       { parts.append("hybrid-SWA") }
        if contains(.needsMinP)    { parts.append("min-p") }
        return parts.joined(separator: ", ")
    }

    /// True for models that should *not* receive a repetition penalty
    /// (Qwen3 was trained without one, and applying it causes degenerate
    /// tool-call loops). SSM/Mamba models likewise don't benefit.
    public var skipsRepetitionPenalty: Bool {
        contains(.qwen3) || contains(.ssm)
    }

    /// True for models that produce built-in `  ` reasoning blocks.
    public var producesThinking: Bool {
        contains(.qwen3)
    }
}

/// Result of profiling a single GGUF model against the current hardware.
/// Feeds the in-process llama.cpp context builder and the spawned
/// llama-server argument list.
public struct ProfiledConfiguration: Sendable {
    /// Detected model architecture flags.
    public let architecture: ModelArchitecture

    /// Hardware tier the model was profiled against.
    public let tier: HardwareTier

    /// KV-cache element type to request from the in-process engine.
    /// Mirrors `--cache-type-k/v` on the server. `nil` means "let the
    /// host decide" (defaults to f16 in llama.cpp).
    public let kvCacheType: GGMLType?

    /// Recommended context window, clamped to the model's training limit.
    public let contextSize: Int

    /// Recommended prompt-processing batch size.
    public let batchSize: Int

    /// micro-batch (ubatch) size — kept small for memory locality.
    public let microBatchSize: Int

    /// Number of layers to offload to GPU (-1 = all).
    public let gpuLayers: Int

    /// RAM budget (MiB) to hand to `--cache-ram` on the spawned server.
    /// nil leaves it to the server default.
    public let cacheRamMiB: Int?

    /// Recommended sampling defaults derived from architecture.
    public let temperature: Double
    public let topP: Double
    public let topK: Int
    public let minP: Double
    public let repetitionPenalty: Double?
    public let repetitionLastN: Int
    public let maxTokens: Int

    /// True when the model carries hidden `  ` reasoning that the UI
    /// should expose as a toggle.
    public let hasNativeThinking: Bool

    /// Whether the optimizer recommends disabling repetition penalty.
    public var shouldSkipRepetitionPenalty: Bool { architecture.skipsRepetitionPenalty }

    public init(
        architecture: ModelArchitecture,
        tier: HardwareTier,
        kvCacheType: GGMLType?,
        contextSize: Int,
        batchSize: Int,
        microBatchSize: Int,
        gpuLayers: Int,
        cacheRamMiB: Int?,
        temperature: Double,
        topP: Double,
        topK: Int,
        minP: Double,
        repetitionPenalty: Double?,
        repetitionLastN: Int,
        maxTokens: Int,
        hasNativeThinking: Bool
    ) {
        self.architecture = architecture
        self.tier = tier
        self.kvCacheType = kvCacheType
        self.contextSize = contextSize
        self.batchSize = batchSize
        self.microBatchSize = microBatchSize
        self.gpuLayers = gpuLayers
        self.cacheRamMiB = cacheRamMiB
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionLastN = repetitionLastN
        self.maxTokens = maxTokens
        self.hasNativeThinking = hasNativeThinking
    }
}

/// GGML scalar type alias carried through to the llama.cpp C structs.
/// Raw values match the `enum ggml_type` in ggml/include/ggml.h so they
/// can be passed straight to context params. We only need the handful
/// llama.cpp actually accepts for KV cache.
public enum GGMLType: UInt32, Codable, Sendable {
    case f32  = 0
    case f16  = 1
    case q8_0 = 8
    case q5_0 = 9
    case q5_1 = 10
    case q4_0 = 11
    case q4_1 = 12

    /// Convert to the imported Swift `ggml_type` enum value expected by
    /// the context params struct.
    var contextValue: UInt32 { rawValue }
}

/// GGUF value type codes (mirrors the enum in ggml/include/gguf.h).
private enum GguValueType: UInt32 {
    case bool   = 0
    case uint32 = 1
    case int32  = 2
    case float32 = 3
    case uint16 = 4
    case int16  = 5
    case uint8  = 6
    case int8   = 7
    case uint64 = 8
    case float64 = 9
    case string = 10
    case array  = 11
}

/// Static model-analysis + hardware-sizing entry point. Mirrors the
/// heuristics in `llama-ai`'s `llama-run.sh` but returns structured Swift
/// values the rest of SAM can consume directly.
///
/// Call this from `LlamaContext.create_context` so the in-process engine
/// receives identical, model-aware tuning.
public enum ModelProfiler {
    /// Bytes of the GGUF header to scan for KV metadata and the first
    /// tensor-name block. 16 KiB covers the vast majority of models;
    /// the scan is O(header size) and completes in < 1 ms.
    private static let headerScanSize = 16 * 1024

    /// Scan a GGUF file and return its detected architecture flags.
    /// Only the header is read; weights are never touched.
    public static func detectArchitecture(at path: String) -> ModelArchitecture {
        guard let file = fopen(path, "rb") else {
            profilerLogger.debug("GGUF_SCAN: could not open \(path), assuming dense")
            return []
        }
        defer { fclose(file) }

        let buf = UnsafeMutableRawPointer(mutating: malloc(headerScanSize))!
        defer { free(buf) }
        let read = fread(buf, 1, headerScanSize, file)
        guard read >= 32 else {
            profilerLogger.debug("GGUF_SCAN: file too small, assuming dense")
            return []
        }

        // Validate "GGUF" magic.
        let magic = buf.assumingMemoryBound(to: UInt8.self)
        if magic[0] != 0x47 || magic[1] != 0x46 || magic[2] != 0x55 || magic[3] != 0x46 {
            profilerLogger.debug("GGUF_SCAN: bad magic, assuming dense")
            return []
        }

        // Header: [4] magic | [u32] version | [u64] n_tensors | [u64] n_kv
        //         | [u64] data_offset  -- then the KV table.
        let base = buf.assumingMemoryBound(to: UInt8.self)
        let nKV = readUInt64(base, at: 16)
        let start = Int(32) // KV block starts after the 5 fixed header fields

        var found: ModelArchitecture = []
        var offset = start
        for _ in 0..<min(nKV, 512) {
            guard offset + 8 <= read else { break }
            let keyLen = Int(readUInt64(base, at: offset))
            offset += 8
            guard offset + keyLen <= read else { break }
            let key = String(decoding: UnsafeBufferPointer(start: base + offset, count: keyLen), as: UTF8.self)
            offset += keyLen
            guard offset + 4 <= read else { break }
            let type = GguValueType(rawValue: readUInt32(base, at: offset)) ?? .uint32
            offset += 4
            // Read value, then advance by its encoded length.
            offset = consumeGguValue(base, offset: offset, type: type, read: read, key: key, found: &found)
        }

        // Secondary SSM detector: scan tensor names in the header region
        // for `ssm`/`mamba` markers (only if arch metadata didn't surface one).
        if found.isDisjoint(with: [.ssm, .recurrent]) {
            if hasTensorMarker(base, read: read, marker: "ssm") ||
               hasTensorMarker(base, read: read, marker: "mamba") {
                found.formUnion([.ssm, .recurrent, .needsMinP])
            }
        }
        return found
    }

    /// Read a single GGUF KV value at `offset`, apply its meaning to `found`,
    /// and return the offset advanced past the value.
    private static func consumeGguValue(_ base: UnsafePointer<UInt8>,
                                        offset: Int,
                                        type: GguValueType,
                                        read: Int,
                                        key: String,
                                        found: inout ModelArchitecture) -> Int {
        switch type {
        case .string:
            guard offset + 8 <= read else { return offset }
            let strLen = Int(readUInt64(base, at: offset))
            let strStart = offset + 8
            guard strStart + strLen <= read else { return offset + 8 + strLen }
            let val = String(decoding: UnsafeBufferPointer(start: base.advanced(by: strStart), count: strLen), as: UTF8.self)
            if key == "general.architecture" {
                found.formUnion(architectureFlags(from: val))
            }
            return strStart + strLen

        case .uint32, .int32:
            guard offset + 4 <= read else { return offset }
            let val = Int(readUInt32(base, at: offset))
            if key.hasSuffix(".expert_count") || key.hasSuffix(".expert_used_count"), val > 1 {
                found.formUnion(.moe)
            }
            return offset + 4

        case .uint16, .int16:
            guard offset + 2 <= read else { return offset }
            let val = Int(readUInt16(base, at: offset))
            if key.hasSuffix(".expert_count"), val > 1 { found.formUnion(.moe) }
            return offset + 2

        case .uint8, .int8, .bool:
            guard offset + 1 <= read else { return offset }
            return offset + 1

        case .uint64, .float64:
            guard offset + 8 <= read else { return offset }
            let val = Int(readUInt64(base, at: offset))
            if key.hasSuffix(".expert_count"), val > 1 { found.formUnion(.moe) }
            return offset + 8

        case .float32:
            return offset + 4

        case .array:
            // ARRAY: [u32 type][u64 len][items]
            guard offset + 12 <= read else { return offset }
            let arrType = GguValueType(rawValue: readUInt32(base, at: offset)) ?? .uint32
            let arrLen = Int(readUInt64(base, at: offset + 4))
            let itemLen = scalarLength(type: arrType)
            return offset + 12 + itemLen * arrLen
        }
    }

    /// Scan the raw header buffer for an ASCII marker (tensor-name substring).
    private static func hasTensorMarker(_ base: UnsafePointer<UInt8>,
                                        read: Int,
                                        marker: String) -> Bool {
        guard let cstr = marker.cString(using: .utf8) else { return false }
        let mlen = strlen(cstr)
        if mlen == 0 || read < mlen { return false }
        return memich(base, cstr, mlen, read)
    }

    /// Naive `memmem`-equivalent for an ASCII needle in raw bytes.
    private static func memich(_ hay: UnsafePointer<UInt8>, _ needle: UnsafePointer<CChar>, _ nlen: Int, _ hlen: Int) -> Bool {
        let n = UnsafeBufferPointer(start: needle, count: nlen).map { UInt8(bitPattern: $0) }
        if nlen > hlen { return false }
        outer: for i in 0...(hlen - nlen) {
            for j in 0..<nlen {
                if hay[i + j] != n[j] { continue outer }
            }
            return true
        }
        return false
    }

    // MARK: - Little-endian readers (GGUF is always LE)

    private static func readUInt32(_ p: UnsafePointer<UInt8>, at: Int) -> UInt32 {
        let vp = p + at
        return UInt32(vp[0]) | (UInt32(vp[1]) << 8) | (UInt32(vp[2]) << 16) | (UInt32(vp[3]) << 24)
    }

    private static func readUInt16(_ p: UnsafePointer<UInt8>, at: Int) -> UInt16 {
        let vp = p + at
        return UInt16(vp[0]) | (UInt16(vp[1]) << 8)
    }

    private static func readUInt64(_ p: UnsafePointer<UInt8>, at: Int) -> UInt64 {
        let vp = p + at
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(UInt64(vp[i]) << (i * 8))
        }
        return v
    }

    private static func scalarLength(type: GguValueType) -> Int {
        switch type {
        case .bool, .uint8, .int8:     return 1
        case .uint16, .int16:          return 2
        case .uint32, .int32, .float32: return 4
        case .uint64, .float64:        return 8
        default:                       return 0
        }
    }

    /// Map a `general.architecture` string to `ModelArchitecture` flags.
    private static func architectureFlags(from name: String) -> ModelArchitecture {
        let lower = name.lowercased()
        var flags: ModelArchitecture = []
        if lower == "qwen3" || lower == "qwen3moe" || lower == "qwen3next" {
            flags.formUnion([.qwen3, .needsMinP])
        }
        if lower.contains("moe") || lower == "qwen2moe" || lower == "qwen3moe" {
            flags.formUnion(.moe)
        }
        if lower == "mamba" || lower == "mamba2" || lower.contains("ssm") {
            flags.formUnion([.ssm, .recurrent, .needsMinP])
        }
        if lower.contains("bert") || lower.contains("jina") || lower == "nomic-bert" {
            flags.formUnion(.encoderOnly)
        }
        return flags
    }

    /// Produce a model-aware configuration for the given hardware tier.
    /// `modelCtxTrain` is the model's training context window (read from
    /// the GGUF metadata by the loader); `modelSize` is the on-disk size.
    public static func profile(
        architecture: ModelArchitecture,
        modelCtxTrain: Int,
        modelSize: UInt64,
        availableMemory: UInt64,
        gpuMemory: UInt64,
        userOverride: LlamaConfiguration? = nil
    ) -> ProfiledConfiguration {

        let ramGB = availableMemory / (1024 * 1024 * 1024)
        let modelGB = modelSize / (1024 * 1024 * 1024)
        let tier = HardwareTier.fromRAM(availableMemory)

        // KV cache type: quantize on constrained memory, keep f16 on
        // ample memory for quality. Mirrors the llama-ai heuristic that
        // prefers q8_0 below ~32 GB and f16 on workstation-class boxes.
        let kvType: GGMLType?
        if architecture.contains(.encoderOnly) {
            kvType = nil  // encoder-only: KV cache is tiny, no quantization
        } else if ramGB >= 32 {
            kvType = .f16
        } else {
            kvType = .q8_0
        }

        // Context: never exceed the model's training limit, never request
        // more than the hardware can afford. Budget ~12 bytes/token (KV)
        // against available RAM minus 1.5x model size (peak activation +
        // swap headroom).
        let kvBytesPerToken: UInt64 = (architecture.contains(.recurrent) && !architecture.contains(.hybrid))
            ? 8   // Mamba state is smaller
            : 12  // dense attention
        let ramHeadroom = availableMemory > (3 * modelSize / 2)
            ? availableMemory - (3 * modelSize / 2) : 0
        let ramKVTokens = ramHeadroom / kvBytesPerToken
        let ctxCeiling = min(modelCtxTrain, Int(ramKVTokens))
        let contextSize = max(2048, ctxCeiling)

        // Batch sizing: larger models need smaller batches to fit GPU
        // activations. Matches llama-ai's size tiers.
        let baseBatch: Int
        if modelGB >= 40 { baseBatch = 512 }
        else if modelGB >= 20 { baseBatch = 1024 }
        else if modelGB >= 8 { baseBatch = 2048 }
        else { baseBatch = 4096 }
        let batchFromMemory = Int(availableMemory / (64 * 1024 * 1024))
        let batchSize = min(baseBatch, min(batchFromMemory, contextSize))
        let microBatchSize = min(512, batchSize)

        // GPU layers: full offload when VRAM can hold the model.
        let gpuLayers: Int
        if modelSize > 0, gpuMemory > modelSize {
            gpuLayers = -1
        } else if gpuMemory > 0 && modelSize > 0 {
            gpuLayers = max(0, Int((gpuMemory * 3 / 4) / modelSize))
        } else {
            gpuLayers = -1
        }

        // cache-ram budget for the spawned server: target ~25% of free RAM
        // minus model footprint, capped per tier.
        let ramCacheBudget = min(
            max(512, (ramHeadroom / 4) / (1024 * 1024)),
            tierCacheCap(tier)
        )

        // --- Sampling defaults ---
        // Qwen3 was trained without a repetition penalty; applying one
        // causes degenerate repeated tool-call loops. llama-ai enforces
        // temp=1.0, top_p=0.95, top_k=20, min_p=0.0, repeat=1.0 for Qwen3.
        let isQwen3 = architecture.contains(.qwen3)
        let isSSM = architecture.contains(.ssm)
        let temperature: Double
        let topP: Double
        let topK: Int
        let minP: Double
        let repetitionPenalty: Double?
        let repetitionLastN: Int

        if isQwen3 {
            temperature = 1.0
            topP = 0.95
            topK = 20
            minP = 0.0
            repetitionPenalty = 1.0  // effectively disabled by setSampling guard
            repetitionLastN = 0
        } else if isSSM {
            temperature = 0.8
            topP = 0.9
            topK = 40
            minP = 0.05
            repetitionPenalty = nil
            repetitionLastN = 64
        } else {
            temperature = 0.8
            topP = 0.95
            topK = 40
            minP = 0.05
            repetitionPenalty = 1.1
            repetitionLastN = 64
        }

        let maxTokens = max(512, min(8192, max(2048, contextSize / 2)))

        return ProfiledConfiguration(
            architecture: architecture,
            tier: tier,
            kvCacheType: kvType,
            contextSize: contextSize,
            batchSize: batchSize,
            microBatchSize: microBatchSize,
            gpuLayers: gpuLayers,
            cacheRamMiB: ramCacheBudget > 512 ? Int(ramCacheBudget) : nil,
            temperature: temperature,
            topP: topP,
            topK: topK,
            minP: minP,
            repetitionPenalty: repetitionPenalty,
            repetitionLastN: repetitionLastN,
            maxTokens: maxTokens,
            hasNativeThinking: architecture.contains(.qwen3)
        )
    }

    /// Per-tier cap on the cache-ram budget (MiB) so we never promise more
    /// than the machine can spare.
    private static func tierCacheCap(_ tier: HardwareTier) -> UInt64 {
        switch tier {
        case .conservative: return 2048
        case .moderate:     return 4096
        case .balanced:     return 8192
        case .aggressive:   return 16384
        case .maximum:      return 32768
        }
    }

    /// Profile a concrete model by path, combining arch detection with the
    /// current hardware. Convenience wrapper around `detectArchitecture` +
    /// `profile`.
    public static func profileModel(at path: String,
                                      modelCtxTrain: Int = 32768,
                                      modelSize: UInt64? = nil) -> ProfiledConfiguration? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let size = modelSize ?? {
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        }()
        let arch = detectArchitecture(at: path)
        let device = MTLCreateSystemDefaultDevice()
        let gpuMem = device?.recommendedMaxWorkingSetSize ?? (4 * 1024 * 1024 * 1024)
        let available = ProcessInfo.processInfo.physicalMemory
        return profile(
            architecture: arch,
            modelCtxTrain: modelCtxTrain,
            modelSize: size,
            availableMemory: available,
            gpuMemory: gpuMem
        )
    }

    // MARK: - MLX profiling

    /// Model-aware configuration for MLX inference. Apple's MLX framework
    /// uses KV-cache quantization (kvBits) rather than the ggml_type cache
    /// types llama.cpp uses, so we need a parallel set of tier-derived
    /// defaults.
    ///
    /// llama-ai's `detect-gpu.sh` recommends q8_0-equivalent (kvBits = 8)
    /// KV quantization below ~32 GB and no quantization on workstation-class
    /// boxes. We mirror that here and additionally gate quantization for
    /// MoE / SSM models (whose sparse state benefits less and can degrade
    /// with aggressive quantization).
    public static func profileMLX(
        architecture: ModelArchitecture,
        modelCtxTrain: Int,
        modelSize: UInt64,
        availableMemory: UInt64,
        isQwen3: Bool
    ) -> MLXProfiledConfiguration {

        let ramGB = availableMemory / (1024 * 1024 * 1024)
        let modelGB = modelSize / (1024 * 1024 * 1024)
        let tier = HardwareTier.fromRAM(availableMemory)

        // KV quantization: q8_0-equiv (kvBits=8) below 32 GB; none on 64 GB+.
        // MoE and SSM models keep full-precision KV for stability.
        let kvBits: Int?
        if architecture.contains(.encoderOnly) || architecture.contains(.moe) || architecture.contains(.ssm) {
            kvBits = nil
        } else if ramGB >= 32 {
            kvBits = nil
        } else {
            kvBits = 8
        }

        // Context: capped to model train limit, shrunk to fit available RAM.
        // MLX KV cache is larger per token (no quantization below 32 GB),
        // so we budget more aggressively: ~24 bytes/token for dense attention.
        let kvBytesPerToken: UInt64 = architecture.contains(.recurrent) ? 12 : 24
        let ramHeadroom = availableMemory > (2 * modelSize) ? availableMemory - (2 * modelSize) : 0
        let ramKVTokens = ramHeadroom / kvBytesPerToken
        let ctxCeiling = min(modelCtxTrain, Int(ramKVTokens))
        let contextLength = max(4096, ctxCeiling)

        // Prefill step size: larger for small models (more parallelism),
        // smaller for big models (memory pressure). Matches llama-ai tiers.
        let prefillStepSize: Int
        switch modelGB {
        case ..<8:  prefillStepSize = 2048
        case 8..<20: prefillStepSize = 1024
        case 20..<40: prefillStepSize = 512
        default: prefillStepSize = 256
        }

        // maxKVSize: unlimited when there's RAM headroom, otherwise cap to
        // avoid OOM on small machines.
        let maxKVSize: Int? = (ramGB >= 16 && modelGB < 20) ? nil : (modelGB >= 20 ? 8192 : 16384)

        // Sampling defaults: Qwen3 gets the reasoning-tailored profile.
        let temperature: Double
        let topP: Double
        let minP: Double
        let topK: Int
        let repetitionPenalty: Double?
        let repetitionContextSize: Int

        if isQwen3 || architecture.contains(.qwen3) {
            temperature = 1.0
            topP = 0.95
            topK = 20
            minP = 0.0
            repetitionPenalty = nil
            repetitionContextSize = 0
        } else {
            temperature = 0.8
            topP = 0.95
            topK = 40
            minP = 0.05
            repetitionPenalty = 1.1
            repetitionContextSize = 64
        }

        let maxTokens = max(512, min(8192, contextLength / 2))

        return MLXProfiledConfiguration(
            architecture: architecture,
            tier: tier,
            kvBits: kvBits,
            kvGroupSize: 64,
            quantizedKVStart: 0,
            maxKVSize: maxKVSize,
            contextLength: contextLength,
            maxTokens: maxTokens,
            prefillStepSize: prefillStepSize,
            topP: topP,
            temperature: temperature,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            hasNativeThinking: architecture.contains(.qwen3),
            shouldSkipRepetitionPenalty: architecture.skipsRepetitionPenalty
        )
    }

    /// Convenience overload: resolve an MLX model directory into an arch,
    /// training context, and size, then delegate to the core profiler.
    /// Reads config.json for model_type + context_config; falls back to
    /// dense + the user's configured length when metadata is absent.
    public static func profileMLX(at path: String) -> MLXProfiledConfiguration? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
        else { return nil }

        let url = URL(fileURLWithPath: path)
        let (arch, trainCtx, modelSize) = resolveMLXModel(at: url)
        let available = ProcessInfo.processInfo.physicalMemory
        return profileMLX(
            architecture: arch,
            modelCtxTrain: trainCtx,
            modelSize: modelSize,
            availableMemory: available,
            isQwen3: arch.contains(.qwen3)
        )
    }

    /// Read model_type + context_config from an MLX directory's config.json,
    /// and the directory's total byte size. Returns (arch, trainCtx, size).
    private static func resolveMLXModel(at url: URL) -> (ModelArchitecture, Int, UInt64) {
        var arch: ModelArchitecture = []
        var trainCtx = 32768
        var size: UInt64 = 0

        if let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            size = entries.reduce(UInt64(0)) { acc, entry in
                let fsize: UInt64
                do {
                    fsize = UInt64(try entry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                } catch { fsize = 0 }
                return fsize + acc
            }
        }

        let cfgPath = url.appendingPathComponent("config.json").path
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cfgPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = json["model_type"] as? String {
                arch = detectArchitecture(at: name)
            }
            if let cfg = json["context_config"] as? [String: Any],
               let ctx = cfg["context_length"] as? Int {
                trainCtx = ctx
            } else if let ctx = json["context_length"] as? Int {
                trainCtx = ctx
            }
        }
        return (arch, trainCtx, size)
    }
}

/// Model-aware configuration for MLX inference, mirroring LLM's
/// `ProfiledConfiguration` for llama.cpp.
public struct MLXProfiledConfiguration: Sendable {
    public let architecture: ModelArchitecture
    public let tier: HardwareTier

    public let kvBits: Int?
    public let kvGroupSize: Int
    public let quantizedKVStart: Int
    public let maxKVSize: Int?

    public let contextLength: Int
    public let maxTokens: Int
    public let prefillStepSize: Int

    public let topP: Double
    public let temperature: Double
    public let repetitionPenalty: Double?
    public let repetitionContextSize: Int

    public let hasNativeThinking: Bool
    public let shouldSkipRepetitionPenalty: Bool

    public init(
        architecture: ModelArchitecture,
        tier: HardwareTier,
        kvBits: Int?,
        kvGroupSize: Int,
        quantizedKVStart: Int,
        maxKVSize: Int?,
        contextLength: Int,
        maxTokens: Int,
        prefillStepSize: Int,
        topP: Double,
        temperature: Double,
        repetitionPenalty: Double?,
        repetitionContextSize: Int,
        hasNativeThinking: Bool,
        shouldSkipRepetitionPenalty: Bool
    ) {
        self.architecture = architecture
        self.tier = tier
        self.kvBits = kvBits
        self.kvGroupSize = kvGroupSize
        self.quantizedKVStart = quantizedKVStart
        self.maxKVSize = maxKVSize
        self.contextLength = contextLength
        self.maxTokens = maxTokens
        self.prefillStepSize = prefillStepSize
        self.topP = topP
        self.temperature = temperature
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.hasNativeThinking = hasNativeThinking
        self.shouldSkipRepetitionPenalty = shouldSkipRepetitionPenalty
    }

    /// Convert to a concrete MLXConfiguration value for MLXProvider.
    public var mlxConfiguration: MLXConfiguration {
        MLXConfiguration(
            kvBits: kvBits,
            kvGroupSize: kvGroupSize,
            quantizedKVStart: quantizedKVStart,
            maxKVSize: maxKVSize,
            topP: topP,
            temperature: temperature,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            contextLength: contextLength,
            maxTokens: maxTokens,
            prefillStepSize: prefillStepSize
        )
    }
}
