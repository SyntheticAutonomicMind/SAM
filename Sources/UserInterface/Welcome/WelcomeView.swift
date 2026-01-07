// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging
import APIFramework
import ConversationEngine

private let logger = Logger(label: "SAM.UserInterface.WelcomeView")

/// Welcome splash screen for SAM Shows on first launch with information about the application.
struct WelcomeView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var endpointManager: EndpointManager
    @EnvironmentObject private var conversationManager: ConversationManager
    @AppStorage("hasSeenWelcomeScreen") private var hasSeenWelcomeScreen: Bool = false
    @State private var dontShowAgain: Bool = false
    @State private var showOnboarding: Bool = false

    var body: some View {
        if showOnboarding {
            OnboardingWizardView(isPresented: $isPresented)
                .environmentObject(endpointManager)
                .environmentObject(conversationManager)
        } else {
            standardWelcomeView
        }
    }
    
    private var standardWelcomeView: some View {
        ZStack {
            /// Background.
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                /// Header with SAM Icon + Name (Horizontal Layout).
                HStack(spacing: 20) {
                    /// SAM Icon (use PNG for better display).
                    if let iconPath = Bundle.main.path(forResource: "sam-icon", ofType: "png"),
                       let samIcon = NSImage(contentsOfFile: iconPath) {
                        Image(nsImage: samIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 120, height: 120)
                            .shadow(radius: 8)
                    } else {
                        /// Fallback icon.
                        Image(systemName: "brain.head.profile")
                            .resizable()
                            .frame(width: 120, height: 120)
                            .foregroundColor(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("SAM")
                            .font(.system(size: 48, weight: .bold))

                        Text("(Synthetic Autonomic Mind)")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 40)

                /// Introduction (General, focused on SAM).
                VStack(alignment: .leading, spacing: 16) {

                    Text("SAM is a conversational AI assistant built for macOS with a focus on transparency and user control. Everything runs locally on your Mac. Your conversations stay on your machine, your data belongs to you, and you decide which AI providers to use. SAM supports multiple providers including OpenAI, GitHub Copilot, Claude, and local models. You get autonomous workflows, integrated tools, and deep macOS integration without tracking, telemetry, or vendor lock-in.")
                        .font(.body)
                        .foregroundColor(.secondary)

                    Divider()

                    Text("What SAM Offers:")
                        .font(.headline)

                    WelcomeFeatureRow(
                        icon: "cpu.fill",
                        title: "Local and Remote Model Providers",
                        description: "Built in support for Remote providers like OpenAI, GitHub Copilot, as well as Local Models via MLX and GGUF"
                    )

                    WelcomeFeatureRow(
                        icon: "wrench.and.screwdriver.fill",
                        title: "Useful Integrated Tools",
                        description: "File operations, web research, terminal access, document processing, and more via MCP"
                    )

                    WelcomeFeatureRow(
                        icon: "photo.fill",
                        title: "AI Image Generation",
                        description: "Create images from text descriptions using Stable Diffusion models with CoreML or Python engines"
                    )

                    WelcomeFeatureRow(
                        icon: "gearshape.2.fill",
                        title: "Autonomous Workflows",
                        description: "Multi-step task execution with automatic tool orchestration and progress updates"
                    )

                    WelcomeFeatureRow(
                        icon: "bubble.left.and.bubble.right.fill",
                        title: "Persistent Conversations",
                        description: "Save, search, export, and manage unlimited conversation history"
                    )

                    WelcomeFeatureRow(
                        icon: "apple.logo",
                        title: "Apple Silicon Optimized",
                        description: "Run local AI models efficiently with MLX and Llama.cpp on Apple Silicon Macs"
                    )

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            /// Load Fewtarius avatar from Resources (use fewtarius.jpg).
                            if let avatarPath = Bundle.main.path(forResource: "fewtarius", ofType: "jpg"),
                               let avatarImage = NSImage(contentsOfFile: avatarPath) {
                                Image(nsImage: avatarImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 50, height: 50)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                            } else {
                                /// Fallback icon.
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 50))
                                    .foregroundColor(.accentColor)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Created by Andrew Wyatt (fewtarius)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                HStack(spacing: 4) {
                                    Text("GitHub:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Link("github.com/fewtarius", destination: URL(string: "https://github.com/fewtarius")!)
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                }

                                HStack(spacing: 4) {
                                    Text("Patreon:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Link("patreon.com/fewtarius", destination: URL(string: "https://patreon.com/fewtarius")!)
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 600)
                .padding(.horizontal, 40)

                Spacer()

                /// Footer Controls.
                VStack(spacing: 16) {
                    Toggle("Don't show this again", isOn: $dontShowAgain)
                        .toggleStyle(.checkbox)

                    Button(action: {
                        if dontShowAgain {
                            hasSeenWelcomeScreen = true
                            logger.debug("INFO: User disabled welcome screen via preference")
                        }
                        isPresented = false
                    }) {
                        Text("Get Started")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 200)
                }
                .padding(.bottom, 40)
            }
        }
        .frame(minWidth: 700, minHeight: 700)
        .onAppear {
            checkIfOnboardingNeeded()
        }
    }
    
    private func checkIfOnboardingNeeded() {
        /// Check if user has any local models installed
        /// Use LocalModelManager to check models directory
        let modelManager = LocalModelManager()
        let hasLocalModels = !modelManager.getModels().isEmpty
        
        /// Check if user has any configured providers
        /// Check if there are any saved provider IDs in UserDefaults
        let savedProviderIds = UserDefaults.standard.stringArray(forKey: "saved_provider_ids") ?? []
        let hasProviders = !savedProviderIds.isEmpty
        
        /// Show onboarding wizard if no models AND no providers
        showOnboarding = !hasLocalModels && !hasProviders
        
        if showOnboarding {
            logger.info("No models or providers configured - showing onboarding wizard")
        } else {
            logger.info("Models or providers found - showing standard welcome screen")
        }
    }
}

/// Feature row component for welcome screen.
struct WelcomeFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    let conversationManager = ConversationManager()
    let endpointManager = EndpointManager(conversationManager: conversationManager)
    
    return WelcomeView(isPresented: .constant(true))
        .environmentObject(endpointManager)
        .environmentObject(conversationManager)
}
