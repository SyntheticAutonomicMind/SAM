// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import SharedData

/// Topic picker using Menu to show only topic name when collapsed
/// Follows the same pattern as PromptPickerView and ModelPickerView
struct TopicPickerView: View {
    let selectedTopicId: String?
    let topics: [SharedTopic]
    let onSelect: (String?) -> Void

    /// String binding initializer
    init(selectedTopicId: Binding<String?>, topics: [SharedTopic]) {
        self.selectedTopicId = selectedTopicId.wrappedValue
        self.topics = topics
        self.onSelect = { newId in
            selectedTopicId.wrappedValue = newId
        }
    }

    var body: some View {
        Menu {
            ForEach(topics, id: \.id) { topic in
                Button(action: { onSelect(topic.id) }) {
                    Text(topic.name)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        } label: {
            /// Show just the topic name in the collapsed state
            HStack {
                Text(selectedTopicName)
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

    /// Get the name of the currently selected topic
    private var selectedTopicName: String {
        if let id = selectedTopicId {
            return topics.first(where: { $0.id == id })?.name ?? "None"
        }
        return "None"
    }

    /// Calculate minimum width based on longest topic name
    private func calculateMinWidth() -> CGFloat {
        let longestName = topics
            .map { $0.name }
            .max(by: { $0.count < $1.count }) ?? ""

        /// Approximate character width in monospaced caption font
        let estimatedWidth = CGFloat(longestName.count) * 7.0

        /// Add padding for chevron icon and margins
        return max(estimatedWidth + 30, 120)
    }
}
