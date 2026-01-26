// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// File-based application preferences replacing UserDefaults.
@MainActor
public class ApplicationPreferencesManager: ObservableObject {
    private let logger = Logger(label: "com.sam.config.apppreferences")
    private let configManager = ConfigurationManager.shared

    // MARK: - File Configuration

    private let preferencesFileName = "app-preferences.json"
    private let uiPreferencesFileName = "ui-preferences.json"
    private let debugPreferencesFileName = "debug-preferences.json"

    // MARK: - Application Preferences

    /// Save application preferences.
    public func saveAppPreferences(_ preferences: ApplicationPreferences) throws {
        try configManager.save(preferences,
                              to: preferencesFileName,
                              in: configManager.preferencesDirectory)

        logger.debug("Saved application preferences")
    }

    /// Load application preferences.
    public func loadAppPreferences() throws -> ApplicationPreferences {
        guard configManager.exists(preferencesFileName, in: configManager.preferencesDirectory) else {
            let defaultPreferences = ApplicationPreferences()
            logger.debug("No app preferences found, using defaults")
            return defaultPreferences
        }

        do {
            let preferences = try configManager.load(ApplicationPreferences.self,
                                                    from: preferencesFileName,
                                                    in: configManager.preferencesDirectory)

            logger.debug("Loaded application preferences")
            return preferences

        } catch {
            logger.error("Failed to load app preferences, using defaults: \(error)")
            return ApplicationPreferences()
        }
    }

    // MARK: - UI Setup

    /// Save UI preferences.
    public func saveUIPreferences(_ preferences: UIPreferences) throws {
        try configManager.save(preferences,
                              to: uiPreferencesFileName,
                              in: configManager.preferencesDirectory)

        logger.debug("Saved UI preferences")
    }

    /// Load UI preferences.
    public func loadUIPreferences() throws -> UIPreferences {
        guard configManager.exists(uiPreferencesFileName, in: configManager.preferencesDirectory) else {
            let defaultPreferences = UIPreferences()
            logger.debug("No UI preferences found, using defaults")
            return defaultPreferences
        }

        do {
            let preferences = try configManager.load(UIPreferences.self,
                                                    from: uiPreferencesFileName,
                                                    in: configManager.preferencesDirectory)

            logger.debug("Loaded UI preferences")
            return preferences

        } catch {
            logger.error("Failed to load UI preferences, using defaults: \(error)")
            return UIPreferences()
        }
    }

    // MARK: - Debug Preferences

    /// Save debug preferences.
    public func saveDebugPreferences(_ preferences: DebugPreferences) throws {
        try configManager.save(preferences,
                              to: debugPreferencesFileName,
                              in: configManager.preferencesDirectory)

        logger.debug("Saved debug preferences")
    }

    /// Load debug preferences.
    public func loadDebugPreferences() throws -> DebugPreferences {
        guard configManager.exists(debugPreferencesFileName, in: configManager.preferencesDirectory) else {
            let defaultPreferences = DebugPreferences()
            logger.debug("No debug preferences found, using defaults")
            return defaultPreferences
        }

        do {
            let preferences = try configManager.load(DebugPreferences.self,
                                                    from: debugPreferencesFileName,
                                                    in: configManager.preferencesDirectory)

            logger.debug("Loaded debug preferences")
            return preferences

        } catch {
            logger.error("Failed to load debug preferences, using defaults: \(error)")
            return DebugPreferences()
        }
    }

    // MARK: - Convenience Methods

    /// Reset all preferences to defaults.
    public func resetToDefaults() throws {
        /// Delete all preference files.
        let preferenceFiles = [preferencesFileName, uiPreferencesFileName, debugPreferencesFileName]

        for fileName in preferenceFiles {
            if configManager.exists(fileName, in: configManager.preferencesDirectory) {
                try configManager.delete(fileName, in: configManager.preferencesDirectory)
            }
        }

        /// Save default configurations.
        try saveAppPreferences(ApplicationPreferences())
        try saveUIPreferences(UIPreferences())
        try saveDebugPreferences(DebugPreferences())

        logger.debug("Reset all preferences to defaults")
    }

    /// Export all preferences to a single file.
    public func exportPreferences(to url: URL) throws {
        let appPrefs = try loadAppPreferences()
        let uiPrefs = try loadUIPreferences()
        let debugPrefs = try loadDebugPreferences()

        let exportData = ExportedPreferences(
            application: appPrefs,
            ui: uiPrefs,
            debug: debugPrefs,
            exportedAt: Date(),
            samVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(exportData)
        try data.write(to: url)

        logger.debug("Exported preferences to: \(url.path)")
    }

    /// Import preferences from a file.
    public func importPreferences(from url: URL) throws {
        let data = try Data(contentsOf: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let exportedPrefs = try decoder.decode(ExportedPreferences.self, from: data)

        /// Save imported preferences.
        try saveAppPreferences(exportedPrefs.application)
        try saveUIPreferences(exportedPrefs.ui)
        try saveDebugPreferences(exportedPrefs.debug)

        logger.debug("Imported preferences from: \(url.path)")
    }
}

// MARK: - Preference Models

public struct ApplicationPreferences: Codable {
    public let launchAtLogin: Bool
    public let enableNotifications: Bool
    public let enableSoundEffects: Bool
    public let autoSaveInterval: Int
    public let maxConversationHistory: Int
    public let enableTerminalAccess: Bool

    public init(launchAtLogin: Bool = false,
               enableNotifications: Bool = true,
               enableSoundEffects: Bool = true,
               autoSaveInterval: Int = 5,
               maxConversationHistory: Int = 100,
               enableTerminalAccess: Bool = false) {
        self.launchAtLogin = launchAtLogin
        self.enableNotifications = enableNotifications
        self.enableSoundEffects = enableSoundEffects
        self.autoSaveInterval = autoSaveInterval
        self.maxConversationHistory = maxConversationHistory
        self.enableTerminalAccess = enableTerminalAccess
    }
}

public struct UIPreferences: Codable {
    public let fontSize: Double
    public let enableAnimations: Bool
    public let theme: String
    public let sidebarWidth: Double
    public let windowWidth: Double
    public let windowHeight: Double

    public init(fontSize: Double = 14.0,
               enableAnimations: Bool = true,
               theme: String = "system",
               sidebarWidth: Double = 250.0,
               windowWidth: Double = 1000.0,
               windowHeight: Double = 700.0) {
        self.fontSize = fontSize
        self.enableAnimations = enableAnimations
        self.theme = theme
        self.sidebarWidth = sidebarWidth
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
    }
}

public struct DebugPreferences: Codable {
    public let enableDebugMode: Bool
    public let logLevel: String
    public let enableVerboseLogging: Bool
    public let enablePerformanceMetrics: Bool
    public let enableNetworkLogging: Bool

    public init(enableDebugMode: Bool = false,
               logLevel: String = "info",
               enableVerboseLogging: Bool = false,
               enablePerformanceMetrics: Bool = true,
               enableNetworkLogging: Bool = false) {
        self.enableDebugMode = enableDebugMode
        self.logLevel = logLevel
        self.enableVerboseLogging = enableVerboseLogging
        self.enablePerformanceMetrics = enablePerformanceMetrics
        self.enableNetworkLogging = enableNetworkLogging
    }
}

// MARK: - Export Model

public struct ExportedPreferences: Codable {
    let application: ApplicationPreferences
    let ui: UIPreferences
    let debug: DebugPreferences
    let exportedAt: Date
    let samVersion: String
}
