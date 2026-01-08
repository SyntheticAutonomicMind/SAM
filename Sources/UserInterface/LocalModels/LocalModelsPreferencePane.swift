// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import APIFramework
import Logging

private let logger = Logger(label: "com.sam.ui.localmodels")

/// Local Models preference pane for downloading and managing GGUF/MLX models.
/// Uses a tabbed interface similar to StableDiffusionPreferencesPane.
public struct LocalModelsPreferencePane: View {
    @StateObject private var downloadManager: ModelDownloadManager
    @State private var selectedTab: LMTab = .installed

    public init(endpointManager: EndpointManager? = nil) {
        _downloadManager = StateObject(wrappedValue: ModelDownloadManager(endpointManager: endpointManager))
    }

    enum LMTab: String, CaseIterable {
        case installed = "Installed Models"
        case download = "Download"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .installed: return "checkmark.circle"
            case .download: return "arrow.down.circle"
            case .settings: return "gearshape"
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            /// Tab bar
            HStack(spacing: 0) {
                ForEach(LMTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                            Text(tab.rawValue)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.1) : Color.clear)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            /// Tab content
            Group {
                switch selectedTab {
                case .installed:
                    LocalModelsPreferencePane_InstalledTab()
                        .environmentObject(downloadManager)
                case .download:
                    LocalModelsPreferencePane_DownloadTab()
                        .environmentObject(downloadManager)
                case .settings:
                    LocalModelsPreferencePane_SettingsTab()
                }
            }
        }
    }
}
