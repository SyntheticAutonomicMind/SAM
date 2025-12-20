// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import StableDiffusionIntegration

/// CivitAI preferences for model browsing and downloading
struct CivitAIPreferencesPane: View {
    @AppStorage("civitai_api_key") private var apiKey: String = ""
    @AppStorage("civitai_auto_convert") private var autoConvert: Bool = true
    @AppStorage("civitai_nsfw_filter") private var nsfwFilter: Bool = true
    @AppStorage("civitai_download_path") private var downloadPath: String = ""

    @State private var testingConnection: Bool = false
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var showAPIKeyHelp: Bool = false

    enum ConnectionStatus {
        case unknown
        case success
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                /// Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "photo.stack")
                            .font(.title)
                            .foregroundColor(.blue)
                        Text("CivitAI Model Browser")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    Text("Browse and download Stable Diffusion models from CivitAI")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                /// API Key Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("API Key")
                            .font(.headline)

                        Spacer()

                        Button(action: { showAPIKeyHelp.toggle() }) {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        .help("How to get a CivitAI API key")
                    }

                    if showAPIKeyHelp {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("To get a CivitAI API key:")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text("1. Visit https://civitai.com")
                                .font(.caption)
                            Text("2. Sign in or create an account")
                                .font(.caption)
                            Text("3. Go to Account Settings → API Keys")
                                .font(.caption)
                            Text("4. Create a new API key and paste it below")
                                .font(.caption)

                            Text("Note: API key is optional for browsing, but recommended for higher rate limits")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                        .padding(12)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }

                    HStack {
                        SecureField("Optional - leave blank for anonymous access", text: $apiKey)
                            .textFieldStyle(.roundedBorder)

                        Button(action: { testConnection() }) {
                            if testingConnection {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "network")
                            }
                            Text("Test")
                        }
                        .buttonStyle(.bordered)
                        .disabled(testingConnection)
                    }

                    /// Connection status indicator
                    switch connectionStatus {
                    case .unknown:
                        EmptyView()
                    case .success:
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Connection successful")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    case .failure(let message):
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text("Connection failed: \(message)")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

                Divider()

                /// Download Settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Download Settings")
                        .font(.headline)

                    /// Download path
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Download Location")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("Default: ~/SAM/StableDiffusion/Models", text: $downloadPath)
                                .textFieldStyle(.roundedBorder)

                            Button(action: { selectDownloadFolder() }) {
                                Image(systemName: "folder")
                                Text("Browse")
                            }
                            .buttonStyle(.bordered)
                        }

                        Text("Downloaded models will be automatically added to the model list")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    /// Auto-convert option
                    Toggle(isOn: $autoConvert) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Automatically convert to Core ML")
                                .font(.body)
                            Text("Convert downloaded models to Apple's optimized format (recommended)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    /// NSFW filter
                    Toggle(isOn: $nsfwFilter) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Filter NSFW content")
                                .font(.body)
                            Text("Hide models marked as NSFW/adult content")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                Divider()

                /// Info Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("About CivitAI Integration")
                        .font(.headline)

                    Text("CivitAI is a community-driven platform for sharing Stable Diffusion models. This integration allows you to:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Browse thousands of community models", systemImage: "magnifyingglass")
                        Label("Download models directly into SAM", systemImage: "arrow.down.circle")
                        Label("View model details, examples, and ratings", systemImage: "star")
                        Label("Filter by type, style, and other criteria", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Test CivitAI API connection
    func testConnection() {
        testingConnection = true
        connectionStatus = .unknown

        Task {
            do {
                let service = CivitAIService(apiKey: apiKey.isEmpty ? nil : apiKey)
                let success = try await service.testConnection()

                await MainActor.run {
                    if success {
                        connectionStatus = .success
                    } else {
                        connectionStatus = .failure("No models returned")
                    }
                    testingConnection = false
                }
            } catch {
                await MainActor.run {
                    connectionStatus = .failure(error.localizedDescription)
                    testingConnection = false
                }
            }
        }
    }

    /// Select download folder using file picker
    private func selectDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Download Folder"

        if panel.runModal() == .OK, let url = panel.url {
            downloadPath = url.path
        }
    }
}

#Preview {
    CivitAIPreferencesPane()
        .frame(width: 700, height: 600)
}
