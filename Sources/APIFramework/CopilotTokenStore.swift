// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

/// Manages storage and refresh of Copilot tokens
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
    
    private init() {
        // Try to load tokens on initialization
        try? loadTokens()
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
                    await MainActor.run {
                        self.username = login
                    }
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
        
        // Save to disk
        try saveTokens()
        
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
        
        // Save to disk
        try? saveTokens()
        
        // Notify that authentication succeeded
        NotificationCenter.default.post(name: .githubAuthenticationDidSucceed, object: nil)
    }
    
    /// Get current Copilot token, refreshing if needed
    /// Falls back to GitHub token if Copilot token not available
    public func getCopilotToken() async throws -> String {
        // If we have a Copilot token, use it (with refresh if needed)
        if let token = copilotToken {
            // Check if expired
            if token.isExpired() {
                logger.info("Copilot token expired, refreshing...")
                try await refreshCopilotToken()
            }
            return token.token
        }
        
        // Fall back to GitHub token (from device flow)
        if let githubToken = githubToken {
            logger.debug("Using GitHub user token (no Copilot token available)")
            return githubToken
        }
        
        // No token at all
        throw TokenStoreError.noToken
    }
    
    /// Refresh Copilot token using stored GitHub token
    private func refreshCopilotToken() async throws {
        guard let githubToken = githubToken else {
            throw TokenStoreError.noGitHubToken
        }
        
        let deviceFlowService = GitHubDeviceFlowService()
        copilotToken = try await deviceFlowService.exchangeForCopilotToken(githubToken: githubToken)
        username = copilotToken?.username
        try saveTokens()
        
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
    
    /// Clear all tokens (sign out)
    public func clearTokens() {
        refreshTask?.cancel()
        githubToken = nil
        copilotToken = nil
        isSignedIn = false
        username = nil
        try? deleteTokensFromDisk()
        
        logger.info("Tokens cleared, user signed out")
    }
    
    // MARK: - Persistence
    
    private var tokensFilePath: URL {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("sam")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        return configDir.appendingPathComponent("github_tokens.json")
    }
    
    private func saveTokens() throws {
        let data = TokensStorage(
            githubToken: githubToken,
            copilotToken: copilotToken
        )
        let encoded = try JSONEncoder().encode(data)
        try encoded.write(to: tokensFilePath)
        logger.debug("Tokens saved to disk")
    }
    
    public func loadTokens() throws {
        guard FileManager.default.fileExists(atPath: tokensFilePath.path) else {
            return
        }
        
        let data = try Data(contentsOf: tokensFilePath)
        let storage = try JSONDecoder().decode(TokensStorage.self, from: data)
        
        githubToken = storage.githubToken
        copilotToken = storage.copilotToken
        
        // Update published properties
        if let token = copilotToken {
            isSignedIn = true
            username = token.username
            
            // Start refresh if we have a valid token
            if !token.isExpired() {
                startRefreshTimer()
                logger.info("Loaded valid Copilot token from disk")
            } else {
                logger.warning("Loaded expired Copilot token, will need refresh")
            }
        }
    }
    
    private func deleteTokensFromDisk() throws {
        if FileManager.default.fileExists(atPath: tokensFilePath.path) {
            try FileManager.default.removeItem(at: tokensFilePath)
        }
    }
}

private struct TokensStorage: Codable {
    let githubToken: String?
    let copilotToken: CopilotTokenResponse?
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
