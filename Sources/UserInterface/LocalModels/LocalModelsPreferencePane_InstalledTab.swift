// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import APIFramework
import AppKit
import Logging

private let logger = Logger(label: "com.sam.ui.localmodels.installed")

/// Installed Models tab - shows all locally installed GGUF, MLX, and SD models
struct LocalModelsPreferencePane_InstalledTab: View {
    @EnvironmentObject private var downloadManager: ModelDownloadManager
    @State private var sortOrder: SortOrder = .name
    @State private var filterType: ModelTypeFilter = .all

    enum SortOrder: String, CaseIterable {
        case name = "Name"
        case size = "Size"
        case dateAdded = "Date Added"

        var icon: String {
            switch self {
            case .name: return "textformat"
            case .size: return "internaldrive"
            case .dateAdded: return "clock"
            }
        }
    }

    enum ModelTypeFilter: String, CaseIterable {
        case all = "All"
        case gguf = "GGUF"
        case mlx = "MLX"
        case stableDiffusion = "Stable Diffusion"

        var icon: String {
            switch self {
            case .all: return "square.stack.3d.up"
            case .gguf: return "cube.box"
            case .mlx: return "cpu"
            case .stableDiffusion: return "photo"
            }
        }
    }

    private var filteredAndSortedModels: [LocalModel] {
        var models = downloadManager.installedModels

        /// Filter by type
        switch filterType {
        case .all:
            break
        case .gguf:
            models = models.filter { $0.name.lowercased().contains("gguf") || $0.quantization != nil }
        case .mlx:
            models = models.filter { $0.name.lowercased().contains("mlx") }
        case .stableDiffusion:
            models = models.filter { $0.provider == "stable-diffusion" }
        }

        /// Sort
        switch sortOrder {
        case .name:
            models.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .size:
            models.sort { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        case .dateAdded:
            /// Use file creation date from path
            models.sort {
                let date0 = fileCreationDate(path: $0.path) ?? Date.distantPast
                let date1 = fileCreationDate(path: $1.path) ?? Date.distantPast
                return date0 > date1
            }
        }

        return models
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                /// Header with controls
                HStack {
                    Text("Installed Models")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    /// Filter picker
                    Menu {
                        ForEach(ModelTypeFilter.allCases, id: \.self) { filter in
                            Button(action: { filterType = filter }) {
                                Label(filter.rawValue, systemImage: filter.icon)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text(filterType.rawValue)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }

                    /// Sort picker
                    Menu {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Button(action: { sortOrder = order }) {
                                Label(order.rawValue, systemImage: order.icon)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                            Text(sortOrder.rawValue)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }
                }

                /// Model list or empty state
                if filteredAndSortedModels.isEmpty {
                    emptyStateView
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredAndSortedModels) { model in
                            InstalledModelRow(model: model, manager: downloadManager)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: filterType == .all ? "externaldrive.badge.questionmark" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            if filterType == .all {
                Text("No models installed yet")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Text("Switch to the Download tab to browse and download models")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("No \(filterType.rawValue) models found")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Text("Try a different filter or download more models")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(48)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    private func fileCreationDate(path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.creationDate] as? Date else {
            return nil
        }
        return date
    }
}

// MARK: - Installed Model Row (migrated from old LocalModelsPreferencePane.swift)

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
