// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import APIFramework
import Logging

private let logger = Logger(label: "com.sam.localmodels")

/// Local Models preference pane for downloading and managing GGUF/MLX models.
public struct LocalModelsPreferencePane: View {
    @StateObject private var downloadManager: ModelDownloadManager
    @State private var searchQuery: String = ""
    @State private var selectedFilter: ModelFilter = .all

    public init(endpointManager: EndpointManager? = nil) {
        _downloadManager = StateObject(wrappedValue: ModelDownloadManager(endpointManager: endpointManager))
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                /// Section 0: Optimization Settings (NEW).
                optimizationSettingsSection

                Divider()

                /// Section 1: Installed Models.
                installedModelsSection

                Divider()

                /// Section 2: HuggingFace Browser.
                huggingFaceBrowserSection

                Divider()

                /// Section 3: Storage Info.
                storageInfoSection
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Optimization Settings Section

    private var optimizationSettingsSection: some View {
        LocalModelOptimizationSection()
    }

    // MARK: - Installed Models Section

    private var installedModelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installed Models")
                .font(.title2)
                .fontWeight(.semibold)

            if downloadManager.installedModels.isEmpty {
                emptyInstalledModelsView
            } else {
                VStack(spacing: 8) {
                    ForEach(downloadManager.installedModels) { model in
                        InstalledModelRow(model: model, manager: downloadManager)
                    }
                }
            }
        }
    }

    private var emptyInstalledModelsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No models installed yet")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Search and download models below to get started")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    // MARK: - HuggingFace Browser Section

    private var huggingFaceBrowserSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download Models")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Search HuggingFace for GGUF, MLX, and Stable Diffusion models")
                .font(.caption)
                .foregroundColor(.secondary)

            /// Context size recommendation
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recommended: Models with 16k+ context window")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("SAM's system prompts require significant context. Models with less than 16k context will have tools automatically disabled.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)

            /// Search bar.
            searchBar

            /// Error message.
            if let error = downloadManager.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }

            /// Loading indicator.
            if downloadManager.isSearching {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Searching HuggingFace...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            }

            /// Search results.
            if !downloadManager.availableModels.isEmpty {
                VStack(spacing: 12) {
                    ForEach(filteredModels) { model in
                        ModelCard(model: model, manager: downloadManager)
                    }
                }
            } else if !searchQuery.isEmpty && !downloadManager.isSearching {
                Text("No models found for '\(searchQuery)'")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(16)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Search models (e.g., 'Qwen2.5-Coder', 'Llama-3', 'Mistral')...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        Task {
                            await performSearch()
                        }
                    }

                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            Menu {
                ForEach(ModelFilter.allCases, id: \.self) { filter in
                    Button(action: { selectedFilter = filter }) {
                        Text(filter.displayName)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            } label: {
                HStack {
                    Text(selectedFilter.displayName)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(width: 120)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )
            }
            .onChange(of: selectedFilter) { newFilter in
                /// Auto-search when SD filter selected
                if newFilter == .stableDiffusion {
                    Task {
                        searchQuery = ""  /// Clear search to show all SD models
                        await performSearch()
                    }
                }
            }

            Button("Search") {
                Task {
                    await performSearch()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled((searchQuery.isEmpty && selectedFilter != .stableDiffusion) || downloadManager.isSearching)
        }
        .onChange(of: selectedFilter) { _, _ in
            /// Re-search when filter changes (if there's a query).
            if !searchQuery.isEmpty {
                Task {
                    await performSearch()
                }
            }
        }
    }

    private func performSearch() async {
        /// Determine file extension filter and adjust query based on selected filter.
        let fileExtension: String?
        var adjustedQuery = searchQuery

        switch selectedFilter {
        case .all:
            fileExtension = nil
        case .gguf, .q4, .q5, .q8:
            fileExtension = ".gguf"
        case .mlx:
            /// MLX models: Add "mlx" to search query to find mlx-community models.
            if !searchQuery.lowercased().contains("mlx") {
                adjustedQuery = "\(searchQuery) mlx"
            }
            fileExtension = ".safetensors"
        case .stableDiffusion:
            /// SD models: Use CoreML filter to find ALL CoreML SD models.
            /// Do NOT add "stable diffusion" to search - many SD models don't contain those words
            /// (e.g., "A-Zovya-RPG", "Analog-Diffusion", "SDXL", etc.)
            logger.debug("SD search filter selected, searchQuery='\(searchQuery)'")
            /// Use user's query as-is (or empty for all CoreML models)
            fileExtension = ".coreml"  /// Use .coreml as signal for filter=coreml
            logger.debug("Setting fileExtension=.coreml for filter=coreml")
        }

        await downloadManager.searchModels(query: adjustedQuery, fileExtension: fileExtension)
    }

    private var filteredModels: [HFModel] {
        let models = downloadManager.availableModels

        /// Apply quantization filters Note: Q4/Q5/Q8 filters require model details (siblings field) which are loaded when expanding a model card.
        switch selectedFilter {
        case .all:
            return models

        case .gguf:
            return models.filter { $0.hasGGUF }

        case .mlx:
            return models.filter { $0.hasMLX }

        case .stableDiffusion:
            /// API already filtered with filter=coreml, return all results
            /// (HF CoreML models are primarily SD models)
            return models

        case .q4:
            /// Filter to models with Q4 quantization Search results use tags, so we still return GGUF models User can expand to see Q4 files.
            return models.filter { $0.hasGGUF && ($0.tags?.contains { $0.contains("q4") || $0.contains("Q4") } == true || $0.siblings != nil) }

        case .q5:
            return models.filter { $0.hasGGUF && ($0.tags?.contains { $0.contains("q5") || $0.contains("Q5") } == true || $0.siblings != nil) }

        case .q8:
            return models.filter { $0.hasGGUF && ($0.tags?.contains { $0.contains("q8") || $0.contains("Q8") } == true || $0.siblings != nil) }
        }
    }

    // MARK: - Storage Info Section

    private var storageInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage")
                .font(.title2)
                .fontWeight(.semibold)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cache Location")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("~/Library/Caches/sam/models/")
                        .font(.caption)
                        .monospaced()
                        .foregroundColor(.primary)
                }

                Spacer()

                Button("Open in Finder") {
                    NSWorkspace.shared.open(LocalModelManager.modelsDirectory)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            .cornerRadius(8)
        }
    }
}

// MARK: - UI Setup

struct InstalledModelRow: View {
    let model: LocalModel
    @ObservedObject var manager: ModelDownloadManager
    @State private var showingDeleteConfirmation = false
    @State private var availableFormats: [SDFormat] = []

    enum SDFormat: String, CaseIterable {
        case safeTensors = "SafeTensors"
        case coreML = "CoreML"
    }

    private var isStableDiffusionModel: Bool {
        model.provider == "stable-diffusion"
    }

    private func checkAvailableFormats() {
        guard isStableDiffusionModel else {
            availableFormats = []
            return
        }

        /// Extract model directory from path
        let modelPath = URL(fileURLWithPath: model.path)
        var modelDir: URL

        /// Navigate up to find the model directory
        if modelPath.path.contains("/original/compiled/") {
            /// CoreML path - go up to model directory
            modelDir = modelPath.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        } else if modelPath.pathExtension == "safetensors" {
            /// SafeTensors path - parent is model directory
            modelDir = modelPath.deletingLastPathComponent()
        } else {
            /// Unknown structure
            availableFormats = []
            return
        }

        var formats: [SDFormat] = []

        /// Check for SafeTensors (any .safetensors file)
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: modelDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            if contents.contains(where: { $0.path.hasSuffix(".safetensors") }) {
                formats.append(.safeTensors)
            }
        } catch {
            /// Continue checking CoreML
        }

        /// Check for CoreML
        let coremlPath = modelDir.appendingPathComponent("original/compiled/Unet.mlmodelc")
        if FileManager.default.fileExists(atPath: coremlPath.path) {
            formats.append(.coreML)
        }

        availableFormats = formats
    }

    var body: some View {
        HStack(spacing: 12) {
            /// Model icon.
            Image(systemName: modelIcon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            /// Model info.
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.headline)

                HStack(spacing: 16) {
                    if let size = model.sizeBytes {
                        Label(formatBytes(size), systemImage: "internaldrive")
                    }

                    if let quant = model.quantization {
                        Label(quant, systemImage: "cpu")
                    }

                    /// Show available formats for SD models
                    if isStableDiffusionModel && !availableFormats.isEmpty {
                        Label(
                            availableFormats.count == 2 ? "CoreML + SafeTensors" : availableFormats.first!.rawValue,
                            systemImage: availableFormats.count == 2 ? "folder.badge.gearshape" : "folder"
                        )
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            /// Delete button.
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.bordered)
            .confirmationDialog(
                "Delete \(model.name)?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                if isStableDiffusionModel && availableFormats.count == 2 {
                    /// Both formats available - offer choice
                    Button("Delete SafeTensors Only", role: .destructive) {
                        deleteFormat(.safeTensors)
                    }
                    Button("Delete CoreML Only", role: .destructive) {
                        deleteFormat(.coreML)
                    }
                    Button("Delete Both", role: .destructive) {
                        manager.deleteModel(id: model.id)
                    }
                    Button("Cancel", role: .cancel) {}
                } else {
                    /// Single format or non-SD model - simple delete
                    Button("Delete", role: .destructive) {
                        manager.deleteModel(id: model.id)
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } message: {
                if isStableDiffusionModel && availableFormats.count == 2 {
                    Text("This model has both SafeTensors and CoreML formats. Choose what to delete:")
                } else {
                    Text("This will permanently delete the model file from your computer.")
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onAppear {
            checkAvailableFormats()
        }
    }

    private func deleteFormat(_ format: SDFormat) {
        guard isStableDiffusionModel else { return }

        /// Extract model directory from path
        let modelPath = URL(fileURLWithPath: model.path)
        var modelDir: URL

        if modelPath.path.contains("/original/compiled/") {
            modelDir = modelPath.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        } else if modelPath.pathExtension == "safetensors" {
            modelDir = modelPath.deletingLastPathComponent()
        } else {
            return
        }

        switch format {
        case .safeTensors:
            /// Delete any .safetensors files
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: modelDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )
                for file in contents where file.path.hasSuffix(".safetensors") {
                    try? FileManager.default.removeItem(at: file)
                }
            } catch {
                /// Failed to delete
            }

        case .coreML:
            /// Delete original/ directory (contains CoreML models)
            let originalDir = modelDir.appendingPathComponent("original")
            try? FileManager.default.removeItem(at: originalDir)
        }

        /// Trigger model registry update by posting notification
        NotificationCenter.default.post(name: NSNotification.Name("RefreshStableDiffusionModels"), object: nil)

        /// Check if directory is now empty (excluding metadata)
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: modelDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            /// If only metadata remains, delete entire directory
            if contents.allSatisfy({ $0.lastPathComponent.hasPrefix(".sam_") }) {
                try? FileManager.default.removeItem(at: modelDir)
                /// Trigger another refresh after removing directory
                NotificationCenter.default.post(name: NSNotification.Name("RefreshStableDiffusionModels"), object: nil)
            }
        } catch {
            /// Continue
        }
    }

    private var modelIcon: String {
        if isStableDiffusionModel {
            return "photo.fill"
        } else if model.name.lowercased().contains("gguf") || model.quantization != nil {
            return "cube.box.fill"
        } else if model.name.lowercased().contains("mlx") {
            return "cpu.fill"
        }
        return "doc.fill"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct ModelCard: View {
    let model: HFModel
    @ObservedObject var manager: ModelDownloadManager
    @State private var isExpanded: Bool = false
    @State private var fullModel: HFModel?
    @State private var isLoadingDetails = false

    var displayModel: HFModel {
        fullModel ?? model
    }

    /// Detect if this is a Stable Diffusion model (any author)
    private var isStableDiffusionModel: Bool {
        let modelId = model.id.lowercased()
        let hasSD = modelId.contains("stable-diffusion") ||
                   modelId.contains("stable_diffusion") ||
                   modelId.contains("stablediffusion")
        let hasCoreML = modelId.contains("coreml") || modelId.contains("core-ml")
        let hasDiffusion = modelId.contains("diffusion")

        /// Check tags for SD indicators
        let hasSDTag = model.tags?.contains { tag in
            let t = tag.lowercased()
            return t.contains("stable-diffusion") || t.contains("text-to-image")
        } ?? false

        /// Accept if clearly a SD model by ID or tags
        return hasSD || (hasCoreML && hasDiffusion) || hasSDTag
    }

    /// Check if this SD model is already installed locally (with valid required files)
    private var isSDModelInstalled: Bool {
        guard isStableDiffusionModel else { return false }

        let modelName = model.id.components(separatedBy: "/").last ?? model.id
        let sdModelsDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("sam/models/stable-diffusion")
        let modelDir = sdModelsDir.appendingPathComponent(modelName)

        /// Directory must exist first
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            return false
        }

        /// Check for required files (same logic as StableDiffusionModelManager.isValidModelDirectory)
        let possiblePaths = [
            modelDir.appendingPathComponent("original/compiled"),
            modelDir.appendingPathComponent("split_einsum/compiled"),
            modelDir
        ]

        let requiredFiles = [
            "TextEncoder.mlmodelc",
            "Unet.mlmodelc",
            "VAEDecoder.mlmodelc",
            "vocab.json",
            "merges.txt"
        ]

        for basePath in possiblePaths {
            var allFilesExist = true
            for file in requiredFiles {
                let filePath = basePath.appendingPathComponent(file)
                if !FileManager.default.fileExists(atPath: filePath.path) {
                    allFilesExist = false
                    break
                }
            }

            if allFilesExist {
                return true
            }
        }

        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            /// Model header (clickable to expand/collapse).
            Button(action: {
                isExpanded.toggle()
                if isExpanded && fullModel == nil && !isLoadingDetails {
                    Task { await fetchModelDetails() }
                }
            }) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.displayName)
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text("by \(model.authorName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 16) {
                        if let downloads = model.downloads {
                            Label("\(formatNumber(downloads))", systemImage: "arrow.down.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let likes = model.likes {
                            Label("\(formatNumber(likes))", systemImage: "heart")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    /// Expansion indicator
                    if isLoadingDetails {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            /// Format tags.
            if let tags = model.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags.prefix(5), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .cornerRadius(4)
                        }
                    }
                }
            }

            /// Available files (expanded).
            if isExpanded {
                Divider()

                if isLoadingDetails {
                    HStack {
                        Spacer()
                        ProgressView("Loading model files...")
                        Spacer()
                    }
                    .padding()
                } else if isStableDiffusionModel {
                    /// Stable Diffusion model - show status or download button
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Stable Diffusion CoreML Model")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)

                        Text("This model contains multiple CoreML files and will be downloaded as a complete package.")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        /// Check download progress first (takes precedence over installation check)
                        if let progress = manager.downloadProgress[model.id] {
                            HStack(spacing: 12) {
                                ProgressView(value: progress)
                                    .frame(maxWidth: 200)

                                Text("\(Int(progress * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()

                                Button("Cancel") {
                                    manager.cancelDownload(modelId: model.id)
                                }
                                .font(.caption)
                                .buttonStyle(.borderless)
                            }
                        } else if isSDModelInstalled {
                            /// Model is fully installed (all required files present)
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Installed")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.green)
                                Spacer()
                            }
                            .padding()
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                        } else {
                            Button(action: {
                                Task {
                                    /// Ensure model details (siblings) are loaded before downloading
                                    if fullModel == nil {
                                        await fetchModelDetails()
                                    }
                                    /// Use displayModel (which now has siblings from fetchModelDetails)
                                    await manager.downloadStableDiffusionModel(model: displayModel)
                                }
                            }) {
                                Label("Download Complete Model", systemImage: "arrow.down.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if !displayModel.ggufFiles.isEmpty {
                            Text("GGUF Files (\(displayModel.ggufFiles.count))")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            ForEach(displayModel.ggufFiles) { file in
                                ModelFileRow(model: displayModel, file: file, manager: manager)
                            }
                        }

                        if !displayModel.mlxFiles.isEmpty {
                            if !displayModel.ggufFiles.isEmpty {
                                Divider()
                                    .padding(.vertical, 4)
                            }

                            Text("MLX Files (\(displayModel.mlxFiles.count))")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            ForEach(displayModel.mlxFiles.prefix(3)) { file in
                                ModelFileRow(model: displayModel, file: file, manager: manager)
                            }

                            if displayModel.mlxFiles.count > 3 {
                                Text("+ \(displayModel.mlxFiles.count - 3) more files")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 8)
                            }
                        }

                        if displayModel.ggufFiles.isEmpty && displayModel.mlxFiles.isEmpty {
                            Text("No downloadable GGUF or MLX files found for this model")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding()
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func fetchModelDetails() async {
        isLoadingDetails = true
        defer { isLoadingDetails = false }

        do {
            let client = HuggingFaceGGUFClient()
            let detailedModel = try await client.getModelInfo(repoId: model.id)
            await MainActor.run {
                self.fullModel = detailedModel
            }
        } catch {
            logger.error("Failed to fetch model details: \(error)")
        }
    }

    private func formatNumber(_ number: Int) -> String {
        if number >= 1_000_000 {
            return String(format: "%.1fM", Double(number) / 1_000_000)
        } else if number >= 1_000 {
            return String(format: "%.1fK", Double(number) / 1_000)
        }
        return "\(number)"
    }
}

struct ModelFileRow: View {
    let model: HFModel
    let file: HFModelFile
    @ObservedObject var manager: ModelDownloadManager

    private var downloadKey: String {
        "\(model.id)_\(file.rfilename)"
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.rfilename)
                    .font(.caption)
                    .monospaced()

                HStack(spacing: 8) {
                    if let size = file.sizeFormatted {
                        Text(size)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if let quant = file.quantization {
                        Text(quant)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }
            }

            Spacer()

            /// Download button or progress with cancel.
            if let progress = manager.downloadProgress[downloadKey] {
                HStack(spacing: 8) {
                    ProgressView(value: progress) {
                        Text("\(Int(progress * 100))%")
                            .font(.caption2)
                    }
                    .frame(width: 100)

                    Button(action: {
                        manager.cancelDownload(modelId: downloadKey)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                }
            } else {
                Button("Download") {
                    Task {
                        await manager.downloadModelWithRelatedFiles(model: model, file: file)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}

// MARK: - Model Filter

enum ModelFilter: String, CaseIterable {
    case all = "All"
    case gguf = "GGUF"
    case mlx = "MLX"
    case stableDiffusion = "Stable Diffusion"
    case q4 = "Q4"
    case q5 = "Q5"
    case q8 = "Q8"

    var displayName: String {
        switch self {
        case .all: return "All Models"
        case .gguf: return "GGUF Only"
        case .mlx: return "MLX Only"
        case .stableDiffusion: return "Stable Diffusion"
        case .q4: return "Q4 (Fast)"
        case .q5: return "Q5 (Balanced)"
        case .q8: return "Q8 (Quality)"
        }
    }
}
