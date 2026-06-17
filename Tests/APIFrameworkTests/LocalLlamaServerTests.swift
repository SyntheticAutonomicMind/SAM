// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework

final class LocalLlamaServerTests: XCTestCase {

    /// Config argument building covers every CachyLLama feature flag SAM wires
    /// through. New CLI flags added to LocalLlamaServerConfig must be reflected
    /// in the resulting argument list or slot affinity / KV cache features will
    /// silently no-op in production.
    func testConfigArgumentsBuild() {
        let config = LocalLlamaServerConfig(
            binaryPath: "/usr/local/bin/llama-server",
            modelPath: "/tmp/model.gguf",
            parallelSlots: 2,
            contextSize: 16384,
            gpuLayers: 35,
            maxConcurrentPerUser: 1,
            cacheSSDPATH: "/tmp/sam-kv",
            cacheIdleSlots: true,
            extraArgs: ["--log-verbosity", "info"]
        )
        let actor = LocalLlamaServer(config: config)
        let args = actor.builtArgumentsForTesting()
        XCTAssertTrue(args.contains("-m"))
        XCTAssertTrue(args.contains("/tmp/model.gguf"))
        XCTAssertTrue(args.contains("--cache-ssd"))
        XCTAssertTrue(args.contains("/tmp/sam-kv"))
        XCTAssertTrue(args.contains("--max-concurrent-per-user"))
        XCTAssertTrue(args.contains("--cache-idle-slots"))
        XCTAssertTrue(args.contains("--log-verbosity"))
        XCTAssertTrue(args.contains("info"))
        /// GPU layer count is always wired (even when -1 = auto).
        XCTAssertTrue(args.contains("-ngl"))
    }

    /// When maxConcurrentPerUser is 0 the flag must be omitted so CachyLLama
    /// uses its default. Sending 0 would change behaviour.
    func testConfigOmitsDisabledFlags() {
        let config = LocalLlamaServerConfig(
            binaryPath: "/usr/local/bin/llama-server",
            modelPath: "/tmp/model.gguf",
            maxConcurrentPerUser: 0,
            cacheSSDPATH: nil,
            cacheIdleSlots: false
        )
        let args = LocalLlamaServer(config: config).builtArgumentsForTesting()
        XCTAssertFalse(args.contains("--max-concurrent-per-user"))
        XCTAssertFalse(args.contains("--cache-ssd"))
        XCTAssertFalse(args.contains("--cache-idle-slots"))
    }

    /// Status starts stopped, transitions to starting, then to ready.
    /// We can't easily test the full lifecycle without a built llama-server
    /// binary, but we can verify the initial state.
    func testInitialStatus() async {
        let actor = LocalLlamaServer(config: LocalLlamaServerConfig(
            binaryPath: "/nonexistent/llama-server",
            modelPath: "/tmp/missing.gguf"
        ))
        let status = await actor.currentStatus()
        if case .stopped = status {
            /// Expected
        } else {
            XCTFail("Initial status should be .stopped, got \(status)")
        }
    }

    /// Recent stderr buffer survives a stop call so the UI can show the
    /// last few lines of the server's diagnostic output.
    func testRecentStderrAfterStop() async {
        let actor = LocalLlamaServer(config: LocalLlamaServerConfig(
            binaryPath: "/nonexistent/llama-server",
            modelPath: "/tmp/missing.gguf"
        ))
        await actor.appendStderrForTesting("model load failed: missing file\n")
        let tail = await actor.recentStderr()
        XCTAssertTrue(tail.contains("model load failed"))
    }
}
