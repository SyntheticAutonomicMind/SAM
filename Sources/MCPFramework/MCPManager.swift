// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Manager for SAM - Coordinates tool registration and execution.
public class MCPManager: ObservableObject {
    @Published public var isInitialized: Bool = false
    @Published public var availableTools: [any MCPTool] = []

    private let toolRegistry = MCPToolRegistry()
    private let logger = Logging.Logger(label: "com.sam.mcp.MCPManager")
    private var builtinTools: [any MCPTool] = []
    private var memoryManager: MemoryManagerProtocol?

    /// Tool factory closures to avoid circular dependencies.
    private var createAdvancedTools: (() async -> [any MCPTool])?

    public init() {
        logger.debug("MCPManager initializing")
    }

    public func setMemoryManager(_ memoryManager: MemoryManagerProtocol) {
        self.memoryManager = memoryManager
        logger.debug("MemoryManager injected into MCPManager")
    }

    public func setWorkflowSpawner(_ spawner: WorkflowSpawner) {
        /// Inject WorkflowSpawner into RunSubagentTool.
        if let runSubagentTool = builtinTools.first(where: { $0.name == "run_subagent" }) as? RunSubagentTool {
            runSubagentTool.setWorkflowSpawner(spawner)
            logger.debug("WorkflowSpawner injected into RunSubagentTool")
        } else {
            logger.warning("RunSubagentTool not found in builtin tools - will inject after initialization")
        }
    }

    public func setAdvancedToolsFactory(_ factory: @escaping () async -> [any MCPTool]) {
        self.createAdvancedTools = factory
        logger.debug("Advanced tools factory injected into MCPManager")
    }

    @MainActor
    public func initialize() async throws {
        logger.debug("Starting MCP Manager initialization")

        /// Initialize builtin tools.
        await initializeBuiltinTools()

        /// Register all tools.
        await registerAllTools()

        isInitialized = true
        logger.debug("MCP Manager initialized successfully with \(self.availableTools.count) tools")

        /// Log available tools.
        for tool in availableTools {
            logger.debug("Available MCP tool: \(tool.name)")
        }
    }

    @MainActor
    public func executeTool(name: String, parameters: [String: Any], context: MCPExecutionContext) async throws -> MCPToolResult {
        logger.debug("Executing MCP tool: \(name)")

        /// Handle dotted tool names (e.g., "file_operations.list_dir" → tool: "file_operations", operation: "list_dir")
        /// This handles cases where LLMs generate tool calls in "tool.operation" format instead of using operation parameter.
        var resolvedName = name
        var resolvedParameters = parameters

        if name.contains("."), toolRegistry.getTool(name: name) == nil {
            let components = name.split(separator: ".", maxSplits: 1)
            if components.count == 2 {
                let baseTool = String(components[0])
                let operation = String(components[1])

                if toolRegistry.getTool(name: baseTool) != nil {
                    logger.info("Resolved dotted tool name: '\(name)' → tool='\(baseTool)', operation='\(operation)'")
                    resolvedName = baseTool
                    /// Only add operation if not already specified
                    if resolvedParameters["operation"] == nil {
                        resolvedParameters["operation"] = operation
                    }
                }
            }
        }

        guard let tool = toolRegistry.getTool(name: resolvedName) else {
            logger.error("Tool not found: \(name)")
            throw MCPError.toolNotFound(name)
        }

        /// Validate parameters.
        do {
            _ = try tool.validateParameters(resolvedParameters)
        } catch {
            logger.error("Parameter validation failed for tool \(resolvedName): \(error)")
            throw MCPError.invalidParameters(error.localizedDescription)
        }

        /// Execute tool.
        let startTime = Date()
        let result = await tool.execute(parameters: resolvedParameters, context: context)
        let executionTime = Date().timeIntervalSince(startTime)

        if result.success {
            logger.debug("Tool \(resolvedName) executed successfully in \(String(format: "%.3f", executionTime))s")
        } else {
            logger.error("Tool \(resolvedName) execution failed after \(String(format: "%.3f", executionTime))s: \(result.output.content)")
        }

        return result
    }

    public func getAvailableTools() -> [any MCPTool] {
        /// Return tools in consistent order for KV cache efficiency.
        return toolRegistry.getToolsInOrder()
    }

    public func getToolByName(_ name: String) -> (any MCPTool)? {
        return toolRegistry.getTool(name: name)
    }

    /// Register a new tool dynamically (e.g., image_generation after SD model download) CRITICAL: After calling this, must call updateAvailableTools() to reflect in availableTools array.
    public func registerTool(_ tool: any MCPTool, name: String) {
        toolRegistry.registerTool(tool, name: name)
        availableTools.append(tool)
        logger.info("Dynamically registered tool: \(name)")
    }

    // MARK: - Helper Methods

    @MainActor
    private func initializeBuiltinTools() async {
        logger.debug("Initializing builtin MCP tools")

        /// Create consolidated MemoryOperationsTool and inject memory manager if available.
        let memoryOperationsTool = MemoryOperationsTool()
        if let memoryManager = self.memoryManager {
            memoryOperationsTool.setMemoryManager(memoryManager)
        }

        var candidateTools: [any MCPTool] = [
            ThinkTool(),
            RunSubagentTool(),
            IncreaseMaxIterationsTool(),

            /// Consolidated memory operations (replaces memory_search + manage_todo_list).
            memoryOperationsTool,

            /// Dedicated todo operations (standard tool pattern, separate from memory)
            TodoOperationsTool(),

            /// Tool result retrieval (for large persisted tool outputs).
            ReadToolResultTool(),

            /// Prompt discovery tools for agent awareness.
            ListSystemPromptsTool(),
            ListMiniPromptsTool(),

            /// History recall for archived context (long-term memory).
            RecallHistoryTool()
            /// terminal_session merged into terminal_operations (created via advanced tools factory).
        ]

        /// Add advanced tools via factory if available.
        if let createAdvancedTools = self.createAdvancedTools {
            logger.debug("Creating advanced tools via factory")
            let advancedTools = await createAdvancedTools()
            candidateTools.append(contentsOf: advancedTools)
            logger.debug("Added \(advancedTools.count) advanced tools: \(advancedTools.map { $0.name }.joined(separator: ", "))")
        } else {
            logger.warning("CRITICAL: Advanced tools (web research, document import, automation) not yet registered")
            logger.warning("Need to inject services: WebResearchService, AutomationService, DocumentImportSystem")
        }

        for tool in candidateTools {
            logger.debug("Initializing tool: \(tool.name)")
            do {
                try await tool.initialize()
                builtinTools.append(tool)
                logger.debug("Successfully initialized tool: \(tool.name)")
            } catch {
                logger.error("Failed to initialize tool \(tool.name): \(error)")
                /// Continue with other tools.
            }
        }

        logger.debug("Initialized \(self.builtinTools.count) builtin tools")
        logger.debug("CONSOLIDATION COMPLETE: memory_operations active (replaced memory_search + manage_todo_list)")
        logger.warning("CRITICAL: Advanced tools (web research, document import, automation) not yet registered")
        logger.warning("Need to inject services: WebResearchService, AutomationService, DocumentImportSystem")
    }

    @MainActor
    private func registerAllTools() async {
        logger.debug("Registering all MCP tools")

        /// Clear available tools to avoid duplicates.
        availableTools.removeAll()

        /// Register builtin tools.
        for tool in builtinTools {
            toolRegistry.registerTool(tool, name: tool.name)
            availableTools.append(tool)
            logger.debug("Registered builtin tool: \(tool.name)")
        }

        logger.debug("Registered \(self.availableTools.count) total MCP tools")
    }
}

/// Simple tool registry for managing MCP tools with consistent ordering CRITICAL: Tools MUST always be returned in same order for KV cache efficiency.
public class MCPToolRegistry {
    private var registeredTools: [String: any MCPTool] = [:]
    private let logger = Logging.Logger(label: "com.sam.mcp.MCPToolRegistry")

    /// Explicit tool ordering for KV cache consistency Tools are returned in this exact order every time to ensure system prompts are identical This dramatically improves KV cache hit rates for MLX models.
    private let toolOrder: [String] = [
        /// Core reasoning and collaboration (always first).
        "think",
        "user_collaboration",

        /// Workflow delegation and control.
        "run_subagent",
        "increase_max_iterations",

        /// Prompt discovery for agent awareness.
        "list_system_prompts",
        "list_mini_prompts",

        /// Memory and task management.
        "memory_operations",
        "todo_operations",
        "read_tool_result",

        /// Long-term memory recall for archived context.
        "recall_history",

        /// Web operations.
        "web_operations",

        /// Document operations.
        "document_operations",

        /// File operations.
        "file_operations",

        /// Terminal operations.
        "terminal_operations",

        /// Build and version control.
        "build_and_version_control",

        /// Image generation (conditional - only if SD models installed).
        "image_generation"
    ]

    public func registerTool(_ tool: any MCPTool, name: String) {
        registeredTools[name] = tool
        logger.debug("Registered tool in registry: \(name)")
    }

    public func getTool(name: String) -> (any MCPTool)? {
        return registeredTools[name]
    }

    public func getToolNames() -> [String] {
        return Array(registeredTools.keys)
    }

    /// Get all registered tools in consistent order CRITICAL: Returns tools in explicit order defined in toolOrder array This ensures system prompts are identical across requests for KV cache efficiency.
    public func getToolsInOrder() -> [any MCPTool] {
        return toolOrder.compactMap { toolName in
            registeredTools[toolName]
        }
    }
}
