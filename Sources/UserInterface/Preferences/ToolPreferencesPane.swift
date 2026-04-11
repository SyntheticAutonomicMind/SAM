// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging

private let logger = Logger(label: "com.sam.preferences.tools")

/// UserDefaults key for disabled tools
private let disabledToolsKey = "tools.disabledBuiltinTools"

// MARK: - Tool Metadata

struct ToolInfo: Identifiable {
    let id: String
    let name: String
    let icon: String
    let iconColor: Color
    let description: String
    let privacyNote: String?
}

struct ToolPreferenceCategory: Identifiable {
    let id: String
    let name: String
    let tools: [ToolInfo]
}

/// All built-in tools organized by category
private let toolCategories: [ToolPreferenceCategory] = [
    ToolPreferenceCategory(id: "core", name: "Core", tools: [
        ToolInfo(
            id: "file_operations",
            name: "File Operations",
            icon: "doc.on.doc",
            iconColor: .blue,
            description: "Read, write, search, and manage files in the working directory.",
            privacyNote: nil
        ),
        ToolInfo(
            id: "user_collaboration",
            name: "User Collaboration",
            icon: "person.bubble",
            iconColor: .green,
            description: "Allows SAM to ask you questions and get confirmation during tasks.",
            privacyNote: nil
        ),
        ToolInfo(
            id: "memory_operations",
            name: "Memory",
            icon: "brain.head.profile",
            iconColor: .purple,
            description: "Store and recall information across conversations for continuity.",
            privacyNote: nil
        ),
        ToolInfo(
            id: "todo_operations",
            name: "Task Tracking",
            icon: "checklist",
            iconColor: .orange,
            description: "Create and manage task lists to track progress during complex work.",
            privacyNote: nil
        ),
    ]),
    ToolPreferenceCategory(id: "productivity", name: "Productivity", tools: [
        ToolInfo(
            id: "web_operations",
            name: "Web Search & Fetch",
            icon: "globe",
            iconColor: .blue,
            description: "Search the web and fetch content from URLs.",
            privacyNote: "Sends search queries to configured search provider."
        ),
        ToolInfo(
            id: "document_operations",
            name: "Documents",
            icon: "doc.richtext",
            iconColor: .indigo,
            description: "Import and create documents in conversations.",
            privacyNote: nil
        ),
        ToolInfo(
            id: "math_operations",
            name: "Math & Calculations",
            icon: "function",
            iconColor: .teal,
            description: "Perform calculations, unit conversions, and evaluate formulas.",
            privacyNote: nil
        ),
    ]),
    ToolPreferenceCategory(id: "macos", name: "macOS Integration", tools: [
        ToolInfo(
            id: "calendar_operations",
            name: "Calendar & Reminders",
            icon: "calendar",
            iconColor: .red,
            description: "List, create, search, and delete calendar events and reminders.",
            privacyNote: "Reads and writes to your Apple Calendar and Reminders."
        ),
        ToolInfo(
            id: "contacts_operations",
            name: "Contacts",
            icon: "person.crop.circle",
            iconColor: .blue,
            description: "Search, read, and create entries in your address book.",
            privacyNote: "Reads and writes to your macOS Contacts."
        ),
        ToolInfo(
            id: "notes_operations",
            name: "Apple Notes",
            icon: "note.text",
            iconColor: .yellow,
            description: "Search, read, create, and append to your Apple Notes.",
            privacyNote: "Reads and writes to your Apple Notes via AppleScript."
        ),
        ToolInfo(
            id: "spotlight_search",
            name: "Spotlight Search",
            icon: "magnifyingglass",
            iconColor: .purple,
            description: "Search your file system by name, content, or metadata using Spotlight.",
            privacyNote: "Can search and list files anywhere on your Mac."
        ),
        ToolInfo(
            id: "weather_operations",
            name: "Weather",
            icon: "cloud.sun.fill",
            iconColor: .cyan,
            description: "Check current conditions, forecasts, and hourly weather for any location.",
            privacyNote: "Sends location data to the Open-Meteo API for weather lookups."
        ),
    ]),
    ToolPreferenceCategory(id: "creative", name: "Creative", tools: [
        ToolInfo(
            id: "image_generation",
            name: "Image Generation",
            icon: "paintbrush",
            iconColor: .pink,
            description: "Generate images using ALICE (requires ALICE server configuration).",
            privacyNote: "Sends prompts to your configured ALICE server."
        ),
    ]),
]

/// All core tool IDs that cannot be disabled
private let coreToolIds: Set<String> = [
    "file_operations",
    "user_collaboration",
    "memory_operations",
    "todo_operations",
]

// MARK: - Preferences Pane

struct ToolPreferencesPane: View {
    @State private var disabledTools: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Tools")
                    .font(.title)
                    .fontWeight(.semibold)
                    .padding(.bottom, 4)

                Text("Control which tools SAM can use. Disabled tools are not sent to the AI and cannot be called. Core tools are required for basic functionality and cannot be disabled.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                ForEach(toolCategories) { category in
                    toolCategorySection(category)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            loadDisabledTools()
        }
    }

    // MARK: - Category Section

    private func toolCategorySection(_ category: ToolPreferenceCategory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Category header
            HStack {
                Text(category.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                if category.id != "core" {
                    let enabledCount = category.tools.filter { !disabledTools.contains($0.id) }.count
                    Text("\(enabledCount)/\(category.tools.count) enabled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            // Tool rows
            ForEach(category.tools) { tool in
                toolRow(tool, isCore: coreToolIds.contains(tool.id))
                if tool.id != category.tools.last?.id {
                    Divider()
                        .padding(.leading, 52)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Tool Row

    private func toolRow(_ tool: ToolInfo, isCore: Bool) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: tool.icon)
                .font(.system(size: 18))
                .foregroundColor(isEnabled(tool) ? tool.iconColor : .secondary)
                .frame(width: 28, alignment: .center)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(.body)
                    .foregroundColor(isEnabled(tool) ? .primary : .secondary)

                Text(tool.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                if let privacyNote = tool.privacyNote {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield")
                            .font(.caption2)
                        Text(privacyNote)
                            .font(.caption2)
                    }
                    .foregroundColor(.orange)
                    .padding(.top, 1)
                }
            }

            Spacer()

            // Toggle
            if isCore {
                Text("Required")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            } else {
                Toggle("", isOn: Binding(
                    get: { isEnabled(tool) },
                    set: { enabled in
                        if enabled {
                            disabledTools.remove(tool.id)
                        } else {
                            disabledTools.insert(tool.id)
                        }
                        saveDisabledTools()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func isEnabled(_ tool: ToolInfo) -> Bool {
        return !disabledTools.contains(tool.id)
    }

    private func loadDisabledTools() {
        if let stored = UserDefaults.standard.stringArray(forKey: disabledToolsKey) {
            disabledTools = Set(stored)
        }
    }

    private func saveDisabledTools() {
        let sorted = disabledTools.sorted()
        UserDefaults.standard.set(sorted, forKey: disabledToolsKey)
        logger.info("Updated disabled tools: \(sorted)")
    }
}
