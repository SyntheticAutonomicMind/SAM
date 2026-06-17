// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import APIFramework

/// User-facing controls for the CachyLLama llama-server child process.
///
/// SAM spawns the llama-server binary on localhost so it can use server-only
/// features (SSD-backed KV cache, per-conversation slot affinity, system
/// prompt KV cache) that are not reachable from the embedded C library.
///
/// This pane is a thin control surface: the LocalLlamaServer actor in
/// APIFramework owns the process lifecycle. The pane only reads status
/// and forwards user actions.
public struct LocalLlamaServerPane: View {
    @EnvironmentObject private var endpointManager: EndpointManager

    @AppStorage("localModels.llamaServer.binaryPath") private var binaryPath: String = ""
    @AppStorage("localModels.llamaServer.modelPath") private var modelPath: String = ""
    @AppStorage("localModels.llamaServer.cacheSSDPATH") private var cacheSSDPATH: String = ""
    @AppStorage("localModels.llamaServer.cacheIdleSlots") private var cacheIdleSlots: Bool = true
    @AppStorage("localModels.llamaServer.parallelSlots") private var parallelSlots: Int = 1
    @AppStorage("localModels.llamaServer.contextSize") private var contextSize: Int = 8192
    @AppStorage("localModels.llamaServer.gpuLayers") private var gpuLayers: Int = -1
    @AppStorage("localModels.llamaServer.maxConcurrentPerUser") private var maxConcurrentPerUser: Int = 1

    @State private var status: LocalLlamaServerStatus = .stopped
    @State private var recentStderr: String = ""
    @State private var lastError: String = ""
    @State private var server: LocalLlamaServer? = nil
    @State private var statusPollTask: Task<Void, Never>? = nil

    public init() {}

    public var body: some View {
        Form {
            Section {
                HStack {
                    Text("Server Binary:")
                    Spacer()
                    TextField("", text: $binaryPath, prompt: Text("/path/to/llama-server"))
                        .frame(maxWidth: 320)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Choose...") { chooseBinary() }
                }
                .help("Path to the llama-server binary built by scripts/build-llama-server-macos.sh")

                HStack {
                    Text("Model File:")
                    Spacer()
                    TextField("", text: $modelPath, prompt: Text("/path/to/model.gguf"))
                        .frame(maxWidth: 320)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Choose...") { chooseModel() }
                }
                .help("Absolute path to a GGUF model file the server will load")
            } header: {
                Label("Server Binary", systemImage: "terminal")
            } footer: {
                Text("Run scripts/build-llama-server-macos.sh to produce the llama-server binary at external/llama.cpp/build-server/bin/llama-server.")
                    .font(.caption)
            }

            Section {
                HStack {
                    Text("Context Size:")
                    Spacer()
                    TextField("", value: $contextSize, formatter: NumberFormatter())
                        .frame(width: 100)
                        .textFieldStyle(.roundedBorder)
                    Text("tokens")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Parallel Slots:")
                    Spacer()
                    Stepper(value: $parallelSlots, in: 1...8) {
                        Text("\(parallelSlots)")
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .help("Number of concurrent requests the server can handle")

                HStack {
                    Text("GPU Layers (-1 = all):")
                    Spacer()
                    TextField("", value: $gpuLayers, formatter: NumberFormatter())
                        .frame(width: 100)
                        .textFieldStyle(.roundedBorder)
                }
                .help("Layers to offload to GPU; -1 means all layers, 0 means CPU only")

                HStack {
                    Text("Per-User Concurrency Cap:")
                    Spacer()
                    Stepper(value: $maxConcurrentPerUser, in: 0...16) {
                        Text("\(maxConcurrentPerUser == 0 ? "disabled" : "\(maxConcurrentPerUser)")")
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                .help("CachyLLama slot affinity. 1 = each conversation gets its own slot, 0 = no cap.")
            } header: {
                Label("CachyLLama Server", systemImage: "cpu.fill")
            } footer: {
                Text("These flags are passed verbatim to the llama-server binary. See llama-server --help for the full set.")
                    .font(.caption)
            }

            Section {
                Toggle("Cache Idle Slots (save/clear on new task)", isOn: $cacheIdleSlots)
                    .help("When a slot goes idle, save its KV state and clear it from RAM so other slots can use the memory")

                HStack {
                    Text("KV Cache SSD Path:")
                    Spacer()
                    TextField("", text: $cacheSSDPATH, prompt: Text("(disabled)"))
                        .frame(maxWidth: 320)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Choose...") { chooseSSDPATH() }
                }
                .help("Directory for SSD-backed KV cache persistence. Leave blank to disable.")
            } header: {
                Label("CachyLLama Optimizations", systemImage: "bolt.fill")
            } footer: {
                Text("SSD cache persists KV state across server restarts. Idle slot save/clear frees RAM between conversations.")
                    .font(.caption)
            }

            Section {
                HStack {
                    statusBadge
                    Spacer()
                    Button(action: { Task { await startServer() } }) {
                        Label("Start", systemImage: "play.fill")
                    }
                    .disabled(!canStart)

                    Button(action: { Task { await stopServer() } }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(!canStop)
                }

                if !lastError.isEmpty {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(lastError)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if !recentStderr.isEmpty {
                    DisclosureGroup("Recent server output") {
                        ScrollView {
                            Text(recentStderr)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                    }
                }
            } header: {
                Label("Lifecycle", systemImage: "play.circle")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            /// Auto-discover the default binary if the user has not set one.
            if binaryPath.isEmpty {
                binaryPath = defaultBinaryPath()
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .stopped:
            Label("Stopped", systemImage: "circle.fill")
                .foregroundColor(.secondary)
        case .starting:
            Label("Starting", systemImage: "arrow.triangle.2.circlepath")
                .foregroundColor(.orange)
        case .ready(let port):
            Label("Ready on port \(port)", systemImage: "circle.fill")
                .foregroundColor(.green)
        case .failed(let reason):
            Label("Failed", systemImage: "xmark.octagon.fill")
                .foregroundColor(.red)
                .help(reason)
        }
    }

    private var canStart: Bool {
        if case .starting = status { return false }
        if case .ready = status { return false }
        return !binaryPath.isEmpty && !modelPath.isEmpty
    }

    private var canStop: Bool {
        if case .ready = status { return true }
        if case .starting = status { return true }
        return false
    }

    private func defaultBinaryPath() -> String {
        let repoRoot = FileManager.default.currentDirectoryPath
        let candidate = "\(repoRoot)/external/llama.cpp/build-server/bin/llama-server"
        return FileManager.default.fileExists(atPath: candidate) ? candidate : ""
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binaryPath = url.path
        }
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.message = "Select a GGUF model file"
        if panel.runModal() == .OK, let url = panel.url {
            modelPath = url.path
        }
    }

    private func chooseSSDPATH() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            cacheSSDPATH = url.path
        }
    }

    private func startServer() async {
        lastError = ""
        let config = LocalLlamaServerConfig(
            binaryPath: binaryPath,
            modelPath: modelPath,
            parallelSlots: parallelSlots,
            contextSize: contextSize,
            gpuLayers: gpuLayers,
            maxConcurrentPerUser: maxConcurrentPerUser,
            cacheSSDPATH: cacheSSDPATH.isEmpty ? nil : cacheSSDPATH,
            cacheIdleSlots: cacheIdleSlots
        )
        let actor = LocalLlamaServer(config: config)
        server = actor
        startStatusPolling(actor: actor)
        do {
            let port = try await actor.start()
            await registerAsProvider(port: port)
        } catch {
            lastError = error.localizedDescription
            server = nil
            status = .failed(reason: error.localizedDescription)
        }
    }

    /// Once the server is up, register it as a remote-llama provider so
    /// its model appears in the model picker alongside the in-process
    /// local llama.cpp and MLX models. The model name is the GGUF
    /// filename without extension, matching what CachyLLama reports.
    private func registerAsProvider(port: Int) async {
        let baseURL = "http://127.0.0.1:\(port)"
        let ggufName = (modelPath as NSString).lastPathComponent
        let modelName = (ggufName as NSString).deletingPathExtension
        let providerId = "local-cachy-llama-\(modelName.lowercased())"
        await MainActor.run {
            endpointManager.registerLocalCachyLLamaServer(
                baseURL: baseURL,
                modelName: modelName,
                providerId: providerId
            )
        }
    }

    private func stopServer() async {
        if let actor = server {
            let providerId = "local-cachy-llama-\(((modelPath as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased())"
            await MainActor.run {
                endpointManager.unregisterProvider(providerId)
            }
            await actor.stop()
        }
        server = nil
        status = .stopped
        statusPollTask?.cancel()
        statusPollTask = nil
    }

    private func startStatusPolling(actor: LocalLlamaServer) {
        statusPollTask?.cancel()
        statusPollTask = Task {
            while !Task.isCancelled {
                let s = await actor.currentStatus()
                let tail = await actor.recentStderr()
                await MainActor.run {
                    self.status = s
                    self.recentStderr = tail
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

#Preview {
    LocalLlamaServerPane()
        .frame(width: 720, height: 720)
}
