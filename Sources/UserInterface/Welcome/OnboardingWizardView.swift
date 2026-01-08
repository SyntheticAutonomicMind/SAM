// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import APIFramework
import ConfigurationSystem
import ConversationEngine
import Logging

private let logger = Logger(label: "SAM.UserInterface.OnboardingWizardView")

/// Onboarding wizard for first-time setup when no models or providers are configured.
struct OnboardingWizardView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var endpointManager: EndpointManager
    @EnvironmentObject private var conversationManager: ConversationManager
    @AppStorage("hasSeenWelcomeScreen") private var hasSeenWelcomeScreen: Bool = false
    
    @State private var selectedPath: OnboardingPath? = nil
    @State private var showingPreferences: Bool = false
    @State private var preferencesSection: PreferencesSection = .apiEndpoints
    @StateObject private var downloadManager: ModelDownloadManager
    @State private var isDownloading: Bool = false
    
    init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
        self._downloadManager = StateObject(wrappedValue: ModelDownloadManager())
    }
    
    enum OnboardingPath {
        case cloudAI
        case localModel
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer().frame(height: 40)
                
                /// Header
                headerSection
                
                /// Main content
                if selectedPath == nil {
                    pathSelectionSection
                } else if selectedPath == .cloudAI {
                    cloudAISection
                } else if selectedPath == .localModel {
                    localModelSection
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
        }
        .frame(minWidth: 800, minHeight: 600)
        .sheet(isPresented: $showingPreferences) {
            PreferencesView(selectedSection: preferencesSection)
                .environmentObject(endpointManager)
                .environmentObject(conversationManager)
                .frame(minWidth: 900, minHeight: 700)
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Text("Welcome to SAM")
                .font(.system(size: 42, weight: .bold))
            
            Text("Let's get you set up with an AI model")
                .font(.title3)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Path Selection Section
    
    private var pathSelectionSection: some View {
        VStack(spacing: 24) {
            Text("Choose Your Setup")
                .font(.title2)
                .fontWeight(.semibold)
            
            HStack(spacing: 32) {
                /// Cloud AI Option
                OnboardingPathCard(
                    icon: "cloud.fill",
                    title: "Use Cloud AI",
                    description: "Connect to services like OpenAI, Claude, or GitHub Copilot",
                    benefits: [
                        "Most powerful models",
                        "Quick setup",
                        "No downloads required"
                    ],
                    isSelected: false
                ) {
                    withAnimation {
                        selectedPath = .cloudAI
                    }
                }
                
                /// Local Model Option
                OnboardingPathCard(
                    icon: "cpu.fill",
                    title: "Download Local Model",
                    description: "Run AI models privately on your Mac",
                    benefits: [
                        "100% private & offline",
                        "No API costs",
                        "Apple Silicon optimized"
                    ],
                    isSelected: false
                ) {
                    withAnimation {
                        selectedPath = .localModel
                    }
                }
            }
        }
    }
    
    // MARK: - Cloud AI Section
    
    private var cloudAISection: some View {
        VStack(spacing: 24) {
            HStack {
                Button(action: { withAnimation { selectedPath = nil } }) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .buttonStyle(.plain)
                
                Spacer()
            }
            
            VStack(spacing: 16) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                
                Text("Cloud AI Providers")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Choose a provider and configure your API access")
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 16) {
                ProviderOptionRow(
                    name: "GitHub Copilot",
                    icon: "chevron.left.forwardslash.chevron.right",
                    difficulty: "Easiest",
                    difficultyColor: .green,
                    description: "Use your existing Copilot subscription"
                )
                
                ProviderOptionRow(
                    name: "OpenAI",
                    icon: "brain.head.profile",
                    difficulty: "Easy",
                    difficultyColor: .blue,
                    description: "Get a free trial API key from OpenAI"
                )
                
                ProviderOptionRow(
                    name: "Anthropic (Claude)",
                    icon: "text.bubble.fill",
                    difficulty: "Easy",
                    difficultyColor: .blue,
                    description: "Get an API key from Anthropic"
                )
                
                ProviderOptionRow(
                    name: "Google (Gemini)",
                    icon: "sparkles",
                    difficulty: "Easy",
                    difficultyColor: .blue,
                    description: "Get an API key from Google AI Studio"
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(12)
            
            Button(action: {
                preferencesSection = .apiEndpoints
                showingPreferences = true
            }) {
                Text("Configure Provider")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 600)
    }
    
    // MARK: - Local Model Section
    
    private var localModelSection: some View {
        VStack(spacing: 24) {
            HStack {
                Button(action: { withAnimation { selectedPath = nil } }) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .buttonStyle(.plain)
                
                Spacer()
            }
            
            VStack(spacing: 16) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                
                Text("Recommended Model for Your Mac")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Based on your \(SystemCapabilities.current.physicalMemoryGB)GB RAM")
                    .foregroundColor(.secondary)
            }
            
            recommendedModelCard
            
            if isDownloading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    
                    Text("Preparing download...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                VStack(spacing: 12) {
                    Button(action: {
                        downloadRecommendedModel()
                    }) {
                        Text("Download Model")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        preferencesSection = .localModels
                        showingPreferences = true
                    }) {
                        Text("Choose a different model")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: 600)
    }
    
    private func downloadRecommendedModel() {
        isDownloading = true
        
        /// Get recommended model based on RAM
        let ramGB = SystemCapabilities.current.physicalMemoryGB
        let (modelRepo, modelFile) = getRecommendedModelDownload(for: ramGB)
        
        /// Search for model on HuggingFace
        Task {
            do {
                logger.info("Searching for model: \(modelRepo)")
                await downloadManager.searchModels(query: modelRepo)
                
                /// Wait for search results
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                
                /// Find the model in results
                if let model = downloadManager.availableModels.first(where: { $0.modelId == modelRepo }) {
                    /// Find the recommended file
                    if let file = model.siblings?.first(where: { $0.rfilename == modelFile }) {
                        logger.info("Starting download: \(modelFile)")
                        await downloadManager.downloadModelWithRelatedFiles(model: model, file: file)
                        
                        /// Mark setup complete
                        await MainActor.run {
                            hasSeenWelcomeScreen = true
                            isPresented = false
                        }
                    } else {
                        logger.error("Model file not found: \(modelFile)")
                        await MainActor.run {
                            isDownloading = false
                        }
                    }
                } else {
                    logger.error("Model not found: \(modelRepo)")
                    await MainActor.run {
                        isDownloading = false
                    }
                }
            } catch {
                logger.error("Download failed: \(error.localizedDescription)")
                await MainActor.run {
                    isDownloading = false
                }
            }
        }
    }
    
    private func getRecommendedModelDownload(for ramGB: Int) -> (repo: String, file: String) {
        switch ramGB {
        case 0..<12:
            /// Qwen3-4B MLX 8-bit (for 8GB RAM)
            return ("Qwen3/Qwen3-4B-MLX-8bit", "model.safetensors")
        case 12..<28:
            /// Qwen3-8B MLX 8-bit (for 16GB RAM)
            return ("Qwen3/Qwen3-8B-MLX-8bit", "model.safetensors")
        case 28..<64:
            /// Qwen3-14B MLX 8-bit (for 32GB RAM)
            return ("Qwen3/Qwen3-14B-MLX-8bit", "model.safetensors")
        default:
            /// Qwen3-32B MLX 8-bit (for 64GB+ RAM)
            return ("Qwen3/Qwen3-32B-MLX-8bit", "model.safetensors")
        }
    }
    
    private var recommendedModelCard: some View {
        let ramGB = SystemCapabilities.current.physicalMemoryGB
        let (modelName, modelSize, contextWindow, description) = getRecommendedModel(for: ramGB)
        
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(modelName)
                        .font(.title3)
                        .fontWeight(.semibold)
                    
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(modelSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("\(contextWindow) context")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                FeatureBadge(icon: "checkmark.circle.fill", text: "Tool support enabled")
                FeatureBadge(icon: "checkmark.circle.fill", text: "FP8/FP16 precision")
                FeatureBadge(icon: "checkmark.circle.fill", text: "Apple Silicon optimized")
                FeatureBadge(icon: "checkmark.circle.fill", text: "100% private & offline")
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }
    
    private func getRecommendedModel(for ramGB: Int) -> (name: String, size: String, context: String, description: String) {
        switch ramGB {
        case 0..<12:
            return (
                "Qwen3-4B MLX 8-bit",
                "~3GB download",
                "16k",
                "Fast, capable model optimized for 8GB systems"
            )
        case 12..<28:
            return (
                "Qwen3-8B MLX 8-bit",
                "~6GB download",
                "32k",
                "Balanced model with excellent capabilities"
            )
        case 28..<64:
            return (
                "Qwen3-14B MLX 8-bit",
                "~10GB download",
                "32k",
                "Powerful model for 32GB systems with enhanced reasoning"
            )
        default:
            return (
                "Qwen3-32B MLX 8-bit",
                "~24GB download",
                "32k",
                "Most capable model for systems with 64GB+ RAM"
            )
        }
    }
    
    // MARK: - Supporting Views
}

// MARK: - Supporting Views

struct OnboardingPathCard: View {
    let icon: String
    let title: String
    let description: String
    let benefits: [String]
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(benefits, id: \.self) { benefit in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            
                            Text(benefit)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                HStack {
                    Spacer()
                    
                    Text("Choose")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .cornerRadius(8)
                    
                    Spacer()
                }
            }
            .padding(24)
            .frame(width: 300, height: 350)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accentColor.opacity(isSelected ? 1.0 : 0.0), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

struct ProviderOptionRow: View {
    let name: String
    let icon: String
    let difficulty: String
    let difficultyColor: Color
    let description: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Text(difficulty)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(difficultyColor)
                        .cornerRadius(4)
                }
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct FeatureBadge: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.green)
                .font(.caption)
            
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    let conversationManager = ConversationManager()
    let endpointManager = EndpointManager(conversationManager: conversationManager)
    
    return OnboardingWizardView(isPresented: .constant(true))
        .environmentObject(endpointManager)
        .environmentObject(conversationManager)
}
