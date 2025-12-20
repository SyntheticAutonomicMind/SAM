// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging

/// UI component for selecting and managing conversation's working directory.
struct WorkingDirectoryPicker: View {
    @Binding var workingDirectory: String
    @State private var isExpanded = false

    private let logger = Logger(label: "com.sam.ui.WorkingDirectoryPicker")

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            /// Collapsed view (shows in toolbar).
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                    .font(.caption)

                Text(displayPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .help(workingDirectory)

                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide Working Directory Details" : "Show Working Directory Details")

                Button(action: selectDirectory) {
                    Image(systemName: "folder.badge.plus")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
                .help("Change Working Directory")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            /// Expanded view (shows full path and actions).
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Working Directory:")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Spacer()

                        Button("Reveal in Finder") {
                            revealInFinder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    Text(workingDirectory)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(4)

                    Text("All file operations and terminal commands will use this directory unless an absolute path is specified.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    HStack {
                        Button("Reset to Default") {
                            resetToDefault()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        Button("Change...") {
                            selectDirectory()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(6)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private var displayPath: String {
        /// Show abbreviated path (e.g., ~/Documents/SAM/MyProject).
        if workingDirectory.hasPrefix(NSHomeDirectory()) {
            let relative = workingDirectory.replacingOccurrences(
                of: NSHomeDirectory(),
                with: "~"
            )

            /// Further abbreviate if too long (keep first and last parts).
            if relative.count > 40 {
                let components = relative.split(separator: "/")
                if components.count > 3 {
                    let first = components.prefix(2).joined(separator: "/")
                    let last = components.suffix(1).joined(separator: "/")
                    return "\(first)/…/\(last)"
                }
            }

            return relative
        }

        /// For non-home paths, show last 2 components.
        let components = workingDirectory.split(separator: "/")
        if components.count > 2 {
            return "…/" + components.suffix(2).joined(separator: "/")
        }

        return workingDirectory
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select working directory for this conversation"
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: workingDirectory)

        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
            logger.debug("Working directory changed to: \(url.path)")
        }
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: workingDirectory)

        /// Ensure directory exists before revealing.
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: workingDirectory) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                logger.debug("Created working directory: \(workingDirectory)")
            } catch {
                logger.error("Failed to create working directory: \(error)")
                return
            }
        }

        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        logger.debug("Revealed working directory in Finder: \(workingDirectory)")
    }

    private func resetToDefault() {
        /// Reset to ~/Documents/SAM/<conversation-name> Note: We don't have access to conversation title here, so reset to parent SAM directory.
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let samDir = homeDir.appendingPathComponent("Documents/SAM")

        /// If current path is already under ~/Documents/SAM/, keep the immediate subdirectory Otherwise, reset to ~/Documents/SAM/.
        if workingDirectory.hasPrefix(samDir.path + "/") {
            /// Extract immediate subdirectory.
            let relativePath = workingDirectory.replacingOccurrences(of: samDir.path + "/", with: "")
            let components = relativePath.split(separator: "/")
            if let firstComponent = components.first {
                workingDirectory = samDir.appendingPathComponent(String(firstComponent)).path
            } else {
                workingDirectory = samDir.path
            }
        } else {
            workingDirectory = samDir.path
        }

        logger.debug("Reset working directory to: \(workingDirectory)")
    }
}

/// Preview provider for SwiftUI previews.
struct WorkingDirectoryPicker_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            /// Compact view.
            WorkingDirectoryPicker(
                workingDirectory: .constant("/Users/testuser/Documents/SAM/My-Project")
            )
            .frame(width: 400)

            /// Long path.
            WorkingDirectoryPicker(
                workingDirectory: .constant("/Users/testuser/Documents/SAM/Very-Long-Project-Name-That-Needs-Truncation")
            )
            .frame(width: 400)
        }
        .padding()
    }
}
