// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import APIFramework
import Logging

/// Preferences pane for ALICE image generation server connection.
struct ALICEPreferencesPane: View {
    @AppStorage("alice_base_url") private var baseURL: String = ""
    @AppStorage("alice_api_key") private var apiKey: String = ""

    @State private var healthStatus: HealthStatus = .unknown
    @State private var healthResponse: ALICEHealthResponse?
    @State private var availableModels: [ALICEModel] = []
    @State private var audioModels: [ALICEAudioModel] = []
    @State private var isChecking = false
    @State private var isCheckingAudio = false
    @State private var errorMessage: String?
    @State private var showingAPIKeyField = false

    private let logger = Logger(label: "com.sam.ui.ALICEPreferences")

    enum HealthStatus {
        case unknown, checking, healthy, unreachable
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "paintbrush.fill")
                            .font(.title)
                            .foregroundColor(.purple)

                        VStack(alignment: .leading) {
                            Text("ALICE Image Generation")
                                .font(.headline)
                            Text("Remote GPU-accelerated Stable Diffusion server")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.bottom, 4)

                    Text("Connect to an ALICE server on your local network for image generation. ALICE provides GPU-accelerated Stable Diffusion with automatic model discovery.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("Connection")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Server URL")
                            .frame(width: 80, alignment: .leading)

                        TextField("http://192.168.1.100:7860/v1", text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    Text("The ALICE server's OpenAI-compatible API endpoint (include /v1)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.leading, 84)

                    HStack {
                        Text("API Key")
                            .frame(width: 80, alignment: .leading)

                        if showingAPIKeyField {
                            SecureField("Optional - only if server requires auth", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            HStack {
                                if apiKey.isEmpty {
                                    Text("Not set")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                } else {
                                    Text(String(repeating: "•", count: min(apiKey.count, 20)))
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }

                                Spacer()

                                Button(apiKey.isEmpty ? "Set Key" : "Change") {
                                    showingAPIKeyField.toggle()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                if !apiKey.isEmpty {
                                    Button("Clear") {
                                        apiKey = ""
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .foregroundColor(.red)
                                }
                            }
                        }
                    }
                }
            }

            Section(header: Text("Status")) {
                HStack {
                    statusIndicator

                    Spacer()

                    Button("Test Connection") {
                        Task {
                            await testConnection()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(baseURL.isEmpty || isChecking)
                }

                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let health = healthResponse, healthStatus == .healthy {
                Section(header: Text("Server Info")) {
                    LabeledContent("Version", value: health.version)
                    LabeledContent("GPU Available", value: health.gpuAvailable ? "Yes" : "No")
                    LabeledContent("Models Loaded", value: "\(health.modelsLoaded)")
                }

                if !availableModels.isEmpty {
                    Section(header: Text("Available Models (\(availableModels.count))")) {
                        ForEach(availableModels) { model in
                            HStack {
                                Image(systemName: model.isSDXL ? "photo.artframe" : "photo")
                                    .foregroundColor(.purple)
                                    .frame(width: 20)

                                VStack(alignment: .leading) {
                                    Text(model.displayName)
                                        .font(.body)
                                    Text(model.id)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                let dims = model.defaultDimensions
                                Text("\(dims.width)x\(dims.height)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Text("Once connected, SAM can generate images through the image_generation tool. Ask SAM to create, draw, or generate an image and it will use ALICE automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.title)
                            .foregroundColor(.blue)

                        VStack(alignment: .leading) {
                            Text("ALICE Audio Generation")
                                .font(.headline)
                            Text("Music and speech synthesis via Stable Audio and MiniMax Music")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.bottom, 4)

                    Text("ALICE supports two audio models: **stable-audio-open-1.0** (47s stereo audio at 44.1 kHz) and **minimax-music-3** (up to 6-minute songs with lyrics). Once connected, SAM can generate music through the music_operations tool.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let health = healthResponse, healthStatus == .healthy {
                        Button("Refresh Audio Models") {
                            Task {
                                await refreshAudioModels()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isCheckingAudio)

                        if !audioModels.isEmpty {
                            ForEach(audioModels) { model in
                                HStack {
                                    Image(systemName: "waveform.path.eco")
                                        .foregroundColor(.blue)
                                        .frame(width: 20)

                                    VStack(alignment: .leading) {
                                        Text(model.displayName)
                                            .font(.body)
                                        Text(model.id)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)

                                        if let maxSec = model.maxSeconds {
                                            Text("Max duration: \(maxSec)s")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Spacer()

                                    Text(model.type)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }

                        if audioModels.isEmpty && !isCheckingAudio {
                            Text("No audio models found. The audio generation backend may not be configured on the server.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !baseURL.isEmpty {
                Task {
                    await testConnection()
                }
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch healthStatus {
        case .unknown:
            HStack(spacing: 6) {
                Circle()
                    .fill(.gray)
                    .frame(width: 8, height: 8)
                Text("Not connected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                Text("Checking...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .healthy:
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Connected")
                    .font(.caption)
                    .foregroundColor(.green)
            }

        case .unreachable:
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Unreachable")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private func testConnection() async {
        isChecking = true
        healthStatus = .checking
        errorMessage = nil
        healthResponse = nil
        availableModels = []

        guard !baseURL.isEmpty else {
            healthStatus = .unknown
            isChecking = false
            return
        }

        let provider = ALICEProvider(baseURL: baseURL, apiKey: apiKey.isEmpty ? nil : apiKey)

        do {
            let health = try await provider.checkHealth()
            healthResponse = health
            healthStatus = .healthy

            let models = try await provider.fetchAvailableModels()
            availableModels = models

            /// Fetch audio models if available.
            do {
                let audioModelsList = try await provider.fetchAudioModels()
                audioModels = audioModelsList
            } catch {
                logger.debug("No audio models available: \(error.localizedDescription)")
                audioModels = []
            }

            /// Save as shared provider for the app.
            ALICEProvider.shared = provider

        } catch {
            healthStatus = .unreachable
            errorMessage = error.localizedDescription
            ALICEProvider.shared = nil
        }

        isChecking = false
    }

    private func refreshAudioModels() async {
        guard let provider = ALICEProvider.shared else { return }
        isCheckingAudio = true
        do {
            let models = try await provider.fetchAudioModels()
            audioModels = models
        } catch {
            logger.debug("Failed to fetch audio models: \(error.localizedDescription)")
            audioModels = []
        }
        isCheckingAudio = false
    }
}
