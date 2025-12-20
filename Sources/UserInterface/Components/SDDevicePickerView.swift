// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Device picker for Stable Diffusion (Python engine only)
///
/// USAGE:
/// ```
/// SDDevicePickerView(selectedDevice: $sdDevice)
/// ```
///
/// PATTERN:
/// - Uses Menu (not Picker) for custom styling
/// - Monospaced font prevents width jumping
/// - Fixed width calculated from longest option
/// - Follows ModelPickerView/SDSchedulerPickerView pattern
///
/// REFERENCE: ModelPickerView.swift, SDSchedulerPickerView.swift
struct SDDevicePickerView: View {
    @Binding var selectedDevice: String

    private struct DeviceOption {
        let id: String
        let displayName: String
        let description: String
    }

    private let deviceOptions: [DeviceOption] = [
        DeviceOption(id: "auto", displayName: "Auto", description: "Automatically select best device"),
        DeviceOption(id: "mps", displayName: "MPS", description: "Metal Performance Shaders (GPU)"),
        DeviceOption(id: "cpu", displayName: "CPU", description: "CPU only (slower)")
    ]

    private var selectedDisplayName: String {
        deviceOptions.first(where: { $0.id == selectedDevice })?.displayName ?? selectedDevice.uppercased()
    }

    private func calculateMinWidth() -> CGFloat {
        /// All device names are short, so use a fixed compact width
        return 100
    }

    var body: some View {
        Menu {
            ForEach(deviceOptions, id: \.id) { option in
                Button(action: { selectedDevice = option.id }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.displayName)
                            .font(.system(.caption, design: .monospaced))
                        Text(option.description)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
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
