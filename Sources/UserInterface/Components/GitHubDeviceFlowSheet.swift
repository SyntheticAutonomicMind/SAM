// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import APIFramework
import Logging

/// Sheet for GitHub Device Flow authentication.
struct GitHubDeviceFlowSheet: View {
    private static let logger = Logger(label: "com.sam.ui.github-device-flow")

    @ObservedObject var deviceFlow: GitHubDeviceFlowService
    let onTokenReceived: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            /// Header.
            HStack {
                Text("Connect with GitHub")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("Cancel") {
                    deviceFlow.cancelAuth()
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            Divider()

            if deviceFlow.isAuthenticating {
                /// Authentication in progress.
                VStack(spacing: 20) {
                    if let userCode = deviceFlow.userCode,
                       let verificationUri = deviceFlow.verificationUri {
                        /// Step 1: Show code and URL.
                        VStack(spacing: 16) {
                            Text("Step 1: Copy your code")
                                .font(.headline)

                            /// Large, copyable code display.
                            HStack {
                                Text(userCode)
                                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                                    .foregroundColor(.blue)
                                    .textSelection(.enabled)
                                    .padding()
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.blue.opacity(0.1))
                                    )

                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(userCode, forType: .string)
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.title2)
                                }
                                .buttonStyle(.borderless)
                                .help("Copy code to clipboard")
                            }

                            Divider()

                            Text("Step 2: Visit GitHub and paste the code")
                                .font(.headline)

                            Button(action: {
                                if let url = URL(string: verificationUri) {
                                    NSWorkspace.shared.open(url)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "globe")
                                    Text("Open \(verificationUri)")
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Divider()

                            /// Waiting indicator.
                            VStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(1.2)

                                Text("Waiting for authorization...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                Text("This window will close automatically once you authorize in your browser")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.top, 8)
                        }
                    } else {
                        /// Initial loading state.
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Requesting device code from GitHub...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()

            } else if deviceFlow.authSuccess {
                /// Success state.
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.green)

                    Text("Successfully Connected!")
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text("Your GitHub token has been saved")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()

            } else if let error = deviceFlow.authError {
                /// Error state.
                VStack(spacing: 16) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.red)

                    Text("Authentication Failed")
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Try Again") {
                        Task {
                            await startDeviceFlow()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()

            } else {
                /// Initial state - start button.
                VStack(spacing: 20) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 64))
                        .foregroundColor(.purple)

                    Text("Connect to GitHub Copilot")
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text("You'll be asked to authorize SAM in your browser")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Start Authorization") {
                        Task {
                            await startDeviceFlow()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding()
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 500, idealWidth: 550, maxWidth: 600,
               minHeight: 400, idealHeight: 500, maxHeight: 600)
    }

    private func startDeviceFlow() async {
        do {
            let githubToken = try await deviceFlow.startDeviceFlow()
            
            /// Store GitHub token directly in CopilotTokenStore (no exchange needed)
            /// GitHub user tokens from device flow already have billing access
            let copilotTokenStore = CopilotTokenStore.shared
            await copilotTokenStore.setGitHubTokenDirect(githubToken)
            
            /// Return token for API usage
            onTokenReceived(githubToken)

            /// Auto-dismiss after brief delay.
            try await Task.sleep(for: .seconds(1.5))
            dismiss()

        } catch {
            Self.logger.error("Device flow failed: \(error)")
        }
    }
}

#Preview {
    GitHubDeviceFlowSheet(
        deviceFlow: GitHubDeviceFlowService(),
        onTokenReceived: { _ in }
    )
}
