// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// File-based API endpoint configuration replacing UserDefaults.
@MainActor
public class EndpointConfigurationManager: ObservableObject {
    private let logger = Logger(label: "com.sam.config.endpointconfigmanager")
    private let configManager = ConfigurationManager.shared

    // MARK: - File Configuration

    private let providersFileName = "providers.json"
    private let serverConfigFileName = "server-config.json"

    // MARK: - Provider Management

    /// Save provider configuration.
    public func saveProvider(_ provider: ProviderConfiguration) throws {
        let fileName = "provider-\(provider.providerId).json"

        try configManager.save(provider,
                              to: fileName,
                              in: configManager.endpointsDirectory)

        /// Update provider index.
        try updateProviderIndex(providerId: provider.providerId, operation: .add)

        logger.debug("Saved provider configuration: \(provider.providerId)")
    }

    /// Load provider configuration.
    public func loadProvider(id: String) throws -> ProviderConfiguration? {
        let fileName = "provider-\(id).json"

        guard configManager.exists(fileName, in: configManager.endpointsDirectory) else {
            return nil
        }

        do {
            let provider = try configManager.load(ProviderConfiguration.self,
                                                 from: fileName,
                                                 in: configManager.endpointsDirectory)

            logger.debug("Loaded provider configuration: \(id)")
            return provider

        } catch {
            logger.error("Failed to load provider \(id): \(error)")
            throw error
        }
    }

    /// Load all provider configurations.
    public func loadAllProviders() throws -> [ProviderConfiguration] {
        let providerIndex = try loadProviderIndex()
        var providers: [ProviderConfiguration] = []

        for providerId in providerIndex.providerIds {
            if let provider = try loadProvider(id: providerId) {
                providers.append(provider)
            } else {
                logger.warning("Provider \(providerId) listed in index but file not found")
            }
        }

        logger.debug("Loaded \(providers.count) provider configurations")
        return providers
    }

    /// Delete provider configuration.
    public func deleteProvider(id: String) throws {
        let fileName = "provider-\(id).json"

        /// Delete provider file.
        if configManager.exists(fileName, in: configManager.endpointsDirectory) {
            try configManager.delete(fileName, in: configManager.endpointsDirectory)
        }

        /// Update provider index.
        try updateProviderIndex(providerId: id, operation: .remove)

        logger.debug("Deleted provider configuration: \(id)")
    }

    /// List all provider IDs.
    public func listProviderIds() throws -> [String] {
        let providerIndex = try loadProviderIndex()
        return providerIndex.providerIds
    }

    // MARK: - Server Configuration

    /// Save server configuration.
    public func saveServerConfig(_ config: ServerConfiguration) throws {
        try configManager.save(config,
                              to: serverConfigFileName,
                              in: configManager.endpointsDirectory)

        logger.debug("Saved server configuration - Port: \(config.port)")
    }

    /// Load server configuration.
    public func loadServerConfig() throws -> ServerConfiguration {
        guard configManager.exists(serverConfigFileName, in: configManager.endpointsDirectory) else {
            /// Return default configuration.
            let defaultConfig = ServerConfiguration()
            logger.debug("No server config found, using defaults")
            return defaultConfig
        }

        do {
            let config = try configManager.load(ServerConfiguration.self,
                                               from: serverConfigFileName,
                                               in: configManager.endpointsDirectory)

            logger.debug("Loaded server configuration - Port: \(config.port)")
            return config

        } catch {
            logger.error("Failed to load server config, using defaults: \(error)")
            return ServerConfiguration()
        }
    }

    // MARK: - Provider Defaults

    /// Save default configuration for a provider type.
    public func saveProviderDefaults(_ defaults: ProviderDefaults, for type: ProviderType) throws {
        let fileName = "defaults-\(type.rawValue).json"

        try configManager.save(defaults,
                              to: fileName,
                              in: configManager.endpointsDirectory)

        logger.debug("Saved provider defaults for: \(type.rawValue)")
    }

    /// Load default configuration for a provider type.
    public func loadProviderDefaults(for type: ProviderType) throws -> ProviderDefaults? {
        let fileName = "defaults-\(type.rawValue).json"

        guard configManager.exists(fileName, in: configManager.endpointsDirectory) else {
            return nil
        }

        do {
            let defaults = try configManager.load(ProviderDefaults.self,
                                                 from: fileName,
                                                 in: configManager.endpointsDirectory)

            logger.debug("Loaded provider defaults for: \(type.rawValue)")
            return defaults

        } catch {
            logger.error("Failed to load provider defaults for \(type.rawValue): \(error)")
            throw error
        }
    }

    // MARK: - Helper Methods

    private func loadProviderIndex() throws -> ProviderIndex {
        guard configManager.exists(providersFileName, in: configManager.endpointsDirectory) else {
            return ProviderIndex(providerIds: [])
        }

        return try configManager.load(ProviderIndex.self,
                                     from: providersFileName,
                                     in: configManager.endpointsDirectory)
    }

    private func updateProviderIndex(providerId: String, operation: IndexOperation) throws {
        var index = try loadProviderIndex()

        switch operation {
        case .add:
            if !index.providerIds.contains(providerId) {
                index.providerIds.append(providerId)
                index.providerIds.sort()
            }

        case .remove:
            index.providerIds.removeAll { $0 == providerId }
        }

        try configManager.save(index,
                              to: providersFileName,
                              in: configManager.endpointsDirectory)
    }

    /// Clear all endpoint configurations.
    public func clearAllEndpoints() throws {
        /// Get all provider files.
        let providerFiles = try configManager.listFiles(in: configManager.endpointsDirectory)

        /// Delete all configuration files.
        for fileName in providerFiles {
            try configManager.delete("\(fileName).json", in: configManager.endpointsDirectory)
        }

        logger.debug("Cleared all endpoint configurations")
    }
}

// MARK: - Supporting Models

private struct ProviderIndex: Codable {
    var providerIds: [String]
}

private enum IndexOperation {
    case add
    case remove
}
