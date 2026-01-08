// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import APIFramework
import Logging

private let logger = Logger(label: "com.sam.ui.localmodels.download")

/// Download Models tab - HuggingFace browser for GGUF/MLX models
struct LocalModelsPreferencePane_DownloadTab: View {
    @EnvironmentObject private var downloadManager: ModelDownloadManager
    @State private var searchQuery: String = ""
    @State private var selectedFilter: ModelFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            /// Search and filter controls
            VStack(alignment: .leading, spacing: 12) {
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

                /// Search bar and filter
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
                            Button(action: {
                                selectedFilter = filter
                                /// Auto-search when SD filter selected
                                if filter == .stableDiffusion {
                                    Task {
                                        searchQuery = ""
                                        await performSearch()
                                    }
                                }
                            }) {
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

                    Button("Search") {
                        Task {
                            await performSearch()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((searchQuery.isEmpty && selectedFilter != .stableDiffusion) || downloadManager.isSearching)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Divider()

            /// Search results
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    /// Error message
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

                    /// Loading indicator
                    if downloadManager.isSearching {
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
                        .frame(maxWidth: .infinity)
                        .padding(32)
                    } else if !filteredModels.isEmpty {
                        /// Model cards
                        VStack(spacing: 12) {
                            ForEach(filteredModels) { model in
                                ModelCard(model: model, manager: downloadManager)
                            }
                        }
                    } else if !searchQuery.isEmpty || selectedFilter == .stableDiffusion {
                        /// Empty results
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("No models found")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            if !searchQuery.isEmpty {
                                Text("Try a different search query or filter")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(32)
                    } else {
                        /// Initial state
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("Search HuggingFace for models")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("Enter a search query or select a filter to begin")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(48)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .onChange(of: selectedFilter) { _, _ in
            /// Re-search when filter changes (if there's a query)
            if !searchQuery.isEmpty {
                Task {
                    await performSearch()
                }
            }
        }
    }

    private func performSearch() async {
        /// Determine file extension filter and adjust query based on selected filter
        let fileExtension: String?
        var adjustedQuery = searchQuery

        switch selectedFilter {
        case .all:
            fileExtension = nil
        case .gguf, .q4, .q5, .q8:
            fileExtension = ".gguf"
        case .mlx:
            /// MLX models: Add "mlx" to search query to find mlx-community models
            if !searchQuery.lowercased().contains("mlx") {
                adjustedQuery = "\(searchQuery) mlx"
            }
            fileExtension = ".safetensors"
        case .stableDiffusion:
            /// SD models: Use CoreML filter to find ALL CoreML SD models
            logger.debug("SD search filter selected, searchQuery='\(searchQuery)'")
            fileExtension = ".coreml"
            logger.debug("Setting fileExtension=.coreml for filter=coreml")
        }

        await downloadManager.searchModels(query: adjustedQuery, fileExtension: fileExtension)
    }

    private var filteredModels: [HFModel] {
        let models = downloadManager.availableModels

        /// Apply quantization filters
        switch selectedFilter {
        case .all:
            return models

        case .gguf:
            return models.filter { $0.hasGGUF }

        case .mlx:
            return models.filter { $0.hasMLX }

        case .stableDiffusion:
            /// API already filtered with filter=coreml, return all results
            return models

        case .q4:
            /// Filter to models with Q4 quantization
            return models.filter { $0.hasGGUF && ($0.tags?.contains { $0.contains("q4") || $0.contains("Q4") } == true || $0.siblings != nil) }

        case .q5:
            return models.filter { $0.hasGGUF && ($0.tags?.contains { $0.contains("q5") || $0.contains("Q5") } == true || $0.siblings != nil) }

        case .q8:
            return models.filter { $0.hasGGUF && ($0.tags?.contains { $0.contains("q8") || $0.contains("Q8") } == true || $0.siblings != nil) }
        }
    }
}

// MARK: - Model Card (migrated from old LocalModelsPreferencePane.swift)

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
            /// Model header (clickable to expand/collapse)
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

            /// Format tags
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

            /// Available files (expanded)
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

// MARK: - Model File Row

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

            /// Download button or progress with cancel
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
