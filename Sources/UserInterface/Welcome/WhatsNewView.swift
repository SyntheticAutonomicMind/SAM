// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging

private let logger = Logger(label: "SAM.UserInterface.WhatsNewView")

/// Model for a single release note item.
struct ReleaseNoteItem: Codable, Identifiable {
    let id: String
    let icon: String
    let title: String
    let description: String

    enum CodingKeys: String, CodingKey {
        case id, icon, title, description
    }

    init(id: String = UUID().uuidString, icon: String, title: String, description: String) {
        self.id = id
        self.icon = icon
        self.title = title
        self.description = description
    }
}

/// Model for release notes for a specific version.
struct ReleaseNotes: Codable, Identifiable {
    let version: String
    let releaseDate: String
    let highlights: [ReleaseNoteItem]
    let improvements: [ReleaseNoteItem]?
    let bugFixes: [ReleaseNoteItem]?

    var id: String { version }

    enum CodingKeys: String, CodingKey {
        case version
        case releaseDate = "release_date"
        case highlights, improvements
        case bugFixes = "bugfixes"
    }
}

/// Container for all release notes.
struct ReleaseNotesData: Codable {
    let releases: [ReleaseNotes]
}

/// Manager for loading and caching release notes.
@MainActor
final class ReleaseNotesManager: ObservableObject {
    static let shared = ReleaseNotesManager()

    @Published private(set) var releases: [ReleaseNotes] = []
    @Published private(set) var isLoaded: Bool = false

    private init() {
        loadReleaseNotes()
    }

    private func loadReleaseNotes() {
        // Try to load from Resources/whats-new.json
        guard let path = Bundle.main.path(forResource: "whats-new", ofType: "json") else {
            logger.debug("whats-new.json not found in bundle, using empty release notes")
            isLoaded = true
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            let releaseData = try decoder.decode(ReleaseNotesData.self, from: data)
            releases = releaseData.releases
            logger.info("Loaded \(releases.count) release notes from whats-new.json")
        } catch {
            logger.error("Failed to load whats-new.json: \(error.localizedDescription)")
        }

        isLoaded = true
    }

    /// Get release notes for a specific version.
    func releaseNotes(for version: String) -> ReleaseNotes? {
        releases.first { $0.version == version }
    }

    /// Get release notes for versions newer than a given version.
    func releaseNotesSince(_ version: String) -> [ReleaseNotes] {
        guard let currentIndex = releases.firstIndex(where: { $0.version == version }) else {
            // If version not found, return all releases (or empty if none)
            return releases.isEmpty ? [] : releases
        }

        // Releases are assumed to be sorted newest first
        return Array(releases.prefix(currentIndex))
    }
}

/// What's New screen displayed on first launch after an update.
struct WhatsNewView: View {
    @Binding var isPresented: Bool
    @AppStorage("lastSeenVersion") private var lastSeenVersion: String = ""
    @State private var dontShowAgain: Bool = false

    @ObservedObject private var releaseNotesManager = ReleaseNotesManager.shared

    /// The current app version.
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// Release notes to display (for current version).
    private var currentReleaseNotes: ReleaseNotes? {
        releaseNotesManager.releaseNotes(for: currentVersion)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                headerSection
                    .padding(.top, 32)

                Divider()
                    .padding(.vertical, 16)

                // Content
                if let releaseNotes = currentReleaseNotes {
                    ScrollView {
                        releaseNotesContent(releaseNotes)
                    }
                } else {
                    emptyStateContent
                }

                Spacer()

                // Footer
                footerSection
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 40)
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 500, idealHeight: 600)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 12) {
            // App Icon
            if let iconPath = Bundle.main.path(forResource: "sam-icon", ofType: "png"),
               let samIcon = NSImage(contentsOfFile: iconPath) {
                Image(nsImage: samIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .shadow(radius: 4)
            } else {
                Image(systemName: "brain.head.profile")
                    .resizable()
                    .frame(width: 80, height: 80)
                    .foregroundColor(.accentColor)
            }

            VStack(spacing: 4) {
                Text("What's New in SAM")
                    .font(.system(size: 28, weight: .bold))

                Text("Version \(currentVersion)")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Release Notes Content

    private func releaseNotesContent(_ releaseNotes: ReleaseNotes) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            // Release date
            if !releaseNotes.releaseDate.isEmpty {
                Text("Released \(releaseNotes.releaseDate)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Highlights section
            if !releaseNotes.highlights.isEmpty {
                releaseSection(title: "Highlights", icon: "star.fill", color: .yellow, items: releaseNotes.highlights)
            }

            // Improvements section
            if let improvements = releaseNotes.improvements, !improvements.isEmpty {
                releaseSection(title: "Improvements", icon: "arrow.up.circle.fill", color: .green, items: improvements)
            }

            // Bug fixes section
            if let bugFixes = releaseNotes.bugFixes, !bugFixes.isEmpty {
                releaseSection(title: "Bug Fixes", icon: "checkmark.circle.fill", color: .blue, items: bugFixes)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private func releaseSection(title: String, icon: String, color: Color, items: [ReleaseNoteItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
            }

            // Items
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    WhatsNewFeatureRow(
                        icon: item.icon,
                        title: item.title,
                        description: item.description
                    )
                }
            }
        }
    }

    private var emptyStateContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No release notes available for this version.")
                .font(.body)
                .foregroundColor(.secondary)

            Text("Check the Help menu for documentation and user guides.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        VStack(spacing: 16) {
            Toggle("Don't show on startup", isOn: $dontShowAgain)
                .toggleStyle(.checkbox)

            Button(action: {
                if dontShowAgain {
                    // Store a special sentinel to indicate "never show"
                    lastSeenVersion = "__never_show__"
                    logger.debug("User disabled What's New screen via preference")
                } else {
                    // Store current version so we don't show again until next update
                    lastSeenVersion = currentVersion
                }
                isPresented = false
            }) {
                Text("Continue")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .frame(width: 200)
        }
    }

    // MARK: - Static Helpers

    /// Check if the What's New screen should be shown.
    static func shouldShow() -> Bool {
        let lastSeen = UserDefaults.standard.string(forKey: "lastSeenVersion") ?? ""

        // Never show if user explicitly disabled
        if lastSeen == "__never_show__" {
            return false
        }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

        // Show if this is a new version the user hasn't seen
        // Also show if lastSeen is empty (first launch with this feature)
        // but only if we have release notes for this version
        if lastSeen.isEmpty {
            // First time - check if we have release notes for current version
            return ReleaseNotesManager.shared.releaseNotes(for: currentVersion) != nil
        }

        return lastSeen != currentVersion && ReleaseNotesManager.shared.releaseNotes(for: currentVersion) != nil
    }
}

/// Feature row component for What's New screen.
struct WhatsNewFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
    }
}

#Preview {
    WhatsNewView(isPresented: .constant(true))
}
