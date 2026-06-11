// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem
import SecurityFramework

/// Manages storage and refresh of Copilot tokens.
///
/// Tokens are stored in the macOS Keychain for security (replaces previous
/// plaintext JSON file storage). On first launch after upgrade, any legacy
/// plaintext file is automatically migrated to Keychain and deleted.
@MainActor
public class CopilotTokenStore: ObservableObject {
    public static let shared = CopilotTokenStore()
    private let logger = Logger(label: "com.sam.copilot.tokenstore")
    
    // Token storage
    @Published public var isSignedIn: Bool = false
    @Published public var username: String?
    
    private var githubToken: String?
    private var copilotToken: CopilotTokenResponse?
    private var refreshTask: Task<Void, Never>?
    
    /// Keychain account identifiers for secure token storage.
    private let keychainAccountGitHub = "copilot-github-token"
    private let keychainAccountCopilotToken = "copilot-api-token"
    private let keychainAccountCopilotExpiry = "copilot-api-token-expiry"
    private let keychainAccountCopilotUsername = "copilot-api-token-username"
    
    /// Legacy file path for migration.
    private var legacyTokensFilePath: URL {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("sam")
        return configDir.appendingPathComponent("github_tokens.json")
    }
    
    private init() {
        // Load tokens asynchronously on init
        Task {
            try? await loadTokens()
        }
    }
    
    /// Store GitHub user token and exchange for Copilot token
    /// Also fetches user info from CopilotUserAPI for enhanced quota tracking
    public func setGitHubToken(_ token: String) async throws {
        githubToken = token
        
        // Exchange for Copilot token using GitHubDeviceFlowService
        let deviceFlowService = GitHubDeviceFlowService()
        copilotToken = try await deviceFlowService.exchangeForCopilotToken(githubToken: token)
        
        // Update published properties
        isSignedIn = true
        username = copilotToken?.username
        
        // Fetch additional user info from CopilotUserAPI (non-blocking)
        Task {
            do {
                let userResponse = try await CopilotUserAPIClient.shared.fetchUser(token: token)
                
                // Update username if we got a better one
                if let login = userResponse.login {
                    self.username = login
                    logger.info("User API: authenticated as \(login)")
                }
                
                if let plan = userResponse.copilotPlan {
                    logger.info("User API: Copilot plan = \(plan)")
                }
                
                if let premium = userResponse.premiumQuota {
                    logger.info("User API: Premium quota \(premium.used)/\(premium.entitlement) used (\(String(format: "%.1f", premium.percentUsed))%)")
                }
            } catch {
                // Non-fatal - user info is supplementary
                logger.debug("Could not prefetch user info: \(error.localizedDescription)")
            }
        }
        
        // Start refresh timer
        startRefreshTimer()
        
        // Save to Keychain
        try await saveTokens()
        
        // Notify that authentication succeeded
        NotificationCenter.default.post(name: .githubAuthenticationDidSucceed, object: nil)
    }
    
    /// Store GitHub user token directly (no Copilot token exchange)
    /// GitHub user tokens from device flow already have billing access
    /// Also fetches user info from CopilotUserAPI to get username and plan
    public func setGitHubTokenDirect(_ token: String) async {
        githubToken = token
        
        // No Copilot token - we use GitHub token directly
        copilotToken = nil
        
        // Update published properties
        isSignedIn = true
        
        // Fetch user info from CopilotUserAPI to get username and plan
        do {
            let userResponse = try await CopilotUserAPIClient.shared.fetchUser(token: token)
            username = userResponse.login
            
            if let login = userResponse.login {
                logger.info("Authenticated as: \(login)")
            }
            if let plan = userResponse.copilotPlan {
                logger.info("Copilot plan: \(plan)")
            }
            if let premium = userResponse.premiumQuota {
                logger.info("Premium quota: \(premium.used)/\(premium.entitlement) used")
            }
        } catch {
            // Non-fatal - we can still use the token without user info
            logger.debug("Could not fetch user info: \(error.localizedDescription)")
            username = nil
        }
        
        // No refresh needed - GitHub tokens are long-lived
        refreshTask?.cancel()
        
        // Save to Keychain
        try? await saveTokens()
        
        // Notify that authentication succeeded
        NotificationCenter.default.post(name: .githubAuthenticationDidSucceed, object: nil)
    }
    
    /// Get current Copilot token, refreshing if needed
    /// Falls back to GitHub token if Copilot token not available
    public func getCopilotToken() async throws -> String {
        // If we have a Copilot token, use it (with refresh if needed)
        if let token = copilotToken {
            if token.isExpired() {
                logger.info("Copilot token expired, refreshing...")
                try await refreshCopilotToken()
            }
            // Re-read copilotToken after potential refresh (local binding may be stale)
            if let current = copilotToken {
                return current.token
            }
        }
        
        // Have a GitHub token but no Copilot token - try exchange
        if githubToken != nil {
            logger.info("No Copilot token, attempting exchange...")
            do {
                try await refreshCopilotToken()
                if let token = copilotToken {
                    return token.token
                }
            } catch {
                logger.warning("Copilot token exchange failed: \(error.localizedDescription)")
            }
            // Don't fall back to raw GitHub token - it won't work with Copilot API
            throw TokenStoreError.noToken
        }
        
        // No token at all
        throw TokenStoreError.noToken
    }
    
    /// Refresh Copilot token using stored GitHub token
    /// Called automatically on expiration, or manually on 401/403 from API
    public func refreshCopilotToken() async throws {
        guard let githubToken = githubToken else {
            throw TokenStoreError.noGitHubToken
        }
        
        let deviceFlowService = GitHubDeviceFlowService()
        copilotToken = try await deviceFlowService.exchangeForCopilotToken(githubToken: githubToken)
        username = copilotToken?.username
        try await saveTokens()
        
        logger.info("Copilot token refreshed successfully")
    }
    
    /// Start automatic refresh timer
    private func startRefreshTimer() {
        refreshTask?.cancel()
        
        refreshTask = Task {
            while !Task.isCancelled {
                guard let token = copilotToken else { return }
                
                // Refresh 5 minutes before expiration
                let refreshInterval = max(token.refreshIn - 300, 60)
                try? await Task.sleep(nanoseconds: UInt64(refreshInterval) * 1_000_000_000)
                
                if !Task.isCancelled {
                    try? await refreshCopilotToken()
                }
            }
        }
    }
    
    /// Attempt token recovery after a 401/403 error
    /// Forces a Copilot token refresh and returns the new token
    /// Returns nil if recovery fails (e.g., GitHub token also invalid)
    public func attemptTokenRecovery() async -> String? {
        logger.info("Attempting token recovery after authentication failure")
        
        do {
            try await refreshCopilotToken()
            if let token = copilotToken {
                logger.info("Token recovery succeeded - new Copilot token obtained")
                return token.token
            }
        } catch {
            logger.warning("Token recovery failed: \(error.localizedDescription)")
        }
        
        // Don't fall back to raw GitHub token - it causes 401 loops
        // The raw GitHub token can't authenticate against the Copilot API
        logger.error("Token recovery failed - no valid Copilot token available")
        return nil
    }
    
    /// Clear all tokens (sign out)
    public func clearTokens() async {
        refreshTask?.cancel()
        githubToken = nil
        copilotToken = nil
        isSignedIn = false
        username = nil
        await deleteTokensFromKeychain()
        
        logger.info("Tokens cleared, user signed out")
    }
    
    // MARK: - Keychain Persistence
    
    /// Save tokens to macOS Keychain (replaces plaintext file storage).
    private func saveTokens() async throws {
        let keychain = KeychainManager.shared
        
        if let githubToken = githubToken {
            try await keychain.store(secret: githubToken, for: keychainAccountGitHub)
        }
        
        if let copilotToken = copilotToken {
            try await keychain.store(secret: copilotToken.token, for: keychainAccountCopilotToken)
            try await keychain.store(secret: String(copilotToken.expiresAt), for: keychainAccountCopilotExpiry)
            if let username = copilotToken.username {
                try await keychain.store(secret: username, for: keychainAccountCopilotUsername)
            }
        }
        
        logger.debug("Tokens saved to Keychain")
    }
    
    /// Load tokens from macOS Keychain, with migration from legacy file.
    public func loadTokens() async throws {
        // First, attempt migration from legacy plaintext file
        try? await migrateFromLegacyFile()
        
        let keychain = KeychainManager.shared
        
        // Load GitHub token
        githubToken = try await keychain.retrieve(for: keychainAccountGitHub)
        
        // Load Copilot token components
        let copilotTokenValue = try await keychain.retrieve(for: keychainAccountCopilotToken)
        let copilotExpiry = try await keychain.retrieve(for: keychainAccountCopilotExpiry)
        let copilotUsername = try await keychain.retrieve(for: keychainAccountCopilotUsername)
        
        if let tokenValue = copilotTokenValue,
           let expiryString = copilotExpiry,
           let expiresAt = Int(expiryString) {
            // Calculate refresh interval from expiry (default: refresh 5 min before expiry)
            let refreshIn = max(expiresAt - Int(Date().timeIntervalSince1970) - 300, 60)
            copilotToken = CopilotTokenResponse(
                token: tokenValue,
                expiresAt: expiresAt,
                refreshIn: refreshIn,
                username: copilotUsername
            )
        }
        
        // Update published properties
        if let token = copilotToken {
            isSignedIn = true
            username = token.username
            
            // Start refresh if we have a valid token
            if !token.isExpired() {
                startRefreshTimer()
                logger.info("Loaded valid Copilot token from Keychain")
            } else {
                logger.warning("Loaded expired Copilot token, will need refresh")
            }
        } else if githubToken != nil {
            // Have a GitHub token but no Copilot token - exchange on first use
            isSignedIn = true
            logger.info("Loaded GitHub token from Keychain, will exchange for Copilot token on first use")
        }
    }
    
    /// Delete tokens from Keychain.
    private func deleteTokensFromKeychain() async {
        let keychain = KeychainManager.shared
        try? await keychain.delete(for: keychainAccountGitHub)
        try? await keychain.delete(for: keychainAccountCopilotToken)
        try? await keychain.delete(for: keychainAccountCopilotExpiry)
        try? await keychain.delete(for: keychainAccountCopilotUsername)
    }
    
    /// Migrate tokens from legacy plaintext file to Keychain.
    ///
    /// Reads the old `~/.config/sam/github_tokens.json` file, stores tokens
    /// in the Keychain, and deletes the plaintext file.
    private func migrateFromLegacyFile() async throws {
        let fileManager = FileManager.default
        let filePath = legacyTokensFilePath
        
        guard fileManager.fileExists(atPath: filePath.path) else {
            return // No legacy file to migrate
        }
        
        logger.info("Found legacy token file, migrating to Keychain: \(filePath.path)")
        
        guard let data = try? Data(contentsOf: filePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("Failed to read legacy token file, skipping migration")
            return
        }
        
        let keychain = KeychainManager.shared
        
        // Migrate GitHub token
        if let githubTokenValue = json["githubToken"] as? String {
            try await keychain.store(secret: githubTokenValue, for: keychainAccountGitHub)
        }
        
        // Migrate Copilot token components
        if let copilotDict = json["copilotToken"] as? [String: Any] {
            if let tokenValue = copilotDict["token"] as? String {
                try await keychain.store(secret: tokenValue, for: keychainAccountCopilotToken)
            }
            if let expiresAt = copilotDict["expiresAt"] as? Double {
                try await keychain.store(secret: String(Int(expiresAt)), for: keychainAccountCopilotExpiry)
            }
            if let username = copilotDict["username"] as? String {
                try await keychain.store(secret: username, for: keychainAccountCopilotUsername)
            }
        }
        
        // Delete the plaintext file after successful migration
        do {
            try fileManager.removeItem(at: filePath)
            logger.info("Successfully migrated tokens from legacy file and deleted plaintext file")
        } catch {
            logger.warning("Migrated tokens to Keychain but failed to delete legacy file: \(error.localizedDescription)")
            // Try to at least zero out the file contents
            try? Data().write(to: filePath)
        }
    }
}

public enum TokenStoreError: LocalizedError {
    case noToken
    case noGitHubToken
    
    public var errorDescription: String? {
        switch self {
        case .noToken:
            return "No Copilot token available. Please sign in with GitHub."
        case .noGitHubToken:
            return "No GitHub token available for refresh."
        }
    }
}

// Notification for authentication success
extension Notification.Name {
    public static let githubAuthenticationDidSucceed = Notification.Name("githubAuthenticationDidSucceed")
}