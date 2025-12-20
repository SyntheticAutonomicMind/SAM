// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import APIFramework
import StableDiffusionIntegration

/// Enhanced model picker showing provider, location, and cost inline using native Picker
struct ModelPickerView: View {
    @Binding var selectedModel: String
    let models: [String]
    let endpointManager: EndpointManager
    @StateObject private var sdModelManager = StableDiffusionModelManager()
    @State private var billingDataLoaded = false

    var body: some View {
        Menu {
            let (freeModels, premiumModels) = categorizeModelsByBilling(models)

            if !freeModels.isEmpty {
                Section {
                    /// Column header
                    Text(formatColumnHeader())
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .disabled(true)

                    Text("FREE MODELS")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .disabled(true)

                    ForEach(freeModels, id: \.self) { model in
                        Button(action: { selectedModel = model }) {
                            Text(formatModelDisplayName(model))
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }

            if !premiumModels.isEmpty {
                Section {
                    Text("PREMIUM MODELS")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .disabled(true)

                    ForEach(premiumModels, id: \.self) { model in
                        Button(action: { selectedModel = model }) {
                            Text(formatModelDisplayName(model))
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }
        } label: {
            /// Show just the beautified model name in the collapsed state
            /// Use fixed width based on longest model name
            HStack {
                Text(beautifyModelName(extractBaseModelId(from: selectedModel)))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(width: calculateMinWidth())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
        .onAppear {
            /// Fetch GitHub Copilot billing data if not already cached
            fetchGitHubCopilotBillingIfNeeded()
        }
    }

    /// Fetch GitHub Copilot billing data if needed
    private func fetchGitHubCopilotBillingIfNeeded() {
        Task {
            do {
                _ = try await endpointManager.getGitHubCopilotModelCapabilities()
                /// Trigger UI refresh after billing data is loaded
                await MainActor.run {
                    billingDataLoaded = true
                }
            } catch {
                /// Silently fail - billing data will remain unavailable and show "-"
                await MainActor.run {
                    billingDataLoaded = true
                }
            }
        }
    }

    /// Calculate minimum width based on longest model name
    private func calculateMinWidth() -> CGFloat {
        let longestName = models
            .map { beautifyModelName(extractBaseModelId(from: $0)) }
            .max(by: { $0.count < $1.count }) ?? ""

        /// Approximate character width in monospaced caption font
        /// Each character is roughly 7 points wide
        let estimatedWidth = CGFloat(longestName.count) * 7.0

        /// Add padding for chevron icon and margins
        return max(estimatedWidth + 30, 150)
    }

    /// Extract base model ID from full model path
    private func extractBaseModelId(from modelId: String) -> String {
        if let lastPart = modelId.split(separator: "/").last {
            return String(lastPart)
        }
        return modelId
    }

    /// Format column header with same spacing as data rows
    private func formatColumnHeader() -> String {
        let paddedName = "Model Name".padding(toLength: 30, withPad: " ", startingAt: 0)
        let paddedProvider = "Provider".padding(toLength: 18, withPad: " ", startingAt: 0)
        let paddedLocation = "Location".padding(toLength: 8, withPad: " ", startingAt: 0)
        return "\(paddedName)  \(paddedProvider)  \(paddedLocation)  Cost"
    }

    /// Categorize models by billing (free vs premium)
    private func categorizeModelsByBilling(_ models: [String]) -> (free: [String], premium: [String]) {
        var freeModels: [String] = []
        var premiumModels: [String] = []

        for model in models {
            /// SD models are always "free" (local)
            if model.hasPrefix("sd/") {
                freeModels.append(model)
                continue
            }

            let baseModelId: String
            if let lastPart = model.split(separator: "/").last {
                baseModelId = String(lastPart)
            } else {
                baseModelId = model
            }

            let billingInfo = endpointManager.getGitHubCopilotModelBillingInfo(modelId: baseModelId)
            if let billing = billingInfo, billing.isPremium {
                premiumModels.append(model)
            } else {
                freeModels.append(model)
            }
        }

        return (
            freeModels.sorted { formatModelDisplayName($0) < formatModelDisplayName($1) },
            premiumModels.sorted { formatModelDisplayName($0) < formatModelDisplayName($1) }
        )
    }

    /// Format model display name with provider, location, and cost
    private func formatModelDisplayName(_ model: String) -> String {
        /// Handle local Stable Diffusion models
        if model.hasPrefix("sd/") {
            let sdModelId = model.replacingOccurrences(of: "sd/", with: "")
            let displayName = sdModelId
                .replacingOccurrences(of: "coreml-", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "stable diffusion", with: "SD", options: .caseInsensitive)
                .capitalized

            let paddedName = displayName.padding(toLength: 30, withPad: " ", startingAt: 0)
            let paddedProvider = "Stable Diffusion".padding(toLength: 18, withPad: " ", startingAt: 0)
            let paddedLocation = "Local".padding(toLength: 8, withPad: " ", startingAt: 0)

            return "\(paddedName)  \(paddedProvider)  \(paddedLocation)  -"
        }

        /// Handle ALICE remote Stable Diffusion models (format: alice-sd-model-name)
        if model.hasPrefix("alice-") {
            let sdModelId = model
                .replacingOccurrences(of: "alice-", with: "")
                .replacingOccurrences(of: "sd-", with: "")
            let displayName = sdModelId
                .replacingOccurrences(of: "-", with: " ")
                .capitalized

            let paddedName = displayName.padding(toLength: 30, withPad: " ", startingAt: 0)
            let paddedProvider = "Stable Diffusion".padding(toLength: 18, withPad: " ", startingAt: 0)
            let paddedLocation = "ALICE".padding(toLength: 8, withPad: " ", startingAt: 0)

            return "\(paddedName)  \(paddedProvider)  \(paddedLocation)  -"
        }

        let baseModelId: String
        let provider: String

        if model.contains("/") {
            let parts = model.split(separator: "/")
            provider = parts.first.map { beautifyProviderName(String($0)) } ?? ""
            baseModelId = parts.last.map(String.init) ?? model
        } else {
            provider = ""
            baseModelId = model
        }

        let displayName = beautifyModelName(baseModelId)
        let isLocal = endpointManager.isLocalModel(model)
        let location = isLocal ? "Local" : "Remote"

        let billingInfo = endpointManager.getGitHubCopilotModelBillingInfo(modelId: baseModelId)
        let multiplierStr: String
        if let billing = billingInfo {
            let multiplier = billing.multiplier ?? 0
            if multiplier == 0 {
                multiplierStr = "-"  /// Free model (multiplier is 0)
            } else if multiplier.truncatingRemainder(dividingBy: 1) == 0 {
                multiplierStr = "\(Int(multiplier))x"
            } else {
                multiplierStr = String(format: "%.1fx", multiplier)
            }
        } else {
            /// No billing data available (not a GitHub Copilot model or data not fetched)
            multiplierStr = "-"
        }

        /// Use fixed-width spacing for uniform column alignment
        /// Format: "ModelName (padded to 30) | Provider (padded to 18) | Location (padded to 8) | Cost"
        let paddedName = displayName.padding(toLength: 30, withPad: " ", startingAt: 0)
        let paddedProvider = (provider.isEmpty ? "-" : provider).padding(toLength: 18, withPad: " ", startingAt: 0)
        let paddedLocation = location.padding(toLength: 8, withPad: " ", startingAt: 0)

        return "\(paddedName)  \(paddedProvider)  \(paddedLocation)  \(multiplierStr)"
    }

    /// Beautify provider name
    private func beautifyProviderName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "github_copilot": return "GitHub Copilot"
        case "unsloth": return "Unsloth"
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "local": return "Local"
        case "mlx": return "MLX"
        default: return provider.capitalized
        }
    }

    /// Beautify model name
    private func beautifyModelName(_ name: String) -> String {
        /// Handle SD model IDs from "sd/model-id" format
        if name.hasPrefix("sd/") || name.hasPrefix("coreml-stable") {
            let modelId = name.replacingOccurrences(of: "sd/", with: "")

            /// Try to get friendly name from metadata
            if let friendlyName = sdModelManager.getFriendlyName(for: modelId) {
                return friendlyName
            }

            /// Fall back to formatted directory name
            let cleaned = name
                .replacingOccurrences(of: "sd/", with: "")
                .replacingOccurrences(of: "coreml-", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "stable diffusion", with: "SD", options: .caseInsensitive)
            return cleaned.capitalized
        }

        /// Remove version dates
        var cleanId = name
        let datePattern = "-\\d{4}-\\d{2}-\\d{2}$"
        if let range = cleanId.range(of: datePattern, options: .regularExpression) {
            cleanId = String(cleanId[..<range.lowerBound])
        }

        /// Special cases for common models
        let specialCases: [String: String] = [
            "gpt-3.5-turbo": "GPT-3.5 Turbo",
            "gpt-4": "GPT-4",
            "gpt-4.1": "GPT-4.1",
            "gpt-41-copilot": "GPT-4.1 Copilot",
            "gpt-4o": "GPT-4o",
            "gpt-4o-mini": "GPT-4o Mini",
            "gpt-5": "GPT-5",
            "gpt-5-mini": "GPT-5 Mini",
            "gpt-5.1": "GPT-5.1",
            "gpt-5.1-codex": "GPT-5.1 Codex",
            "gpt-5.1-codex-mini": "GPT-5.1 Codex Mini"
        ]

        if let special = specialCases[cleanId.lowercased()] {
            return special
        }

        /// Handle prefixed models (claude, gemini, etc.)
        if cleanId.lowercased().hasPrefix("claude-") ||
           cleanId.lowercased().hasPrefix("gemini-") ||
           cleanId.lowercased().hasPrefix("grok-") {
            let parts = cleanId.split(separator: "-")
            return parts.map { part in
                String(part.prefix(1).uppercased() + part.dropFirst())
            }.joined(separator: " ")
        }

        /// Default: capitalize and replace dashes
        return cleanId.split(separator: "-").map { part in
            String(part.prefix(1).uppercased() + part.dropFirst())
        }.joined(separator: " ")
    }
}
