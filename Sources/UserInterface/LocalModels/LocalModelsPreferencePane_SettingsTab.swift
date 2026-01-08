// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import APIFramework
import AppKit
import Logging

private let logger = Logger(label: "com.sam.ui.localmodels.settings")

/// Settings tab - storage, cache management, and optimization settings
struct LocalModelsPreferencePane_SettingsTab: View {
    @State private var cacheSize: String = "Calculating..."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                /// Optimization Settings Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Model Optimization")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Configure runtime optimization settings for local models")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    LocalModelOptimizationSection()
                }

                Divider()

                /// Storage Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Storage")
                        .font(.title2)
                        .fontWeight(.semibold)

                    VStack(spacing: 12) {
                        /// Cache location
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

                        /// Cache size and management
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Cache Size")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Text(cacheSize)
                                    .font(.caption)
                                    .monospaced()
                                    .foregroundColor(.primary)
                            }

                            Spacer()

                            Button("Refresh") {
                                calculateCacheSize()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(16)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                        .cornerRadius(8)
                    }
                }

                Divider()

                /// Model Directories Info
                VStack(alignment: .leading, spacing: 12) {
                    Text("Model Directories")
                        .font(.title2)
                        .fontWeight(.semibold)

                    VStack(alignment: .leading, spacing: 8) {
                        DirectoryInfoRow(
                            title: "GGUF Models",
                            path: "~/Library/Caches/sam/models/gguf/",
                            icon: "cube.box"
                        )

                        DirectoryInfoRow(
                            title: "MLX Models",
                            path: "~/Library/Caches/sam/models/mlx/",
                            icon: "cpu"
                        )

                        DirectoryInfoRow(
                            title: "Stable Diffusion",
                            path: "~/Library/Caches/sam/models/stable-diffusion/",
                            icon: "photo"
                        )
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            calculateCacheSize()
        }
    }

    private func calculateCacheSize() {
        Task {
            let size = await calculateDirectorySize(LocalModelManager.modelsDirectory)
            await MainActor.run {
                cacheSize = formatBytes(size)
            }
        }
    }

    private func calculateDirectorySize(_ url: URL) async -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }

        var totalSize: Int64 = 0

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for item in contents {
                let resourceValues = try item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])

                if resourceValues.isDirectory == true {
                    totalSize += await calculateDirectorySize(item)
                } else if let fileSize = resourceValues.fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        } catch {
            logger.error("Failed to calculate directory size: \(error.localizedDescription)")
        }

        return totalSize
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Directory Info Row

struct DirectoryInfoRow: View {
    let title: String
    let path: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)

                Text(path)
                    .font(.caption2)
                    .monospaced()
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .cornerRadius(6)
    }
}
