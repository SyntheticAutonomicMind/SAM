// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

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

        // Access SystemPromptManager directly (same process, no API needed)
        let allPrompts = await MainActor.run {
            SystemPromptManager.shared.allConfigurations
        }
        
        /// Format output for agent consumption
        var output = "Available System Prompts:\n\n"

        for prompt in allPrompts {
            let id = prompt.id.uuidString
            let promptName = prompt.name
            let description = prompt.description ?? ""

            output += "ID: \(id)\n"
            output += "Name: \(promptName)\n"
            if !description.isEmpty {
                output += "Description: \(description)\n"
            }
            output += "\n"
        }

        if allPrompts.isEmpty {
            output = "No system prompts configured.\n\nSystem prompts can be created in Preferences > System Prompts."
        } else {
            output += "\nTO USE: Call run_subagent with systemPromptId parameter set to desired prompt ID"
        }

        return MCPToolResult(
            success: true,
            output: MCPOutput(content: output),
            toolName: name
        )
    }
}
