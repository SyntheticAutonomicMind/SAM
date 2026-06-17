// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import APIFramework

/// Enhanced model picker showing provider and location inline using native Picker
struct ModelPickerView: View {
    @Binding var selectedModel: String
    @ObservedObject var modelListManager: ModelListManager
    let endpointManager: EndpointManager

    /// Computed properties for model lists
    private var models: [String] {
        modelListManager.availableModels
    }

    private var sortedModels: [String] {
        models.sorted { formatModelDisplayName($0) < formatModelDisplayName($1) }
    }

    var body: some View {
        Menu {
            Section {
                /// Column header
                Text(formatColumnHeader())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .disabled(true)

                ForEach(sortedModels, id: \.self) { model in
                    Button(action: { selectedModel = model }) {
                        Text(formatModelDisplayName(model))
                            .font(.system(.caption, design: .monospaced))
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
    }

    /// Beautify provider name
    private func beautifyProviderName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "github_copilot": return "GitHub Copilot"
        case "unsloth": return "Unsloth"
        case "openai": return "OpenAI"
        case "local": return "Local"
        case "mlx": return "MLX"
        default: return provider.capitalized
        }
    }

    /// Calculate minimum width based on longest model name
    private func calculateMinWidth() -> CGFloat {
        let longestName = modelListManager.availableModels
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
        return "\(paddedName)  \(paddedProvider)  \(paddedLocation)"
    }

    /// Format model display name with provider and location
    private func formatModelDisplayName(_ model: String) -> String {
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

        /// Use fixed-width spacing for uniform column alignment
        /// Format: "ModelName (padded to 30) | Provider (padded to 18) | Location (padded to 8)"
        let paddedName = displayName.padding(toLength: 30, withPad: " ", startingAt: 0)
        let paddedProvider = (provider.isEmpty ? "-" : provider).padding(toLength: 18, withPad: " ", startingAt: 0)
        let paddedLocation = location.padding(toLength: 8, withPad: " ", startingAt: 0)

        return "\(paddedName)  \(paddedProvider)  \(paddedLocation)"
    }

    /// Beautify model name
    private func beautifyModelName(_ name: String) -> String {
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
