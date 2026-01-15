// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// Folder for organizing conversations
public struct Folder: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var color: String?  // Hex color
    public var icon: String?   // SF Symbol name
    public var isCollapsed: Bool  // Whether folder is collapsed in sidebar

    public init(id: String = UUID().uuidString, name: String, color: String? = nil, icon: String? = nil, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.isCollapsed = isCollapsed
    }

    // Custom decoder for backward compatibility with existing folders.json
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, icon, isCollapsed
    }
}
