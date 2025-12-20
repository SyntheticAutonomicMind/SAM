// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Fast file index for working directory Provides instant search capabilities by maintaining an in-memory index of all files in the working directory.
public class WorkingDirectoryIndexer {
    public struct FileEntry: Codable {
        public let path: String
        public let relativePath: String
        public let fileName: String
        public let fileExtension: String
        public let size: Int64
        public let modifiedAt: Date
        public let isDirectory: Bool

        public init(
            path: String,
            relativePath: String,
            fileName: String,
            fileExtension: String,
            size: Int64,
            modifiedAt: Date,
            isDirectory: Bool
        ) {
            self.path = path
            self.relativePath = relativePath
            self.fileName = fileName
            self.fileExtension = fileExtension
            self.size = size
            self.modifiedAt = modifiedAt
            self.isDirectory = isDirectory
        }
    }

    private var index: [FileEntry] = []
    private let workingDirectory: URL
    private let logger = Logger(label: "com.sam.file-indexer")
    private var fileSystemMonitor: DispatchSourceFileSystemObject?

    /// Directories to exclude from indexing.
    private let excludedDirectories: Set<String> = [
        ".git", ".build", "build", ".swiftpm",
        "node_modules", ".DS_Store", "DerivedData",
        ".xcode", "xcuserdata", ".vscode"
    ]

    /// File extensions to exclude.
    private let excludedExtensions: Set<String> = [
        "xcuserstate", "xcworkspacedata", "xcscheme"
    ]

    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
        buildIndex()
        startWatching()
    }

    deinit {
        stopWatching()
    }

    /// Build the file index by recursively scanning the working directory.
    public func buildIndex() {
        let startTime = Date()
        var entries: [FileEntry] = []

        logger.info("Building file index for \(workingDirectory.path)")

        /// Recursively scan directory.
        scanDirectory(url: workingDirectory, baseURL: workingDirectory, entries: &entries)

        index = entries.sorted { $0.relativePath < $1.relativePath }

        let elapsed = Date().timeIntervalSince(startTime)
        logger.info("Indexed \(index.count) files in \(String(format: "%.2f", elapsed * 1000))ms")
    }

    /// Recursively scan a directory and add files to index.
    private func scanDirectory(url: URL, baseURL: URL, entries: inout [FileEntry]) {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            logger.warning("Failed to create enumerator for \(url.path)")
            return
        }

        for case let fileURL as URL in enumerator {
            /// Get relative path.
            let relativePath = fileURL.path.replacingOccurrences(
                of: baseURL.path + "/",
                with: ""
            )

            /// Check if should exclude.
            let pathComponents = relativePath.components(separatedBy: "/")
            let shouldExclude = pathComponents.contains { excludedDirectories.contains($0) }

            if shouldExclude {
                enumerator.skipDescendants()
                continue
            }

            /// Get file attributes.
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey
            ]) else {
                continue
            }

            let isDirectory = resourceValues.isDirectory ?? false
            let fileName = fileURL.lastPathComponent
            let fileExtension = fileURL.pathExtension

            /// Skip excluded extensions.
            if excludedExtensions.contains(fileExtension) {
                continue
            }

            let size = Int64(resourceValues.fileSize ?? 0)
            let modifiedAt = resourceValues.contentModificationDate ?? Date()

            let entry = FileEntry(
                path: fileURL.path,
                relativePath: relativePath,
                fileName: fileName,
                fileExtension: fileExtension,
                size: size,
                modifiedAt: modifiedAt,
                isDirectory: isDirectory
            )

            entries.append(entry)
        }
    }

    /// Search files by name pattern (case-insensitive).
    public func searchByName(query: String) -> [FileEntry] {
        let lowercaseQuery = query.lowercased()
        return index.filter { entry in
            entry.fileName.lowercased().contains(lowercaseQuery) ||
            entry.relativePath.lowercased().contains(lowercaseQuery)
        }
    }

    /// Search files by extension.
    public func searchByExtension(_ ext: String) -> [FileEntry] {
        let normalizedExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        return index.filter { $0.fileExtension == normalizedExt }
    }

    /// Search files by multiple criteria.
    public func search(
        namePattern: String? = nil,
        extensions: [String]? = nil,
        minSize: Int64? = nil,
        maxSize: Int64? = nil,
        modifiedAfter: Date? = nil,
        modifiedBefore: Date? = nil,
        includeDirectories: Bool = false
    ) -> [FileEntry] {
        var results = index

        /// Filter by directory flag.
        if !includeDirectories {
            results = results.filter { !$0.isDirectory }
        }

        /// Filter by name pattern.
        if let pattern = namePattern {
            let lowercasePattern = pattern.lowercased()
            results = results.filter {
                $0.fileName.lowercased().contains(lowercasePattern) ||
                $0.relativePath.lowercased().contains(lowercasePattern)
            }
        }

        /// Filter by extensions.
        if let exts = extensions {
            let normalizedExts = exts.map { ext in
                ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
            }
            results = results.filter { normalizedExts.contains($0.fileExtension) }
        }

        /// Filter by size.
        if let min = minSize {
            results = results.filter { $0.size >= min }
        }
        if let max = maxSize {
            results = results.filter { $0.size <= max }
        }

        /// Filter by modification date.
        if let after = modifiedAfter {
            results = results.filter { $0.modifiedAt >= after }
        }
        if let before = modifiedBefore {
            results = results.filter { $0.modifiedAt <= before }
        }

        return results
    }

    /// Get all indexed files.
    public func getAllFiles() -> [FileEntry] {
        return index
    }

    /// Get file count.
    public func getFileCount() -> Int {
        return index.count
    }

    /// Get file statistics.
    public func getStatistics() -> [String: Any] {
        let totalSize = index.reduce(0) { $0 + $1.size }
        let fileCount = index.filter { !$0.isDirectory }.count
        let dirCount = index.filter { $0.isDirectory }.count

        var extensionCounts: [String: Int] = [:]
        for entry in index where !entry.isDirectory {
            let ext = entry.fileExtension.isEmpty ? "(no extension)" : entry.fileExtension
            extensionCounts[ext, default: 0] += 1
        }

        return [
            "totalFiles": fileCount,
            "totalDirectories": dirCount,
            "totalSize": totalSize,
            "extensionCounts": extensionCounts,
            "workingDirectory": workingDirectory.path
        ]
    }

    /// Start watching for file system changes NOTE: DispatchSource file watching has limitations - it only watches the directory inode, not contents.
    private func startWatching() {
        /// Disabled - DispatchSource.makeFileSystemObjectSource doesn't detect file additions User code should call refresh() explicitly when needed.
        logger.debug("File watching not active - call refresh() to update index")
    }

    /// Stop watching for file system changes.
    private func stopWatching() {
        fileSystemMonitor?.cancel()
        fileSystemMonitor = nil
    }

    /// Force refresh the index.
    public func refresh() {
        buildIndex()
    }
}
