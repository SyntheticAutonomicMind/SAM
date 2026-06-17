// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConfigurationSystem
import Logging

private let serverLogger = Logger(label: "com.sam.api.localLlamaServer")

/// Configuration for spawning a local CachyLLama server.
public struct LocalLlamaServerConfig: Sendable, Equatable {
    /// Absolute path to the llama-server binary (built by scripts/build-llama-server-macos.sh).
    public var binaryPath: String

    /// Absolute path to the GGUF model file.
    public var modelPath: String

    /// Number of parallel slots (default: 1).
    public var parallelSlots: Int

    /// Context window size in tokens.
    public var contextSize: Int

    /// Number of layers to offload to GPU (-1 = all).
    public var gpuLayers: Int

    /// Per-user concurrency cap passed to --max-concurrent-per-user.
    /// 0 disables the per-user limit (CachyLLama default).
    public var maxConcurrentPerUser: Int

    /// SSD directory for KV cache persistence. nil disables SSD caching.
    public var cacheSSDPATH: String?

    /// Enable idle-slot save/clear via --cache-idle-slots.
    public var cacheIdleSlots: Bool

    /// Custom CLI args to append after the standard set.
    public var extraArgs: [String]

    public init(
        binaryPath: String,
        modelPath: String,
        parallelSlots: Int = 1,
        contextSize: Int = 8192,
        gpuLayers: Int = -1,
        maxConcurrentPerUser: Int = 1,
        cacheSSDPATH: String? = nil,
        cacheIdleSlots: Bool = true,
        extraArgs: [String] = []
    ) {
        self.binaryPath = binaryPath
        self.modelPath = modelPath
        self.parallelSlots = parallelSlots
        self.contextSize = contextSize
        self.gpuLayers = gpuLayers
        self.maxConcurrentPerUser = maxConcurrentPerUser
        self.cacheSSDPATH = cacheSSDPATH
        self.cacheIdleSlots = cacheIdleSlots
        self.extraArgs = extraArgs
    }
}

/// Status reported back to the UI and EndpointManager.
public enum LocalLlamaServerStatus: Sendable, Equatable {
    case stopped
    case starting
    case ready(port: Int)
    case failed(reason: String)
}

/// Manages a child CachyLLama server process and exposes its localhost endpoint
/// to RemoteLlamaProvider. One actor per running server; lifecycle is owned by
/// the actor (caller triggers start/stop, the actor does the rest).
///
/// CachyLLama server-only features exposed by this actor:
///   - SSD-backed KV cache (--cache-ssd)
///   - Per-conversation slot affinity via llama_user_id (--max-concurrent-per-user)
///   - System prompt KV cache (--cache-ssd-system-prompts)
///   - Idle-slot save/clear (--cache-idle-slots)
///
/// The actor is the only path that holds the Process handle. Anything that
/// needs to talk to the server does so via the URL it returns from start().
public actor LocalLlamaServer {
    private let config: LocalLlamaServerConfig
    private var process: Process?
    private var port: Int = 0
    private var status: LocalLlamaServerStatus = .stopped
    private var readinessTask: Task<Void, Never>?
    private var stdoutBuffer: String = ""
    private var stderrBuffer: String = ""

    public init(config: LocalLlamaServerConfig) {
        self.config = config
    }

    /// Start the server. Resolves with the port once /health 200s, or throws
    /// after a 30s timeout. Safe to call multiple times - subsequent calls
    /// return the existing port without respawning.
    public func start() async throws -> Int {
        switch status {
        case .ready(let p):
            return p
        case .starting:
            /// Wait for the in-flight start to finish.
            while case .starting = status {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if case .ready(let p) = status { return p }
            throw LocalLlamaServerError.startFailed("Server failed to reach ready state")
        case .stopped, .failed:
            break
        }

        status = .starting
        serverLogger.info("Starting llama-server: binary=\(config.binaryPath) model=\(config.modelPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.binaryPath)
        process.arguments = buildArguments()
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        /// Capture stdout/stderr for diagnostics. We keep the most recent
        /// few hundred lines so crashes are debuggable from the SAM UI.
        if let outPipe = process.standardOutput as? Pipe {
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { return }
                let chunk = String(data: data, encoding: .utf8) ?? ""
                Task { await self?.appendStdout(chunk) }
            }
        }
        if let errPipe = process.standardError as? Pipe {
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { return }
                let chunk = String(data: data, encoding: .utf8) ?? ""
                Task { await self?.appendStderr(chunk) }
            }
        }

        process.terminationHandler = { [weak self] proc in
            let reason = proc.terminationReason
            let code = proc.terminationStatus
            Task { await self?.handleTermination(reason: reason, exitCode: code) }
        }

        do {
            try process.run()
        } catch {
            status = .failed(reason: "spawn failed: \(error.localizedDescription)")
            serverLogger.error("llama-server spawn failed: \(error.localizedDescription)")
            throw LocalLlamaServerError.spawnFailed(error.localizedDescription)
        }
        self.process = process

        /// Wait up to 30s for the server to come up.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if case .ready(let p) = status { return p }
            if case .failed = status { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        if case .ready(let p) = status { return p }

        /// Timed out. Capture the last stderr to help the user diagnose.
        let tail = String(stderrBuffer.suffix(2000))
        serverLogger.error("llama-server did not become ready within 30s. stderr tail:\n\(tail)")
        await stop()
        status = .failed(reason: "timeout waiting for /health (stderr: \(tail))")
        throw LocalLlamaServerError.startFailed("Server did not respond to /health within 30s")
    }

    /// Stop the server. SIGTERM, then SIGKILL after 5s.
    public func stop() async {
        readinessTask?.cancel()
        readinessTask = nil
        guard let proc = process, proc.isRunning else {
            process = nil
            status = .stopped
            return
        }
        serverLogger.info("Stopping llama-server (pid \(proc.processIdentifier))")
        proc.terminate()
        /// Give it 5 seconds to drain, then SIGKILL.
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if proc.isRunning {
            serverLogger.warning("llama-server did not exit after SIGTERM, sending SIGKILL")
            kill(proc.processIdentifier, SIGKILL)
        }
        process = nil
        status = .stopped
    }

    public func currentStatus() -> LocalLlamaServerStatus {
        return status
    }

    public func currentPort() -> Int {
        return port
    }

    /// Read-only access to the captured stderr. Useful for surfacing
    /// "why did the server fail" in the Local Models preference pane.
    public func recentStderr(maxChars: Int = 2000) -> String {
        return String(stderrBuffer.suffix(maxChars))
    }

    // MARK: - Private

    private func buildArguments() -> [String] {
        var args: [String] = [
            "-m", config.modelPath,
            "-c", String(config.contextSize),
            "--port", "0",
            "--host", "127.0.0.1",
            "-np", String(config.parallelSlots),
            "-ngl", String(config.gpuLayers)
        ]
        if config.maxConcurrentPerUser > 0 {
            args.append(contentsOf: ["--max-concurrent-per-user", String(config.maxConcurrentPerUser)])
        }
        if let ssdPath = config.cacheSSDPATH {
            args.append(contentsOf: ["--cache-ssd", ssdPath])
        }
        if config.cacheIdleSlots {
            args.append("--cache-idle-slots")
        }
        args.append(contentsOf: config.extraArgs)
        return args
    }

    // MARK: - Test accessors

    /// Synchronous argument builder exposed for tests only. Mirrors buildArguments
    /// so the test suite can verify CLI flag wiring without spawning a real process.
    nonisolated public func builtArgumentsForTesting() -> [String] {
        var args: [String] = [
            "-m", config.modelPath,
            "-c", String(config.contextSize),
            "--port", "0",
            "--host", "127.0.0.1",
            "-np", String(config.parallelSlots),
            "-ngl", String(config.gpuLayers)
        ]
        if config.maxConcurrentPerUser > 0 {
            args.append(contentsOf: ["--max-concurrent-per-user", String(config.maxConcurrentPerUser)])
        }
        if let ssdPath = config.cacheSSDPATH {
            args.append(contentsOf: ["--cache-ssd", ssdPath])
        }
        if config.cacheIdleSlots {
            args.append("--cache-idle-slots")
        }
        args.append(contentsOf: config.extraArgs)
        return args
    }

    /// Test-only appender for the stderr capture buffer. Verifies the
    /// buffer survives until queried by the UI surface.
    public func appendStderrForTesting(_ chunk: String) {
        appendStderr(chunk)
    }

    private func appendStdout(_ chunk: String) {
        stdoutBuffer.append(chunk)
        if stdoutBuffer.count > 64_000 { stdoutBuffer = String(stdoutBuffer.suffix(32_000)) }
        /// CachyLLama writes its bound port to stdout via "listening on ..."
        /// Parse the port from the log line. Fall back to default 8080.
        if port == 0, let match = chunk.range(of: #"listening on (?:[a-zA-Z]+://)?[^:]+:(\d+)"#, options: .regularExpression) {
            let line = String(chunk[match])
            if let portMatch = line.range(of: #":(\d+)"#, options: .regularExpression),
               let captured = line[portMatch].split(separator: ":").last,
               let parsed = Int(captured) {
                port = parsed
                serverLogger.info("llama-server bound to port \(port)")
                Task { await self.markReadyIfHealthy() }
            }
        }
    }

    private func appendStderr(_ chunk: String) {
        stderrBuffer.append(chunk)
        if stderrBuffer.count > 64_000 { stderrBuffer = String(stderrBuffer.suffix(32_000)) }
    }

    private func markReadyIfHealthy() async {
        guard port > 0 else { return }
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return }
        /// CachyLLama returns 200 OK from /health when ready. Poll up to
        /// 10 seconds after the port appears in case the HTTP listener
        /// is still starting.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    serverLogger.info("llama-server ready on port \(port)")
                    status = .ready(port: port)
                    return
                }
            } catch {
                /// Server hasn't bound the listener yet; try again.
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        serverLogger.error("Port \(port) appeared in stdout but /health never returned 200")
    }

    private func handleTermination(reason: Process.TerminationReason, exitCode: Int32) {
        serverLogger.warning("llama-server exited: reason=\(reason) code=\(exitCode)")
        if case .ready = status {
            status = .failed(reason: "Server exited unexpectedly (code \(exitCode))")
        }
        process = nil
    }
}

public enum LocalLlamaServerError: Error, LocalizedError {
    case spawnFailed(String)
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let msg): return "Failed to spawn llama-server: \(msg)"
        case .startFailed(let msg): return "llama-server failed to start: \(msg)"
        }
    }
}
