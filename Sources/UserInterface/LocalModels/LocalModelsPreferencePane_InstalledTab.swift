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

        var icon: String {
            switch self {
            case .all: return "square.stack.3d.up"
            case .gguf: return "cube.box"
            case .mlx: return "cpu"
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

    private func checkAvailableFormats() {
        availableFormats = []
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
                Button("Delete", role: .destructive) {
                    manager.deleteModel(id: model.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete the model file from your computer.")
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onAppear {
            checkAvailableFormats()
        }
    }

    private var modelIcon: String {
        if model.name.lowercased().contains("gguf") || model.quantization != nil {
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
