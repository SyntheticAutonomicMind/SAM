// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

private let logger = Logger(label: "SAM.UserInterface.HelpContentManager")

// MARK: - Help Content Data Models

/// Element type for help content.
enum HelpElementType: String, Codable {
    case heading
    case subheading
    case text
    case bulletPoint
    case step
    case example
    case tip
    case warning
    case note
    case keyboardShortcut
    case divider
    case group
    case code
    case link
    case troubleshootingItem
    case formatSupport
    case systemPromptOption
    case capabilityCategory
    case toolCategory
}

/// A single content element within a help section.
struct HelpElement: Codable, Identifiable {
    let id: String
    let type: HelpElementType
    let content: String
    var children: [HelpElement]?
    var properties: [String: String]?

    init(
        id: String = UUID().uuidString,
        type: HelpElementType,
        content: String,
        children: [HelpElement]? = nil,
        properties: [String: String]? = nil
    ) {
        self.id = id
        self.type = type
        self.content = content
        self.children = children
        self.properties = properties
    }
}

/// A help section containing multiple content elements.
struct HelpSectionData: Codable, Identifiable {
    let id: String
    let title: String
    let icon: String
    let order: Int
    let elements: [HelpElement]
}

/// Root container for all help data.
struct HelpDataFile: Codable {
    let version: String
    let sections: [HelpSectionData]
}

// MARK: - Help Content Manager

/// Singleton manager for loading and caching help content from JSON.
@MainActor
final class HelpContentManager: ObservableObject {
    static let shared = HelpContentManager()

    @Published private(set) var sections: [HelpSectionData] = []
    @Published private(set) var isLoaded: Bool = false
    @Published private(set) var loadError: String?

    private init() {
        loadHelpContent()
    }

    /// Load help content from bundled help.json.
    func loadHelpContent() {
        guard let helpURL = Bundle.main.url(forResource: "help", withExtension: "json") else {
            logger.debug("help.json not found in bundle - using hardcoded HelpView")
            isLoaded = true
            return
        }

        do {
            let data = try Data(contentsOf: helpURL)
            let decoder = JSONDecoder()
            let helpData = try decoder.decode(HelpDataFile.self, from: data)
            sections = helpData.sections.sorted { $0.order < $1.order }
            logger.info("Loaded \(sections.count) help sections from help.json")
        } catch {
            logger.error("Failed to load help.json: \(error.localizedDescription)")
            loadError = error.localizedDescription
        }

        isLoaded = true
    }

    /// Get a specific section by ID.
    func section(for id: String) -> HelpSectionData? {
        sections.first { $0.id == id }
    }

    /// Reload all help content.
    func reload() {
        isLoaded = false
        loadError = nil
        sections = []
        loadHelpContent()
    }
}
