// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import ConversationEngine
import APIFramework

/// Thinking/reasoning card. Collapsed by default once the response finishes
/// streaming; expanded while the reasoning is actively arriving.
struct ThinkingMessageRow: View {
    let message: EnhancedMessage
    let enableAnimations: Bool

    @State private var isExpanded: Bool = false

    private var reasoningText: String {
        if let r = message.reasoningContent, !r.isEmpty {
            return r
        }
        return message.content
    }

    private var isReasoningLive: Bool {
        message.isStreaming && !reasoningText.isEmpty
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundColor(.purple)
                    Text(isReasoningLive ? "Thinking..." : "Reasoning")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.purple)
                    if isReasoningLive {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.5)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }

                if isExpanded && !reasoningText.isEmpty {
                    Text(reasoningText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.purple.opacity(0.06))
                        )
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.purple.opacity(0.04))
            )
        }
        .padding(.horizontal, 4)
        .onAppear {
            isExpanded = isReasoningLive
        }
        .onChange(of: isReasoningLive) { _, newValue in
            if newValue { isExpanded = true }
        }
    }
}
