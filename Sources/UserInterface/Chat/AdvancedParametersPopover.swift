// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import ConversationEngine
import APIFramework

/// Popover for advanced model parameters (temperature, top_p, max_tokens,
/// context window, repetition penalty, reasoning effort).
struct AdvancedParametersPopover: View {
    @Binding var temperature: Double
    @Binding var topP: Double
    @Binding var repetitionPenalty: Double
    @Binding var maxTokens: Int
    @Binding var maxMaxTokens: Int
    @Binding var contextWindowSize: Int
    @Binding var maxContextWindowSize: Int
    @Binding var enableReasoning: Bool
    @Binding var thinkingEffort: String
    let isLocalModel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Advanced Parameters")
                    .font(.headline)
                Spacer()
            }
            Divider()

            Group {
                slider("Temperature",
                       value: $temperature,
                       range: 0.0...2.0,
                       format: { String(format: "%.2f", $0) })
                slider("Top P",
                       value: $topP,
                       range: 0.0...1.0,
                       format: { String(format: "%.2f", $0) })
                slider("Repetition penalty",
                       value: $repetitionPenalty,
                       range: 0.5...2.0,
                       format: { String(format: "%.2f", $0) })
            }

            Divider()

            HStack {
                Text("Max tokens")
                    .frame(width: 110, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(maxTokens) },
                    set: { maxTokens = Int($0) }
                ), in: 64...Double(maxMaxTokens), step: 64)
                Text("\(maxTokens)")
                    .font(.caption.monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }

            HStack {
                Text("Context window")
                    .frame(width: 110, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(contextWindowSize) },
                    set: { contextWindowSize = Int($0) }
                ), in: 1024...Double(maxContextWindowSize), step: 1024)
                Text("\(contextWindowSize)")
                    .font(.caption.monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }

            Divider()

            Toggle("Enable reasoning", isOn: $enableReasoning)
            Picker("Effort", selection: $thinkingEffort) {
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
            }
            .pickerStyle(.segmented)
            .disabled(!enableReasoning)
        }
        .padding(16)
        .frame(width: 360)
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        HStack {
            Text(title)
                .frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
            Text(format(value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
        }
    }
}
