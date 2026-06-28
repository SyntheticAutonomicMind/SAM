// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import ConversationEngine
import AppKit

/// User message row. Right-aligned bubble with accent color. Mini-prompt and
/// userContext blocks are filtered from display.
struct UserMessageRow: View {
    let message: EnhancedMessage
    let enableAnimations: Bool
    let onEdit: () -> Void

    @State private var showCopyConfirmation: Bool = false

    private var displayContent: String {
        var result = message.content
        if let xmlStart = result.range(of: "\n\n<userContext>") {
            if let xmlEnd = result.range(of: "</userContext>", range: xmlStart.upperBound..<result.endIndex) {
                result = String(result[..<xmlStart.lowerBound])
            }
        }
        if let contextStart = result.range(of: "\n\n[User Context:") {
            result = String(result[..<contextStart.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                Text(displayContent)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor)
                            .shadow(color: .primary.opacity(0.08), radius: 2, x: 0, y: 1)
                    )
                    .foregroundColor(.white)
                    .frame(maxWidth: 600, alignment: .trailing)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Text(message.timestamp, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Button(action: copy) {
                        Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(showCopyConfirmation ? .green : .secondary)
                    .help("Copy message")

                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Edit and resend")
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayContent, forType: .string)
        showCopyConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopyConfirmation = false
        }
    }
}
