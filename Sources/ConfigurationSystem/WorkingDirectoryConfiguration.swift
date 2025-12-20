// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// Configuration for SAM's working directory base path
/// Provides centralized management of the base directory for all conversation working directories
public class WorkingDirectoryConfiguration: ObservableObject {
    nonisolated(unsafe) public static let shared = WorkingDirectoryConfiguration()

    private static let basePathKey = "workingDirectory.basePath"
    private static let defaultBasePath = "~/SAM"

    @Published public private(set) var basePath: String

    private init() {
        // Load from UserDefaults or use default
        self.basePath = UserDefaults.standard.string(forKey: Self.basePathKey) ?? Self.defaultBasePath
    }

    /// Get the full expanded base path
    public var expandedBasePath: String {
        NSString(string: basePath).expandingTildeInPath
    }

    /// Update the base path and persist to UserDefaults
    public func updateBasePath(_ newPath: String) {
        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed

        self.basePath = normalized
        UserDefaults.standard.set(normalized, forKey: Self.basePathKey)

        // Create base directory if it doesn't exist
        let expandedPath = NSString(string: normalized).expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: expandedPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Reset to default base path
    public func resetToDefault() {
        updateBasePath(Self.defaultBasePath)
    }

    /// Build a conversation working directory path
    /// - Parameter subdirectory: The subdirectory name (e.g., conversation title or topic name)
    /// - Returns: Full path like "/Users/name/SAM/subdirectory/"
    public func buildPath(subdirectory: String) -> String {
        let safeName = subdirectory.replacingOccurrences(of: "/", with: "-")
        return NSString(string: "\(basePath)/\(safeName)/").expandingTildeInPath
    }

    /// Get the default base path constant
    public static var `default`: String {
        defaultBasePath
    }
}
