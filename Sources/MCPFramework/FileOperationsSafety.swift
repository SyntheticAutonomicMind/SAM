// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// Provides safety infrastructure for file operations including atomic writes, backups, and rollback.
public class FileOperationsSafety: @unchecked Sendable {
    private let fileManager = FileManager.default

    /// Result of a file operation with safety features.
    public struct OperationResult: @unchecked Sendable {
        public let success: Bool
        public let backupPath: String?
        public let error: String?
        public let metadata: [String: Any]

        public init(success: Bool, backupPath: String? = nil, error: String? = nil, metadata: [String: Any] = [:]) {
            self.success = success
            self.backupPath = backupPath
            self.error = error
            self.metadata = metadata
        }
    }

    /// Validation result for file operations.
    public struct ValidationResult {
        public let isValid: Bool
        public let error: String?

        public init(isValid: Bool, error: String? = nil) {
            self.isValid = isValid
            self.error = error
        }
    }

    // MARK: - File Validation

    /// Validates that a file path is safe for read operations.
    public func validateFileForReading(_ path: String) -> ValidationResult {
        /// Convert to URL for proper path handling.
        let url = URL(fileURLWithPath: path)
        let filePath = url.path

        /// Check if file exists.
        guard fileManager.fileExists(atPath: filePath) else {
            let error = """
            ERROR: File not found for reading operation
            - Attempted to read: \(filePath)
            - Issue: File does not exist at this location
            - Suggestions:
              1. Verify the file path is correct
              2. Check if file exists in working directory using list_dir operation with path="."
              3. If file should exist, verify working directory path
              4. Consider using file_search to locate the file
            """
            return ValidationResult(isValid: false, error: error)
        }

        /// Check if it's actually a file (not a directory).
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            let error = """
            ERROR: Path is a directory, not a file
            - Attempted to read: \(filePath)
            - Issue: This path points to a directory
            - Suggestion: Use list_dir operation to read directory contents
            """
            return ValidationResult(isValid: false, error: error)
        }

        /// Check read permissions.
        guard fileManager.isReadableFile(atPath: filePath) else {
            let error = """
            ERROR: No read permission for file
            - Attempted to read: \(filePath)
            - Issue: File exists but cannot be read (permission denied)
            - Suggestion: Check file permissions or request user_collaboration for authorization
            """
            return ValidationResult(isValid: false, error: error)
        }

        return ValidationResult(isValid: true)
    }

    /// Validates that a file path is safe for write operations.
    public func validateFileForWriting(_ path: String) -> ValidationResult {
        let url = URL(fileURLWithPath: path)
        let filePath = url.path

        /// Check if file exists.
        guard fileManager.fileExists(atPath: filePath) else {
            let error = """
            ERROR: File not found for write operation
            - Attempted to write to: \(filePath)
            - Issue: File does not exist at this location
            - Suggestions:
              1. Use create_file operation to create a new file first
              2. Verify the file path is correct
              3. Check working directory with list_dir operation
            """
            return ValidationResult(isValid: false, error: error)
        }

        /// Check if it's actually a file (not a directory).
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            let error = """
            ERROR: Path is a directory, not a file
            - Attempted to write to: \(filePath)
            - Issue: This path points to a directory
            - Suggestion: Specify a file path within the directory
            """
            return ValidationResult(isValid: false, error: error)
        }

        /// Check write permissions.
        guard fileManager.isWritableFile(atPath: filePath) else {
            let error = """
            ERROR: No write permission for file
            - Attempted to write to: \(filePath)
            - Issue: File exists but cannot be written (permission denied)
            - Suggestion: Check file permissions or request user_collaboration for authorization
            """
            return ValidationResult(isValid: false, error: error)
        }

        return ValidationResult(isValid: true)
    }

    /// Validates that a directory path exists and is accessible.
    public func validateDirectory(_ path: String) -> ValidationResult {
        let url = URL(fileURLWithPath: path)
        let dirPath = url.path

        /// Check if directory exists.
        guard fileManager.fileExists(atPath: dirPath) else {
            let error = """
            ERROR: Directory not found
            - Attempted to access: \(dirPath)
            - Issue: Directory does not exist at this location
            - Suggestions:
              1. Verify the directory path is correct
              2. Check parent directory with list_dir operation
              3. Use create_directory operation to create the directory if needed
            """
            return ValidationResult(isValid: false, error: error)
        }

        /// Check if it's actually a directory.
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: dirPath, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
            let error = """
            ERROR: Path is not a directory
            - Attempted to access: \(dirPath)
            - Issue: This path points to a file, not a directory
            - Suggestion: Verify the path or use appropriate file operation
            """
            return ValidationResult(isValid: false, error: error)
        }

        /// Check read permissions.
        guard fileManager.isReadableFile(atPath: dirPath) else {
            let error = """
            ERROR: No read permission for directory
            - Attempted to access: \(dirPath)
            - Issue: Directory exists but cannot be read (permission denied)
            - Suggestion: Check directory permissions or request user_collaboration for authorization
            """
            return ValidationResult(isValid: false, error: error)
        }

        return ValidationResult(isValid: true)
    }

    // MARK: - Backup Operations

    /// Creates a backup of a file before modification.
    public func createBackup(_ path: String) -> OperationResult {
        let url = URL(fileURLWithPath: path)
        let filePath = url.path

        /// Validate file exists.
        let validation = validateFileForReading(filePath)
        guard validation.isValid else {
            return OperationResult(success: false, error: validation.error)
        }

        /// Use UUID instead of timestamp to prevent backup conflicts Timestamp-based backups fail when multiple operations occur in same second UUID guarantees unique backup filenames even for rapid successive operations.
        let backupIdentifier = UUID().uuidString
        let backupPath = "\(filePath).backup.\(backupIdentifier)"
        let backupURL = URL(fileURLWithPath: backupPath)

        do {
            /// Copy file to backup location.
            try fileManager.copyItem(at: url, to: backupURL)
            return OperationResult(success: true, backupPath: backupPath)
        } catch {
            /// Check if error is due to existing backup file.
            if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileWriteFileExistsError {
                /// This should never happen with UUID, but handle it gracefully.
                return OperationResult(success: false, error: "Backup already exists (UUID collision - extremely rare)")
            }
            return OperationResult(success: false, error: "Failed to create backup: \(error.localizedDescription)")
        }
    }

    /// Restores a file from backup.
    public func restoreFromBackup(_ originalPath: String, backupPath: String) -> OperationResult {
        let originalURL = URL(fileURLWithPath: originalPath)
        let backupURL = URL(fileURLWithPath: backupPath)

        /// Verify backup exists.
        guard fileManager.fileExists(atPath: backupPath) else {
            return OperationResult(success: false, error: "Backup file not found: \(backupPath)")
        }

        do {
            /// Remove current file if it exists.
            if fileManager.fileExists(atPath: originalPath) {
                try fileManager.removeItem(at: originalURL)
            }

            /// Copy backup back to original location.
            try fileManager.copyItem(at: backupURL, to: originalURL)

            return OperationResult(success: true)
        } catch {
            return OperationResult(success: false, error: "Failed to restore from backup: \(error.localizedDescription)")
        }
    }

    /// Removes a backup file.
    public func removeBackup(_ backupPath: String) -> OperationResult {
        let backupURL = URL(fileURLWithPath: backupPath)

        guard fileManager.fileExists(atPath: backupPath) else {
            return OperationResult(success: true)
        }

        do {
            try fileManager.removeItem(at: backupURL)
            return OperationResult(success: true)
        } catch {
            /// Non-critical error - backup removal failure doesn't affect operation success.
            return OperationResult(success: true, error: "Warning: Failed to remove backup: \(error.localizedDescription)")
        }
    }

    // MARK: - Atomic Write Operations

    /// Performs an atomic write of content to a file with automatic backup and rollback.
    public func atomicWrite(content: String, to path: String, createBackup: Bool = true) -> OperationResult {
        let url = URL(fileURLWithPath: path)
        let filePath = url.path

        /// Validate file for writing.
        let validation = validateFileForWriting(filePath)
        guard validation.isValid else {
            return OperationResult(success: false, error: validation.error)
        }

        /// Create backup if requested.
        var backupPath: String?
        if createBackup {
            let backupResult = self.createBackup(filePath)
            guard backupResult.success else {
                return OperationResult(success: false, error: "Backup failed: \(backupResult.error ?? "Unknown error")")
            }
            backupPath = backupResult.backupPath
        }

        /// Perform atomic write.
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)

            /// Success - return result with backup path.
            return OperationResult(
                success: true,
                backupPath: backupPath,
                metadata: ["bytesWritten": content.utf8.count]
            )
        } catch {
            /// Write failed - attempt rollback if we have a backup.
            if let backup = backupPath {
                let restoreResult = restoreFromBackup(filePath, backupPath: backup)
                if restoreResult.success {
                    return OperationResult(
                        success: false,
                        backupPath: backup,
                        error: "Write failed, restored from backup: \(error.localizedDescription)"
                    )
                } else {
                    return OperationResult(
                        success: false,
                        backupPath: backup,
                        error: "Write failed AND rollback failed: \(error.localizedDescription). Backup at: \(backup)"
                    )
                }
            } else {
                return OperationResult(success: false, error: "Write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Reads file content safely with error handling.
    public func readFile(_ path: String) -> (content: String?, error: String?) {
        let url = URL(fileURLWithPath: path)
        let filePath = url.path

        /// Validate file for reading.
        let validation = validateFileForReading(filePath)
        guard validation.isValid else {
            return (nil, validation.error)
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            return (content, nil)
        } catch {
            return (nil, "Failed to read file: \(error.localizedDescription)")
        }
    }

    // MARK: - Safe File Modification

    /// Safely modifies a file using a transformation closure with automatic backup/rollback.
    public func safelyModifyFile(
        _ path: String,
        transformation: (String) throws -> String
    ) -> OperationResult {
        /// Read original content.
        let (originalContent, readError) = readFile(path)
        guard let original = originalContent else {
            return OperationResult(success: false, error: readError)
        }

        /// Apply transformation.
        let modifiedContent: String
        do {
            modifiedContent = try transformation(original)
        } catch {
            return OperationResult(success: false, error: "Transformation failed: \(error.localizedDescription)")
        }

        /// Write modified content with backup.
        let writeResult = atomicWrite(content: modifiedContent, to: path, createBackup: true)
        return writeResult
    }
}
