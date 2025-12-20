// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Scheduler picker for Stable Diffusion
///
/// USAGE:
/// ```
/// SDSchedulerPickerView(
///     selectedScheduler: $sdScheduler,
///     engine: sdEngine,
///     useKarras: $sdUseKarras
/// )
/// ```
///
/// PATTERN:
/// - Uses Menu (not Picker) for custom styling
/// - Monospaced font prevents width jumping
/// - Fixed width calculated from longest option
/// - Follows ModelPickerView pattern
/// - Engine-aware: Shows different schedulers for CoreML vs Python
///
/// REFERENCE: ModelPickerView.swift, UpscaleModelPickerView.swift
struct SDSchedulerPickerView: View {
    @Binding var selectedScheduler: String
    let engine: String
    @Binding var useKarras: Bool

    private struct SchedulerOption {
        let id: String
        let displayName: String
    }

    private var coreMLSchedulers: [SchedulerOption] {
        [
            SchedulerOption(id: "dpm++_karras", displayName: "DPM++ Karras"),
            SchedulerOption(id: "pndm", displayName: "PNDM")
        ]
    }

    private var pythonSchedulers: [SchedulerOption] {
        // CRITICAL: Filter out SDE schedulers on macOS (MPS device)
        // SDE schedulers produce all-black images on MPS due to VAE decode issues
        // This is a known Apple Silicon limitation
        let allSchedulers = [
            SchedulerOption(id: "euler", displayName: "Euler"),
            SchedulerOption(id: "euler_a", displayName: "Euler Ancestral"),
            SchedulerOption(id: "dpm++_karras", displayName: "DPM++ Karras"),
            SchedulerOption(id: "ddim", displayName: "DDIM"),
            SchedulerOption(id: "ddim_uniform", displayName: "DDIM Uniform"),
            SchedulerOption(id: "pndm", displayName: "PNDM"),
            SchedulerOption(id: "lms", displayName: "LMS")
            // REMOVED: dpm++_sde, dpm++_sde_karras - Not compatible with MPS
        ]
        return allSchedulers
    }

    private var availableSchedulers: [SchedulerOption] {
        engine == "coreml" ? coreMLSchedulers : pythonSchedulers
    }

    private var selectedDisplayName: String {
        /// For CoreML, combine scheduler + karras state
        if engine == "coreml" {
            if useKarras && selectedScheduler == "dpm++" {
                return "DPM++ Karras"
            } else if selectedScheduler == "dpm++" {
                return "DPM++"
            } else {
                return availableSchedulers.first(where: { $0.id == selectedScheduler })?.displayName ?? selectedScheduler
            }
        } else {
            /// For Python, use scheduler directly
            return availableSchedulers.first(where: { $0.id == selectedScheduler })?.displayName ?? selectedScheduler
        }
    }

    private func calculateMinWidth() -> CGFloat {
        let longestName = availableSchedulers
            .map { $0.displayName }
            .max(by: { $0.count < $1.count }) ?? "DPM++ SDE Karras"

        // Approximate character width in monospaced caption font
        let estimatedWidth = CGFloat(longestName.count) * 7.0

        // Add padding for chevron icon and margins
        return max(estimatedWidth + 30, 160)
    }

    private func selectScheduler(_ optionId: String) {
        if engine == "coreml" {
            if optionId == "dpm++_karras" {
                selectedScheduler = "dpm++"
                useKarras = true
            } else {
                selectedScheduler = optionId
                useKarras = (optionId == "dpm++")
            }
        } else {
            selectedScheduler = optionId
            useKarras = false
        }
    }

    var body: some View {
        Menu {
            ForEach(availableSchedulers, id: \.id) { option in
                Button(action: { selectScheduler(option.id) }) {
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
