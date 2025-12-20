// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem

/// Personality picker following SAM UI patterns (monospaced, menu-based, fixed width)
struct PersonalityPickerView: View {
    @Binding var selectedPersonalityId: UUID?
    @StateObject private var personalityManager = PersonalityManager.shared

    var body: some View {
        Menu {
            /// Group built-in personalities by category
            let groupedPersonalities = Personality.personalitiesByCategory()

            ForEach(Array(groupedPersonalities.enumerated()), id: \.element.category) { index, group in
                if index > 0 {
                    Divider()
                }

                Section {
                    Text(group.category.displayName.uppercased())
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .disabled(true)

                    ForEach(group.personalities) { personality in
                        Button(action: { selectedPersonalityId = personality.id }) {
                            Text(formatPersonalityDisplayName(personality))
                                .font(.system(.caption, design: .monospaced))
                        }
                        .help(personality.description)
                    }
                }
            }

            /// Custom personalities (user-created)
            let customPersonalities = personalityManager.personalities
            if !customPersonalities.isEmpty {
                Divider()

                Section {
                    Text("CUSTOM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .disabled(true)

                    ForEach(customPersonalities) { personality in
                        Button(action: { selectedPersonalityId = personality.id }) {
                            Text(formatPersonalityDisplayName(personality))
                                .font(.system(.caption, design: .monospaced))
                        }
                        .help(personality.description)
                    }
                }
            }
        } label: {
            HStack {
                Text(getCurrentPersonalityName())
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(width: 180)  // Fixed width prevents jumping
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

    /// Get current personality name for collapsed state
    private func getCurrentPersonalityName() -> String {
        guard let selectedId = selectedPersonalityId else {
            return "Assistant"  // Default
        }

        /// Check defaults first
        if let personality = Personality.defaultPersonalities().first(where: { $0.id == selectedId }) {
            return personality.name
        }

        /// Then check user-created
        if let personality = personalityManager.personalities.first(where: { $0.id == selectedId }) {
            return personality.name
        }

        return "Assistant"  // Fallback
    }

    /// Format personality display name
    private func formatPersonalityDisplayName(_ personality: Personality) -> String {
        // Simple format: just the name (description shown in preferences)
        return personality.name
    }
}
