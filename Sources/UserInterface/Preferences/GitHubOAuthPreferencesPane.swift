// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging
import ConfigurationSystem
import APIFramework

/// Preferences pane for configuring GitHub OAuth credentials using device code flow.
struct GitHubOAuthPreferencesPane: View {
    private static let logger = Logger(label: "com.sam.preferences.github-oauth")

    @StateObject private var deviceFlowService = GitHubDeviceFlowService()
    @ObservedObject private var tokenStore = CopilotTokenStore.shared

    @State private var signInState: SignInState = .idle
    @State private var errorMessage: String? = nil
    
    enum SignInState {
        case idle
        case showingCode
        case polling
        case success
        case error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("GitHub Copilot Sign-In")
                .font(.headline)

            GroupBox("Sign in to GitHub") {
                VStack(alignment: .leading, spacing: 12) {
                    if tokenStore.isSignedIn {
                        signedInView
                    } else {
                        switch signInState {
                        case .idle:
                            idleView
                        case .showingCode:
                            showCodeView
                        case .polling:
                            pollingView
                        case .success:
                            successView
                        case .error:
                            errorView
                        }
                    }
                }
                .padding()
            }

            if let errorMessage = errorMessage, signInState == .error {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }

            Spacer()
        }
        .padding()
    }
    
    /// Signed in view
    private var signedInView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading) {
                    Text("Signed in successfully")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    if let username = tokenStore.username {
                        Text("GitHub user: \(username)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Button("Sign Out") {
                tokenStore.clearTokens()
                signInState = .idle
            }
            .buttonStyle(.bordered)
        }
    }
    
    /// Idle state view
    private var idleView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with GitHub to access Copilot models with full billing information.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button(action: { Task { await startSignIn() } }) {
                HStack {
                    Image(systemName: "person.badge.key.fill")
                    Text("Sign In with GitHub")
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    /// Show code view
    private var showCodeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter this code on GitHub:")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            if let userCode = deviceFlowService.userCode {
                Text(userCode)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
            }
            
            if let verificationUri = deviceFlowService.verificationUri {
                Button("Open GitHub") {
                    if let url = URL(string: verificationUri) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Waiting for authorization...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Button("Cancel") {
                deviceFlowService.cancelAuth()
                signInState = .idle
            }
            .buttonStyle(.bordered)
        }
    }
    
    /// Polling view
    private var pollingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Completing sign in...")
                .foregroundColor(.secondary)
        }
    }
    
    /// Success view
    private var successView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.green)
                
                VStack(alignment: .leading) {
                    Text("Signed In Successfully!")
                        .font(.headline)
                        .bold()
                    
                    Text("Copilot token obtained with billing access")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    /// Error view
    private var errorView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.red)
                
                VStack(alignment: .leading) {
                    Text("Sign In Failed")
                        .font(.headline)
                        .bold()
                    
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Button("Try Again") {
                signInState = .idle
                errorMessage = ""
            }
            .buttonStyle(.bordered)
        }
    }

    private func startSignIn() async {
        do {
            signInState = .showingCode
            
            /// Use GitHubDeviceFlowService to get GitHub token
            let githubToken = try await deviceFlowService.startDeviceFlow()
            
            /// Exchange for Copilot token
            signInState = .polling
            try await tokenStore.setGitHubToken(githubToken)
            
            signInState = .success
            
            Self.logger.info("GitHub OAuth device code flow completed successfully")
            
            /// Auto-dismiss success after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                signInState = .idle
            }
            
        } catch {
            signInState = .error
            errorMessage = error.localizedDescription
            Self.logger.error("GitHub OAuth device code flow failed: \(error)")
        }
    }
}

#Preview {
    GitHubOAuthPreferencesPane()
}
