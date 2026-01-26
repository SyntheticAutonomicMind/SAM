// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging

private let logger = Logger(label: "com.sam.help.jsonview")

// MARK: - JSON-Based Help View

/// Help view that loads content from JSON file.
/// Falls back gracefully if JSON not available.
struct JSONHelpView: View {
    @StateObject private var contentManager = HelpContentManager.shared
    @State private var selectedSectionId: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                sidebar
                Divider()
                contentPane
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            if selectedSectionId == nil, let firstSection = contentManager.sections.first {
                selectedSectionId = firstSection.id
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("SAM User Guide")
                .font(.title)
                .fontWeight(.bold)

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            Text("Contents")
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            if contentManager.isLoaded && !contentManager.sections.isEmpty {
                List(contentManager.sections, selection: $selectedSectionId) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section.id)
                }
                .listStyle(.sidebar)
            } else if let error = contentManager.loadError {
                errorState(error)
            } else if !contentManager.isLoaded {
                loadingState
            } else {
                emptyState
            }
        }
        .frame(width: 220)
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text("Failed to load help")
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var loadingState: some View {
        ProgressView()
            .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No help content")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - Content Pane

    private var contentPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let sectionId = selectedSectionId,
                   let section = contentManager.section(for: sectionId) {
                    HelpSectionContentView(section: section)
                } else {
                    selectSectionPrompt
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectSectionPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Select a section from the sidebar")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("JSON Help View") {
    JSONHelpView()
}
