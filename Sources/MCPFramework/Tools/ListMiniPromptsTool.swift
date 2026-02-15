// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

/// List available mini-prompts for contextual awareness
/// Enables agents to discover mini-prompts available in the system
public class ListMiniPromptsTool: MCPTool, @unchecked Sendable {
    public let name = "list_mini_prompts"
    public let description = """
List all available mini-prompts with IDs, names, and content.

USE CASE:
- Discover contextual information available
- Learn about user preferences and project details
- Understand conversation context

WHAT ARE MINI-PROMPTS:
Mini-prompts are reusable snippets of contextual information that can be
enabled per-conversation. They contain things like:
- Personal info (location, system specs)
- Project details (tech stack, architecture)
- Code preferences (style, patterns)
- Technical specs (hardware, software)

EXAMPLE:
{}  // No parameters required

Returns JSON array with:
- id: UUID string
- name: Descriptive name
- content: Full mini-prompt text
"""

    public var parameters: [String: MCPToolParameter] {
        return [:]  // No parameters needed
    }

    private let logger = Logger(label: "com.sam.list-mini-prompts-tool")

    public init() {}

    public func execute(
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        logger.debug("Listing mini-prompts")

        // Access MiniPromptManager directly (same process, no API needed)
        let allMiniPrompts = await MainActor.run {
            MiniPromptManager.shared.miniPrompts
        }

        /// Format output for agent consumption
        var output = "Available Mini-Prompts:\n\n"

        for prompt in allMiniPrompts {
            let id = prompt.id.uuidString
            let promptName = prompt.name
            let content = prompt.content

            output += "ID: \(id)\n"
            output += "Name: \(promptName)\n"
            output += "Content: \(content)\n"
            output += "\n---\n\n"
        }

        if allMiniPrompts.isEmpty {
            output = "No mini-prompts configured yet.\n\nMini-prompts can be created in Preferences to add contextual information to conversations."
        }

        return MCPToolResult(
            success: true,
            output: MCPOutput(content: output),
            toolName: name
        )
    }
}
