// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Comprehensive file-based configuration management for SAM Replaces UserDefaults with robust JSON configuration system.
@MainActor
public class ConfigurationManager: ObservableObject {
    private let logger = Logger(label: "com.syntheticautonomicmind.sam.ConfigurationManager")

    // MARK: - Configuration Directories

    /// Base configuration directory: ~/Library/Application Support/SAM/.
    public let configurationDirectory: URL

    /// Conversations directory: ~/Library/Application Support/SAM/conversations/.
    public let conversationsDirectory: URL

    /// System prompts directory: ~/Library/Application Support/SAM/system-prompts/.
    public let systemPromptsDirectory: URL

    /// API endpoints directory: ~/Library/Application Support/SAM/endpoints/.
    public let endpointsDirectory: URL

    /// Application preferences directory: ~/Library/Application Support/SAM/preferences/.
    public let preferencesDirectory: URL

    /// Backup directory: ~/Library/Application Support/SAM/backups/.
    public let backupsDirectory: URL

    // MARK: - Singleton

    public static let shared = ConfigurationManager()

    // MARK: - Lifecycle

    private init() {
        /// Get Application Support directory.
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        /// Create SAM configuration directory structure.
        configurationDirectory = applicationSupport.appendingPathComponent("SAM")
        conversationsDirectory = configurationDirectory.appendingPathComponent("conversations")
        systemPromptsDirectory = configurationDirectory.appendingPathComponent("system-prompts")
        endpointsDirectory = configurationDirectory.appendingPathComponent("endpoints")
        preferencesDirectory = configurationDirectory.appendingPathComponent("preferences")
        backupsDirectory = configurationDirectory.appendingPathComponent("backups")

        /// Create directory structure on initialization.
        createDirectoryStructure()

        logger.debug("ConfigurationManager initialized with base directory: \(self.configurationDirectory.path)")
    }

    // MARK: - Directory Management

    private func createDirectoryStructure() {
        let directories = [
            configurationDirectory,
            conversationsDirectory,
            systemPromptsDirectory,
            endpointsDirectory,
            preferencesDirectory,
            backupsDirectory
        ]

        for directory in directories {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
                logger.debug("Created directory: \(directory.path)")
            } catch {
                logger.error("Failed to create directory \(directory.path): \(error)")
            }
        }
    }

    // MARK: - Generic Configuration Management

    /// Save any Codable object to a JSON file with atomic write operations.
    public func save<T: Codable>(_ object: T, to filename: String, in directory: URL) throws {
        let fileURL = directory.appendingPathComponent(filename)
        let tempURL = fileURL.appendingPathExtension("tmp")

        do {
            /// Encode to JSON with pretty printing.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(object)

            /// Atomic write: write to temp file first, then rename.
            try data.write(to: tempURL)

            /// Atomic rename operation.
            _ = try FileManager.default.replaceItem(at: fileURL, withItemAt: tempURL,
                                                 backupItemName: nil, options: [],
                                                 resultingItemURL: nil)

            logger.debug("Saved configuration to: \(fileURL.path)")

        } catch {
            /// Clean up temp file if operation failed.
            try? FileManager.default.removeItem(at: tempURL)
            throw ConfigurationError.saveFailure(error.localizedDescription)
        }
    }

    /// Load any Codable object from a JSON file.
    public func load<T: Codable>(_ type: T.Type, from filename: String, in directory: URL) throws -> T {
        let fileURL = directory.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ConfigurationError.fileNotFound(fileURL.path)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let object = try decoder.decode(type, from: data)
            logger.debug("Loaded configuration from: \(fileURL.path)")

            return object

        } catch {
            throw ConfigurationError.loadFailure(error.localizedDescription)
        }
    }

    /// Check if a configuration file exists.
    public func exists(_ filename: String, in directory: URL) -> Bool {
        let fileURL = directory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Delete a configuration file.
    public func delete(_ filename: String, in directory: URL) throws {
        let fileURL = directory.appendingPathComponent(filename)

        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.debug("Deleted configuration file: \(fileURL.path)")
        } catch {
            throw ConfigurationError.deleteFailure(error.localizedDescription)
        }
    }

    /// List all files in a configuration directory.
    public func listFiles(in directory: URL, withExtension ext: String = "json") throws -> [String] {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles])

            return contents
                .filter { $0.pathExtension.lowercased() == ext.lowercased() }
                .map { $0.deletingPathExtension().lastPathComponent }
                .sorted()

        } catch {
            throw ConfigurationError.listFailure(error.localizedDescription)
        }
    }

    // MARK: - Backup and Restore

    /// Create a complete backup of all configuration data.
    public func createBackup(name: String? = nil) throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let backupName = name ?? "sam-backup-\(timestamp)"
        let backupURL = backupsDirectory.appendingPathComponent(backupName)

        do {
            /// Create backup directory.
            try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true, attributes: nil)

            /// Copy all configuration directories to backup.
            let directoriesToBackup = [
                ("conversations", conversationsDirectory),
                ("system-prompts", systemPromptsDirectory),
                ("endpoints", endpointsDirectory),
                ("preferences", preferencesDirectory)
            ]

            for (name, sourceDirectory) in directoriesToBackup {
                let destinationURL = backupURL.appendingPathComponent(name)

                if FileManager.default.fileExists(atPath: sourceDirectory.path) {
                    try FileManager.default.copyItem(at: sourceDirectory, to: destinationURL)
                }
            }

            /// Create backup metadata.
            let metadata = BackupMetadata(
                version: "1.0",
                created: Date(),
                samVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            )

            try save(metadata, to: "backup-info.json", in: backupURL)

            logger.debug("Created backup: \(backupURL.path)")
            return backupURL

        } catch {
            throw ConfigurationError.backupFailure(error.localizedDescription)
        }
    }

    /// Restore configuration from a backup.
    public func restoreFromBackup(at backupURL: URL) throws {
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw ConfigurationError.fileNotFound(backupURL.path)
        }

        do {
            /// Validate backup structure.
            let backupInfo = try load(BackupMetadata.self, from: "backup-info.json", in: backupURL)
            logger.debug("Restoring backup created: \(backupInfo.created)")

            /// Create current backup before restore.
            let currentBackupURL = try createBackup(name: "pre-restore-\(ISO8601DateFormatter().string(from: Date()))")
            logger.debug("Created safety backup at: \(currentBackupURL.path)")

            /// Restore each directory.
            let directoriesToRestore = [
                ("conversations", conversationsDirectory),
                ("system-prompts", systemPromptsDirectory),
                ("endpoints", endpointsDirectory),
                ("preferences", preferencesDirectory)
            ]

            for (name, destinationDirectory) in directoriesToRestore {
                let sourceURL = backupURL.appendingPathComponent(name)

                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    /// Remove existing directory.
                    if FileManager.default.fileExists(atPath: destinationDirectory.path) {
                        try FileManager.default.removeItem(at: destinationDirectory)
                    }

                    /// Copy from backup.
                    try FileManager.default.copyItem(at: sourceURL, to: destinationDirectory)
                    logger.debug("Restored \(name) from backup")
                }
            }

            logger.debug("Successfully restored configuration from backup")

        } catch {
            throw ConfigurationError.restoreFailure(error.localizedDescription)
        }
    }

    /// List available backups.
    public func listBackups() throws -> [BackupInfo] {
        do {
            let backupContents = try FileManager.default.contentsOfDirectory(at: backupsDirectory,
                                                                            includingPropertiesForKeys: [.creationDateKey],
                                                                            options: [.skipsHiddenFiles])

            var backups: [BackupInfo] = []

            for backupURL in backupContents {
                guard backupURL.hasDirectoryPath else { continue }

                /// Try to load backup metadata.
                do {
                    let metadata = try load(BackupMetadata.self, from: "backup-info.json", in: backupURL)
                    let resourceValues = try backupURL.resourceValues(forKeys: [.fileSizeKey])

                    backups.append(BackupInfo(
                        name: backupURL.lastPathComponent,
                        path: backupURL.path,
                        created: metadata.created,
                        version: metadata.version,
                        samVersion: metadata.samVersion,
                        size: resourceValues.fileSize ?? 0
                    ))

                } catch {
                    logger.warning("Could not read backup metadata for: \(backupURL.path)")
                }
            }

            return backups.sorted { $0.created > $1.created }

        } catch {
            throw ConfigurationError.listFailure(error.localizedDescription)
        }
    }
}

// MARK: - Configuration Errors

public enum ConfigurationError: LocalizedError {
    case saveFailure(String)
    case loadFailure(String)
    case deleteFailure(String)
    case listFailure(String)
    case fileNotFound(String)
    case backupFailure(String)
    case restoreFailure(String)

    public var errorDescription: String? {
        switch self {
        case .saveFailure(let message):
            return "Failed to save configuration: \(message)"

        case .loadFailure(let message):
            return "Failed to load configuration: \(message)"

        case .deleteFailure(let message):
            return "Failed to delete configuration: \(message)"

        case .listFailure(let message):
            return "Failed to list configuration files: \(message)"

        case .fileNotFound(let path):
            return "Configuration file not found: \(path)"

        case .backupFailure(let message):
            return "Failed to create backup: \(message)"

        case .restoreFailure(let message):
            return "Failed to restore backup: \(message)"
        }
    }
}

// MARK: - Backup Models

public struct BackupMetadata: Codable {
    let version: String
    let created: Date
    let samVersion: String
}

public struct BackupInfo: Identifiable {
    public let id = UUID()
    let name: String
    let path: String
    let created: Date
    let version: String
    let samVersion: String
    let size: Int

    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: created)
    }
}
