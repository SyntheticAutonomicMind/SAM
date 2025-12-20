// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem

/// Enhanced prompt picker using Menu to show only prompt name when collapsed
/// Supports both UUID and String (UUID string) bindings
struct PromptPickerView: View {
    let selectedPromptId: UUID
    let prompts: [SystemPromptConfiguration]
    let onSelect: (UUID) -> Void

    /// UUID binding initializer (for ChatWidget)
    init(selectedPromptId: Binding<UUID>, prompts: [SystemPromptConfiguration]) {
        self.selectedPromptId = selectedPromptId.wrappedValue
        self.prompts = prompts
        self.onSelect = { newId in
            selectedPromptId.wrappedValue = newId
        }
    }

    /// String binding initializer (for PreferencesView)
    init(selectedPromptIdString: Binding<String>, prompts: [SystemPromptConfiguration]) {
        self.selectedPromptId = UUID(uuidString: selectedPromptIdString.wrappedValue) ?? prompts.first?.id ?? UUID()
        self.prompts = prompts
        self.onSelect = { newId in
            selectedPromptIdString.wrappedValue = newId.uuidString
        }
    }

    var body: some View {
        Menu {
            ForEach(prompts, id: \.id) { prompt in
                Button(action: { onSelect(prompt.id) }) {
                    Text(prompt.name)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        } label: {
            /// Show just the prompt name in the collapsed state
            HStack {
                Text(selectedPromptName)
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

    /// Get the name of the currently selected prompt
    private var selectedPromptName: String {
        prompts.first(where: { $0.id == selectedPromptId })?.name ?? "Unknown"
    }

    /// Calculate minimum width based on longest prompt name
    private func calculateMinWidth() -> CGFloat {
        let longestName = prompts
            .map { $0.name }
            .max(by: { $0.count < $1.count }) ?? ""

        /// Approximate character width in monospaced caption font
        let estimatedWidth = CGFloat(longestName.count) * 7.0

        /// Add padding for chevron icon and margins
        return max(estimatedWidth + 30, 140)
    }
}
