// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import AppKit
import StableDiffusionIntegration
import APIFramework
import Logging

private let sdPrefLogger = Logger(label: "com.sam.ui.sdprefs")

/// Unified preferences pane for Image Generation model management (Stable Diffusion, Z-Image, Qwen-Image, etc.)
struct StableDiffusionPreferencesPane: View {
    @StateObject private var downloadManager = ModelDownloadManager()
    @StateObject private var sdModelManager = StableDiffusionModelManager()
    @State private var selectedTab: SDTab = .civitai

    enum SDTab: String, CaseIterable {
        case civitai = "CivitAI"
        case huggingface = "Hugging Face"
        case loras = "LoRAs"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .civitai: return "photo.stack"
            case .huggingface: return "face.smiling"
            case .loras: return "square.stack.3d.up"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            /// Tab bar
            HStack(spacing: 0) {
                ForEach(SDTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                            Text(tab.rawValue)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.1) : Color.clear)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            /// Tab content (no TabView - just conditional views)
            Group {
                switch selectedTab {
                case .civitai:
                    CivitAIBrowserView()
                        .environmentObject(downloadManager)
                case .huggingface:
                    HuggingFaceBrowserView()
                        .environmentObject(downloadManager)
                case .loras:
                    LoRABrowserView()
                        .environmentObject(downloadManager)
                case .settings:
                    SDSettingsView()
                }
            }
        }
    }
}

// MARK: - CivitAI Browser View

struct CivitAIBrowserView: View {
    @AppStorage("civitai_api_key") private var apiKey: String = ""
    @AppStorage("civitai_nsfw_filter") private var nsfwFilter: Bool = true

    @StateObject private var sdModelManager = StableDiffusionModelManager()

    @State private var searchQuery: String = ""
    @State private var allModels: [CivitAIModel] = []  /// All loaded Checkpoint models
    @State private var isLoading: Bool = false
    @State private var selectedModel: CivitAIModel?
    @State private var errorMessage: String?
    @State private var downloadedModelInfo: [Int: (slug: String, hasSafeTensors: Bool, hasCoreML: Bool)] = [:]  /// Track downloaded models by CivitAI model ID

    /// Filtered models based on search query and NSFW setting
    private var filteredModels: [CivitAIModel] {
        var filtered = allModels

        /// Local search filtering
        if !searchQuery.isEmpty {
            let query = searchQuery.lowercased()
            filtered = filtered.filter { model in
                model.name.lowercased().contains(query) ||
                model.description?.lowercased().contains(query) == true ||
                model.tags?.contains(where: { $0.lowercased().contains(query) }) == true
            }
        }

        /// NSFW filtering
        if nsfwFilter {
            filtered = filtered.filter { !$0.isNSFW() }
        }

        return filtered
    }

    var body: some View {
        VStack(spacing: 0) {
            /// Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search loaded models...", text: $searchQuery)
                    .textFieldStyle(.plain)

                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { loadAllModels() }) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .help("Reload models from CivitAI")
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            /// Results grid
            if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        loadAllModels()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allModels.isEmpty && !isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Load Image Generation models")
                        .font(.title3)
                    Text("Click to load popular Checkpoint models from CivitAI")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Load Models") {
                        loadAllModels()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                /// Show loading indicator while fetching models
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading models from CivitAI...")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("This may take a moment")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredModels.isEmpty && !searchQuery.isEmpty {
                /// Only show "no matches" when user has actually searched
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No models match '\(searchQuery)'")
                        .font(.title3)
                    Text("Try a different search query")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredModels.isEmpty && !allModels.isEmpty {
                /// Show message when NSFW filter hides all results
                VStack(spacing: 12) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("All results filtered")
                        .font(.title3)
                    Text("All search results were filtered by NSFW content filter")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Disable filter in Settings tab to see all results")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)
                    ], spacing: 16) {
                        ForEach(filteredModels, id: \.id) { model in
                            Button(action: {
                                selectedModel = model
                            }) {
                                CivitAIModelCard(
                                    model: model,
                                    downloadInfo: downloadedModelInfo[model.id]
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(item: $selectedModel) { model in
            CivitAIModelDetailView(model: model)
        }
        .onAppear {
            /// Load all Checkpoint models on first appearance
            if allModels.isEmpty {
                loadAllModels()
            }
        }
    }

    private func loadAllModels() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let service = CivitAIService(apiKey: apiKey.isEmpty ? nil : apiKey)

                sdPrefLogger.info("Loading all Checkpoint models from CivitAI...")

                /// Load all Checkpoints (no query, just type filter)
                let response = try await service.searchModels(
                    query: nil,  /// No search query - get all
                    limit: 100,
                    page: 1,
                    types: ["Checkpoint"],  /// Only Checkpoints
                    sort: "Highest Rated",
                    period: "AllTime",
                    nsfw: nsfwFilter ? false : nil
                )

                sdPrefLogger.info("Loaded \(response.items.count) Checkpoint models from CivitAI")

                await MainActor.run {
                    allModels = response.items
                    isLoading = false
                }

                /// Scan for downloaded models
                await scanDownloadedModels()
            } catch let error as CivitAIError {
                sdPrefLogger.error("Failed to load models: \(error.localizedDescription)")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    allModels = []
                    isLoading = false
                }
            } catch {
                sdPrefLogger.error("Failed to load models: \(error.localizedDescription)")
                await MainActor.run {
                    errorMessage = "Load failed: \(error.localizedDescription)"
                    allModels = []
                    isLoading = false
                }
            }
        }
    }

    /// Scan filesystem for downloaded models and match them to CivitAI models by name
    private func scanDownloadedModels() async {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let modelsDir = cachesDir.appendingPathComponent("sam/models/stable-diffusion")

        guard FileManager.default.fileExists(atPath: modelsDir.path) else { return }

        var downloadedInfo: [Int: (slug: String, hasSafeTensors: Bool, hasCoreML: Bool)] = [:]

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: modelsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for modelDir in contents {
                guard let isDirectory = try? modelDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                      isDirectory else { continue }

                /// Read metadata to get original name and source
                let metadataPath = modelDir.appendingPathComponent(".sam_metadata.json")
                guard FileManager.default.fileExists(atPath: metadataPath.path),
                      let data = try? Data(contentsOf: metadataPath),
                      let metadata = try? JSONDecoder().decode(StableDiffusionModelManager.ModelMetadata.self, from: data),
                      metadata.source == "civitai" else { continue }

                /// Check for safetensors and CoreML
                let hasSafeTensors = FileManager.default.fileExists(
                    atPath: modelDir.appendingPathComponent("model.safetensors").path
                )
                let hasCoreML = FileManager.default.fileExists(
                    atPath: modelDir.appendingPathComponent("original/compiled/Unet.mlmodelc").path
                )

                /// Match by model name from metadata
                /// Format: "ModelName - VersionName"
                let originalName = metadata.originalName

                /// Find matching CivitAI model
                if let matchingModel = allModels.first(where: { civitaiModel in
                    /// Check if any version matches
                    civitaiModel.modelVersions?.contains(where: { version in
                        let expectedName = "\(civitaiModel.name) - \(version.name)"
                        return expectedName == originalName
                    }) == true
                }) {
                    downloadedInfo[matchingModel.id] = (
                        slug: modelDir.lastPathComponent,
                        hasSafeTensors: hasSafeTensors,
                        hasCoreML: hasCoreML
                    )
                }
            }
        } catch {
            sdPrefLogger.error("Failed to scan downloaded models: \(error.localizedDescription)")
        }

        await MainActor.run {
            downloadedModelInfo = downloadedInfo
        }
    }
}

// MARK: - CivitAI Model Card

struct CivitAIModelCard: View {
    let model: CivitAIModel
    let downloadInfo: (slug: String, hasSafeTensors: Bool, hasCoreML: Bool)?  /// Download status info
    @State private var imageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            /// Model preview image
            Group {
                if let url = imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 150)
                                .clipped()
                        case .failure:
                            placeholderImage
                        case .empty:
                            ProgressView()
                                .frame(height: 150)
                        @unknown default:
                            placeholderImage
                        }
                    }
                } else {
                    placeholderImage
                }
            }
            .frame(height: 150)
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.headline)
                    .lineLimit(2)

                if let creator = model.creator {
                    Text("by \(creator.username)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Label(model.type, systemImage: "tag")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Spacer()

                    /// Download status badges
                    if let info = downloadInfo {
                        if info.hasCoreML {
                            Label("Converted", systemImage: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.green)
                        } else if info.hasSafeTensors {
                            Label("Downloaded", systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                    }

                    if model.nsfw == true {
                        Label("NSFW", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 2)
        .onAppear {
            /// Get first image from first model version
            if let firstVersion = model.modelVersions?.first,
               let firstImage = firstVersion.images?.first,
               let url = URL(string: firstImage.url) {
                imageURL = url
            }
        }
    }

    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.2))
            .overlay(
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
            )
    }
}

// MARK: - Conversion Progress Sheet

struct ConversionProgressSheet: View {
    let modelName: String
    @Binding var progress: String
    @Binding var isShowing: Bool

    /// Track whether conversion is still in progress
    private var isConverting: Bool {
        !progress.hasPrefix("SUCCESS:") && !progress.hasPrefix("ERROR:")
    }

    /// Track whether conversion succeeded
    private var conversionSucceeded: Bool {
        progress.hasPrefix("SUCCESS:")
    }

    var body: some View {
        VStack(spacing: 20) {
            /// Header
            HStack {
                if isConverting {
                    Image(systemName: "gearshape.2")
                        .font(.title)
                        .foregroundColor(.accentColor)
                    Text("Converting Model to Core ML")
                        .font(.title2)
                        .fontWeight(.semibold)
                } else if conversionSucceeded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundColor(.green)
                    Text("Conversion Complete")
                        .font(.title2)
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundColor(.orange)
                    Text("Conversion Failed")
                        .font(.title2)
                        .fontWeight(.semibold)
                }
            }

            Divider()

            /// Model info
            VStack(alignment: .leading, spacing: 8) {
                Text("Model:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(modelName)
                    .font(.body)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            /// Progress indicator (only show while converting)
            if isConverting {
                ProgressView()
                    .scaleEffect(1.2)
                    .padding()
            }

            /// Status text
            VStack(alignment: .leading, spacing: 8) {
                Text("Status:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ScrollView {
                    Text(progress.isEmpty ? "Initializing conversion..." : progress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(4)
                }
                .frame(height: 100)
            }

            /// Time estimate (only show while converting)
            if isConverting {
                Text("This process may take a few minutes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }

            Divider()

            /// Close button (always visible, but only enabled when done)
            HStack {
                Spacer()
                Button(action: { isShowing = false }) {
                    Text("Close")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConverting)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

// MARK: - CivitAI Model Detail View

struct CivitAIModelDetailView: View {
    /// Model state enum for tracking download/conversion status
    enum ModelState {
        case notDownloaded
        case safetensorsOnly
        case converted
        case downloading
        case converting
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloadManager: ModelDownloadManager
    @AppStorage("civitai_api_key") private var apiKey: String = ""

    let model: CivitAIModel
    @State private var downloadingVersionId: Int?
    @State private var downloadProgress: Double = 0
    @State private var downloadStatus: String = ""
    @State private var downloadTask: Task<Void, Never>?
    @State private var isConverting: Bool = false
    @State private var conversionProgress: String = ""
    @State private var showConversionSheet: Bool = false

    /// Check model state for a specific version
    private func getModelState(for version: CivitAIModel.ModelVersion) -> ModelState {
        /// Check if currently downloading
        if downloadingVersionId == version.id {
            if isConverting {
                return .converting
            }
            return .downloading
        }

        /// Create friendly name and slug
        let friendlyName = "\(model.name) - \(version.name)"
        let slug = StableDiffusionModelManager.createSlug(from: friendlyName)

        /// Check filesystem
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let modelDir = cachesDir
            .appendingPathComponent("sam/models/stable-diffusion")
            .appendingPathComponent(slug)

        let safetensorsPath = modelDir.appendingPathComponent("model.safetensors")
        let coremlPath = modelDir.appendingPathComponent("original/compiled/Unet.mlmodelc")

        let hasSafetensors = FileManager.default.fileExists(atPath: safetensorsPath.path)
        let hasCoreML = FileManager.default.fileExists(atPath: coremlPath.path)

        if hasCoreML {
            return .converted
        } else if hasSafetensors {
            return .safetensorsOnly
        } else {
            return .notDownloaded
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            /// Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    if let creator = model.creator {
                        Text("by \(creator.username)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            /// Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    /// Link to CivitAI
                    HStack {
                        Link(destination: URL(string: "https://civitai.com/models/\(model.id)")!) {
                            Label("View on CivitAI", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                        Spacer()
                    }

                    /// Model info
                    if let description = model.description {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Description")
                                .font(.headline)

                            Text(stripHTML(description))
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }

                    /// Model versions
                    if let versions = model.modelVersions, !versions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Available Versions (\(versions.count))")
                                .font(.headline)

                            ForEach(versions) { version in
                                ModelVersionRow(
                                    version: version,
                                    modelState: getModelState(for: version),
                                    downloadProgress: downloadProgress,
                                    downloadStatus: downloadStatus,
                                    conversionProgress: conversionProgress,
                                    onDownloadOnly: { downloadVersionOnly(version) },
                                    onDownloadAndConvert: { downloadVersion(version) },  // Use legacy function for download+convert
                                    onConvert: { convertVersion(version) },
                                    onCancel: { cancelDownload() }
                                )
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 700, idealWidth: 800, maxWidth: .infinity,
               minHeight: 600, idealHeight: 700, maxHeight: .infinity)
        .sheet(isPresented: $showConversionSheet) {
            ConversionProgressSheet(
                modelName: model.name,
                progress: $conversionProgress,
                isShowing: $showConversionSheet
            )
        }
    }

    /// Strip HTML tags from description
    private func stripHTML(_ html: String) -> String {
        var result = html

        /// Remove HTML tags
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        /// Decode common HTML entities
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")

        /// Clean up excessive whitespace
        result = result.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sanitize model name for safe filesystem use
    /// Removes shell-unsafe characters like parentheses, brackets, quotes, etc.
    private func sanitizeModelName(_ name: String) -> String {
        /// Replace spaces with underscores
        var result = name.replacingOccurrences(of: " ", with: "_")

        /// Remove problematic shell characters
        let unsafeChars = CharacterSet(charactersIn: "()[]{}<>\"'`$!&|;\\")
        result = result.components(separatedBy: unsafeChars).joined()

        /// Limit length to prevent filesystem issues
        if result.count > 100 {
            result = String(result.prefix(100))
        }

        return result
    }

    /// Download model files only (no conversion)
    private func downloadVersionOnly(_ version: CivitAIModel.ModelVersion) {
        guard downloadingVersionId == nil else { return }

        downloadingVersionId = version.id
        downloadProgress = 0
        downloadStatus = "Preparing download..."

        downloadTask?.cancel()
        downloadTask = nil

        downloadTask = Task {
            do {
                /// Create friendly model name for metadata
                let friendlyName = "\(model.name) - \(version.name)"

                /// Create slug for directory name (URL-safe, no special chars)
                let slug = StableDiffusionModelManager.createSlug(from: friendlyName)
                let fileName = "model.safetensors"

                /// Use correct SAM models directory
                let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                let baseModelsDir = cachesDir.appendingPathComponent("sam/models/stable-diffusion")

                /// Create model-specific directory using slug
                let modelDir = baseModelsDir.appendingPathComponent(slug)
                try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

                /// Get download URL
                let downloadURL = version.files?.first?.downloadUrl ?? version.downloadUrl ?? ""
                guard !downloadURL.isEmpty else {
                    throw CivitAIError.downloadFailed("No download URL available")
                }

                /// Track progress
                let progressId = "civitai_\(version.id)"

                /// Start progress monitoring
                let progressMonitor = Task {
                    while !Task.isCancelled {
                        await MainActor.run {
                            if let progress = downloadManager.downloadProgress[progressId] {
                                self.downloadProgress = progress
                                self.downloadStatus = "Downloading \(Int(progress * 100))%"
                            }
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }

                /// Download file
                _ = try await downloadManager.downloadSDModel(
                    from: downloadURL,
                    filename: fileName,
                    destinationDir: modelDir,
                    progressId: progressId
                )

                progressMonitor.cancel()

                /// Save metadata
                let metadata = StableDiffusionModelManager.ModelMetadata(
                    originalName: friendlyName,
                    source: "civitai",
                    downloadDate: ISO8601DateFormatter().string(from: Date()),
                    version: version.name
                )
                let modelManager = StableDiffusionModelManager()
                try? modelManager.saveMetadata(metadata, for: modelDir)

                await MainActor.run {
                    self.downloadProgress = 1.0
                    self.downloadStatus = "Download complete!"
                    self.downloadingVersionId = nil
                    self.downloadTask = nil
                }
            } catch {
                await MainActor.run {
                    if !Task.isCancelled {
                        self.downloadStatus = "Download failed: \(error.localizedDescription)"
                    } else {
                        self.downloadStatus = "Cancelled"
                    }
                    self.downloadingVersionId = nil
                    self.downloadTask = nil
                }
            }
        }
    }

    /// Convert existing safetensors model to CoreML
    private func convertVersion(_ version: CivitAIModel.ModelVersion) {
        guard downloadingVersionId == nil else { return }

        downloadingVersionId = version.id
        isConverting = false
        conversionProgress = ""

        downloadTask?.cancel()
        downloadTask = nil

        downloadTask = Task {
            do {
                /// Get model directory
                let friendlyName = "\(model.name) - \(version.name)"
                let slug = StableDiffusionModelManager.createSlug(from: friendlyName)

                let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                let modelDir = cachesDir
                    .appendingPathComponent("sam/models/stable-diffusion")
                    .appendingPathComponent(slug)

                let safetensorsPath = modelDir.appendingPathComponent("model.safetensors")

                /// Verify safetensors exists
                guard FileManager.default.fileExists(atPath: safetensorsPath.path) else {
                    throw CivitAIError.downloadFailed("SafeTensors file not found")
                }

                await MainActor.run {
                    self.isConverting = true
                    self.showConversionSheet = true
                    self.conversionProgress = "Starting conversion..."
                }

                /// Convert to CoreML
                let success = try await convertToCoreML(
                    safetensorsPath: safetensorsPath.path,
                    outputDir: modelDir.path
                )

                if success {
                    try? reorganizeConvertedModel(at: modelDir)

                    await MainActor.run {
                        self.conversionProgress = "SUCCESS: Conversion complete! Model ready to use."
                        sdPrefLogger.info("Conversion complete: \(friendlyName)")
                        self.downloadingVersionId = nil
                        self.downloadTask = nil
                        self.isConverting = false
                    }

                    /// Sheet stays open - user must click Close button to acknowledge success
                } else {
                    await MainActor.run {
                        self.conversionProgress = "ERROR: Conversion process failed"
                        sdPrefLogger.error("Conversion failed for: \(friendlyName)")
                        self.downloadingVersionId = nil
                        self.downloadTask = nil
                        self.isConverting = false
                    }

                    /// Sheet stays open - user must click Close button to acknowledge error
                }
            } catch {
                await MainActor.run {
                    self.conversionProgress = "ERROR: Conversion failed - \(error.localizedDescription)"
                    sdPrefLogger.error("Conversion failed: \(error.localizedDescription)")
                    self.downloadingVersionId = nil
                    self.downloadTask = nil
                    self.isConverting = false
                }

                /// Sheet stays open - user must click Close button to acknowledge error
            }
        }
    }

    /// Download and convert model (legacy function for auto-convert mode)
    private func downloadVersion(_ version: CivitAIModel.ModelVersion) {
        guard downloadingVersionId == nil else { return }

        downloadingVersionId = version.id
        downloadProgress = 0
        downloadStatus = "Preparing download..."

        downloadTask?.cancel()
        downloadTask = nil

        downloadTask = Task {
            do {
                /// Create friendly model name for metadata
                let friendlyName = "\(model.name) - \(version.name)"

                /// Create slug for directory name (URL-safe, no special chars)
                let slug = StableDiffusionModelManager.createSlug(from: friendlyName)
                let fileName = "model.safetensors"  /// Standardized filename for all models

                /// Use correct SAM models directory (matches StableDiffusionModelManager)
                let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                let baseModelsDir = cachesDir.appendingPathComponent("sam/models/stable-diffusion")

                /// Create model-specific directory using slug
                let modelDir = baseModelsDir.appendingPathComponent(slug)
                try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

                /// Download .safetensors directly to model directory
                let downloadDir = modelDir

                /// Get download URL from first file or use version downloadUrl if available
                let downloadURL = version.files?.first?.downloadUrl ?? version.downloadUrl ?? ""
                guard !downloadURL.isEmpty else {
                    throw CivitAIError.downloadFailed("No download URL available")
                }

                /// Track progress ID
                let progressId = "civitai_\(version.id)"

                /// Start progress monitoring task
                let progressMonitor = Task {
                    while !Task.isCancelled {
                        await MainActor.run {
                            if let progress = downloadManager.downloadProgress[progressId] {
                                self.downloadProgress = progress
                                self.downloadStatus = "Downloading \(Int(progress * 100))%"
                            }
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    }
                }

                /// Use ModelDownloadManager for download
                let downloadedFile = try await downloadManager.downloadSDModel(
                    from: downloadURL,
                    filename: fileName,
                    destinationDir: downloadDir,
                    progressId: progressId
                )

                /// Stop progress monitoring
                progressMonitor.cancel()

                /// Final update
                await MainActor.run {
                    self.downloadProgress = 1.0
                    self.downloadStatus = "Download complete"
                }

                /// Save metadata with friendly name
                let metadata = StableDiffusionModelManager.ModelMetadata(
                    originalName: friendlyName,  /// Use the friendly name we created earlier
                    source: "civitai",
                    downloadDate: ISO8601DateFormatter().string(from: Date()),
                    version: version.name
                )
                let modelManager = StableDiffusionModelManager()
                try? modelManager.saveMetadata(metadata, for: modelDir)

                /// Step 2: Convert to Core ML
                await MainActor.run {
                    isConverting = true
                    showConversionSheet = true
                    downloadStatus = "Starting conversion to Core ML..."
                    conversionProgress = "Converting model \(friendlyName) to CoreML, please wait..."
                }

                /// Convert in the same directory (already created during download)
                /// model.safetensors is already in modelDir
                /// CoreML files will be written to modelDir/*.mlmodelc

                /// Run conversion script
                let success = try await convertToCoreML(
                    safetensorsPath: downloadedFile.path,
                    outputDir: modelDir.path
                )

                /// CRITICAL: Reorganize files if conversion used old structure
                if success {
                    try? reorganizeConvertedModel(at: modelDir)

                    /// NOTE: No need to move SafeTensors - it's already in the right place!
                    /// model.safetensors is in modelDir alongside *.mlmodelc files
                }

                await MainActor.run {
                    if success {
                        downloadStatus = "Conversion complete! Model ready to use."
                        sdPrefLogger.info("Model converted and organized successfully")
                    } else {
                        downloadStatus = "Conversion failed. Safetensors file saved to \(downloadedFile.path)"
                    }
                    downloadingVersionId = nil
                    downloadTask = nil
                    isConverting = false
                    showConversionSheet = false
                }
            } catch {
                await MainActor.run {
                    if !Task.isCancelled {
                        downloadStatus = isConverting
                            ? "Conversion failed: \(error.localizedDescription)"
                            : "Download failed: \(error.localizedDescription)"
                    } else {
                        downloadStatus = "Cancelled"
                    }
                    downloadingVersionId = nil
                    downloadTask = nil
                    isConverting = false
                    showConversionSheet = false
                }
            }
        }
    }

    /// Convert safetensors model to Core ML using Python script
    private func convertToCoreML(safetensorsPath: String, outputDir: String) async throws -> Bool {
        /// Try bundled Python venv first, fall back to system Python
        let bundledPython = Bundle.main.resourceURL?
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/python_env/bin/python3")
            .path

        let pythonPath = (bundledPython != nil && FileManager.default.fileExists(atPath: bundledPython!))
            ? bundledPython!
            : "/usr/bin/python3"

        let scriptPath = Bundle.main.resourceURL?
            .appendingPathComponent("convert_sd_to_coreml.py")
            .path ?? "scripts/convert_sd_to_coreml.py"

        sdPrefLogger.debug("Using Python: \(pythonPath)")
        sdPrefLogger.debug("Running conversion script: \(scriptPath)")
        sdPrefLogger.debug("Input: \(safetensorsPath)")
        sdPrefLogger.debug("Output: \(outputDir)")

        /// Run conversion script
        /// Python script creates 'original/compiled' structure internally
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        /// Pass output directory directly - script handles structure creation
        process.arguments = [scriptPath, safetensorsPath, outputDir]

        /// Capture output for progress updates
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        /// Monitor output in background
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading

        Task {
            for try await line in outputHandle.bytes.lines {
                await MainActor.run {
                    conversionProgress = String(line)
                    sdPrefLogger.info("Conversion output: \(line)")
                }
            }
        }

        Task {
            for try await line in errorHandle.bytes.lines {
                await MainActor.run {
                    /// Filter out INFO and WARNING messages - only log actual errors
                    /// Python conversion script outputs progress to stderr, not actual errors
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)

                    if trimmedLine.hasPrefix("ERROR:") || trimmedLine.hasPrefix("CRITICAL:") || trimmedLine.hasPrefix("Traceback") {
                        /// Actual error - log it
                        conversionProgress = String(line)
                        sdPrefLogger.error("Conversion error: \(line)")
                    } else if trimmedLine.hasPrefix("INFO:") || trimmedLine.hasPrefix("WARNING:") || trimmedLine.hasPrefix("DEBUG:") {
                        /// Informational message - log at appropriate level, don't show as error
                        if trimmedLine.hasPrefix("INFO:") {
                            sdPrefLogger.info("Conversion: \(line)")
                        } else if trimmedLine.hasPrefix("WARNING:") {
                            sdPrefLogger.warning("Conversion: \(line)")
                        } else {
                            sdPrefLogger.debug("Conversion: \(line)")
                        }
                        /// Don't update progress with INFO/WARNING messages
                    } else {
                        /// Unknown format - log as debug
                        sdPrefLogger.debug("Conversion output: \(line)")
                    }
                }
            }
        }

        try process.run()
        process.waitUntilExit()

        let success = process.terminationStatus == 0
        sdPrefLogger.debug("Conversion \(success ? "succeeded" : "failed") with status \(process.terminationStatus)")

        return success
    }

    /// Reorganize converted model from coreml/Resources to original/compiled structure
    /// This fixes models that were converted with older scripts or incomplete conversions
    private func reorganizeConvertedModel(at modelDir: URL) throws {
        let fileManager = FileManager.default

        /// Check if already in correct structure
        let correctPath = modelDir.appendingPathComponent("original/compiled")
        if fileManager.fileExists(atPath: correctPath.path) {
            sdPrefLogger.debug("Model already in correct structure: \(correctPath.path)")
            return
        }

        /// Check for incorrect structure: coreml/Resources
        let incorrectPath = modelDir.appendingPathComponent("coreml/Resources")
        guard fileManager.fileExists(atPath: incorrectPath.path) else {
            sdPrefLogger.debug("No reorganization needed, structure unknown")
            return
        }

        sdPrefLogger.debug("Reorganizing model from \(incorrectPath.path) to \(correctPath.path)")

        /// Create target directory
        try fileManager.createDirectory(at: correctPath, withIntermediateDirectories: true)

        /// Move all files from Resources to compiled
        let contents = try fileManager.contentsOfDirectory(at: incorrectPath, includingPropertiesForKeys: nil)
        for item in contents {
            let destination = correctPath.appendingPathComponent(item.lastPathComponent)

            /// Remove destination if exists
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            /// Move file
            try fileManager.moveItem(at: item, to: destination)
            sdPrefLogger.debug("  Moved \(item.lastPathComponent)")
        }

        /// Clean up coreml directory
        let coremlDir = modelDir.appendingPathComponent("coreml")
        if fileManager.fileExists(atPath: coremlDir.path) {
            try fileManager.removeItem(at: coremlDir)
            sdPrefLogger.debug("Cleaned up coreml directory")
        }

        sdPrefLogger.debug("Model reorganization complete")
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadingVersionId = nil
        downloadProgress = 0
        downloadStatus = ""
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Model Version Row

struct ModelVersionRow: View {
    typealias ModelState = CivitAIModelDetailView.ModelState

    let version: CivitAIModel.ModelVersion
    let modelState: ModelState
    let downloadProgress: Double
    let downloadStatus: String
    let conversionProgress: String
    let onDownloadOnly: () -> Void
    let onDownloadAndConvert: () -> Void
    let onConvert: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            /// Header row
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(version.name)
                        .font(.body)

                    if let baseModel = version.baseModel {
                        Text("Base: \(baseModel)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    /// Status badges
                    HStack(spacing: 8) {
                        if modelState == .converted {
                            Label("Converted", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else if modelState == .safetensorsOnly {
                            Label("Downloaded", systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                }

                Spacer()

                /// Action buttons (only when not downloading/converting)
                if modelState != .downloading && modelState != .converting {
                    actionButtons
                }
            }

            /// Progress section for active downloads/conversions
            if modelState == .downloading || modelState == .converting {
                progressView
            }
        }
        .padding()
        .background(backgroundColor)
        .cornerRadius(8)
    }

    /// Background color based on state
    private var backgroundColor: Color {
        switch modelState {
        case .downloading:
            return Color.green.opacity(0.1)
        case .converting:
            return Color.orange.opacity(0.1)
        default:
            return Color.blue.opacity(0.1)
        }
    }

    /// Action buttons based on state
    @ViewBuilder
    private var actionButtons: some View {
        switch modelState {
        case .notDownloaded:
            Button(action: onDownloadOnly) {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)

            Button(action: onDownloadAndConvert) {
                Label("+ Convert", systemImage: "gearshape.arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)

        case .safetensorsOnly:
            Button(action: onConvert) {
                Label("Convert to CoreML", systemImage: "gearshape.arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)

        case .converted:
            Button(action: onConvert) {
                Label("Re-convert", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)

        case .downloading, .converting:
            EmptyView()
        }
    }

    /// Progress view for downloads/conversions
    private var progressView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(modelState == .downloading ? "Downloading..." : "Converting to CoreML...")
                    .font(.headline)

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .disabled(modelState == .converting)  // Can't cancel during conversion
            }

            if modelState == .downloading {
                ProgressView(value: downloadProgress, total: 1.0) {
                    HStack {
                        Text("\(Int(downloadProgress * 100))%")
                            .font(.caption)

                        Spacer()

                        Text(downloadStatus)
                            .font(.caption)
                    }
                }
                .progressViewStyle(.linear)
            } else {
                ProgressView {
                    if !conversionProgress.isEmpty {
                        Text(conversionProgress)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
                .progressViewStyle(.linear)
            }
        }
    }
}

// MARK: - Hugging Face Browser View

struct HuggingFaceBrowserView: View {
    @EnvironmentObject private var downloadManager: ModelDownloadManager
    @AppStorage("huggingface_api_token") private var apiToken: String = ""

    @State private var searchQuery: String = ""
    @State private var models: [StableDiffusionIntegration.HFModel] = []
    @State private var isLoading: Bool = false
    @State private var selectedModel: StableDiffusionIntegration.HFModel?
    @State private var errorMessage: String?
    @State private var downloadedModelInfo: [String: (slug: String, hasSafeTensors: Bool, hasCoreML: Bool)] = [:]  /// Track downloaded models by HF model ID

    var body: some View {
        VStack(spacing: 0) {
            /// Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search HuggingFace models...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        performSearch()
                    }

                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { performSearch() }) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Search")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .frame(minWidth: 70)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            /// Results grid
            if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        performSearch()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                /// Show loading indicator while fetching models
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Searching HuggingFace...")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("This may take a moment")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if models.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Search HuggingFace models")
                        .font(.title3)
                    Text("Enter a search query or browse popular models")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)
                    ], spacing: 16) {
                        ForEach(models) { model in
                            HFModelCard(
                                model: model,
                                downloadInfo: downloadedModelInfo[model.modelId]
                            )
                            .onTapGesture {
                                selectedModel = model
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(item: $selectedModel) { model in
            HFModelDetailView(model: model)
                .environmentObject(downloadManager)
        }
        .onAppear {
            if models.isEmpty && searchQuery.isEmpty {
                performSearch()
            }
        }
    }

    private func performSearch() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let service = HuggingFaceService(apiToken: apiToken.isEmpty ? nil : apiToken)

                let results = try await service.searchModels(
                    query: searchQuery.isEmpty ? nil : searchQuery,
                    filter: "text-to-image",  // Generic filter for ALL image generation models
                    limit: 20,
                    sort: "downloads",
                    direction: "-1"
                )

                await MainActor.run {
                    models = results
                    isLoading = false
                }

                await scanDownloadedModels()
            } catch let error as StableDiffusionIntegration.HFError {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    models = []
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Search failed: \(error.localizedDescription)"
                    models = []
                    isLoading = false
                }
            }
        }
    }

    private func scanDownloadedModels() async {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let modelsDir = cachesDir.appendingPathComponent("sam/models/stable-diffusion")

        guard FileManager.default.fileExists(atPath: modelsDir.path) else { return }

        var downloadedInfo: [String: (slug: String, hasSafeTensors: Bool, hasCoreML: Bool)] = [:]

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: modelsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for modelDir in contents {
                guard let isDirectory = try? modelDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                      isDirectory else { continue }

                /// Read metadata to get original name and source
                let metadataPath = modelDir.appendingPathComponent(".sam_metadata.json")
                guard FileManager.default.fileExists(atPath: metadataPath.path),
                      let data = try? Data(contentsOf: metadataPath),
                      let metadata = try? JSONDecoder().decode(StableDiffusionModelManager.ModelMetadata.self, from: data),
                      metadata.source == "huggingface" else { continue }

                /// Check for safetensors and CoreML
                let hasSafeTensors = FileManager.default.fileExists(
                    atPath: modelDir.appendingPathComponent("model.safetensors").path
                )
                let hasCoreML = FileManager.default.fileExists(
                    atPath: modelDir.appendingPathComponent("original/compiled/Unet.mlmodelc").path
                )

                /// Match by display name from metadata
                let originalName = metadata.originalName

                /// Find matching HuggingFace model
                if let matchingModel = models.first(where: { hfModel in
                    hfModel.displayName == originalName
                }) {
                    downloadedInfo[matchingModel.modelId] = (
                        slug: modelDir.lastPathComponent,
                        hasSafeTensors: hasSafeTensors,
                        hasCoreML: hasCoreML
                    )
                }
            }
        } catch {
            sdPrefLogger.error("Failed to scan downloaded HuggingFace models: \(error.localizedDescription)")
        }

        await MainActor.run {
            downloadedModelInfo = downloadedInfo
        }
    }
}

// MARK: - HuggingFace Model Card

struct HFModelCard: View {
    let model: StableDiffusionIntegration.HFModel
    let downloadInfo: (slug: String, hasSafeTensors: Bool, hasCoreML: Bool)?  /// Download status info

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            /// Placeholder image (HF doesn't provide preview images like CivitAI)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.1))
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(model.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                )
                .frame(height: 150)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName)
                    .font(.headline)
                    .lineLimit(2)

                Text("by \(model.username)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    if let downloads = model.downloads {
                        Label("\(downloads)", systemImage: "arrow.down.circle")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    /// Download status badges
                    if let info = downloadInfo {
                        if info.hasCoreML {
                            Label("Converted", systemImage: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.green)
                        } else if info.hasSafeTensors {
                            Label("Downloaded", systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                    }

                    if let likes = model.likes {
                        Label("\(likes)", systemImage: "heart")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

// MARK: - HuggingFace Model Detail View

struct HFModelDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloadManager: ModelDownloadManager
    @AppStorage("huggingface_api_token") private var apiToken: String = ""
    @AppStorage("civitai_download_path") private var downloadPath: String = ""

    let model: StableDiffusionIntegration.HFModel
    @State private var files: [HFFile] = []
    @State private var isLoadingFiles: Bool = false
    @State private var downloadingFile: String?
    @State private var downloadProgress: Double = 0
    @State private var downloadedBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0
    @State private var downloadTask: Task<Void, Never>?
    @State private var isConverting: Bool = false
    @State private var convertingFile: String?
    @State private var conversionProgress: String = ""
    @State private var showConversionSheet: Bool = false
    @State private var fileStates: [String: ModelState] = [:]

    /// Repository download state
    @State private var isDownloadingRepository: Bool = false
    @State private var repositoryFilesDownloaded: Int = 0
    @State private var repositoryTotalFiles: Int = 0
    @State private var repositoryBytesDownloaded: Int64 = 0
    @State private var repositoryTotalBytes: Int64 = 0

    enum ModelState {
        case notDownloaded
        case safetensorsOnly
        case converted
        case downloading
        case converting
    }

    /// Get the state of a specific file
    private func getFileState(for file: HFFile) -> ModelState {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let slug = StableDiffusionModelManager.createSlug(from: model.displayName)
        let modelDir = cachesDir
            .appendingPathComponent("sam/models/stable-diffusion")
            .appendingPathComponent(slug)

        /// Use actual filename from HFFile instead of hardcoding
        let filename = file.path.components(separatedBy: "/").last ?? "model.safetensors"
        let safetensorsPath = modelDir.appendingPathComponent(filename)
        let coremlPath = modelDir.appendingPathComponent("original/compiled/Unet.mlmodelc")

        let hasSafetensors = FileManager.default.fileExists(atPath: safetensorsPath.path)
        let hasCoreML = FileManager.default.fileExists(atPath: coremlPath.path)

        if hasCoreML {
            return .converted
        } else if hasSafetensors {
            return .safetensorsOnly
        } else {
            return .notDownloaded
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            /// Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("by \(model.username)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            /// Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    /// Link to HuggingFace
                    HStack {
                        Link(destination: URL(string: "https://huggingface.co/\(model.modelId)")!) {
                            Label("View on HuggingFace", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                        Spacer()
                    }

                    /// Model info
                    HStack {
                        if let downloads = model.downloads {
                            Label("\(downloads) downloads", systemImage: "arrow.down.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let likes = model.likes {
                            Label("\(likes) likes", systemImage: "heart")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let pipelineTag = model.pipeline_tag {
                            Label(pipelineTag, systemImage: "tag")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        /// Show base model requirement for variants
                        if model.isVariant, let baseModelId = model.baseModelId {
                            Label("requires: \(baseModelId)", systemImage: "link")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }

                    /// Tags
                    if let tags = model.tags, !tags.isEmpty {
                        FlowLayout(spacing: 8) {
                            ForEach(tags.prefix(10), id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                    }

                    Divider()

                    /// Available files OR Repository download for multi-part models OR base model download
                    if isDownloadingRepository {
                        /// Show repository download progress (for multi-part OR base model downloads)
                        baseModelDownloadProgressView
                    } else if isMultiPartModel {
                        /// Multi-part model - show repository download UI
                        repositoryDownloadView
                    } else {
                        /// Single-file model - show individual files
                        individualFilesView
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 700, idealWidth: 800, maxWidth: .infinity,
               minHeight: 600, idealHeight: 700, maxHeight: .infinity)
        .sheet(isPresented: $showConversionSheet) {
            ConversionProgressSheet(
                modelName: model.displayName,
                progress: $conversionProgress,
                isShowing: $showConversionSheet
            )
        }
        .task {
            await loadFiles()
        }
    }

    /// Repository download view for multi-part models
    private var repositoryDownloadView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Multi-Component Model")
                .font(.headline)

            Text("This model requires downloading all components to function properly.")
                .font(.caption)
                .foregroundColor(.secondary)

            let requiredFiles = getRequiredFiles()
            let totalSize = requiredFiles.compactMap { $0.fileSize }.reduce(0, +)
            let sizeGB = Double(totalSize) / (1024 * 1024 * 1024)
            let isModelDownloaded = checkIfModelDownloaded()

            if !isDownloadingRepository {
                /// Download controls
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(requiredFiles.count) files")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.1f GB", sizeGB))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        /// Download button
                        Button(isModelDownloaded ? "Download Again" : "Download") {
                            downloadRepository()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoadingFiles)
                    }
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            } else {
                /// Show download progress
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Downloading Model...")
                            .font(.headline)
                        Spacer()
                        Button("Cancel") {
                            cancelDownload()
                        }
                        .buttonStyle(.bordered)
                    }

                    /// Progress bar
                    ProgressView(value: Double(repositoryFilesDownloaded), total: Double(repositoryTotalFiles)) {
                        HStack {
                            Text("Files: \(repositoryFilesDownloaded)/\(repositoryTotalFiles)")
                                .font(.caption)
                            Spacer()
                            let downloadedGB = Double(repositoryBytesDownloaded) / (1024 * 1024 * 1024)
                            let totalGB = Double(repositoryTotalBytes) / (1024 * 1024 * 1024)
                            Text(String(format: "%.1f / %.1f GB", downloadedGB, totalGB))
                                .font(.caption)
                        }
                    }
                    .progressViewStyle(.linear)

                    /// Current file being downloaded
                    if let currentFile = downloadingFile {
                        Text("Downloading: \(currentFile)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }

    /// Base model download progress view (for single-file variants)
    private var baseModelDownloadProgressView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Downloading Base Model Components")
                .font(.headline)

            Text("Downloading essential components for variant model")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Downloading...")
                        .font(.headline)
                    Spacer()
                    Button("Cancel") {
                        cancelDownload()
                    }
                    .buttonStyle(.bordered)
                }

                /// Progress bar
                ProgressView(value: Double(repositoryFilesDownloaded), total: Double(repositoryTotalFiles)) {
                    HStack {
                        Text("Files: \(repositoryFilesDownloaded)/\(repositoryTotalFiles)")
                            .font(.caption)
                        Spacer()
                        let downloadedGB = Double(repositoryBytesDownloaded) / (1024 * 1024 * 1024)
                        let totalGB = Double(repositoryTotalBytes) / (1024 * 1024 * 1024)
                        Text(String(format: "%.1f / %.1f GB", downloadedGB, totalGB))
                            .font(.caption)
                    }
                }
                .progressViewStyle(.linear)

                /// Current file being downloaded
                if let currentFile = downloadingFile {
                    Text(currentFile)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
        }
    }

    /// Individual files view for single-file models
    private var individualFilesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Available Files")
                    .font(.headline)

                if isLoadingFiles {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                Spacer()
            }

            if files.isEmpty && !isLoadingFiles {
                Text("No supported model files found (.safetensors, .mlmodelc, .zip)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(files.filter { $0.isSupportedSDFormat }) { file in
                    HFFileRow(
                        file: file,
                        model: model,
                        modelState: fileStates[file.path] ?? getFileState(for: file),
                        isDownloading: downloadingFile == file.path,
                        isConverting: isConverting && convertingFile == file.path,
                        downloadProgress: downloadProgress,
                        downloadedBytes: downloadedBytes,
                        totalBytes: totalBytes,
                        onDownloadOnly: { downloadFile(file, autoConvert: false) },
                        onDownloadAndConvert: { downloadFile(file, autoConvert: true) },
                        onDownloadWithBase: model.isVariant && file.isSafetensors && !isMultiPartModel
                            ? { downloadFileWithBase(file) }
                            : nil,
                        onConvert: { convertExistingSafetensors(for: file) },
                        onCancel: { cancelDownload() }
                    )
                }
            }
        }
    }

    /// Sanitize model name for safe filesystem use
    /// Removes shell-unsafe characters like parentheses, brackets, quotes, etc.
    private func sanitizeModelName(_ name: String) -> String {
        /// Replace spaces with underscores
        var result = name.replacingOccurrences(of: " ", with: "_")

        /// Remove problematic shell characters
        let unsafeChars = CharacterSet(charactersIn: "()[]{}<>\"'`$!&|;\\")
        result = result.components(separatedBy: unsafeChars).joined()

        /// Limit length to prevent filesystem issues
        if result.count > 100 {
            result = String(result.prefix(100))
        }

        return result
    }

    private func loadFiles() async {
        isLoadingFiles = true

        do {
            let service = HuggingFaceService(apiToken: apiToken.isEmpty ? nil : apiToken)
            let loadedFiles = try await service.listModelFiles(modelId: model.modelId)

            await MainActor.run {
                files = loadedFiles
                isLoadingFiles = false
            }
        } catch {
            await MainActor.run {
                isLoadingFiles = false
            }
        }
    }

    /// Check if model is a multi-part diffusers repository
    private var isMultiPartModel: Bool {
        files.contains { $0.path == "model_index.json" }
    }

    /// Get required files for multi-part model based on model_index.json
    private func getRequiredFiles() -> [HFFile] {
        guard isMultiPartModel else { return [] }

        /// Required files for diffusers models
        let requiredPaths = [
            "model_index.json",
            "README.md"
        ]

        /// Required directories (download all files within these)
        let requiredDirs = [
            "transformer/",
            "unet/",
            "vae/",
            "text_encoder/",
            "text_encoder_2/",
            "scheduler/",
            "tokenizer/",
            "tokenizer_2/",
            "feature_extractor/",
            "safety_checker/"
        ]

        return files.filter { file in
            /// Include specific required files
            if requiredPaths.contains(file.path) {
                return true
            }

            /// Include all files in required directories
            for dir in requiredDirs {
                if file.path.hasPrefix(dir) {
                    return true
                }
            }

            return false
        }
    }

    /// Check if the base model is already downloaded
    private func checkIfModelDownloaded() -> Bool {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let slug = StableDiffusionModelManager.createSlug(from: model.displayName)
        let modelDir = cachesDir
            .appendingPathComponent("sam/models/stable-diffusion")
            .appendingPathComponent(slug)

        /// Check if model_index.json exists (indicates diffusers model)
        let modelIndexPath = modelDir.appendingPathComponent("model_index.json")
        return FileManager.default.fileExists(atPath: modelIndexPath.path)
    }

    /// Download all required files for a multi-part diffusers repository
    /// Automatically uses hierarchical downloads when base_model is detected
    private func downloadRepository() {
        /// Check if this model references a base model
        let useHierarchical = model.isVariant

        if useHierarchical, let baseModelId = model.baseModelId {
            sdPrefLogger.info("Detected variant model with base: \(baseModelId)")
            downloadRepositoryHierarchical(baseModelId: baseModelId)
        } else {
            downloadRepositoryStandard()
        }
    }

    /// Standard (non-hierarchical) repository download
    private func downloadRepositoryStandard() {
        let requiredFiles = getRequiredFiles()
        guard !requiredFiles.isEmpty else {
            sdPrefLogger.warning("No required files found for repository download")
            return
        }

        /// Create model directory
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let slug = StableDiffusionModelManager.createSlug(from: model.displayName)
        let modelDir = cachesDir
            .appendingPathComponent("sam/models/stable-diffusion")
            .appendingPathComponent(slug)

        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        /// Initialize repository download state
        isDownloadingRepository = true
        repositoryFilesDownloaded = 0
        repositoryTotalFiles = requiredFiles.count
        repositoryBytesDownloaded = 0
        repositoryTotalBytes = requiredFiles.compactMap { $0.fileSize }.reduce(0, +)
        downloadingFile = nil

        downloadTask = Task {
            var filesDownloaded = 0
            var bytesDownloaded: Int64 = 0
            let totalFilesCount = requiredFiles.count

            do {
                for file in requiredFiles {
                    /// Check if cancelled
                    try Task.checkCancellation()

                    /// Update UI to show current file
                    await MainActor.run {
                        downloadingFile = file.path
                    }

                    /// Download this file
                    let downloadURL = "https://huggingface.co/\(model.modelId)/resolve/main/\(file.path)"

                    /// Determine destination path (preserve directory structure)
                    let destinationPath: URL
                    if file.path.contains("/") {
                        /// File in subdirectory - create subdirectory
                        let components = file.path.components(separatedBy: "/")
                        let subdirs = components.dropLast()
                        var subPath = modelDir
                        for subdir in subdirs {
                            subPath = subPath.appendingPathComponent(subdir)
                        }
                        try? FileManager.default.createDirectory(at: subPath, withIntermediateDirectories: true)
                        destinationPath = subPath.appendingPathComponent(components.last!)
                    } else {
                        /// File in root
                        destinationPath = modelDir.appendingPathComponent(file.path)
                    }

                    /// Download file
                    sdPrefLogger.info("Downloading \(file.path)...")

                    let progressId = "hf_repo_\(model.modelId)_\(file.path)"
                    let downloadedFile = try await downloadManager.downloadSDModel(
                        from: downloadURL,
                        filename: file.path.components(separatedBy: "/").last ?? file.path,
                        destinationDir: destinationPath.deletingLastPathComponent(),
                        progressId: progressId
                    )

                    filesDownloaded += 1
                    if let fileSize = file.fileSize {
                        bytesDownloaded += fileSize
                    }

                    await MainActor.run {
                        repositoryFilesDownloaded = filesDownloaded
                        repositoryBytesDownloaded = bytesDownloaded
                        sdPrefLogger.info("Downloaded \(filesDownloaded)/\(totalFilesCount): \(file.path)")
                    }
                }

                /// Save metadata
                let metadataPath = modelDir.appendingPathComponent(".sam_metadata.json")
                let metadata = StableDiffusionModelManager.ModelMetadata(
                    originalName: model.displayName,
                    source: "huggingface",
                    downloadDate: ISO8601DateFormatter().string(from: Date()),
                    version: nil
                )
                let modelManager = StableDiffusionModelManager()
                try? modelManager.saveMetadata(metadata, for: modelDir)

                await MainActor.run {
                    isDownloadingRepository = false
                    downloadingFile = nil
                    sdPrefLogger.info("Repository download complete: \(model.displayName)")

                    /// Refresh file states
                    for file in requiredFiles {
                        fileStates[file.path] = .safetensorsOnly
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloadingRepository = false
                    downloadingFile = nil
                    sdPrefLogger.error("Repository download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Hierarchical repository download (variant + base model)
    private func downloadRepositoryHierarchical(baseModelId: String) {
        /// Initialize repository download state
        isDownloadingRepository = true
        repositoryFilesDownloaded = 0
        repositoryBytesDownloaded = 0
        downloadingFile = nil

        downloadTask = Task {
            do {
                let service = HuggingFaceService(apiToken: apiToken.isEmpty ? nil : apiToken)

                /// Get base model details
                sdPrefLogger.info("Fetching base model: \(baseModelId)")
                let baseModel = try await service.getModelDetails(modelId: baseModelId)

                /// Get file lists from both repos
                sdPrefLogger.info("Listing variant files: \(model.modelId)")
                let variantFiles = try await service.listModelFiles(modelId: model.modelId)

                sdPrefLogger.info("Listing base files: \(baseModelId)")
                let baseFiles = try await service.listModelFiles(modelId: baseModelId)

                /// Categorize files for hierarchical download
                let (filesToDownloadFromVariant, filesToDownloadFromBase) = service.categorizeHierarchicalFiles(
                    variantModel: model,
                    variantFiles: variantFiles,
                    baseModel: baseModel,
                    baseFiles: baseFiles
                )

                let totalFiles = filesToDownloadFromVariant.count + filesToDownloadFromBase.count
                let totalBytes = filesToDownloadFromVariant.compactMap { $0.fileSize }.reduce(0, +) +
                                filesToDownloadFromBase.compactMap { $0.fileSize }.reduce(0, +)

                await MainActor.run {
                    repositoryTotalFiles = totalFiles
                    repositoryTotalBytes = totalBytes
                }

                sdPrefLogger.info("Hierarchical download plan:")
                sdPrefLogger.info("  Variant files: \(filesToDownloadFromVariant.count)")
                sdPrefLogger.info("  Base files: \(filesToDownloadFromBase.count)")
                sdPrefLogger.info("  Total: \(totalFiles) files, \(formatBytes(totalBytes))")

                /// Create model directory
                let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                let slug = StableDiffusionModelManager.createSlug(from: model.displayName)
                let modelDir = cachesDir
                    .appendingPathComponent("sam/models/stable-diffusion")
                    .appendingPathComponent(slug)

                try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

                var filesDownloaded = 0
                var bytesDownloaded: Int64 = 0

                /// Download variant files first
                for file in filesToDownloadFromVariant {
                    try Task.checkCancellation()

                    await MainActor.run {
                        downloadingFile = "variant: \(file.path)"
                    }

                    sdPrefLogger.info("Downloading from variant: \(file.path)")

                    let downloadURL = "https://huggingface.co/\(model.modelId)/resolve/main/\(file.path)"
                    let destination = modelDir.appendingPathComponent(file.path)
                    let destinationDir = destination.deletingLastPathComponent()

                    try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

                    let progressId = "hf_hierarchical_variant_\(model.modelId)_\(file.path)"
                    _ = try await downloadManager.downloadSDModel(
                        from: downloadURL,
                        filename: (file.path as NSString).lastPathComponent,
                        destinationDir: destinationDir,
                        progressId: progressId
                    )

                    filesDownloaded += 1
                    if let fileSize = file.fileSize {
                        bytesDownloaded += fileSize
                    }

                    await MainActor.run {
                        repositoryFilesDownloaded = filesDownloaded
                        repositoryBytesDownloaded = bytesDownloaded
                    }
                }

                /// Download base model files
                for file in filesToDownloadFromBase {
                    try Task.checkCancellation()

                    await MainActor.run {
                        downloadingFile = "base: \(file.path)"
                    }

                    sdPrefLogger.info("Downloading from base: \(file.path)")

                    let downloadURL = "https://huggingface.co/\(baseModelId)/resolve/main/\(file.path)"
                    let destination = modelDir.appendingPathComponent(file.path)
                    let destinationDir = destination.deletingLastPathComponent()

                    try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

                    let progressId = "hf_hierarchical_base_\(baseModelId)_\(file.path)"
                    _ = try await downloadManager.downloadSDModel(
                        from: downloadURL,
                        filename: (file.path as NSString).lastPathComponent,
                        destinationDir: destinationDir,
                        progressId: progressId
                    )

                    filesDownloaded += 1
                    if let fileSize = file.fileSize {
                        bytesDownloaded += fileSize
                    }

                    await MainActor.run {
                        repositoryFilesDownloaded = filesDownloaded
                        repositoryBytesDownloaded = bytesDownloaded
                    }
                }

                /// Save metadata with hierarchical info
                let metadataPath = modelDir.appendingPathComponent(".sam_metadata.json")
                let metadata = StableDiffusionModelManager.ModelMetadata(
                    originalName: model.displayName,
                    source: "huggingface",
                    downloadDate: ISO8601DateFormatter().string(from: Date()),
                    version: nil,
                    baseModel: baseModelId,
                    downloadType: "hierarchical"
                )
                let modelManager = StableDiffusionModelManager()
                try? modelManager.saveMetadata(metadata, for: modelDir)

                await MainActor.run {
                    isDownloadingRepository = false
                    downloadingFile = nil

                    let spaceSaved = (variantFiles.compactMap { $0.fileSize }.reduce(0, +) +
                                     baseFiles.compactMap { $0.fileSize }.reduce(0, +)) - totalBytes

                    sdPrefLogger.info("Hierarchical download complete: \(model.displayName)")
                    sdPrefLogger.info("Space saved: \(formatBytes(spaceSaved))")
                }

            } catch {
                await MainActor.run {
                    isDownloadingRepository = false
                    downloadingFile = nil
                    sdPrefLogger.error("Hierarchical download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func downloadFile(_ file: HFFile, autoConvert: Bool = false) {
        let filename = file.path.components(separatedBy: "/").last ?? file.path

        /// Create model-specific directory in models/stable-diffusion using slug from friendly name
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let slug = StableDiffusionModelManager.createSlug(from: model.displayName)
        let modelDir = cachesDir
            .appendingPathComponent("sam/models/stable-diffusion")
            .appendingPathComponent(slug)

        /// Create directory if needed
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let basePath = modelDir

        downloadingFile = file.path
        fileStates[file.path] = .downloading
        downloadProgress = 0
        downloadedBytes = 0
        totalBytes = file.fileSize ?? 0

        downloadTask = Task {
            do {
                /// Construct HuggingFace download URL
                let downloadURL = "https://huggingface.co/\(model.modelId)/resolve/main/\(file.path)"

                /// Track progress ID
                let progressId = "hf_\(model.modelId)_\(filename)"

                /// Start progress monitoring task
                let progressMonitor = Task {
                    while !Task.isCancelled {
                        await MainActor.run {
                            if let progress = downloadManager.downloadProgress[progressId] {
                                self.downloadProgress = progress
                                if let totalBytes = file.fileSize {
                                    self.downloadedBytes = Int64(Double(totalBytes) * progress)
                                    self.totalBytes = totalBytes
                                }
                            }
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    }
                }

                /// Use ModelDownloadManager for download
                let downloadedFile = try await downloadManager.downloadSDModel(
                    from: downloadURL,
                    filename: filename,
                    destinationDir: basePath,
                    progressId: progressId
                )

                /// Stop progress monitoring
                progressMonitor.cancel()

                /// Save metadata with friendly name (if first download for this model)
                /// (reuse the slug we created earlier)

                let metadataPath = modelDir.appendingPathComponent(".sam_metadata.json")
                if !FileManager.default.fileExists(atPath: metadataPath.path) {
                    let metadata = StableDiffusionModelManager.ModelMetadata(
                        originalName: model.displayName,
                        source: "huggingface",
                        downloadDate: ISO8601DateFormatter().string(from: Date()),
                        version: nil
                    )
                    let modelManager = StableDiffusionModelManager()
                    try? modelManager.saveMetadata(metadata, for: modelDir)
                }

                await MainActor.run {
                    downloadingFile = nil
                    downloadProgress = 1.0

                    if !autoConvert {
                        /// Only mark as downloaded if not auto-converting
                        fileStates[file.path] = .safetensorsOnly
                    }

                    /// Handle different file types
                    Task {
                        await handleDownloadedFile(file: file, path: downloadedFile.path, autoConvert: autoConvert)
                    }
                }
            } catch {
                await MainActor.run {
                    downloadingFile = nil
                    fileStates[file.path] = getFileState(for: file)
                }
            }
        }
    }

    /// Download variant file AND base model components in one bundled operation
    private func downloadFileWithBase(_ file: HFFile) {
        guard model.isVariant, let baseModelId = model.baseModelId else {
            sdPrefLogger.warning("downloadFileWithBase called but model is not a variant")
            return
        }

        let filename = file.path.components(separatedBy: "/").last ?? file.path

        /// Create model directory
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let slug = StableDiffusionModelManager.createSlug(from: model.displayName)
        let modelDir = cachesDir
            .appendingPathComponent("sam/models/stable-diffusion")
            .appendingPathComponent(slug)

        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        /// Set repository download mode to show progress
        isDownloadingRepository = true
        repositoryFilesDownloaded = 0
        repositoryBytesDownloaded = 0
        downloadingFile = nil

        downloadTask = Task {
            do {
                let service = HuggingFaceService(apiToken: apiToken.isEmpty ? nil : apiToken)

                /// Get base model details and files
                sdPrefLogger.info("Fetching base model: \\(baseModelId)")
                let baseModel = try await service.getModelDetails(modelId: baseModelId)
                let baseFiles = try await service.listModelFiles(modelId: baseModelId)
                let variantFiles = try await service.listModelFiles(modelId: model.modelId)

                /// Use hierarchical categorization
                let (_, filesToDownloadFromBase) = service.categorizeHierarchicalFiles(
                    variantModel: model,
                    variantFiles: variantFiles,
                    baseModel: baseModel,
                    baseFiles: baseFiles
                )

                /// Total: variant file + base files
                let totalFiles = 1 + filesToDownloadFromBase.count
                let variantBytes = file.fileSize ?? 0
                let baseBytes = filesToDownloadFromBase.compactMap { $0.fileSize }.reduce(0, +)
                let totalBytes = variantBytes + baseBytes

                await MainActor.run {
                    repositoryTotalFiles = totalFiles
                    repositoryTotalBytes = totalBytes
                }

                sdPrefLogger.info("Bundled download: variant + base")
                sdPrefLogger.info("  Variant: 1 file (\(formatBytes(variantBytes)))")
                sdPrefLogger.info("  Base: \(filesToDownloadFromBase.count) files (\(formatBytes(baseBytes)))")
                sdPrefLogger.info("  Total: \(totalFiles) files (\(formatBytes(totalBytes)))")

                var filesDownloaded = 0
                var bytesDownloaded: Int64 = 0

                /// STEP 1: Download variant file DIRECTLY to transformer/ directory
                /// Create transformer directory first
                let transformerDir = modelDir.appendingPathComponent("transformer")
                try FileManager.default.createDirectory(at: transformerDir, withIntermediateDirectories: true)

                await MainActor.run {
                    downloadingFile = "variant: \(file.path)"
                }

                let variantURL = "https://huggingface.co/\(model.modelId)/resolve/main/\(file.path)"
                let progressId = "hf_bundled_variant_\(model.modelId)_\(filename)"

                /// Start progress monitoring task for continuous byte-level updates
                let progressMonitor = Task { @MainActor in
                    while !Task.isCancelled {
                        if let progress = downloadManager.downloadProgress[progressId], progress < 1.0 {
                            let currentBytes = Int64(Double(variantBytes) * progress)
                            repositoryBytesDownloaded = bytesDownloaded + currentBytes
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000) // Update every 0.1s
                    }
                }

                /// Download directly to transformer/ and rename to diffusion_pytorch_model.safetensors
                _ = try await downloadManager.downloadSDModel(
                    from: variantURL,
                    filename: "diffusion_pytorch_model.safetensors",
                    destinationDir: transformerDir,
                    progressId: progressId
                )

                /// Stop progress monitoring
                progressMonitor.cancel()

                filesDownloaded += 1
                bytesDownloaded += variantBytes

                await MainActor.run {
                    repositoryFilesDownloaded = filesDownloaded
                    repositoryBytesDownloaded = bytesDownloaded
                    fileStates[file.path] = .safetensorsOnly
                }

                /// STEP 2: Download base model components
                for baseFile in filesToDownloadFromBase {
                    try Task.checkCancellation()

                    await MainActor.run {
                        downloadingFile = "base: \(baseFile.path)"
                    }

                    sdPrefLogger.info("Downloading from base: \(baseFile.path)")

                    let downloadURL = "https://huggingface.co/\(baseModelId)/resolve/main/\(baseFile.path)"
                    let destination = modelDir.appendingPathComponent(baseFile.path)
                    let destinationDir = destination.deletingLastPathComponent()

                    try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

                    let baseProgressId = "hf_bundled_base_\(baseModelId)_\(baseFile.path)"
                    let baseFileSize = baseFile.fileSize ?? 0

                    /// Start progress monitoring for continuous byte-level updates
                    let baseProgressMonitor = Task { @MainActor in
                        while !Task.isCancelled {
                            if let progress = downloadManager.downloadProgress[baseProgressId], progress < 1.0 {
                                let currentBytes = Int64(Double(baseFileSize) * progress)
                                repositoryBytesDownloaded = bytesDownloaded + currentBytes
                            }
                            try? await Task.sleep(nanoseconds: 100_000_000) // Update every 0.1s
                        }
                    }

                    _ = try await downloadManager.downloadSDModel(
                        from: downloadURL,
                        filename: (baseFile.path as NSString).lastPathComponent,
                        destinationDir: destinationDir,
                        progressId: baseProgressId
                    )

                    /// Stop progress monitoring
                    baseProgressMonitor.cancel()

                    filesDownloaded += 1
                    bytesDownloaded += baseFileSize

                    await MainActor.run {
                        repositoryFilesDownloaded = filesDownloaded
                        repositoryBytesDownloaded = bytesDownloaded
                    }
                }

                /// STEP 3: Download transformer/config.json from base
                await MainActor.run {
                    downloadingFile = "base: transformer/config.json"
                }

                sdPrefLogger.info("Downloading transformer/config.json from base")
                let transformerConfigURL = "https://huggingface.co/\(baseModelId)/resolve/main/transformer/config.json"

                let configProgressId = "hf_bundled_base_\(baseModelId)_transformer_config"
                _ = try await downloadManager.downloadSDModel(
                    from: transformerConfigURL,
                    filename: "config.json",
                    destinationDir: transformerDir,
                    progressId: configProgressId
                )

                filesDownloaded += 1
                await MainActor.run {
                    repositoryFilesDownloaded = filesDownloaded
                }

                /// Save metadata
                let metadata = StableDiffusionModelManager.ModelMetadata(
                    originalName: model.displayName,
                    source: "huggingface",
                    downloadDate: ISO8601DateFormatter().string(from: Date()),
                    version: nil,
                    baseModel: baseModelId,
                    downloadType: "variant+base"
                )
                let modelManager = StableDiffusionModelManager()
                try? modelManager.saveMetadata(metadata, for: modelDir)

                await MainActor.run {
                    isDownloadingRepository = false
                    downloadingFile = nil

                    sdPrefLogger.info("Bundled download complete: \(model.displayName)")
                    sdPrefLogger.info("  Variant + base merged in: \(slug)")
                }

            } catch {
                await MainActor.run {
                    isDownloadingRepository = false
                    downloadingFile = nil
                    sdPrefLogger.error("Bundled download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        /// Remove fileStates entry to force re-scan on next access
        if let file = downloadingFile {
            fileStates.removeValue(forKey: file)
        }
        downloadingFile = nil
        downloadProgress = 0
        downloadedBytes = 0
        totalBytes = 0

        /// Reset repository download state
        isDownloadingRepository = false
        repositoryFilesDownloaded = 0
        repositoryTotalFiles = 0
        repositoryBytesDownloaded = 0
        repositoryTotalBytes = 0
    }

    private func handleDownloadedFile(file: HFFile, path: String, autoConvert: Bool = false) async {
        let fileURL = URL(fileURLWithPath: path)

        if file.isCoreML {
            // CoreML model - move to models directory with proper structure
            await moveCoreMLModel(from: fileURL, modelName: model.displayName)
        } else if file.isZip {
            // ZIP file - extract and check for CoreML models
            await extractAndProcessZip(from: fileURL, modelName: model.displayName)
        } else if file.isSafetensors {
            // Safetensors downloaded
            sdPrefLogger.info("Safetensors file downloaded: \(path)")

            if autoConvert {
                // Set convertingFile before starting conversion
                await MainActor.run {
                    convertingFile = file.path
                }

                // Trigger automatic conversion
                sdPrefLogger.info("Starting automatic conversion to CoreML...")
                await convertToCoreMl(safetensorsPath: fileURL)
            } else {
                sdPrefLogger.info("Model ready. Use 'Convert to CoreML' button to convert.")
            }
        }
    }

    private func moveCoreMLModel(from sourceURL: URL, modelName: String) async {
        let modelsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sam/models/stable-diffusion")

        let modelDir = modelsDir.appendingPathComponent(modelName)
        let compiledDir = modelDir.appendingPathComponent("original/compiled")

        do {
            // Create directory structure
            try FileManager.default.createDirectory(at: compiledDir, withIntermediateDirectories: true)

            // Move CoreML model
            let destURL = compiledDir.appendingPathComponent(sourceURL.lastPathComponent)
            try FileManager.default.moveItem(at: sourceURL, to: destURL)

            sdPrefLogger.info("Moved CoreML model to: \(destURL.path)")

            // Trigger model registry update
            NotificationCenter.default.post(name: NSNotification.Name("RefreshStableDiffusionModels"), object: nil)
        } catch {
            sdPrefLogger.error("Failed to move CoreML model: \(error)")
        }
    }

    private func extractAndProcessZip(from zipURL: URL, modelName: String) async {
        let extractDir = zipURL.deletingPathExtension()

        do {
            // Extract ZIP
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", "-q", zipURL.path, "-d", extractDir.path]

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                sdPrefLogger.error("Failed to extract ZIP file")
                return
            }

            // Look for CoreML models and support files in extracted contents
            let contents = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)

            // Get all .mlmodelc directories AND support files (vocab.json, merges.txt)
            let filesToMove = contents.filter { url in
                url.pathExtension == "mlmodelc" ||
                url.pathExtension == "mlpackage" ||
                url.lastPathComponent == "vocab.json" ||
                url.lastPathComponent == "merges.txt"
            }

            if !filesToMove.isEmpty {
                // Found CoreML models and support files - organize them
                await organizeCoreMLModels(models: filesToMove, modelName: modelName)

                // Clean up ZIP
                try? FileManager.default.removeItem(at: zipURL)
                try? FileManager.default.removeItem(at: extractDir)
            } else {
                sdPrefLogger.warning("No CoreML models found in ZIP file")
            }
        } catch {
            sdPrefLogger.error("Failed to process ZIP file: \(error)")
        }
    }

    private func organizeCoreMLModels(models: [URL], modelName: String) async {
        let modelsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sam/models/stable-diffusion")

        let modelDir = modelsDir.appendingPathComponent(modelName)
        let compiledDir = modelDir.appendingPathComponent("original/compiled")

        do {
            try FileManager.default.createDirectory(at: compiledDir, withIntermediateDirectories: true)

            for modelURL in models {
                let destURL = compiledDir.appendingPathComponent(modelURL.lastPathComponent)

                // Skip if already exists
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try? FileManager.default.removeItem(at: destURL)
                }

                try FileManager.default.moveItem(at: modelURL, to: destURL)
                sdPrefLogger.info("Moved component: \(modelURL.lastPathComponent)")
            }

            // Check if tokenizer files are present, if not copy from reference
            let tokenizerFiles = ["vocab.json", "merges.txt"]
            let missingTokenizerFiles = tokenizerFiles.filter { file in
                !FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent(file).path)
            }

            if !missingTokenizerFiles.isEmpty {
                sdPrefLogger.info("Missing tokenizer files, copying from reference model")
                let referenceModel = modelsDir.appendingPathComponent("coreml-stable-diffusion-v1-5/original/compiled")

                for file in missingTokenizerFiles {
                    let sourceURL = referenceModel.appendingPathComponent(file)
                    let destURL = compiledDir.appendingPathComponent(file)

                    if FileManager.default.fileExists(atPath: sourceURL.path) {
                        try? FileManager.default.copyItem(at: sourceURL, to: destURL)
                        sdPrefLogger.info("Copied tokenizer file: \(file)")
                    } else {
                        sdPrefLogger.warning("Reference tokenizer file not found: \(file)")
                    }
                }
            }

            // Trigger model registry update
            NotificationCenter.default.post(name: NSNotification.Name("RefreshStableDiffusionModels"), object: nil)
            NotificationCenter.default.post(name: .stableDiffusionModelInstalled, object: nil, userInfo: ["modelPath": modelDir.path])
        } catch {
            sdPrefLogger.error("Failed to organize CoreML models: \(error)")
        }
    }

    /// Convert safetensors to CoreML (auto-conversion for HuggingFace downloads)
    private func convertSafetensorsToCoreML(safetensorsPath: URL, modelName: String) async {
        await MainActor.run {
            isConverting = true
            /// Don't set convertingFile here - it should already be set by caller
            /// to match the file.path from HFFileRow
            fileStates[safetensorsPath.lastPathComponent] = .converting
            showConversionSheet = true
            conversionProgress = "Starting conversion..."
        }

        let modelsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sam/models/stable-diffusion")

        let modelDir = modelsDir.appendingPathComponent(modelName)
        let outputDir = modelDir.appendingPathComponent("original/compiled")

        do {
            // Create output directory
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

            await MainActor.run {
                conversionProgress = "Running Python conversion script..."
            }

            // Get Python path
            let bundledPython = Bundle.main.resourceURL?
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/python_env/bin/python3")
                .path

            let pythonPath = (bundledPython != nil && FileManager.default.fileExists(atPath: bundledPython!))
                ? bundledPython!
                : "/usr/bin/python3"

            let scriptPath = Bundle.main.resourceURL?
                .appendingPathComponent("convert_sd_to_coreml.py")
                .path ?? "scripts/convert_sd_to_coreml.py"

            // Run conversion
            // CRITICAL: Pass base model directory, NOT outputDir
            // Python script creates 'original/compiled' structure internally
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = [scriptPath, safetensorsPath.path, modelDir.path]

            // Capture output
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            // Monitor progress
            let outputHandle = outputPipe.fileHandleForReading
            let errorHandle = errorPipe.fileHandleForReading

            /// Actor for thread-safe state tracking (replaces NSLock for Swift 6 concurrency)
            actor ProcessingState {
                var hasFinished = false
                
                func checkAndUpdate() -> Bool {
                    return !hasFinished
                }
                
                func markFinished() {
                    hasFinished = true
                }
            }
            
            let processingState = ProcessingState()

            /// Track stream tasks so we can wait for them to complete
            let outputTask = Task {
                for try await line in outputHandle.bytes.lines {
                    let shouldUpdate = await processingState.checkAndUpdate()

                    if shouldUpdate {
                        await MainActor.run {
                            conversionProgress = String(line)
                            sdPrefLogger.info("HF Conversion: \(line)")
                        }
                    }
                }
            }

            let errorTask = Task {
                for try await line in errorHandle.bytes.lines {
                    /// Filter stderr by log level - Python conversion outputs progress to stderr
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    let isActualError = trimmedLine.hasPrefix("ERROR:") || trimmedLine.hasPrefix("CRITICAL:") || trimmedLine.hasPrefix("Traceback")
                    let isInfo = trimmedLine.hasPrefix("INFO:")
                    let isWarning = trimmedLine.hasPrefix("WARNING:")

                    await MainActor.run {
                        /// Log at appropriate level based on message prefix
                        if isActualError {
                            sdPrefLogger.error("HF Conversion error: \(line)")
                        } else if isWarning {
                            sdPrefLogger.warning("HF Conversion: \(line)")
                        } else if isInfo {
                            sdPrefLogger.info("HF Conversion: \(line)")
                        } else {
                            sdPrefLogger.debug("HF Conversion output: \(line)")
                        }
                    }

                    let shouldUpdate = await processingState.checkAndUpdate()

                    if shouldUpdate {
                        await MainActor.run {
                            /// Prefer lines that look like actual error messages
                            /// (contain exception class name with "Error:" or contain ": " which indicates error messages)
                            let looksLikeError = line.contains("Error:") ||
                                                (line.contains(": ") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("File ") &&
                                                !line.trimmingCharacters(in: .whitespaces).hasPrefix("at "))

                            if looksLikeError {
                                /// Extract just the error message part after the colon
                                if let colonIndex = line.lastIndex(of: ":") {
                                    let errorMessage = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                                    if !errorMessage.isEmpty {
                                        conversionProgress = "ERROR: \(errorMessage)"
                                    } else {
                                        conversionProgress = "ERROR: \(line)"
                                    }
                                } else {
                                    conversionProgress = "ERROR: \(line)"
                                }
                            } else if !conversionProgress.hasPrefix("ERROR:") {
                                /// Only overwrite with non-error lines if we don't already have an error
                                conversionProgress = String(line)
                            }
                        }
                    }
                }
            }

            try process.run()
            process.waitUntilExit()

            /// Wait for stream tasks to complete reading all output
            try await outputTask.value
            try await errorTask.value

            /// Mark as finished to prevent any further updates
            await processingState.markFinished()

            if process.terminationStatus == 0 {
                await MainActor.run {
                    conversionProgress = "SUCCESS: Conversion complete! Model ready to use."
                    sdPrefLogger.info("HuggingFace model converted successfully: \(modelName)")
                    isConverting = false
                    if let file = convertingFile {
                        fileStates[file] = .converted
                    }
                    convertingFile = nil
                }

                // Trigger registry update
                NotificationCenter.default.post(name: NSNotification.Name("RefreshStableDiffusionModels"), object: nil)
                NotificationCenter.default.post(name: .stableDiffusionModelInstalled, object: nil, userInfo: ["modelPath": modelDir.path])

                /// Sheet stays open - user must click Close button to acknowledge success
            } else {
                await MainActor.run {
                    /// Only set generic error if stderr didn't already set a specific error
                    if !conversionProgress.hasPrefix("ERROR:") {
                        conversionProgress = "ERROR: Conversion process failed (status \(process.terminationStatus))"
                    }
                    sdPrefLogger.error("HuggingFace model conversion failed with status \(process.terminationStatus)")
                    isConverting = false
                    if let file = convertingFile {
                        fileStates[file] = .safetensorsOnly
                    }
                    convertingFile = nil
                }

                /// Sheet stays open - user must click Close button to acknowledge error
            }

        } catch {
            await MainActor.run {
                conversionProgress = "ERROR: Conversion failed - \(error.localizedDescription)"
                sdPrefLogger.error("HuggingFace conversion error: \(error.localizedDescription)")
                isConverting = false
                if let file = convertingFile {
                    fileStates[file] = .safetensorsOnly
                }
                convertingFile = nil
            }

            /// Sheet stays open - user must click Close button to acknowledge error
        }
    }

    /// Convert to CoreML (used when autoConvert is true after download)
    private func convertToCoreMl(safetensorsPath: URL) async {
        await convertSafetensorsToCoreML(safetensorsPath: safetensorsPath, modelName: model.displayName)
    }

    /// Convert existing SafeTensors to CoreML (used when user clicks "Convert" button)
    private func convertExistingSafetensors(for file: HFFile) {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let slug = StableDiffusionModelManager.createSlug(from: model.displayName)
        let modelDir = cachesDir
            .appendingPathComponent("sam/models/stable-diffusion")
            .appendingPathComponent(slug)

        /// Find the actual SafeTensors file (don't hardcode filename)
        /// Use the filename from the HFFile which has the correct name
        let filename = file.path.components(separatedBy: "/").last ?? "model.safetensors"
        let safetensorsPath = modelDir.appendingPathComponent(filename)

        /// Verify file exists before attempting conversion
        guard FileManager.default.fileExists(atPath: safetensorsPath.path) else {
            sdPrefLogger.error("Cannot convert: SafeTensors file not found at \(safetensorsPath.path)")
            return
        }

        Task {
            // Set convertingFile before starting conversion
            await MainActor.run {
                convertingFile = file.path
            }
            await convertToCoreMl(safetensorsPath: safetensorsPath)
        }
    }
}

// MARK: - HuggingFace File Row

struct HFFileRow: View {
    let file: HFFile
    let model: StableDiffusionIntegration.HFModel
    let modelState: HFModelDetailView.ModelState
    let isDownloading: Bool
    let isConverting: Bool
    let downloadProgress: Double
    let downloadedBytes: Int64
    let totalBytes: Int64
    let onDownloadOnly: () -> Void
    let onDownloadAndConvert: () -> Void
    let onDownloadWithBase: (() -> Void)?
    let onConvert: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            /// Header row
            HStack {
                Image(systemName: file.isCoreML ? "cube.fill" : file.isZip ? "doc.zipper" : "doc.fill")
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(file.path)
                            .font(.system(.body, design: .monospaced))

                        if file.isCoreML {
                            Text("CoreML")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .cornerRadius(3)
                        } else if file.isZip {
                            Text("Archive")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2))
                                .foregroundColor(.orange)
                                .cornerRadius(3)
                        }
                    }

                    if let size = file.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                /// Action buttons
                if !isDownloading && !isConverting {
                    actionButtons
                }
            }

            /// Progress section for active downloads/conversions
            if isDownloading || isConverting {
                progressView
            }
        }
        .padding()
        .background(backgroundColor)
        .cornerRadius(8)
    }

    /// Background color based on state
    private var backgroundColor: Color {
        if isDownloading {
            return Color.green.opacity(0.1)
        } else if isConverting {
            return Color.orange.opacity(0.1)
        } else {
            return Color.blue.opacity(0.1)
        }
    }

    /// Action buttons based on state
    @ViewBuilder
    private var actionButtons: some View {
        if file.isSafetensors {
            switch modelState {
            case .notDownloaded:
                Button(action: onDownloadOnly) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)

                /// Show + Base button for variant models
                if let downloadWithBase = onDownloadWithBase {
                    Button(action: downloadWithBase) {
                        Label("+ Base", systemImage: "link.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(action: onDownloadAndConvert) {
                        Label("+ Convert", systemImage: "gearshape.arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .safetensorsOnly:
                Button(action: onConvert) {
                    Label("Convert to CoreML", systemImage: "gearshape.arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)

            case .converted:
                Button(action: onConvert) {
                    Label("Re-convert", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)

            case .downloading, .converting:
                EmptyView()
            }
        } else {
            /// For CoreML or ZIP files
            Button(action: onDownloadOnly) {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
        }
    }

    /// Progress view for downloads/conversions
    private var progressView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isDownloading ? "Downloading..." : "Converting...")
                    .font(.headline)

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
            }

            ProgressView(value: downloadProgress, total: 1.0) {
                HStack {
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption)

                    Spacer()

                    if totalBytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                            .font(.caption)
                    }
                }
            }
            .progressViewStyle(.linear)
        }
    }
}

// MARK: - Settings View

struct SDSettingsView: View {
    @AppStorage("civitai_api_key") private var civitaiAPIKey: String = ""
    @AppStorage("civitai_nsfw_filter") private var nsfwFilter: Bool = true

    /// ALICE remote server settings
    @AppStorage("alice_base_url") private var aliceBaseURL: String = ""
    @AppStorage("alice_api_key") private var aliceApiKey: String = ""

    @State private var isTestingConnection: Bool = false
    @State private var connectionTestResult: ConnectionTestResult?
    @State private var aliceModels: [APIFramework.ALICEModel] = []

    enum ConnectionTestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                /// ALICE Remote Server Settings
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "network")
                            .foregroundColor(.accentColor)
                        Text("ALICE Remote Server")
                            .font(.headline)
                    }

                    Text("Connect to a remote ALICE server for GPU-accelerated image generation (AMD/Linux)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server URL")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("http://192.168.1.100:8000/v1", text: $aliceBaseURL)
                                .textFieldStyle(.roundedBorder)

                            Button(action: testConnection) {
                                if isTestingConnection {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Test")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(aliceBaseURL.isEmpty || isTestingConnection)
                        }

                        Text("Example: http://192.168.1.100:8000/v1 or http://remotecomputer.local:8000/v1")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key (Optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        SecureField("Leave empty if not required", text: $aliceApiKey)
                            .textFieldStyle(.roundedBorder)

                        Text("Required only if your ALICE server has authentication enabled")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    /// Connection test result
                    if let result = connectionTestResult {
                        switch result {
                        case .success(let message):
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text(message)
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                            .padding(8)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(6)
                        case .failure(let message):
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text(message)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .padding(8)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(6)
                        }
                    }

                    /// Available models (shown after successful connection)
                    if !aliceModels.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Available Models (\(aliceModels.count))")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(aliceModels) { model in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(model.displayName)
                                                .font(.caption)
                                                .fontWeight(.medium)
                                            Text(model.isSDXL ? "SDXL" : "SD 1.5")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(8)
                                        .background(Color.accentColor.opacity(0.1))
                                        .cornerRadius(6)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)

                Divider()

                /// CivitAI Settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("CivitAI")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        SecureField("Optional", text: $civitaiAPIKey)
                            .textFieldStyle(.roundedBorder)

                        Text("Optional - Enables access to NSFW content, higher rate limits, and some exclusive models")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                /// Content Filter
                VStack(alignment: .leading, spacing: 12) {
                    Text("Content Filter")
                        .font(.headline)

                    Toggle(isOn: $nsfwFilter) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("NSFW Content Filter")
                            Text("Filter NSFW models from search AND enable safety filter for image generation")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
            .padding(24)
        }
    }

    func testConnection() {
        guard !aliceBaseURL.isEmpty else { return }

        isTestingConnection = true
        connectionTestResult = nil
        aliceModels = []

        Task {
            do {
                let provider = ALICEProvider(
                    baseURL: aliceBaseURL,
                    apiKey: aliceApiKey.isEmpty ? nil : aliceApiKey
                )

                /// Test health first
                let health = try await provider.checkHealth()

                /// Fetch available models
                let models = try await provider.fetchAvailableModels()

                await MainActor.run {
                    aliceModels = models
                    connectionTestResult = .success("Connected! Server v\(health.version), GPU: \(health.gpuAvailable ? "Yes" : "No"), \(models.count) model(s)")
                    isTestingConnection = false

                    /// Set shared provider for global access
                    ALICEProvider.shared = provider
                }
            } catch {
                await MainActor.run {
                    connectionTestResult = .failure(error.localizedDescription)
                    isTestingConnection = false

                    /// Clear shared provider on failure
                    ALICEProvider.shared = nil
                }
            }
        }
    }
}

// MARK: - LoRA Browser View

struct LoRABrowserView: View {
    @EnvironmentObject private var downloadManager: ModelDownloadManager
    @StateObject private var loraManager = LoRAManager()
    @StateObject private var stableDiffusionModelManager = StableDiffusionModelManager()
    @AppStorage("civitai_nsfw_filter") private var nsfwFilter: Bool = true

    @State private var searchQuery: String = ""
    @State private var baseModelFilter: String = ""
    @State private var allLoRAs: [CivitAIModel] = []  /// All loaded LoRAs from CivitAI
    @State private var allHFLoRAs: [StableDiffusionIntegration.HFModel] = []  /// All loaded LoRAs from HuggingFace
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var selectedLoRA: CivitAIModel?
    @State private var selectedHFLoRA: StableDiffusionIntegration.HFModel?
    @State private var showConversionDialog: Bool = false
    @State private var viewMode: LoRAViewMode = .library  /// Default to Library view
    @State private var currentPage: Int = 1  /// Pagination for CivitAI
    @State private var hasMoreResults: Bool = true  /// Track if more results available

    enum LoRAViewMode: String, CaseIterable {
        case library = "Library"
        case civitai = "CivitAI"
        case huggingface = "HuggingFace"
    }

    /// Filtered search results based on search query, base model, and NSFW settings
    private var filteredSearchResults: [CivitAIModel] {
        var results = allLoRAs

        /// Local search filtering
        if !searchQuery.isEmpty {
            let query = searchQuery.lowercased()
            results = results.filter { model in
                model.name.lowercased().contains(query) ||
                model.description?.lowercased().contains(query) == true ||
                model.tags?.contains(where: { $0.lowercased().contains(query) }) == true
            }
        }

        /// Apply NSFW filter
        if nsfwFilter {
            results = results.filter { !$0.isNSFW() }
        }

        /// Apply base model filter
        if !baseModelFilter.isEmpty {
            results = results.filter { model in
                if let versions = model.modelVersions {
                    return versions.contains { version in
                        version.baseModel?.contains(baseModelFilter) ?? false
                    }
                }
                return false
            }
        }

        return results
    }

    /// Filtered HuggingFace results
    private var filteredHFResults: [StableDiffusionIntegration.HFModel] {
        var results = allHFLoRAs

        /// Local search filtering
        if !searchQuery.isEmpty {
            let query = searchQuery.lowercased()
            results = results.filter { model in
                model.modelId.lowercased().contains(query) ||
                model.tags?.contains(where: { $0.lowercased().contains(query) }) == true
            }
        }

        /// Apply base model filter
        if !baseModelFilter.isEmpty {
            results = results.filter { model in
                if let baseModel = model.baseModelId {
                    return baseModel.lowercased().contains(baseModelFilter.lowercased())
                }
                return false
            }
        }

        return results
    }

    var body: some View {
        VStack(spacing: 0) {
            /// View mode selector
            Picker("View", selection: $viewMode) {
                ForEach(LoRAViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .onChange(of: viewMode) { _, newMode in
                /// Pre-load searches when switching tabs
                if newMode == .civitai && allLoRAs.isEmpty {
                    loadCivitAILoRAs(page: 1)
                } else if newMode == .huggingface && allHFLoRAs.isEmpty {
                    loadHuggingFaceLoRAs()
                }
            }

            Divider()

            /// Content based on view mode
            if viewMode == .library {
                libraryView
            } else if viewMode == .civitai {
                civitaiSearchView
            } else {
                huggingfaceSearchView
            }
        }
        .sheet(item: $selectedLoRA) { lora in
            LoRADetailView(lora: lora, loraManager: loraManager)
                .environmentObject(downloadManager)
        }
        .sheet(item: $selectedHFLoRA) { lora in
            HFLoRADetailView(lora: lora, loraManager: loraManager)
                .environmentObject(downloadManager)
        }
        .sheet(isPresented: $showConversionDialog) {
            LoRAConversionDialog(loraManager: loraManager, modelManager: stableDiffusionModelManager)
        }
        .onAppear {
            /// Reload LoRAs when view appears
            loraManager.loadLoRAs()

            ///  Load all LoRAs from CivitAI on first appearance (for search view)
            if allLoRAs.isEmpty && viewMode == .civitai {
                loadCivitAILoRAs(page: 1)
            }
            if allHFLoRAs.isEmpty && viewMode == .huggingface {
                loadHuggingFaceLoRAs()
            }
        }
    }

    /// Library view - shows downloaded LoRAs
    private var libraryView: some View {
        VStack(spacing: 0) {
            /// Header with fusion button
            HStack {
                Text("Downloaded LoRAs (\(loraManager.availableLoRAs.count))")
                    .font(.headline)

                Spacer()

                Button(action: { showConversionDialog = true }) {
                    Label("Fuse with Model", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(loraManager.availableLoRAs.isEmpty || stableDiffusionModelManager.listInstalledModels().isEmpty)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            /// LoRA list
            if loraManager.availableLoRAs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No LoRAs downloaded")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("Switch to Search tab to browse and download LoRAs from CivitAI")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(loraManager.availableLoRAs) { lora in
                        LoRALibraryRow(lora: lora, loraManager: loraManager)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    /// CivitAI Search view - browse and download from CivitAI
    private var civitaiSearchView: some View {
        VStack(spacing: 0) {
            /// Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search LoRAs...", text: $searchQuery)
                    .textFieldStyle(.plain)

                if !searchQuery.isEmpty {
                    Button(action: {
                        searchQuery = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    allLoRAs = []
                    currentPage = 1
                    hasMoreResults = true
                    loadCivitAILoRAs(page: 1)
                }) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .help("Reload LoRAs from CivitAI")
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))

            /// Base model filter
            HStack {
                Text("Base Model:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("", selection: $baseModelFilter) {
                    Text("All").tag("")
                    Text("SD 1.5").tag("SD 1.5")
                    Text("SD 2.x").tag("SD 2")
                    Text("SDXL").tag("SDXL")
                    Text("Z-Image").tag("Z-Image")
                    Text("Flux").tag("Flux")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
                .font(.system(.caption, design: .monospaced))

                Spacer()

                /// Show count
                if !allLoRAs.isEmpty {
                    Text("Showing \(filteredSearchResults.count) of \(allLoRAs.count) LoRAs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            /// Search results
            if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        allLoRAs = []
                        currentPage = 1
                        loadCivitAILoRAs(page: 1)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allLoRAs.isEmpty && !isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Load LoRAs from CivitAI")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("Click to load popular LoRAs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Load LoRAs") {
                        loadCivitAILoRAs(page: 1)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading && allLoRAs.isEmpty {
                /// Show loading indicator while fetching LoRAs
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading LoRAs from CivitAI...")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("This may take a moment")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSearchResults.isEmpty && !allLoRAs.isEmpty {
                /// Show message when filters hide all results
                VStack(spacing: 12) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("All results filtered")
                        .font(.title3)
                    Text("All search results were filtered by your settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if nsfwFilter {
                        Text("NSFW filter is active")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)
                        ], spacing: 16) {
                            ForEach(filteredSearchResults, id: \.id) { lora in
                                Button(action: {
                                    selectedLoRA = lora
                                }) {
                                    LoRASearchResultCard(lora: lora)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)

                        /// Load More button
                        if hasMoreResults && !isLoading {
                            Button(action: {
                                loadCivitAILoRAs(page: currentPage + 1)
                            }) {
                                Label("Load More LoRAs", systemImage: "arrow.down.circle")
                                    .padding()
                            }
                            .buttonStyle(.bordered)
                            .padding(.bottom, 16)
                        }

                        if isLoading && !allLoRAs.isEmpty {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading more...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                        }
                    }
                }
            }
        }
    }

    /// HuggingFace Search view - browse and download from HuggingFace
    private var huggingfaceSearchView: some View {
        VStack(spacing: 0) {
            /// Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search HuggingFace LoRAs...", text: $searchQuery)
                    .textFieldStyle(.plain)

                if !searchQuery.isEmpty {
                    Button(action: {
                        searchQuery = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { loadHuggingFaceLoRAs() }) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .help("Reload LoRAs from HuggingFace")
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))

            /// Base model filter
            HStack {
                Text("Base Model:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("", selection: $baseModelFilter) {
                    Text("All").tag("")
                    Text("SD 1.5").tag("SD 1.5")
                    Text("SD 2.x").tag("SD 2")
                    Text("SDXL").tag("SDXL")
                    Text("Z-Image").tag("Z-Image")
                    Text("Flux").tag("Flux")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
                .font(.system(.caption, design: .monospaced))

                Spacer()

                /// Show count
                if !allHFLoRAs.isEmpty {
                    let filtered = filteredHFResults
                    Text("Showing \(filtered.count) of \(allHFLoRAs.count) LoRAs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            /// Search results
            if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        loadHuggingFaceLoRAs()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allHFLoRAs.isEmpty && !isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Load LoRAs from HuggingFace")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("Search for LoRA models on HuggingFace")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Load LoRAs") {
                        loadHuggingFaceLoRAs()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading LoRAs from HuggingFace...")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("This may take a moment")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredHFResults.isEmpty && !allHFLoRAs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("All results filtered")
                        .font(.title3)
                    Text("All search results were filtered by your settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)
                    ], spacing: 16) {
                        ForEach(filteredHFResults, id: \.id) { lora in
                            Button(action: {
                                selectedHFLoRA = lora
                            }) {
                                HFLoRASearchResultCard(lora: lora)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func loadCivitAILoRAs(page: Int) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let service = CivitAIService()

                sdPrefLogger.info("Loading LoRAs from CivitAI (page \(page))...")

                /// Load LoRAs with pagination
                let response = try await service.searchLoRAs(
                    query: nil,  /// No search query - get all
                    baseModel: nil,  /// Don't filter by base model in API
                    limit: 100,  /// CivitAI API max is 100
                    page: page,
                    sort: "Highest Rated",
                    nsfw: nsfwFilter ? false : nil
                )

                sdPrefLogger.info("Loaded \(response.items.count) items from CivitAI (page \(page))")

                await MainActor.run {
                    /// Filter to only LoRAs (API might return other types)
                    let newLoRAs = response.items.filter { $0.type == "LORA" }

                    if page == 1 {
                        allLoRAs = newLoRAs
                    } else {
                        allLoRAs.append(contentsOf: newLoRAs)
                    }

                    currentPage = page
                    /// If we got fewer than limit, there are no more results
                    hasMoreResults = response.items.count >= 100

                    isLoading = false
                    sdPrefLogger.info("Now have \(allLoRAs.count) total LoRAs loaded")
                }
            } catch {
                sdPrefLogger.error("Failed to load LoRAs: \(error.localizedDescription)")
                await MainActor.run {
                    errorMessage = "Load failed: \(error.localizedDescription)"
                    if page == 1 {
                        allLoRAs = []
                    }
                    isLoading = false
                }
            }
        }
    }

    private func loadHuggingFaceLoRAs() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let service = HuggingFaceService()

                sdPrefLogger.info("Loading LoRAs from HuggingFace...")

                /// Load LoRAs - service already filters for lora tag
                let models = try await service.searchLoRAs(
                    query: searchQuery.isEmpty ? nil : searchQuery,
                    limit: 100,
                    sort: "downloads",
                    direction: "-1"
                )

                sdPrefLogger.info("Loaded \(models.count) LoRA models from HuggingFace")

                await MainActor.run {
                    allHFLoRAs = models
                    isLoading = false
                }
            } catch {
                sdPrefLogger.error("Failed to load HF LoRAs: \(error.localizedDescription)")
                await MainActor.run {
                    errorMessage = "Load failed: \(error.localizedDescription)"
                    allHFLoRAs = []
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - LoRA Library Row

struct LoRALibraryRow: View {
    let lora: LoRAManager.LoRAInfo
    let loraManager: LoRAManager
    @State private var showDeleteAlert = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(lora.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Text(lora.baseModel)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text("\(formatBytes(Int64(lora.sizeKB * 1024)))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { showDeleteAlert = true }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Delete LoRA")
        }
        .padding(.vertical, 4)
        .alert("Delete LoRA?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                do {
                    try loraManager.deleteLoRA(lora)
                } catch {
                    sdPrefLogger.error("Failed to delete LoRA: \(error.localizedDescription)")
                }
            }
        } message: {
            Text("Are you sure you want to delete \(lora.name)? This cannot be undone.")
        }
    }
}

// MARK: - LoRA Search Result Card

struct LoRASearchResultCard: View {
    let lora: CivitAIModel
    @State private var imageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            /// Preview image
            Group {
                if let url = imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 150)
                                .clipped()
                        case .failure:
                            placeholderImage
                        case .empty:
                            ProgressView()
                                .frame(height: 150)
                        @unknown default:
                            placeholderImage
                        }
                    }
                } else {
                    placeholderImage
                }
            }
            .frame(height: 150)
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(lora.name)
                    .font(.headline)
                    .lineLimit(2)

                if let creator = lora.creator {
                    Text("by \(creator.username)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let version = lora.modelVersions?.first,
                   let baseModel = version.baseModel {
                    HStack {
                        Label(baseModel, systemImage: "tag")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 2)
        .onAppear {
            if let firstVersion = lora.modelVersions?.first,
               let firstImage = firstVersion.images?.first,
               let url = URL(string: firstImage.url) {
                imageURL = url
            }
        }
    }

    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.2))
            .overlay(
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
            )
    }
}

// MARK: - LoRA Detail View

struct LoRADetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloadManager: ModelDownloadManager

    let lora: CivitAIModel
    let loraManager: LoRAManager

    @State private var selectedVersion: CivitAIModel.ModelVersion?
    @State private var downloading = false
    @State private var downloadProgress: Double = 0
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            /// Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lora.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    if let creator = lora.creator {
                        Text("by \(creator.username)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            /// Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    /// Link to CivitAI
                    HStack {
                        Link(destination: URL(string: "https://civitai.com/models/\(lora.id)")!) {
                            Label("View on CivitAI", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                        Spacer()
                    }

                    /// Base model warning
                    if let version = selectedVersion ?? lora.modelVersions?.first,
                       let baseModel = version.baseModel {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Requires base model: \(baseModel)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Make sure you have a compatible \(baseModel) model installed")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }

                    /// Description (with HTML stripping)
                    if let description = lora.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Description")
                                .font(.headline)
                            Text(stripHTMLFromDescription(description))
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                    }

                    /// Versions
                    if let versions = lora.modelVersions, !versions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Versions")
                                .font(.headline)

                            ForEach(versions) { version in
                                LoRAVersionRow(version: version, isSelected: selectedVersion?.id == version.id)
                                    .onTapGesture {
                                        selectedVersion = version
                                    }
                            }
                        }
                    }

                    /// Trigger words
                    if let version = selectedVersion ?? lora.modelVersions?.first,
                       let triggerWords = version.trainedWords, !triggerWords.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Trigger Words")
                                .font(.headline)

                            FlowLayout(spacing: 8) {
                                ForEach(triggerWords, id: \.self) { word in
                                    Text(word)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.1))
                                        .cornerRadius(6)
                                }
                            }
                        }
                    }

                    if let error = errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                .padding()
            }

            Divider()

            /// Footer with download button
            HStack {
                if downloading {
                    ProgressView(value: downloadProgress)
                        .frame(maxWidth: .infinity)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Spacer()

                    Button(action: { downloadLoRA() }) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedVersion == nil && lora.modelVersions?.first == nil)
                }
            }
            .padding()
        }
        .frame(width: 600, height: 700)
        .onAppear {
            selectedVersion = lora.modelVersions?.first
        }
    }

    /// Sanitize a string for use in filenames by removing/replacing invalid characters
    private func sanitizeFilename(_ input: String) -> String {
        /// Handle empty input
        if input.isEmpty {
            return "unnamed"
        }

        /// Characters that are invalid in filenames across platforms
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")

        /// Replace spaces with underscores, remove invalid chars, collapse multiple underscores
        var sanitized = input
            .replacingOccurrences(of: " ", with: "_")
            .components(separatedBy: invalidChars)
            .joined(separator: "_")

        /// Remove any null characters or other control characters
        sanitized = sanitized.filter { !$0.isASCII || ($0.asciiValue ?? 0) >= 32 }

        /// Collapse multiple underscores into single underscore
        while sanitized.contains("__") {
            sanitized = sanitized.replacingOccurrences(of: "__", with: "_")
        }

        /// Remove leading/trailing underscores
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        /// Ensure non-empty result
        return sanitized.isEmpty ? "unnamed" : sanitized
    }

    /// Strip HTML tags from description
    private func stripHTMLFromDescription(_ html: String) -> String {
        var result = html

        /// Remove HTML tags
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        /// Decode common HTML entities
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")

        /// Clean up excessive whitespace
        result = result.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func downloadLoRA() {
        guard let version = selectedVersion ?? lora.modelVersions?.first,
              let file = version.files?.first(where: { $0.type == "Model" || $0.type == "Primary" }) else {
            errorMessage = "No download file available"
            return
        }

        let downloadURL = version.downloadUrl ?? file.downloadUrl

        downloading = true
        errorMessage = nil

        Task {
            do {
                let progressId = "lora_\(version.id)"

                /// Sanitize filename components to prevent path issues
                let sanitizedName = sanitizeFilename(lora.name)
                let sanitizedVersion = sanitizeFilename(version.name)

                /// Build filename - ensure we have valid components
                var filename: String
                if sanitizedVersion.isEmpty || sanitizedVersion == "unnamed" {
                    /// Version name was empty or invalid - use ID as fallback
                    filename = "\(sanitizedName)_v\(version.id).safetensors"
                } else {
                    filename = "\(sanitizedName)_\(sanitizedVersion).safetensors"
                }

                /// Validate filename has extension
                if !filename.hasSuffix(".safetensors") {
                    filename += ".safetensors"
                }

                /// Log paths for debugging
                sdPrefLogger.info("LoRA download starting")
                sdPrefLogger.info("  Destination dir: \(loraManager.loraDirectory.path)")
                sdPrefLogger.info("  Filename: \(filename)")
                sdPrefLogger.info("  Download URL: \(downloadURL)")

                /// Ensure LoRA directory exists
                try FileManager.default.createDirectory(
                    at: loraManager.loraDirectory,
                    withIntermediateDirectories: true
                )
                sdPrefLogger.info("LoRA directory created/verified")

                /// Start download using ModelDownloadManager
                let downloadedFile = try await downloadManager.downloadSDModel(
                    from: downloadURL,
                    filename: filename,
                    destinationDir: loraManager.loraDirectory,
                    progressId: progressId
                )

                sdPrefLogger.info("Download complete: \(downloadedFile.path)")

                /// Create metadata
                let metadata = LoRAMetadata(
                    id: "\(version.id)",
                    name: lora.name,
                    baseModel: version.baseModel ?? "Unknown",
                    triggerWords: version.trainedWords ?? [],
                    civitaiId: "\(lora.id)",
                    previewImageURL: version.images?.first?.url,
                    description: lora.description
                )

                /// Register with LoRAManager
                sdPrefLogger.info("Registering LoRA: \(filename)")
                _ = try loraManager.registerDownloadedLoRA(filename: filename, metadata: metadata)
                sdPrefLogger.info("LoRA registered successfully")

                await MainActor.run {
                    downloading = false
                    dismiss()
                }
            } catch {
                sdPrefLogger.error("LoRA download/registration failed: \(error.localizedDescription)")
                await MainActor.run {
                    downloading = false
                    errorMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }

        /// Monitor progress
        Task {
            let progressId = "lora_\(selectedVersion?.id ?? 0)"
            while downloading {
                await MainActor.run {
                    downloadProgress = downloadManager.downloadProgress[progressId] ?? 0
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

// MARK: - LoRA Version Row

struct LoRAVersionRow: View {
    let version: CivitAIModel.ModelVersion
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(version.name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)

                HStack {
                    if let baseModel = version.baseModel {
                        Text(baseModel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let file = version.files?.first {
                        Text(formatBytes(Int64(file.sizeKB * 1024)))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }
}

// Helper function for formatting bytes
private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

// MARK: - LoRA Conversion Dialog

struct LoRAConversionDialog: View {
    @Environment(\.dismiss) private var dismiss

    let loraManager: LoRAManager
    let modelManager: StableDiffusionModelManager

    @State private var selectedBaseModel: StableDiffusionModelManager.ModelInfo?
    @State private var selectedLoRAs: Set<LoRAManager.LoRAInfo> = []
    @State private var loraScales: [String: Double] = [:]
    @State private var fusedModelName: String = ""
    @State private var isConverting: Bool = false
    @State private var conversionLog: String = ""
    @State private var conversionProgress: String = ""
    @State private var conversionError: String?

    private var availableBaseModels: [StableDiffusionModelManager.ModelInfo] {
        modelManager.listInstalledModels()
    }

    /// Filter LoRAs compatible with selected base model
    private var compatibleLoRAs: [LoRAManager.LoRAInfo] {
        guard let baseModel = selectedBaseModel else {
            return loraManager.availableLoRAs
        }

        let baseModelArch = detectArchitecture(variant: baseModel.variant)

        return loraManager.availableLoRAs.filter { lora in
            let loraArch = detectArchitecture(baseModel: lora.baseModel)
            return loraArch == baseModelArch || loraArch == .unknown
        }
    }

    /// Detect model architecture from variant or baseModel string
    private func detectArchitecture(variant: String? = nil, baseModel: String? = nil) -> ModelArchitecture {
        let text = (variant ?? baseModel ?? "").lowercased()

        if text.contains("xl") || text.contains("sdxl") {
            return .sdxl
        } else if text.contains("sd 1") || text.contains("sd1") || text.contains("v1") {
            return .sd15
        } else if text.contains("sd 2") || text.contains("sd2") || text.contains("v2") {
            return .sd20
        }

        return .unknown
    }

    private enum ModelArchitecture: String {
        case sd15 = "SD 1.5"
        case sd20 = "SD 2.0"
        case sdxl = "SDXL"
        case unknown = "Unknown"
    }

    private var isReadyToConvert: Bool {
        selectedBaseModel != nil && !selectedLoRAs.isEmpty && !fusedModelName.isEmpty && !isConverting && hasCompatibleSelection
    }

    /// Validate that all selected LoRAs are compatible with base model
    private var hasCompatibleSelection: Bool {
        guard let baseModel = selectedBaseModel else { return false }

        let baseArch = detectArchitecture(variant: baseModel.variant)

        for lora in selectedLoRAs {
            let loraArch = detectArchitecture(baseModel: lora.baseModel)
            if loraArch != .unknown && baseArch != .unknown && loraArch != baseArch {
                return false
            }
        }

        return true
    }

    /// Get compatibility warning if selection is incompatible
    private var compatibilityWarning: String? {
        guard let baseModel = selectedBaseModel, !selectedLoRAs.isEmpty else { return nil }

        let baseArch = detectArchitecture(variant: baseModel.variant)

        for lora in selectedLoRAs {
            let loraArch = detectArchitecture(baseModel: lora.baseModel)
            if loraArch != .unknown && baseArch != .unknown && loraArch != baseArch {
                return "Incompatible: LoRA '\(lora.name)' is \(loraArch.rawValue), base model is \(baseArch.rawValue)"
            }
        }

        return nil
    }

    /// Check if safetensors file is available in model directory
    private func hasSafetensors(model: StableDiffusionModelManager.ModelInfo) -> Bool {
        /// With unified structure, safetensors are in the model directory itself
        /// Check model.safetensorsPath or look in model directory
        if let safetensorsPath = model.safetensorsPath {
            return FileManager.default.fileExists(atPath: safetensorsPath.path)
        }

        /// Fallback: check for model.safetensors in model directory
        let safetensorsFile = model.path.appendingPathComponent("model.safetensors")
        return FileManager.default.fileExists(atPath: safetensorsFile.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            /// Header
            HStack {
                Text("Fuse LoRA with Model")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(isConverting)
            }
            .padding()

            Divider()

            /// Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    /// Base model selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Select Base Model")
                            .font(.headline)

                        Picker("", selection: $selectedBaseModel) {
                            Text("Choose a model...").tag(nil as StableDiffusionModelManager.ModelInfo?)
                            ForEach(availableBaseModels) { model in
                                let hasSource = hasSafetensors(model: model)
                                let displayText = hasSource ? "\(model.name) ✓" : "\(model.name) (no source)"
                                Text(displayText)
                                    .font(.system(.caption, design: .monospaced))
                                    .tag(model as StableDiffusionModelManager.ModelInfo?)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 300)

                        if let model = selectedBaseModel {
                            Text("\(model.variant) • \(String(format: "%.1f GB", model.sizeGB))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    /// LoRA selection
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("2. Select LoRAs to Fuse")
                                .font(.headline)

                            if let model = selectedBaseModel {
                                let arch = detectArchitecture(variant: model.variant)
                                if arch != .unknown {
                                    Text("(\(arch.rawValue) only)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        if compatibilityWarning != nil {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(compatibilityWarning!)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(6)
                        }

                        if loraManager.availableLoRAs.isEmpty {
                            Text("No LoRAs available. Download some first.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if compatibleLoRAs.isEmpty && selectedBaseModel != nil {
                            Text("No compatible LoRAs found for selected base model architecture.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(compatibleLoRAs) { lora in
                                    LoRASelectionRow(
                                        lora: lora,
                                        isSelected: selectedLoRAs.contains(lora),
                                        scale: loraScales[lora.id] ?? 1.0,
                                        onToggle: { toggleLoRA(lora) },
                                        onScaleChange: { scale in
                                            loraScales[lora.id] = scale
                                        }
                                    )
                                }
                            }
                        }
                    }

                    /// Output model name
                    VStack(alignment: .leading, spacing: 8) {
                        Text("3. Name Fused Model")
                            .font(.headline)

                        TextField("Enter model name...", text: $fusedModelName)
                            .textFieldStyle(.roundedBorder)

                        Text("Example: MyModel_with_AnimeLoRA")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    /// Conversion log
                    if !conversionLog.isEmpty || isConverting {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Conversion Log")
                                    .font(.headline)

                                Spacer()

                                Button(action: copyLogToClipboard) {
                                    Label("Copy Log", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(conversionLog.isEmpty)
                            }

                            ScrollView {
                                Text(conversionLog.isEmpty ? "Starting conversion..." : conversionLog)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(height: 200)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(8)
                        }
                    }

                    if let error = conversionError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(error)
                                    .foregroundColor(.red)
                                    .font(.callout)
                                    .fontWeight(.medium)
                                if !conversionLog.isEmpty {
                                    Text("Full details available in the log above")
                                        .foregroundColor(.secondary)
                                        .font(.caption2)
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                .padding()
            }

            Divider()

            /// Footer
            HStack {
                if isConverting {
                    ProgressView()
                        .controlSize(.small)
                    Text(conversionProgress)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(selectedLoRAs.count) LoRA(s) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .disabled(isConverting)

                Button("Start Conversion") {
                    startConversion()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isReadyToConvert)
            }
            .padding()
        }
        .frame(width: 700, height: 800)
    }

    private func toggleLoRA(_ lora: LoRAManager.LoRAInfo) {
        if selectedLoRAs.contains(lora) {
            selectedLoRAs.remove(lora)
            loraScales.removeValue(forKey: lora.id)
        } else {
            selectedLoRAs.insert(lora)
            loraScales[lora.id] = 1.0
        }
    }

    private func copyLogToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(conversionLog, forType: .string)
    }

    /// Parse conversion log to extract specific error causes
    private func parseConversionError(from log: String) -> String {
        // Check for architecture mismatch (target modules not found)
        if log.contains("Target modules") && log.contains("not found in the base model") {
            // Extract LoRA name from error context
            let lines = log.components(separatedBy: "\n")
            var loraName: String?

            for (index, line) in lines.enumerated() {
                if line.contains("Loading LoRA:") {
                    loraName = line.replacingOccurrences(of: "Loading LoRA:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: "(scale:").first?
                        .trimmingCharacters(in: .whitespaces)
                }
                if line.contains("Target modules") && index > 0 {
                    break
                }
            }

            if let lora = loraName {
                return "Architecture incompatibility: LoRA '\(lora)' cannot be fused with this base model. They likely use different architectures (SD1.5 vs SDXL)."
            }
            return "Architecture incompatibility: LoRA and base model have incompatible architectures (SD1.5 vs SDXL)."
        }

        // Check for other common errors
        if log.contains("ERROR: ARCHITECTURE_MISMATCH") {
            return "Architecture mismatch detected between base model and LoRA."
        }

        if log.contains("FileNotFoundError") || log.contains("No such file") {
            return "Missing file: Check that base model .safetensors file exists in staging."
        }

        if log.contains("OutOfMemoryError") || log.contains("CUDA out of memory") {
            return "Out of memory: LoRA fusion requires significant RAM. Close other applications and try again."
        }

        // Default generic error
        return "Conversion failed - see log for details"
    }

    private func startConversion() {
        guard let baseModel = selectedBaseModel else { return }

        isConverting = true
        conversionError = nil
        conversionLog = ""
        conversionProgress = "Preparing conversion..."

        Task {
            do {
                /// Check if base model has safetensors file
                guard let safetensorsPath = baseModel.safetensorsPath else {
                    await MainActor.run {
                        conversionLog += "ERROR: Base model does not have .safetensors file tracked\n"
                        conversionLog += "\n"
                        conversionLog += "This model was converted before .safetensors tracking was added.\n"
                        conversionLog += "To enable LoRA fusion with this model:\n"
                        conversionLog += "1. Download the model again from CivitAI or HuggingFace\n"
                        conversionLog += "2. The .safetensors file will be kept in staging\n"
                        conversionLog += "3. Then you can fuse LoRAs with it\n"
                        conversionError = "Base model .safetensors file not available"
                        conversionProgress = "Conversion failed"
                        isConverting = false
                    }
                    return
                }

                await MainActor.run {
                    conversionLog += "Found base model .safetensors: \(safetensorsPath.lastPathComponent)\n"
                    conversionLog += "Selected LoRAs: \(selectedLoRAs.count)\n"
                    for lora in selectedLoRAs {
                        let scale = loraScales[lora.id] ?? 1.0
                        conversionLog += "  - \(lora.name) (scale: \(String(format: "%.2f", scale)))\n"
                    }
                    conversionLog += "\n"
                    conversionProgress = "Starting conversion..."
                }

                /// Setup output directory
                let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                let modelsDir = cachesDir.appendingPathComponent("sam/models/stable-diffusion")
                let outputDir = modelsDir.appendingPathComponent(fusedModelName)

                /// Create output directory
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

                await MainActor.run {
                    conversionLog += "Output directory: \(outputDir.path)\n\n"
                    conversionProgress = "Running Python conversion script..."
                }

                /// Build Python command with LoRA arguments
                let bundledPython = Bundle.main.resourceURL?
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources/python_env/bin/python3")
                    .path

                let pythonPath = (bundledPython != nil && FileManager.default.fileExists(atPath: bundledPython!))
                    ? bundledPython!
                    : "/usr/bin/python3"

                let scriptPath = Bundle.main.resourceURL?
                    .appendingPathComponent("convert_sd_to_coreml.py")
                    .path ?? "scripts/convert_sd_to_coreml.py"

                var arguments = [scriptPath, safetensorsPath.path, outputDir.path]

                /// Add LoRA arguments
                for lora in selectedLoRAs {
                    arguments.append("--lora")
                    arguments.append(lora.path.path)
                    arguments.append("--lora-scale")
                    arguments.append(String(format: "%.2f", loraScales[lora.id] ?? 1.0))
                }

                await MainActor.run {
                    conversionLog += "Command: \(pythonPath) \\\n"
                    conversionLog += "  \(arguments.joined(separator: " \\\n  "))\n\n"
                }

                /// Run conversion
                let process = Process()
                process.executableURL = URL(fileURLWithPath: pythonPath)
                process.arguments = arguments

                /// Capture output
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                /// Stream output to log
                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                        Task { @MainActor in
                            self.conversionLog += output
                        }
                    }
                }

                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                        Task { @MainActor in
                            self.conversionLog += output
                        }
                    }
                }

                try process.run()
                process.waitUntilExit()

                /// Clean up handlers
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let success = process.terminationStatus == 0

                await MainActor.run {
                    if success {
                        conversionLog += "\n\nConversion successful!\n"
                        conversionLog += "Fused model created: \(fusedModelName)\n"
                        conversionLog += "The model will appear in the model picker after SAM restarts.\n"
                        conversionProgress = "Conversion complete"
                    } else {
                        conversionLog += "\n\nConversion failed with exit code \(process.terminationStatus)\n"

                        // Parse error for specific failure reasons
                        let errorMessage = parseConversionError(from: conversionLog)
                        conversionError = errorMessage
                        conversionProgress = "Conversion failed"
                    }
                    isConverting = false
                }

            } catch {
                await MainActor.run {
                    conversionLog += "\n\nERROR: \(error.localizedDescription)\n"
                    conversionError = error.localizedDescription
                    conversionProgress = "Conversion failed"
                    isConverting = false
                }
            }
        }
    }
}

// MARK: - LoRA Selection Row

struct LoRASelectionRow: View {
    let lora: LoRAManager.LoRAInfo
    let isSelected: Bool
    let scale: Double
    let onToggle: () -> Void
    let onScaleChange: (Double) -> Void

    var body: some View {
        HStack {
            /// Use custom button as toggle to handle selection
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundColor(isSelected ? .accentColor : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(lora.name)
                                .font(.subheadline)
                                .foregroundColor(.primary)

                            // Warning badge for unknown architecture
                            if lora.baseModel.lowercased() == "unknown" || lora.baseModel.isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                    .help("Unknown architecture - fusion may fail")
                            }
                        }

                        HStack {
                            Text(lora.baseModel.isEmpty ? "Unknown" : lora.baseModel)
                                .font(.caption)
                                .foregroundColor(lora.baseModel.lowercased() == "unknown" || lora.baseModel.isEmpty ? .orange : .secondary)

                            if !lora.triggerWords.isEmpty {
                                Text("•")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(lora.triggerWords.count) trigger word(s)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if isSelected {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Scale: \(String(format: "%.2f", scale))")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Slider(value: .init(
                        get: { scale },
                        set: { onScaleChange($0) }
                    ), in: 0.1...2.0, step: 0.1)
                    .frame(width: 150)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
    }
}

// MARK: - HuggingFace LoRA Components

struct HFLoRASearchResultCard: View {
    let lora: StableDiffusionIntegration.HFModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            /// Model icon placeholder
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.2))
                .overlay(
                    VStack {
                        Image(systemName: "face.smiling")
                            .font(.largeTitle)
                            .foregroundColor(.blue)
                        Text("HF")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                )
                .frame(height: 150)

            VStack(alignment: .leading, spacing: 4) {
                Text(lora.displayName)
                    .font(.headline)
                    .lineLimit(2)

                Text("by \(lora.username)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let baseModel = lora.baseModelId {
                    HStack {
                        Label(baseModel.components(separatedBy: "/").last ?? baseModel, systemImage: "tag")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Spacer()
                    }
                }

                /// Downloads count
                if let downloads = lora.downloads {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption2)
                        Text("\(downloads)")
                            .font(.caption2)
                        Spacer()
                    }
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

struct HFLoRADetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloadManager: ModelDownloadManager

    let lora: StableDiffusionIntegration.HFModel
    let loraManager: LoRAManager

    @State private var downloading = false
    @State private var downloadProgress: Double = 0
    @State private var errorMessage: String?
    @State private var files: [StableDiffusionIntegration.HFFile] = []
    @State private var loadingFiles = false

    var body: some View {
        VStack(spacing: 0) {
            /// Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lora.displayName)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("by \(lora.username)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            /// Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    /// Link to HuggingFace
                    HStack {
                        Link(destination: URL(string: "https://huggingface.co/\(lora.modelId)")!) {
                            Label("View on HuggingFace", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                        Spacer()
                    }

                    /// Base model info
                    if let baseModel = lora.baseModelId {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Base model: \(baseModel)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("Make sure you have a compatible base model installed")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }

                    /// Model info
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model Information")
                            .font(.headline)

                        if let downloads = lora.downloads {
                            HStack {
                                Image(systemName: "arrow.down.circle")
                                Text("\(downloads) downloads")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if let tags = lora.tags, !tags.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Tags:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                FlowLayout(spacing: 6) {
                                    ForEach(tags.prefix(10), id: \.self) { tag in
                                        Text(tag)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.secondary.opacity(0.1))
                                            .cornerRadius(4)
                                    }
                                }
                            }
                        }
                    }

                    /// Files list
                    if loadingFiles {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading files...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if !files.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Available Files")
                                .font(.headline)

                            ForEach(files.filter { $0.isSafetensors }, id: \.path) { file in
                                HStack {
                                    Image(systemName: "doc")
                                        .foregroundColor(.secondary)
                                    Text(file.path)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Spacer()
                                    if let size = file.fileSize {
                                        Text(formatBytes(size))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(6)
                                .background(Color.secondary.opacity(0.05))
                                .cornerRadius(4)
                            }
                        }
                    }

                    if let error = errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                .padding()
            }

            Divider()

            /// Footer with download button
            HStack {
                if downloading {
                    ProgressView(value: downloadProgress)
                        .frame(maxWidth: .infinity)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Spacer()

                    Button(action: { downloadLoRA() }) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 600, height: 700)
        .onAppear {
            loadFiles()
        }
    }

    private func loadFiles() {
        loadingFiles = true
        Task {
            do {
                let service = HuggingFaceService()
                let loadedFiles = try await service.listModelFiles(modelId: lora.modelId)
                await MainActor.run {
                    files = loadedFiles
                    loadingFiles = false
                }
            } catch {
                sdPrefLogger.error("Failed to load files: \(error.localizedDescription)")
                await MainActor.run {
                    loadingFiles = false
                }
            }
        }
    }

    private func downloadLoRA() {
        guard let safetensorsFile = files.first(where: { $0.isSafetensors }) else {
            errorMessage = "No .safetensors file found"
            return
        }

        downloading = true
        errorMessage = nil

        Task {
            do {
                let service = HuggingFaceService()
                let progressId = "hf_lora_\(lora.modelId.replacingOccurrences(of: "/", with: "_"))"

                /// Sanitize filename
                let filename = sanitizeFilename(lora.displayName) + ".safetensors"
                let destination = loraManager.loraDirectory.appendingPathComponent(filename)

                sdPrefLogger.info("Downloading HF LoRA: \(lora.modelId)/\(safetensorsFile.path)")

                /// Download file
                let downloadedFile = try await service.downloadFile(
                    repoId: lora.modelId,
                    file: safetensorsFile,
                    destination: destination,
                    progress: { @Sendable progress in
                        Task { @MainActor in
                            downloadProgress = progress
                        }
                    }
                )

                sdPrefLogger.info("Downloaded to: \(downloadedFile.path)")

                /// Create metadata
                let metadata = LoRAMetadata(
                    id: lora.modelId,
                    name: lora.displayName,
                    baseModel: lora.baseModelId ?? "Unknown",
                    triggerWords: [],  /// HF doesn't have structured trigger words
                    civitaiId: nil,
                    previewImageURL: nil,
                    description: nil
                )

                /// Register with LoRAManager
                _ = try loraManager.registerDownloadedLoRA(filename: filename, metadata: metadata)

                await MainActor.run {
                    downloading = false
                    dismiss()
                }
            } catch {
                sdPrefLogger.error("HF LoRA download failed: \(error.localizedDescription)")
                await MainActor.run {
                    downloading = false
                    errorMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func sanitizeFilename(_ input: String) -> String {
        if input.isEmpty { return "unnamed" }
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var sanitized = input
            .replacingOccurrences(of: " ", with: "_")
            .components(separatedBy: invalidChars)
            .joined(separator: "_")
        sanitized = sanitized.filter { !$0.isASCII || ($0.asciiValue ?? 0) >= 32 }
        while sanitized.contains("__") {
            sanitized = sanitized.replacingOccurrences(of: "__", with: "_")
        }
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return sanitized.isEmpty ? "unnamed" : sanitized
    }
}

#Preview {
    StableDiffusionPreferencesPane()
        .frame(width: 900, height: 700)
}
