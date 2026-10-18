// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Unified credential store for all API keys, tokens, and secrets in SAM.
///
/// Replaces direct UserDefaults access for sensitive data across all SAM modules.
/// All credentials are stored exclusively in the macOS Keychain via `KeychainManager`.
///
/// **Two security models were merged:**
/// - Model 1 (Keychain): `CopilotTokenStore` already stored Copilot tokens in Keychain.
/// - Model 2 (UserDefaults): Provider API keys, ALICE keys, SerpAPI keys, and the SAM
///   API token were stored in plaintext UserDefaults. These are now migrated to Keychain.
///
/// **Migration:** On first launch after this change (`initialize()`), existing UserDefaults
/// credentials are transparently moved to Keychain. After migration, old UserDefaults entries
/// are cleared. A version flag prevents re-migration on subsequent launches.
///
/// **Startup gating:** `initialize()` sets `isReady = true` when complete. The app's
/// WindowGroup should show a loading screen until `isReady` is true, ensuring no service
/// or UI function attempts to access a secret before it's available.
///
/// Usage:
/// ```swift
/// let store = CredentialStore.shared
/// await store.initialize()  // Run once at app startup
/// await store.waitUntilReady()  // Block until migration completes
///
/// let key = await store.providerAPIKey(for: "openai")
/// try await store.setProviderAPIKey("sk-...", for: "openai")
/// ```
@MainActor
public final class CredentialStore: ObservableObject {
    /// Shared singleton instance.
    public static let shared = CredentialStore()

    /// Whether the credential store has completed initialization (including migration).
    /// UI and services should wait until this is true before accessing secrets.
    @Published public private(set) var isReady: Bool = false

    /// Whether migration from legacy UserDefaults storage is currently in progress.
    @Published public private(set) var isMigrating: Bool = false

    /// Number of credentials migrated during the current initialization.
    @Published public private(set) var migratedCount: Int = 0

    private let logger = Logger(label: "com.sam.security.credentialstore")
    private let keychain = KeychainManager.shared

    /// UserDefaults key for tracking migration version.
    private let migrationVersionDefaultsKey = "samCredentialMigrationVersion"
    
    /// Current migration version. Bump this when migration logic changes.
    private let currentMigrationVersion = 1

    private init() {}

    // MARK: - Initialization

    /// Initialize the credential store by running migration if needed.
    ///
    /// This method is idempotent — if migration has already been completed,
    /// it simply marks the store as ready. Must be called once at app startup
    /// before any credentials are accessed.
    ///
    /// Blocks until migration is complete.
    public func initialize() async {
        let storedVersion = UserDefaults.standard.integer(forKey: migrationVersionDefaultsKey)

        if storedVersion < currentMigrationVersion {
            isMigrating = true
            migratedCount = 0
            await performMigration()
            UserDefaults.standard.set(currentMigrationVersion, forKey: migrationVersionDefaultsKey)
            UserDefaults.standard.synchronize()
            isMigrating = false
            logger.info("CredentialStore migration complete. Migrated \(migratedCount) credentials.")
        } else {
            logger.debug("CredentialStore already migrated (version \(storedVersion)).")
        }

        isReady = true
        logger.info("CredentialStore is ready.")
    }

    /// Block until the credential store is ready.
    ///
    /// Call this from any service or function that needs credentials to ensure
    /// migration has completed before proceeding.
    public func waitUntilReady() async {
        while !isReady {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    // MARK: - Migration

    /// Migrate all known UserDefaults-based secrets to Keychain.
    ///
    /// This covers:
    /// 1. Provider API keys (from `provider_config_<id>` JSON in UserDefaults)
    /// 2. ALICE API key (`alice_api_key`)
    /// 3. SerpAPI key (`serpAPIKey`)
    /// 4. SAM API token (`samAPIToken`)
    private func performMigration() async {
        // 1. Migrate provider API keys from UserDefaults
        await migrateProviderAPIKeys()

        // 2. Migrate ALICE API key
        await migrateUserDefaultsKey("alice_api_key", to: aliceKeychainAccount)

        // 3. Migrate SerpAPI key
        await migrateUserDefaultsKey("serpAPIKey", to: serpAPIKeychainAccount)

        // 4. Migrate SAM API token (used by the local HTTP API server if enabled)
        await migrateUserDefaultsKey("samAPIToken", to: samAPITokenKeychainAccount)
    }

    /// Migrate a simple string secret from UserDefaults to Keychain.
    /// Clears the UserDefaults entry after successful migration.
    private func migrateUserDefaultsKey(_ userDefaultsKey: String, to keychainAccount: String) async {
        guard let value = UserDefaults.standard.string(forKey: userDefaultsKey), !value.isEmpty else {
            return
        }

        do {
            try await storeAndBump(secret: value, for: keychainAccount)
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            UserDefaults.standard.synchronize()
            logger.info("Migrated secret from UserDefaults '\(userDefaultsKey)' to Keychain account '\(keychainAccount)'")
        } catch {
            logger.error("Failed to migrate '\(userDefaultsKey)' to Keychain: \(error)")
            // If migration fails, the secret remains in UserDefaults.
            // We don't want to block app startup on a single key migration failure,
            // but we log it as an error so it's visible.
        }
    }

    /// Migrate provider API keys from UserDefaults JSON configs to Keychain.
    ///
    /// Old approach: `ProviderConfiguration` including `apiKey` was encoded as JSON
    /// and stored in UserDefaults under `provider_config_<providerId>`.
    /// New approach: `apiKey` is stripped from the config before saving to UserDefaults,
    /// and stored separately in Keychain under `provider_api_key.<providerId>`.
    ///
    /// This migration reads old configs, extracts apiKey, stores it in Keychain,
    /// and re-saves the config without apiKey.
    private func migrateProviderAPIKeys() async {
        // Collect all known provider IDs (default + any custom saved IDs)
        let defaultIds = [
            "openai", "github-copilot", "deepseek", "gemini", "minimax",
            "openrouter", "local-llama", "local-mlx", "remote-llama",
            "ollama-cloud", "zai", "zai-coding", "custom"
        ]
        let savedIds = UserDefaults.standard.stringArray(forKey: "saved_provider_ids") ?? []
        let allIds = Set(defaultIds + savedIds)

        for providerId in allIds {
            let udKey = "provider_config_\(providerId)"
            guard let data = UserDefaults.standard.data(forKey: udKey) else { continue }

            // Parse JSON to extract apiKey without importing ConfigurationSystem
            guard let configDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.warning("Could not parse provider config for migration: \(providerId)")
                continue
            }

            guard let apiKey = configDict["apiKey"] as? String, !apiKey.isEmpty else { continue }

            // Store apiKey in Keychain
            let keychainAccount = providerKeychainAccount(for: providerId)
            do {
                try await storeAndBump(secret: apiKey, for: keychainAccount)
                logger.info("Migrated API key for provider '\(providerId)' to Keychain")

                // Re-save config without apiKey
                var updatedDict = configDict
                updatedDict["apiKey"] = nil
                if let newData = try? JSONSerialization.data(withJSONObject: updatedDict, options: [.prettyPrinted, .sortedKeys]) {
                    UserDefaults.standard.set(newData, forKey: udKey)
                    UserDefaults.standard.synchronize()
                }
            } catch {
                logger.error("Failed to migrate API key for provider '\(providerId)': \(error)")
            }
        }
    }

    // MARK: - Credential Accessors

    /// Store a secret in Keychain for the given account (migration helper).
    private func storeAndBump(secret: String, for account: String) async throws {
        try await keychain.store(secret: secret, for: account)
        migratedCount += 1
    }

    // MARK: - Keychain Account Names

    /// Keychain account naming convention for provider API keys.
    private func providerKeychainAccount(for providerId: String) -> String {
        return "provider_api_key.\(providerId)"
    }

    private var aliceKeychainAccount: String { "alice_api_key" }
    private var serpAPIKeychainAccount: String { "serpapi_api_key" }
    private var samAPITokenKeychainAccount: String { "sam_api_token" }

    // MARK: - Provider API Keys

    /// Retrieve the API key for a specific provider from Keychain.
    /// - Parameter providerId: The provider identifier (e.g., "openai", "deepseek")
    /// - Returns: The API key string, or nil if not stored.
    public func providerAPIKey(for providerId: String) async -> String? {
        try? await keychain.retrieve(for: providerKeychainAccount(for: providerId))
    }

    /// Store or delete an API key for a provider in Keychain.
    /// Pass nil or empty string to delete the key.
    public func setProviderAPIKey(_ key: String?, for providerId: String) async throws {
        let account = providerKeychainAccount(for: providerId)
        if let key = key, !key.isEmpty {
            try await keychain.store(secret: key, for: account)
        } else {
            try? await keychain.delete(for: account)
        }
    }

    /// Delete a provider's API key from Keychain.
    public func deleteProviderAPIKey(for providerId: String) async throws {
        try await keychain.delete(for: providerKeychainAccount(for: providerId))
    }

    // MARK: - ALICE API Key

    /// Retrieve the ALICE server API key from Keychain.
    public func aliceAPIKey() async -> String? {
        try? await keychain.retrieve(for: aliceKeychainAccount)
    }

    /// Store or delete the ALICE API key in Keychain.
    public func setAliceAPIKey(_ key: String?) async throws {
        if let key = key, !key.isEmpty {
            try await keychain.store(secret: key, for: aliceKeychainAccount)
        } else {
            try? await keychain.delete(for: aliceKeychainAccount)
        }
    }

    // MARK: - SerpAPI Key

    /// Retrieve the SerpAPI key from Keychain.
    public func serpAPIKey() async -> String? {
        try? await keychain.retrieve(for: serpAPIKeychainAccount)
    }

    /// Store or delete the SerpAPI key in Keychain.
    public func setSerpAPIKey(_ key: String?) async throws {
        if let key = key, !key.isEmpty {
            try await keychain.store(secret: key, for: serpAPIKeychainAccount)
        } else {
            try? await keychain.delete(for: serpAPIKeychainAccount)
        }
    }

    // MARK: - SAM API Token

    /// Retrieve the SAM local API server token from Keychain.
    public func samAPIToken() async -> String? {
        try? await keychain.retrieve(for: samAPITokenKeychainAccount)
    }

    /// Store or delete the SAM API token in Keychain.
    public func setSAMAPIToken(_ token: String?) async throws {
        if let token = token, !token.isEmpty {
            try await keychain.store(secret: token, for: samAPITokenKeychainAccount)
        } else {
            try? await keychain.delete(for: samAPITokenKeychainAccount)
        }
    }
}
