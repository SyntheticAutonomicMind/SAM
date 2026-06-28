// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import ConversationEngine
import APIFramework

/// System status row. Used for orchestrator status messages (e.g. "loading
/// model", "rate-limited retry in 30s", "compacting context").
struct SystemStatusMessageRow: View {
    let message: EnhancedMessage
    let enableAnimations: Bool

    private var statusKind: StatusKind {
        let content = message.content.lowercased()
        if content.contains("loading") && content.contains("model") { return .loadingModel }
        if content.contains("rate") || content.contains("retry") { return .retry }
        if content.contains("compact") || content.contains("compres") { return .compressing }
        if content.contains("error") { return .error }
        return .info
    }

    enum StatusKind {
        case info, loadingModel, retry, compressing, error
    }

    private var iconName: String {
        switch statusKind {
        case .info: return "info.circle"
        case .loadingModel: return "cpu"
        case .retry: return "arrow.clockwise"
        case .compressing: return "arrow.down.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch statusKind {
        case .info: return .secondary
        case .loadingModel: return .blue
        case .retry: return .orange
        case .compressing: return .purple
        case .error: return .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundColor(color)
            Text(message.content)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}
