// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import Combine

/// Manages LoRA (Low-Rank Adaptation) files for Stable Diffusion
@MainActor
public class LoRAManager: ObservableObject {
    private let logger = Logger(label: "com.sam.lora")

    /// Published properties for UI binding
    @Published public var availableLoRAs: [LoRAInfo] = []
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String?

    /// Storage paths
    public let loraDirectory: URL
    private let metadataDirectory: URL

    /// LoRA information structure
    public struct LoRAInfo: Codable, Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let filename: String
        public let path: URL
        public let sizeKB: Int
        public let baseModel: String
        public let triggerWords: [String]
        public let downloadedDate: Date
        public let civitaiId: String?
        public let previewImageURL: String?
        public let description: String?

        public init(
            id: String,
            name: String,
            filename: String,
            path: URL,
            sizeKB: Int,
            baseModel: String,
            triggerWords: [String],
            downloadedDate: Date,
            civitaiId: String? = nil,
            previewImageURL: String? = nil,
            description: String? = nil
        ) {
            self.id = id
            self.name = name
            self.filename = filename
            self.path = path
            self.sizeKB = sizeKB
            self.baseModel = baseModel
            self.triggerWords = triggerWords
            self.downloadedDate = downloadedDate
            self.civitaiId = civitaiId
            self.previewImageURL = previewImageURL
            self.description = description
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        public static func == (lhs: LoRAInfo, rhs: LoRAInfo) -> Bool {
            lhs.id == rhs.id
        }
    }

    public init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        loraDirectory = cachesDir.appendingPathComponent("sam/models/stable-diffusion/loras")
        metadataDirectory = loraDirectory.appendingPathComponent(".metadata")

        createDirectoriesIfNeeded()
        loadLoRAs()
    }

    /// Create directories if they don't exist
    private func createDirectoriesIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: loraDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
            logger.info("LoRA directories created: \(loraDirectory.path)")
        } catch {
            logger.error("Failed to create LoRA directories: \(error.localizedDescription)")
        }
    }

    /// Load all LoRAs from disk
    public func loadLoRAs() {
        isLoading = true
        errorMessage = nil

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: loraDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )

            var loras: [LoRAInfo] = []

            for fileURL in contents {
                guard fileURL.pathExtension == "safetensors" else { continue }

                if let loraInfo = loadLoRAInfo(from: fileURL) {
                    loras.append(loraInfo)
                }
            }

            availableLoRAs = loras.sorted { $0.downloadedDate > $1.downloadedDate }
            logger.info("Loaded \(loras.count) LoRAs")

        } catch {
            logger.error("Failed to load LoRAs: \(error.localizedDescription)")
            errorMessage = "Failed to load LoRAs: \(error.localizedDescription)"
            availableLoRAs = []
        }

        isLoading = false
    }

    /// Load LoRA info from file, including metadata if available
    private func loadLoRAInfo(from fileURL: URL) -> LoRAInfo? {
        do {
            let filename = fileURL.lastPathComponent
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = (fileAttributes[.size] as? Int64) ?? 0
            let creationDate = (fileAttributes[.creationDate] as? Date) ?? Date()

            // Load metadata if exists
            let metadataURL = metadataDirectory.appendingPathComponent(
                fileURL.deletingPathExtension().lastPathComponent + ".json"
            )

            if FileManager.default.fileExists(atPath: metadataURL.path),
               let metadataData = try? Data(contentsOf: metadataURL),
               let metadata = try? JSONDecoder().decode(LoRAMetadata.self, from: metadataData) {

                return LoRAInfo(
                    id: metadata.id ?? UUID().uuidString,
                    name: metadata.name,
                    filename: filename,
                    path: fileURL,
                    sizeKB: Int(fileSize / 1024),
                    baseModel: metadata.baseModel,
                    triggerWords: metadata.triggerWords,
                    downloadedDate: creationDate,
                    civitaiId: metadata.civitaiId,
                    previewImageURL: metadata.previewImageURL,
                    description: metadata.description
                )
            } else {
                // No metadata, create basic info
                let name = fileURL.deletingPathExtension().lastPathComponent
                return LoRAInfo(
                    id: UUID().uuidString,
                    name: name,
                    filename: filename,
                    path: fileURL,
                    sizeKB: Int(fileSize / 1024),
                    baseModel: "Unknown",
                    triggerWords: [],
                    downloadedDate: creationDate
                )
            }

        } catch {
            logger.error("Failed to load LoRA info for \(fileURL.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Save metadata for a downloaded LoRA
    public func saveMetadata(filename: String, metadata: LoRAMetadata) throws {
        let metadataURL = metadataDirectory.appendingPathComponent(
            URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent + ".json"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL)

        logger.info("Saved metadata for \(filename)")
    }

    /// Delete a LoRA and its metadata
    public func deleteLoRA(_ lora: LoRAInfo) throws {
        // Delete the safetensors file
        try FileManager.default.removeItem(at: lora.path)

        // Delete metadata if exists
        let metadataURL = metadataDirectory.appendingPathComponent(
            lora.path.deletingPathExtension().lastPathComponent + ".json"
        )

        if FileManager.default.fileExists(atPath: metadataURL.path) {
            try FileManager.default.removeItem(at: metadataURL)
        }

        logger.info("Deleted LoRA: \(lora.name)")

        // Reload list
        loadLoRAs()
    }

    /// Get LoRAs compatible with a specific base model
    public func getCompatibleLoRAs(baseModel: String) -> [LoRAInfo] {
        return availableLoRAs.filter { lora in
            lora.baseModel.lowercased().contains(baseModel.lowercased()) ||
            baseModel.lowercased().contains(lora.baseModel.lowercased()) ||
            lora.baseModel == "Unknown"
        }
    }

    /// Register a downloaded LoRA file with metadata
    /// This should be called after downloading via ModelDownloadManager
    /// - Parameters:
    ///   - filename: Filename of the downloaded LoRA
    ///   - metadata: Metadata to save with the LoRA
    /// - Returns: Downloaded LoRA info
    public func registerDownloadedLoRA(
        filename: String,
        metadata: LoRAMetadata
    ) throws -> LoRAInfo {
        logger.info("Registering downloaded LoRA: \(filename)")

        // Verify file exists
        let filePath = loraDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            throw NSError(domain: "LoRAManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Downloaded file not found: \(filename)"])
        }

        // Save metadata
        try saveMetadata(filename: filename, metadata: metadata)

        logger.info("LoRA registered successfully: \(filename)")

        // Reload list
        loadLoRAs()

        // Return the LoRA info
        guard let loraInfo = availableLoRAs.first(where: { $0.filename == filename }) else {
            throw NSError(domain: "LoRAManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to find registered LoRA"])
        }

        return loraInfo
    }
}

/// Metadata structure for LoRA files
public struct LoRAMetadata: Codable {
    public let id: String?
    public let name: String
    public let baseModel: String
    public let triggerWords: [String]
    public let civitaiId: String?
    public let previewImageURL: String?
    public let description: String?

    public init(
        id: String? = nil,
        name: String,
        baseModel: String,
        triggerWords: [String],
        civitaiId: String? = nil,
        previewImageURL: String? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.baseModel = baseModel
        self.triggerWords = triggerWords
        self.civitaiId = civitaiId
        self.previewImageURL = previewImageURL
        self.description = description
    }
}
