// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

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

        /// Call API endpoint to get mini-prompts
        guard let url = URL(string: "http://127.0.0.1:8080/api/prompts/mini") else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "ERROR: Invalid API URL"),
                toolName: name
            )
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let prompts = json["prompts"] as? [[String: String]] else {
                return MCPToolResult(
                    success: false,
                    output: MCPOutput(content: "ERROR: Failed to parse response"),
                    toolName: name
                )
            }

            /// Format output for agent consumption
            var output = "Available Mini-Prompts:\n\n"

            for prompt in prompts {
                let id = prompt["id"] ?? "unknown"
                let name = prompt["name"] ?? "unknown"
                let content = prompt["content"] ?? ""

                output += "ID: \(id)\n"
                output += "Name: \(name)\n"
                output += "Content: \(content)\n"
                output += "\n---\n\n"
            }

            if prompts.isEmpty {
                output = "No mini-prompts configured yet.\n\nMini-prompts can be created in Preferences to add contextual information to conversations."
            }

            return MCPToolResult(
                success: true,
                output: MCPOutput(content: output),
                toolName: name
            )

        } catch {
            logger.error("Failed to list mini-prompts: \(error)")
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "ERROR: Failed to fetch mini-prompts - \(error.localizedDescription)"),
                toolName: name
            )
        }
    }
}
