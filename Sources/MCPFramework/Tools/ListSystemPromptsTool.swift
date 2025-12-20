// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// List available system prompts for agent awareness
/// Enables agents to discover system prompts for run_subagent tool
public class ListSystemPromptsTool: MCPTool, @unchecked Sendable {
    public let name = "list_system_prompts"
    public let description = """
List all available system prompts with IDs, names, and descriptions.

USE CASE:
- Discover available prompts before creating subagents
- Find appropriate prompt for specialized tasks
- Get prompt IDs for run_subagent systemPromptId parameter

WORKFLOW:
1. Agent: "What system prompts are available?"
2. Uses list_system_prompts tool
3. Gets list with IDs and descriptions
4. Agent: "Create subagent with [prompt name]"
5. Uses run_subagent with systemPromptId from discovery

EXAMPLE:
{}  // No parameters required

Returns JSON array with:
- id: UUID string for use with run_subagent
- name: Human-readable prompt name
- description: What the prompt is designed for
"""

    public var parameters: [String: MCPToolParameter] {
        return [:]  // No parameters needed
    }

    private let logger = Logger(label: "com.sam.list-system-prompts-tool")

    public init() {}

    public func execute(
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        logger.debug("Listing system prompts")

        /// Call API endpoint to get prompts
        guard let url = URL(string: "http://127.0.0.1:8080/api/prompts/system") else {
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
            var output = "Available System Prompts:\n\n"

            for prompt in prompts {
                let id = prompt["id"] ?? "unknown"
                let name = prompt["name"] ?? "unknown"
                let description = prompt["description"] ?? ""

                output += "ID: \(id)\n"
                output += "Name: \(name)\n"
                if !description.isEmpty {
                    output += "Description: \(description)\n"
                }
                output += "\n"
            }

            output += "\nTO USE: Call run_subagent with systemPromptId parameter set to desired prompt ID"

            return MCPToolResult(
                success: true,
                output: MCPOutput(content: output),
                toolName: name
            )

        } catch {
            logger.error("Failed to list system prompts: \(error)")
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "ERROR: Failed to fetch prompts - \(error.localizedDescription)"),
                toolName: name
            )
        }
    }
}
