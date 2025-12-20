// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// View for displaying reasoning content in a collapsible, distinctive format.
public struct ReasoningView: View {
    let reasoningContent: String
    @State private var isExpanded: Bool

    public init(reasoningContent: String, autoExpand: Bool = false) {
        self.reasoningContent = reasoningContent
        self._isExpanded = State(initialValue: autoExpand)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            /// Reasoning header with toggle.
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .foregroundColor(.orange)
                        .font(.caption)

                    Text("Reasoning")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.orange)
                        .font(.caption2)
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
            }
            .buttonStyle(.plain)

            /// Expandable reasoning content.
            if isExpanded {
                ScrollView {
                    Text(reasoningContent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .transition(.opacity.combined(with: .slide))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

#if DEBUG
struct ReasoningView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            ReasoningView(
                reasoningContent: "Let me think about this step by step:\n\n1. First, I need to understand what the user is asking\n2. Then I should consider the best approach\n3. Finally, I'll provide a comprehensive response\n\nThis seems like a good approach because it breaks down the problem systematically.",
                autoExpand: true
            )

            ReasoningView(
                reasoningContent: "Short reasoning content",
                autoExpand: false
            )
        }
        .padding()
    }
}
#endif
