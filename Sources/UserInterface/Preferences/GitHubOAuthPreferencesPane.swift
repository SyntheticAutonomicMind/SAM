// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging
import ConfigurationSystem

/// Preferences pane for configuring GitHub OAuth credentials.
struct GitHubOAuthPreferencesPane: View {
    private static let logger = Logger(label: "com.sam.preferences.github-oauth")

    @StateObject private var oauthService = GitHubOAuthService()

    @State private var clientId: String = ""
    @State private var clientSecret: String = ""
    @State private var isSaved: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var isConnecting: Bool = false
    @State private var connectionSuccess: Bool = false
    @State private var obtainedToken: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("GitHub Copilot OAuth Setup")
                .font(.headline)

            /// Instructions Section.
            GroupBox("Step 1: Register OAuth App") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create a GitHub OAuth App to allow SAM to access GitHub Copilot:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Link("Register New OAuth App →",
                         destination: URL(string: "https://github.com/settings/applications/new")!)
                        .font(.caption)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("OAuth App Settings:")
                            .font(.caption)
                            .fontWeight(.semibold)

                        HStack {
                            Text("Application name:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("SAM")
                                .font(.caption)
                                .fontWeight(.medium)
                                .textSelection(.enabled)
                        }

                        HStack {
                            Text("Homepage URL:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("https://github.com")
                                .font(.caption)
                                .fontWeight(.medium)
                                .textSelection(.enabled)
                        }

                        HStack {
                            Text("Authorization callback URL:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("sam://oauth/callback")
                                .font(.caption)
                                .fontWeight(.medium)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding()
            }

            /// Credentials Section.
            GroupBox("Step 2: Enter OAuth Credentials") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Client ID")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("GitHub OAuth App Client ID", text: $clientId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Client Secret")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        SecureField("GitHub OAuth App Client Secret", text: $clientSecret)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    HStack {
                        Button("Save Credentials") {
                            saveCredentials()
                        }
                        .disabled(clientId.isEmpty || clientSecret.isEmpty)
                        .buttonStyle(.borderedProminent)

                        if isSaved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        }

                        Spacer()

                        Button("Clear") {
                            clearCredentials()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }

            /// Connection Section.
            GroupBox("Step 3: Connect to GitHub") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Click 'Connect with GitHub' to authorize SAM and obtain an access token.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: { connectWithGitHub() }) {
                        HStack {
                            if isConnecting {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Authorizing...")
                            } else {
                                Image(systemName: "arrow.triangle.branch")
                                Text("Connect with GitHub")
                            }
                        }
                    }
                    .disabled(clientId.isEmpty || clientSecret.isEmpty || isConnecting)
                    .buttonStyle(.borderedProminent)

                    if connectionSuccess, let token = obtainedToken {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Connected successfully!", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)

                            Text("Access token obtained. Use this in Endpoint Management to configure GitHub Copilot provider.")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            HStack {
                                Text("Token:")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                Text(String(token.prefix(16)) + "...")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .textSelection(.enabled)

                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(token, forType: .string)
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                                .help("Copy token to clipboard")
                            }

                            Button("Use Token in Endpoint Management") {
                                /// This would navigate to endpoint management.
                                /// For now, just copy to clipboard.
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(token, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.top, 8)
                    }

                    if oauthService.isAuthenticating {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Waiting for authorization in browser...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let error = oauthService.authError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.top, 4)
                    }
                }
                .padding()
            }

            if showError {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            loadCredentials()
        }
    }

    private func saveCredentials() {
        oauthService.saveCredentials(clientId: clientId, clientSecret: clientSecret)
        isSaved = true
        showError = false

        /// Hide success indicator after 2 seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            isSaved = false
        }
    }

    private func loadCredentials() {
        if let (loadedId, loadedSecret) = oauthService.loadCredentials() {
            clientId = loadedId
            clientSecret = loadedSecret
        }
    }

    private func clearCredentials() {
        clientId = ""
        clientSecret = ""
        oauthService.clearCredentials()
        isSaved = false
        connectionSuccess = false
        obtainedToken = nil
    }

    private func connectWithGitHub() {
        isConnecting = true
        connectionSuccess = false
        obtainedToken = nil

        Task {
            do {
                let token = try await oauthService.authorize()
                await MainActor.run {
                    obtainedToken = token
                    connectionSuccess = true
                    isConnecting = false
                    Self.logger.info("Successfully obtained GitHub access token")
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    errorMessage = "Authorization failed: \(error.localizedDescription)"
                    showError = true
                    Self.logger.error("GitHub OAuth failed: \(error)")
                }
            }
        }
    }
}

#Preview {
    GitHubOAuthPreferencesPane()
}
