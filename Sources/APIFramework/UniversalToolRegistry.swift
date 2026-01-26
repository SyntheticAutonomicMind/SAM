// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConversationEngine
import Logging
import ConfigurationSystem

// MARK: - Protocol Conformance

/// Universal Tool Registry for Cross-Model MCP Tool Integration Follows Model Context Protocol (MCP) architecture to provide universal tool access across all language models (GPT-4, Claude, etc.) with proper tool registration, discovery, and execution.
@MainActor
public class UniversalToolRegistry: ObservableObject, ToolRegistryProtocol {
    private let logger = Logger(label: "com.syntheticautonomicmind.sam.UniversalToolRegistry")

    /// Core registry storage.
    private var registeredTools: [String: UniversalTool] = [:]
    private var toolDefinitions: [OpenAITool] = []
    private var mcpToolsRegistered = false

    /// Dependencies.
    private let conversationManager: ConversationManager
    private let isExternalExecution: Bool

    public init(conversationManager: ConversationManager, isExternalExecution: Bool = false) {
        self.conversationManager = conversationManager
        self.isExternalExecution = isExternalExecution
        logger.debug("DEBUG_TOOLS: UniversalToolRegistry - Initialized with ConversationManager")

    }

    /// Initialize MCP tools - must be called from MainActor context.
    public func initializeMCPTools() async {
        logger.debug("DEBUG_TOOLS: UniversalToolRegistry - initializeMCPTools called on MainActor")
        let availableTools = conversationManager.getAvailableMCPTools()
        logger.debug("DEBUG_TOOLS: Found \(availableTools.count) MCP tools")
        for tool in availableTools {
            logger.debug("DEBUG_TOOLS: MCP Tool - \(tool.name)")
        }
    }

    /// Register MCP tools safely (called from MainActor context).
    @MainActor
    private func registerMCPToolsSafely() {
        guard !mcpToolsRegistered else { return }

        let mcpTools = conversationManager.getAvailableMCPTools()
        logger.debug("DEBUG_TOOLS: Found \(mcpTools.count) MCP tools from ConversationManager")

        for mcpTool in mcpTools {
            let universalTool = UniversalTool(
                name: mcpTool.name,
                description: mcpTool.description,
                parameters: mcpTool.parameters,
                executor: MCPToolExecutor(
                    toolName: mcpTool.name,
                    conversationManager: conversationManager,
                    isExternalExecution: self.isExternalExecution
                ),
                icon: getIconForTool(mcpTool.name)
            )

            registerTool(universalTool)
            logger.debug("DEBUG_TOOLS: Registered tool: \(mcpTool.name)")
        }

        mcpToolsRegistered = true
        logger.debug("DEBUG_TOOLS: MCP tools registration completed")
    }

    // MARK: - Tool Registration

    /// Get appropriate SF Symbol icon for a tool based on its name
    private func getIconForTool(_ toolName: String) -> String {
        switch toolName {
        // Image & Visual
        case "image_generation":
            return "photo.on.rectangle.angled"
        case "document_create", "document_create_mcp":
            return "doc.badge.plus"
        case "document_import", "document_import_mcp":
            return "doc.badge.arrow.up"
        case "document_operations", "document_operations_mcp":
            return "doc.text"

        // Web & Research
        case "web_research", "web_research_mcp":
            return "globe.badge.chevron.backward"
        case "web_operations", "web_operations_mcp":
            return "network"
        case "fetch_webpage":
            return "arrow.down.doc"

        // File Operations
        case "read_file":
            return "doc.plaintext"
        case "create_file":
            return "doc.badge.plus"
        case "delete_file":
            return "trash"
        case "rename_file":
            return "pencil.and.list.clipboard"
        case "list_dir":
            return "folder"
        case "get_changed_files":
            return "arrow.triangle.2.circlepath"

        // Code Operations
        case "replace_string_in_file", "multi_replace_string_in_file":
            return "arrow.left.arrow.right"
        case "insert_edit":
            return "text.insert"
        case "apply_patch":
            return "bandage"
        case "grep_search":
            return "magnifyingglass.circle"
        case "semantic_search":
            return "brain"
        case "list_code_usages":
            return "list.bullet.indent"

        // Memory & Data
        case "vectorrag_add_document":
            return "doc.badge.arrow.up"
        case "vectorrag_query":
            return "doc.text.magnifyingglass"
        case "vectorrag_list_documents":
            return "list.bullet.rectangle"
        case "vectorrag_delete_document":
            return "trash.circle"

        // Tasks & Management
        case "create_and_run_task":
            return "play.circle"
        case "manage_todo_list":
            return "checklist"
        case "think":
            return "brain.head.profile"

        // User Interaction
        case "user_collaboration":
            return "person.2.badge.gearshape"

        // Terminal & Execution
        case "run_in_terminal":
            return "terminal"
        case "get_terminal_output":
            return "terminal.fill"
        case "terminal_last_command":
            return "clock.arrow.2.circlepath"
        case "terminal_selection":
            return "selection.pin.in.out"

        // Testing
        case "run_tests":
            return "checkmark.seal"
        case "test_failure":
            return "xmark.seal"

        // Git Operations
        case "run_subagent":
            return "person.crop.circle.badge.plus"

        // Default fallback
        default:
            return "wrench.and.screwdriver"
        }
    }

    /// Register a universal tool in the MCP framework.
    public func registerTool(_ tool: UniversalTool) {
        registeredTools[tool.name] = tool

        /// Convert to OpenAI tool definition for LLM consumption.
        let openAITool = OpenAITool(
            type: "function",
            function: OpenAIFunction(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters
            )
        )

        /// Update tool definitions array.
        toolDefinitions.removeAll { $0.function.name == tool.name }
        toolDefinitions.append(openAITool)

        logger.debug("Registered universal tool: '\(tool.name)' - \(tool.description)")
    }

    // MARK: - Tool Metadata Lookup

    /// Get display metadata for a tool by name.
    public func getToolMetadata(for toolName: String) -> (displayName: String, icon: String)? {
        guard let tool = registeredTools[toolName] else {
            return nil
        }
        return (tool.displayName, tool.icon)
    }

    /// Get display name for a tool (with fallback).
    public func getDisplayName(for toolName: String) -> String {
        return registeredTools[toolName]?.displayName ?? UniversalTool.generateDisplayName(from: toolName)
    }

    /// Get icon for a tool (with fallback).
    public func getIcon(for toolName: String) -> String {
        return registeredTools[toolName]?.icon ?? "wrench.and.screwdriver"
    }

    /// Register all available MCP tools as universal tools.
    private func registerMCPTools() async {
        let mcpTools = conversationManager.getAvailableMCPTools()
        logger.debug("DEBUG_TOOLS: Registering \(mcpTools.count) MCP tools as universal tools")

        if mcpTools.isEmpty {
            logger.warning("DEBUG_TOOLS: No MCP tools available from ConversationManager")
        }

        for mcpTool in mcpTools {
            let universalTool = UniversalTool(
                name: mcpTool.name,
                description: mcpTool.description,
                parameters: mcpTool.parameters,
                executor: MCPToolExecutor(
                    toolName: mcpTool.name,
                    conversationManager: conversationManager
                ),
                icon: getIconForTool(mcpTool.name)
            )

            registerTool(universalTool)
        }
    }

    // MARK: - Tool Discovery (System Prompt Integration)

    /// Get all tool definitions for injection into system prompts LLM discovers tools through system context.
    /// IMPORTANT: Rebuilds definitions dynamically to pick up updated tool descriptions (e.g., new models).
    public func getToolDefinitionsForSystemPrompt() -> [OpenAITool] {
        /// Rebuild tool definitions from current registered tools to ensure dynamic content (like ImageGenerationTool's model list) is fresh
        return registeredTools.values.map { tool in
            OpenAITool(
                type: "function",
                function: OpenAIFunction(
                    name: tool.name,
                    description: tool.description,  // Re-read description (may be computed property)
                    parameters: tool.parameters
                )
            )
        }
    }

    /// Get tool definitions formatted for system prompt text.
    public nonisolated func getToolsDescription() -> String {
        /// Since this is nonisolated, we'll use a simpler approach Main implementation will be in the MainActor version below.
        return ""
    }

    /// Main actor version for actual tool description generation.
    @MainActor
    public func getToolsDescriptionMainActor() -> String {
        /// HYBRID APPROACH: Return known tool description without MainActor MCP calls Tool execution will still route to MCP properly.
        logger.debug("DEBUG_TOOLS: Returning hybrid tool description (avoids MainActor deadlock)")

        return """

        # Available Tools

        ## ERROR: CRITICAL: When to Use Tools vs Natural Responses

        **ONLY use tools when the user's request REQUIRES tool functionality:**

        SUCCESS: **USE TOOLS when user requests:**
        - Search/research tasks: "search my memory", "find information about X"
        - Task management: "add todo", "show my todo list"
        - Deep analysis: "think about the best approach for X"
        - Document operations: "import document", "analyze file"
        - Web operations: "search the web for X", "scrape this URL"

        ERROR: **DO NOT use tools for:**
        - Simple greetings: "Hi", "Hello", "How are you?"
        - Basic conversation: "Tell me about yourself", "What can you do?"
        - Questions you can answer directly: "What is Python?", "Explain REST APIs"
        - Casual chat: "Thanks", "That's helpful", "Good morning"
        - Requests for general knowledge or explanations

        **Key Principle: Respond naturally UNLESS the user's request specifically needs a tool.**

        Examples:
        - User: "Hi" → Response: "Hello! How can I help you today?" (NO TOOLS)
        - User: "What is Python?" → Response: "Python is a programming language..." (NO TOOLS)
        - User: "Search my memory for Python notes" → Response: "Let me search..." + memory_operations tool
        - User: "Add task: study Python" → Response: "I'll add that to your list..." + memory_operations tool

        ## Tool Catalog

        You have access to the following tools:

        ```json
        [
          {
            "type": "function",
            "function": {
              "name": "think",
              "description": "Use this tool to think deeply about the user's request and organize your thoughts. This tool helps improve response quality by allowing you to consider the request carefully, brainstorm solutions, and plan complex tasks.",
              "parameters": {
                "type": "object",
                "properties": {
                  "thoughts": {
                    "type": "string",
                    "description": "Your thoughts about the current task or problem. This should be a clear, structured explanation of your reasoning, analysis, or planning process."
                  }
                },
                "required": ["thoughts"]
              }
            }
          },
          {
            "type": "function",
            "function": {
              "name": "manage_todo_list",
              "description": "Manage a structured todo list to track progress and plan tasks throughout your coding session",
              "parameters": {
                "type": "object",
                "properties": {
                  "operation": {
                    "type": "string",
                    "enum": ["write", "read"],
                    "description": "write: Replace entire todo list with new content. read: Retrieve current todo list"
                  },
                  "todoList": {
                    "type": "array",
                    "description": "Complete array of all todo items (required for write operation, ignored for read)",
                    "items": {
                      "type": "object",
                      "properties": {
                        "id": {"type": "number", "description": "Unique identifier for the todo"},
                        "title": {"type": "string", "description": "Concise action-oriented todo label"},
                        "description": {"type": "string", "description": "Detailed context and requirements"},
                        "status": {"type": "string", "enum": ["not-started", "in-progress", "completed"], "description": "Current status"}
                      },
                      "required": ["id", "title", "description", "status"]
                    }
                  }
                },
                "required": ["operation"]
              }
            }
          }
        ]
        ```

        To call a tool, use this exact format in your response:
        ```json
        {
          "tool_calls": [
            {
              "function": {
                "name": "manage_todo_list",
                "arguments": "{\"operation\": \"read\"}"
              }
            }
          ]
        }
        ```
        """
    }

    // MARK: - Tool Execution (Clean Invocation)

    /// Execute a registered tool call.
    public func executeTool(name: String, arguments: String) async throws -> ToolExecutionResult {
        guard let tool = registeredTools[name] else {
            logger.error("Tool not found: \(name)")
            throw ToolRegistryError.toolNotFound(name)
        }

        /// Parse arguments.
        let parameters: [String: Any]
        if let argumentsData = arguments.data(using: .utf8),
           let parsedArgs = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] {
            parameters = parsedArgs
        } else {
            parameters = [:]
        }

        logger.debug("Executing tool '\(name)' with parameters: \(parameters)")

        /// Execute tool.
        let startTime = Date()
        let result = try await tool.executor.execute(parameters: parameters)
        let executionTime = Date().timeIntervalSince(startTime)

        logger.debug("Tool '\(name)' executed in \(String(format: "%.3f", executionTime))s: \(result.success ? "SUCCESS" : "FAILURE")")

        return result
    }

    /// Get all registered tool names.
    public func getToolNames() -> [String] {
        return Array(registeredTools.keys).sorted()
    }

    /// Check if a tool is registered.
    public func hasTool(name: String) -> Bool {
        return registeredTools[name] != nil
    }
}

// MARK: - Lifecycle

/// Universal tool definition that works across all models.
public struct UniversalTool {
    public let name: String
    public let description: String
    public let parameters: [String: Any]
    public let executor: ToolExecutor

    /// UI Display metadata.
    public let displayName: String
    public let icon: String

    public init(
        name: String,
        description: String,
        parameters: [String: Any],
        executor: ToolExecutor,
        displayName: String? = nil,
        icon: String? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.executor = executor

        /// Auto-generate displayName from tool name if not provided.
        self.displayName = displayName ?? UniversalTool.generateDisplayName(from: name)
        self.icon = icon ?? "wrench.and.screwdriver"
    }

    /// Generate a friendly display name from a tool name.
    public static func generateDisplayName(from toolName: String) -> String {
        /// Remove common suffixes and convert to title case.
        let cleaned = toolName
            .replacingOccurrences(of: "_tool", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_operations", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_operation", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_mcp", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")

        /// Capitalize each word.
        let words = cleaned.split(separator: " ").map { $0.capitalized }
        return words.isEmpty ? "Tool" : words.joined(separator: " ")
    }
}

// MARK: - Protocol Conformance

/// Protocol for tool execution implementations.
public protocol ToolExecutor {
    @MainActor
    func execute(parameters: [String: Any]) async throws -> ToolExecutionResult
}

// MARK: - MCP Tool Executor

/// Executor that bridges to MCP tools.
public class MCPToolExecutor: ToolExecutor {
    private let toolName: String
    private let conversationManager: ConversationManager
        private let isExternalExecution: Bool
    private let logger = Logger(label: "com.syntheticautonomicmind.sam.MCPToolExecutor")
    public init(toolName: String, conversationManager: ConversationManager, isExternalExecution: Bool = false) {
        self.toolName = toolName
        self.conversationManager = conversationManager
        self.isExternalExecution = isExternalExecution
    }

    @MainActor
    public func execute(parameters: [String: Any]) async throws -> ToolExecutionResult {
        /// Execute via ConversationManager MCP integration.
        if let result = await conversationManager.executeMCPTool(name: toolName, parameters: parameters, isExternalAPICall: isExternalExecution, isUserInitiated: false) {
            return ToolExecutionResult(
                success: result.success,
                content: result.output.content,
                metadata: [
                    "tool_name": toolName,
                    "execution_time": Date().timeIntervalSince1970
                ]
            )
        } else {
            throw ToolRegistryError.executionFailed(toolName, "MCP tool execution returned nil")
        }
    }
}

// MARK: - Tool Execution Result

/// Result of tool execution.
public struct ToolExecutionResult: @unchecked Sendable {
    public let success: Bool
    public let content: String
    public let metadata: [String: Any]

    public init(success: Bool, content: String, metadata: [String: Any] = [:]) {
        self.success = success
        self.content = content
        self.metadata = metadata
    }
}

// MARK: - Tool Registry Errors

public enum ToolRegistryError: Error, LocalizedError {
    case toolNotFound(String)
    case executionFailed(String, String)
    case invalidParameters(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool not found: \(name)"

        case .executionFailed(let name, let reason):
            return "Tool '\(name)' execution failed: \(reason)"

        case .invalidParameters(let details):
            return "Invalid tool parameters: \(details)"
        }
    }
}
