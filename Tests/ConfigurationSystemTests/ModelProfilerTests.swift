// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import ConfigurationSystem

final class ModelProfilerTests: XCTestCase {

    /// The empty-path fallback must not crash and must return a profile
    /// (non-arch) with sane defaults rather than nil when the file is
    /// missing — callers use the result to seed context params.
    func testProfileModelMissingFileReturnsNil() {
        let result = ModelProfiler.profileModel(at: "/nonexistent/model.gguf")
        XCTAssertNil(result)
    }

    /// HardwareTier.fromRAM buckets known memory figures.
    func testHardwareTierFromRAM() {
        XCTAssertEqual(HardwareTier.fromRAM(8  * 1024 * 1024 * 1024), .conservative)
        XCTAssertEqual(HardwareTier.fromRAM(16 * 1024 * 1024 * 1024), .moderate)
        XCTAssertEqual(HardwareTier.fromRAM(24 * 1024 * 1024 * 1024), .balanced)
        XCTAssertEqual(HardwareTier.fromRAM(36 * 1024 * 1024 * 1024), .aggressive)
        XCTAssertEqual(HardwareTier.fromRAM(128 * 1024 * 1024 * 1024), .maximum)
    }

    /// Qwen3 flags: builds a synthetic GGUF with general.architecture =
    /// "qwen3" and verifies arch detection + sampler defaults.
    func testProfileQwen3Defaults() throws {
        let url = try makeSyntheticGGUF(architecture: "qwen3", expertCount: nil)
        let path = url.path
        let arch = ModelProfiler.detectArchitecture(at: path)
        XCTAssertTrue(arch.contains(.qwen3), "Qwen3 arch must be detected")
        XCTAssertTrue(arch.contains(.needsMinP), "Qwen3 must flag min-p sampler")
        XCTAssertFalse(arch.contains(.moe), "plain Qwen3 is not MoE")
        XCTAssertTrue(arch.skipsRepetitionPenalty, "Qwen3 must skip repetition penalty")
        XCTAssertTrue(arch.producesThinking, "Qwen3 must report native thinking")

        let profile = ModelProfiler.profile(
            architecture: arch,
            modelCtxTrain: 32768,
            modelSize: 4 * 1024 * 1024 * 1024,
            availableMemory: 64 * 1024 * 1024 * 1024,
            gpuMemory: 32 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(profile.kvCacheType, .f16, "64 GB host should use f16 KV cache")
        XCTAssertEqual(profile.temperature, 1.0, "Qwen3 defaults to temp=1.0")
        XCTAssertEqual(profile.topK, 20, "Qwen3 defaults to top_k=20")
        XCTAssertEqual(profile.minP, 0.0, "Qwen3 defaults to min_p=0.0")
        XCTAssertEqual(profile.topP, 0.95)
        XCTAssertEqual(profile.repetitionPenalty, 1.0)
        XCTAssertEqual(profile.repetitionLastN, 0)
        XCTAssertTrue(profile.hasNativeThinking)
    }

    /// MoE models are detected via the expert_count KV (>1).
    func testDetectArchitectureMoE() throws {
        let url = try makeSyntheticGGUF(architecture: "llama", expertCount: 16)
        let arch = ModelProfiler.detectArchitecture(at: url.path)
        XCTAssertTrue(arch.contains(.moe), "expert_count=16 must flag MoE")
    }

    /// Dense (no arch metadata) defaults to empty flags.
    func testDetectArchitectureDense() throws {
        let url = try makeSyntheticGGUF(architecture: "llama", expertCount: nil)
        let arch = ModelProfiler.detectArchitecture(at: url.path)
        XCTAssertTrue(arch.isEmpty, "plain llama should detect as dense (no special flags)")
    }

    /// Build a minimal valid GGUF file at a temp URL with the given
    /// general.architecture and optional expert_count metadata.
    private func makeSyntheticGGUF(architecture: String,
                                   expertCount: Int?) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sam-profiling-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let url = tmp.appendingPathExtension("gguf")

        var data = Data()
        // [4] "GGUF" magic
        data.append(contentsOf: [0x47, 0x46, 0x55, 0x46])
        // version 3 (u32 LE)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(3).littleEndian) { Array($0) })
        // n_tensors = 0 (u64 LE)
        data.append(contentsOf: withUnsafeBytes(of: UInt64(0).littleEndian) { Array($0) })
        // n_kv = count of metadata entries (1 or 2)
        let nKV = expertCount != nil ? UInt64(2) : UInt64(1)
        data.append(contentsOf: withUnsafeBytes(of: nKV.littleEndian) { Array($0) })
        // data_offset (u64 LE) — value doesn't matter, we only scan header
        data.append(contentsOf: withUnsafeBytes(of: UInt64(0).littleEndian) { Array($0) })

        // KV entry 1: general.architecture (STRING)
        let key1 = "general.architecture"
        data.append(contentsOf: withUnsafeBytes(of: UInt64(key1.utf8.count).littleEndian) { Array($0) })
        data.append(key1.data(using: .utf8)!)
        // value type = 10 (STRING)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(10).littleEndian) { Array($0) })
        let archBytes = architecture.data(using: .utf8)!
        data.append(contentsOf: withUnsafeBytes(of: UInt64(archBytes.count).littleEndian) { Array($0) })
        data.append(archBytes)

        // KV entry 2 (optional): <arch>.expert_count (UINT32). The real
        // GGUF KV template is "%s.expert_count" (e.g. "qwen3.expert_count"),
        // so we use the arch prefix to match the scanner's suffix check.
        if let nExperts = expertCount {
            let key2 = "\(architecture).expert_count"
            data.append(contentsOf: withUnsafeBytes(of: UInt64(key2.utf8.count).littleEndian) { Array($0) })
            data.append(key2.data(using: .utf8)!)
            // type = 1 (UINT32)
            data.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian) { Array($0) })
            data.append(contentsOf: withUnsafeBytes(of: UInt32(nExperts).littleEndian) { Array($0) })
        }

        try data.write(to: url)
        return url
    }

    /// SSM / Mamba models: detected as recurrent+ssm, skip rep penalty.
    func testProfileSsmDefaults() throws {
        let arch = ModelArchitecture.ssm.union(.recurrent)
        XCTAssertTrue(arch.skipsRepetitionPenalty)
        XCTAssertFalse(arch.producesThinking)
        let profile = ModelProfiler.profile(
            architecture: arch,
            modelCtxTrain: 16384,
            modelSize: 2 * 1024 * 1024 * 1024,
            availableMemory: 16 * 1024 * 1024 * 1024,
            gpuMemory: 8 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(profile.kvCacheType, .q8_0, "16 GB host should quantize KV cache")
        XCTAssertNil(profile.repetitionPenalty, "SSM models omit rep penalty")
    }

    /// Dense Llama model on a constrained (16 GB) host quantizes KV cache.
    func testProfileDenseConstrained() {
        let arch = ModelArchitecture()
        let profile = ModelProfiler.profile(
            architecture: arch,
            modelCtxTrain: 32768,
            modelSize: 8 * 1024 * 1024 * 1024,
            availableMemory: 16 * 1024 * 1024 * 1024,
            gpuMemory: 8 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(profile.kvCacheType, .q8_0)
        XCTAssertEqual(profile.repetitionPenalty, 1.1)
        XCTAssertEqual(profile.temperature, 0.8)
        XCTAssertTrue(profile.cacheRamMiB ?? 0 > 512, "cache-ram budget should be set on constrained hosts")
    }
}
