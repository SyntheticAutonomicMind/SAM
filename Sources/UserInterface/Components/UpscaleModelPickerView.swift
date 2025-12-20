// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Upscale model picker for Stable Diffusion image generation
///
/// USAGE:
/// ```
/// UpscaleModelPickerView(
///     selectedModel: $sdUpscaleModel
/// )
/// ```
///
/// PATTERN:
/// - Uses Menu (not Picker) for custom styling
/// - Monospaced font prevents width jumping
/// - Fixed width calculated from longest option
/// - Follows ModelPickerView pattern
///
/// REFERENCE: ModelPickerView.swift, PromptPickerView.swift
struct UpscaleModelPickerView: View {
    @Binding var selectedModel: String

    private struct UpscaleOption {
        let id: String
        let displayName: String
    }

    private let options: [UpscaleOption] = [
        UpscaleOption(id: "none", displayName: "None"),
        UpscaleOption(id: "general", displayName: "General 4x"),
        UpscaleOption(id: "anime", displayName: "Anime 4x"),
        UpscaleOption(id: "general_x2", displayName: "General 2x")
    ]

    private var selectedDisplayName: String {
        options.first(where: { $0.id == selectedModel })?.displayName ?? "None"
    }

    private func calculateMinWidth() -> CGFloat {
        let longestName = options
            .map { $0.displayName }
            .max(by: { $0.count < $1.count }) ?? ""

        // Approximate character width in monospaced caption font
        let estimatedWidth = CGFloat(longestName.count) * 7.0

        // Add padding for chevron icon and margins
        return max(estimatedWidth + 30, 120)
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.id) { option in
                Button(action: { selectedModel = option.id }) {
                    Text(option.displayName)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        } label: {
            HStack {
                Text(selectedDisplayName)
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
}
