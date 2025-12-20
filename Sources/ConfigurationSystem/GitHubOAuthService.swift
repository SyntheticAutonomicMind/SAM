// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import AppKit

/// Service for handling GitHub OAuth authentication flow for GitHub Copilot access.
@MainActor
public class GitHubOAuthService: ObservableObject {
    private static let logger = Logger(label: "com.sam.config.github-oauth")

    @Published public var isAuthenticating = false
    @Published public var authError: String?
    @Published public var authSuccess: Bool = false

    /// Client credentials for GitHub OAuth App.
    private var clientId: String?
    private var clientSecret: String?

    /// Pending authorization state.
    private var authorizationContinuation: CheckedContinuation<String, Error>?

    public init() {
        setupURLHandler()
    }

    /// Load OAuth credentials from UserDefaults.
    public func loadCredentials() -> (clientId: String, clientSecret: String)? {
        guard let clientId = UserDefaults.standard.string(forKey: "github_oauth_client_id"),
              let clientSecret = UserDefaults.standard.string(forKey: "github_oauth_client_secret") else {
            return nil
        }
        return (clientId, clientSecret)
    }

    /// Save OAuth credentials to UserDefaults.
    public func saveCredentials(clientId: String, clientSecret: String) {
        UserDefaults.standard.set(clientId, forKey: "github_oauth_client_id")
        UserDefaults.standard.set(clientSecret, forKey: "github_oauth_client_secret")
        self.clientId = clientId
        self.clientSecret = clientSecret
    }

    /// Clear stored OAuth credentials.
    public func clearCredentials() {
        UserDefaults.standard.removeObject(forKey: "github_oauth_client_id")
        UserDefaults.standard.removeObject(forKey: "github_oauth_client_secret")
        self.clientId = nil
        self.clientSecret = nil
    }

    /// Start OAuth authorization flow.
    public func authorize() async throws -> String {
        guard let clientId = self.clientId ?? loadCredentials()?.clientId else {
            throw GitHubOAuthError.credentialsNotConfigured
        }

        Self.logger.info("Starting GitHub OAuth authorization flow")
        isAuthenticating = true
        authError = nil
        authSuccess = false

        defer {
            isAuthenticating = false
        }

        do {
            /// Build authorization URL.
            let authURL = try buildAuthorizationURL(clientId: clientId)

            /// Open browser for user authorization.
            NSWorkspace.shared.open(authURL)

            /// Wait for callback with authorization code.
            let authCode = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                self.authorizationContinuation = continuation

                /// Set timeout to prevent indefinite waiting.
                Task {
                    try await Task.sleep(for: .seconds(300))  /// 5 minute timeout
                    self.authorizationContinuation?.resume(throwing: GitHubOAuthError.authorizationTimeout)
                    self.authorizationContinuation = nil
                }
            }

            Self.logger.debug("Received authorization code, exchanging for token")

            /// Exchange authorization code for access token.
            let token = try await exchangeCodeForToken(code: authCode)

            authSuccess = true
            Self.logger.info("GitHub OAuth authorization successful")

            return token

        } catch {
            authError = error.localizedDescription
            Self.logger.error("GitHub OAuth authorization failed: \(error)")
            throw error
        }
    }

    /// Build GitHub OAuth authorization URL.
    private func buildAuthorizationURL(clientId: String) throws -> URL {
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: "sam://oauth/callback"),
            URLQueryItem(name: "scope", value: "read:user")
        ]

        guard let url = components.url else {
            throw GitHubOAuthError.invalidURL
        }

        return url
    }

    /// Exchange authorization code for access token.
    private func exchangeCodeForToken(code: String) async throws -> String {
        guard let clientId = self.clientId ?? loadCredentials()?.clientId,
              let clientSecret = self.clientSecret ?? loadCredentials()?.clientSecret else {
            throw GitHubOAuthError.credentialsNotConfigured
        }

        let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: String] = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "code": code,
            "redirect_uri": "sam://oauth/callback"
        ]

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubOAuthError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            Self.logger.error("Token exchange failed with status: \(httpResponse.statusCode)")
            throw GitHubOAuthError.tokenExchangeFailed(statusCode: httpResponse.statusCode)
        }

        /// Parse response.
        struct TokenResponse: Codable {
            let access_token: String?
            let error: String?
            let error_description: String?
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        if let error = tokenResponse.error {
            let description = tokenResponse.error_description ?? "Unknown error"
            Self.logger.error("Token exchange error: \(error) - \(description)")
            throw GitHubOAuthError.tokenExchangeError(error: error, description: description)
        }

        guard let token = tokenResponse.access_token else {
            throw GitHubOAuthError.noTokenReceived
        }

        return token
    }

    /// Handle OAuth callback URL.
    public func handleCallback(url: URL) {
        Self.logger.debug("Received OAuth callback: \(url.absoluteString)")

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            Self.logger.error("OAuth callback error: Failed to parse URL")
            authorizationContinuation?.resume(throwing: GitHubOAuthError.invalidURL)
            authorizationContinuation = nil
            return
        }

        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            let error = components.queryItems?.first(where: { $0.name == "error" })?.value ?? "Unknown error"
            let description = components.queryItems?.first(where: { $0.name == "error_description" })?.value ?? ""
            Self.logger.error("OAuth callback error: \(error) - \(description)")
            authorizationContinuation?.resume(throwing: GitHubOAuthError.authorizationDenied(error: error))
            authorizationContinuation = nil
            return
        }

        authorizationContinuation?.resume(returning: code)
        authorizationContinuation = nil
    }

    /// Setup URL event handler for OAuth callback.
    private func setupURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            Self.logger.error("Failed to extract URL from Apple Event")
            return
        }

        handleCallback(url: url)
    }
}

/// Errors that can occur during GitHub OAuth flow.
public enum GitHubOAuthError: LocalizedError {
    case credentialsNotConfigured
    case invalidURL
    case authorizationTimeout
    case authorizationDenied(error: String)
    case invalidResponse
    case tokenExchangeFailed(statusCode: Int)
    case tokenExchangeError(error: String, description: String)
    case noTokenReceived

    public var errorDescription: String? {
        switch self {
        case .credentialsNotConfigured:
            return "GitHub OAuth credentials not configured. Please configure Client ID and Client Secret in preferences."

        case .invalidURL:
            return "Failed to build authorization URL"

        case .authorizationTimeout:
            return "Authorization timed out after 5 minutes. Please try again."

        case .authorizationDenied(let error):
            return "Authorization denied: \(error)"

        case .invalidResponse:
            return "Invalid response from GitHub"

        case .tokenExchangeFailed(let statusCode):
            return "Token exchange failed with status code: \(statusCode)"

        case .tokenExchangeError(let error, let description):
            return "Token exchange error: \(error) - \(description)"

        case .noTokenReceived:
            return "No access token received from GitHub"
        }
    }
}
