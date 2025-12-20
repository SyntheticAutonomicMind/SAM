// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Combine
import Logging

/// Manages folders for conversation organization
@MainActor
public class FolderManager: ObservableObject {
    @Published public private(set) var folders: [Folder] = []
    private let storageURL: URL
    private let logger = Logger(label: "com.sam.folders")

    public init() {
        let cachesDir = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        storageURL = cachesDir
            .appendingPathComponent("sam/conversations/folders.json")
        loadFolders()
    }

    /// Create a new folder
    public func createFolder(name: String, color: String? = nil, icon: String? = nil) -> Folder {
        let folder = Folder(name: name, color: color, icon: icon)
        folders.append(folder)
        saveFolders()
        logger.info("Created folder: \(name)")
        return folder
    }

    /// Delete a folder by ID
    public func deleteFolder(_ id: String) {
        folders.removeAll { $0.id == id }
        saveFolders()
        logger.info("Deleted folder: \(id)")
    }

    /// Update an existing folder
    public func updateFolder(_ folder: Folder) {
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index] = folder
            saveFolders()
            logger.info("Updated folder: \(folder.name)")
        }
    }

    /// Toggle folder collapsed state
    public func toggleCollapsed(_ id: String) {
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].isCollapsed.toggle()
            saveFolders()
            logger.debug("Toggled folder collapse: \(id) -> \(folders[index].isCollapsed)")
        }
    }

    /// Get folder by ID
    public func getFolder(by id: String) -> Folder? {
        return folders.first { $0.id == id }
    }

    /// Load folders from disk
    private func loadFolders() {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([Folder].self, from: data)
        else {
            logger.debug("No folders file found, starting fresh")
            return
        }
        folders = decoded
        logger.info("Loaded \(folders.count) folders")
    }

    /// Save folders to disk
    private func saveFolders() {
        guard let encoded = try? JSONEncoder().encode(folders)
        else {
            logger.error("Failed to encode folders")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoded.write(to: storageURL)
            logger.debug("Saved \(folders.count) folders")
        } catch {
            logger.error("Failed to save folders: \(error)")
        }
    }
}
