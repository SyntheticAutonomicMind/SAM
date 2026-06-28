// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import ConversationEngine
import APIFramework

/// Tool message row. Renders the tool card with status pill, name, summary,
/// and (when present) details. Collapsible to keep long-running tool
/// output from dominating the chat surface.
struct ToolMessageRow: View {
    let message: EnhancedMessage
    let children: [EnhancedMessage]
    let enableAnimations: Bool

    @State private var isExpanded: Bool = true
    @State private var now: Date = Date()
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var displayName: String {
        if let display = message.toolDisplayData {
            return display.actionDisplayName
        }
        if let name = message.toolName, !name.isEmpty {
            return UniversalTool.generateDisplayName(from: name)
        }
        return "Tool Operation"
    }

    private var iconName: String {
        message.toolIcon ?? "wrench.and.screwdriver"
    }

    private var statusColor: Color {
        switch message.toolStatus {
        case .queued: return .secondary
        case .running: return .blue
        case .success: return .green
        case .error: return .red
        case .userInputRequired: return .orange
        case .none: return .secondary
        }
    }

    private var statusText: String {
        switch message.toolStatus {
        case .queued: return "Queued"
        case .running: return "Running"
        case .success: return "Complete"
        case .error: return "Failed"
        case .userInputRequired: return "Input needed"
        case .none: return ""
        }
    }

    private var summary: String {
        if let display = message.toolDisplayData, let s = display.summary {
            return s
        }
        // Try to extract from the raw content if it has "SUCCESS: Action: detail"
        let raw = message.content
        if raw.hasPrefix("SUCCESS: ") {
            let withoutPrefix = raw.dropFirst(9).trimmingCharacters(in: .whitespaces)
            if let colonIndex = withoutPrefix.firstIndex(of: ":") {
                return String(withoutPrefix[withoutPrefix.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            return String(withoutPrefix)
        }
        if raw.hasPrefix("ERROR: ") {
            return String(raw.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    private var details: [String] {
        if let display = message.toolDisplayData, let d = display.details {
            return d
        }
        return message.toolDetails ?? []
    }

    private var isRunning: Bool {
        message.toolStatus == .running || message.toolStatus == .queued
    }

    private var duration: String {
        if let d = message.toolDuration {
            return String(format: "%.2fs", d)
        }
        if isRunning, let started = message.timestamp as Date? {
            let elapsed = now.timeIntervalSince(started)
            return String(format: "%.1fs", elapsed)
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            card
            if !children.isEmpty && isExpanded {
                childList
            }
        }
        .padding(.horizontal, 4)
        .onReceive(timer) { newDate in
            now = newDate
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.callout)
                    .foregroundColor(statusColor)
                    .frame(width: 18)

                Text(displayName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                Spacer()

                statusPill
            }

            if !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if isExpanded, !details.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(nil)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
            }

            if !duration.isEmpty || message.toolMetadata != nil {
                HStack(spacing: 8) {
                    if !duration.isEmpty {
                        Text(duration)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if let metadata = message.toolMetadata, !metadata.isEmpty {
                        Text(metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isRunning ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if isRunning {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
                    .opacity(0.7)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }
            Text(statusText)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.12))
        )
    }

    private var childList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(children) { child in
                childRow(child)
            }
        }
        .padding(.leading, 26)
        .padding(.top, 4)
    }

    private func childRow(_ child: EnhancedMessage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: child.toolIcon ?? "circle.fill")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(child.toolDisplayData?.actionDisplayName ?? child.toolName ?? "Subtask")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            if child.toolStatus == .running {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.5)
            } else if child.toolStatus == .error {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundColor(.red)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 2)
    }
}
