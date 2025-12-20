// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

private let logger = Logger(label: "SAM.ConfigurationSystem.BuildConfiguration")

/// Build configuration for SAM Provides compile-time configuration flags for DEBUG and RELEASE builds.
public struct BuildConfiguration {
    /// Whether SAM is built in DEBUG mode DEBUG mode enables: - Verbose logging and debugging output - Full tool schema disclosure to agents - Development-friendly error messages - Internal protocol information visibility.
    public static let isDebug: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Whether SAM is built in RELEASE mode RELEASE mode enables: - Optimized logging (warnings and errors only) - User-friendly tool capability descriptions - Professional error messages - Internal protocol information hidden.
    public static let isRelease: Bool = {
        return !isDebug
    }()

    // MARK: - Tool Disclosure Settings

    /// Whether to allow SAM to disclose detailed tool schemas - DEBUG: true (agents can see full implementation details) - RELEASE: false (users see abstract capabilities only).
    public static var allowDetailedToolDisclosure: Bool {
        return isDebug
    }

    /// Whether to allow SAM to disclose internal protocols - DEBUG: true (full MCP protocol details visible) - RELEASE: false (implementation details hidden).
    public static var allowInternalProtocolDisclosure: Bool {
        return isDebug
    }

    /// Whether to allow SAM to disclose parameter schemas - DEBUG: true (full parameter types and structures) - RELEASE: false (high-level usage patterns only).
    public static var allowParameterSchemaDisclosure: Bool {
        return isDebug
    }

    // MARK: - Logging Settings

    /// Whether verbose logging is enabled.
    public static var verboseLogging: Bool {
        return isDebug
    }

    /// Whether debug-level logging is enabled.
    public static var debugLogging: Bool {
        return isDebug
    }

    // MARK: - UI Setup

    /// Human-readable build configuration name.
    public static var configurationName: String {
        return isDebug ? "Debug" : "Release"
    }

    /// Build timestamp (compile time).
    public static let buildTimestamp = Date()

    /// Build version information.
    public static let buildVersion = "1.0.0-beta"

    // MARK: - Helper Methods

    /// Log build configuration for debugging Useful for verifying Release builds have correct flag values.
    public static func logBuildMode() {
        logger.debug("CONFIG: BuildConfiguration.configurationName: \(configurationName)")
        logger.debug("CONFIG: BuildConfiguration.isDebug: \(isDebug)")
        logger.debug("CONFIG: BuildConfiguration.isRelease: \(isRelease)")
        logger.debug("CONFIG: BuildConfiguration.allowDetailedToolDisclosure: \(allowDetailedToolDisclosure)")
        logger.debug("CONFIG: BuildConfiguration.allowInternalProtocolDisclosure: \(allowInternalProtocolDisclosure)")
        logger.debug("CONFIG: BuildConfiguration.allowParameterSchemaDisclosure: \(allowParameterSchemaDisclosure)")
    }
}
