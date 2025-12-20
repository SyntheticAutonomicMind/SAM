// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Image size picker for Stable Diffusion
///
/// USAGE:
/// ```
/// SDSizePickerView(
///     selectedSize: Binding(
///         get: { "\(sdImageWidth)×\(sdImageHeight)" },
///         set: { newValue in
///             let components = newValue.split(separator: "×")
///             if components.count == 2,
///                let width = Int(components[0]),
///                let height = Int(components[1]) {
///                 sdImageWidth = width
///                 sdImageHeight = height
///             }
///         }
///     ),
///     availableSizes: ["512×512", "512×768", "768×512", "1024×1024"]
/// )
/// ```
///
/// PATTERN:
/// - Uses Menu (not Picker) for custom styling
/// - Monospaced font prevents width jumping
/// - Fixed width calculated from longest option
/// - Follows ModelPickerView pattern
///
/// REFERENCE: ModelPickerView.swift, UpscaleModelPickerView.swift
struct SDSizePickerView: View {
    @Binding var selectedSize: String
    let availableSizes: [String]

    private func calculateMinWidth() -> CGFloat {
        let longestSize = availableSizes
            .max(by: { $0.count < $1.count }) ?? "1024×1024"

        // Approximate character width in monospaced caption font
        let estimatedWidth = CGFloat(longestSize.count) * 7.0

        // Add padding for chevron icon and margins
        return max(estimatedWidth + 30, 100)
    }

    var body: some View {
        Menu {
            ForEach(availableSizes, id: \.self) { size in
                Button(action: { selectedSize = size }) {
                    Text(size)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        } label: {
            HStack {
                Text(selectedSize)
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
