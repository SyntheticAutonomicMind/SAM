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
    
    private var imageGenerationService: ImageGenerationService?
    
    /// Error guidance for providing helpful messages when tool calls fail
    private let errorGuidance = ToolErrorGuidance()

    /// Tool factory closures to avoid circular dependencies.
    private var createAdvancedTools: (() async -> [any MCPTool])?

    public init() {
        logger.debug("MCPManager initializing")
    }

    public func setMemoryManager(_ memoryManager: MemoryManagerProtocol) {
        self.memoryManager = memoryManager
        logger.debug("MemoryManager injected into MCPManager")
    }

    /// Set image generation service for the image_generation tool.
    /// Must be called before initialize() so the service is available during tool setup.
    public func setImageGenerationService(_ service: ImageGenerationService) {
        self.imageGenerationService = service
        logger.debug("ImageGenerationService set on MCPManager")
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


        /// Handle operation aliases (e.g., "file_search" -> "file_operations" with operation="file_search")
        /// This fixes MiniMax and similar models calling operations directly instead of using file_operations with operation parameter
        /// Based on CLIO fix for MiniMax tool calling issues.
        if toolRegistry.isOperationAlias(resolvedName) {
            if let aliasInfo = toolRegistry.getAliasInfo(for: resolvedName) {
                logger.info("OPERATION_ALIAS: '\(resolvedName)' -> '\(aliasInfo.tool)' with operation='\(aliasInfo.operation)'")
                resolvedName = aliasInfo.tool
                /// Only add operation if not already specified
                if resolvedParameters["operation"] == nil {
                    resolvedParameters["operation"] = aliasInfo.operation
                }
            }
        }

        guard let tool = toolRegistry.getTool(name: resolvedName) else {
            logger.error("Tool not found: \(name)")
            throw MCPError.toolNotFound(name)
        }

        /// Check if the tool is disabled by the user
        if let disabled = UserDefaults.standard.stringArray(forKey: "tools.disabledBuiltinTools"),
           disabled.contains(resolvedName) {
            logger.warning("Tool '\(resolvedName)' is disabled by user")
            return MCPToolResult(
                success: false,
                output: MCPOutput(
                    content: "Tool '\(resolvedName)' is disabled. The user has turned off this tool in Preferences > Tools.",
                    mimeType: "text/plain",
                    additionalData: [:]
                ),
                toolName: resolvedName
            )
        }

        /// Validate parameters.
        do {
            _ = try tool.validateParameters(resolvedParameters)
        } catch {
            logger.error("Parameter validation failed for tool \(resolvedName): \(error)")
            
            // Provide enhanced error guidance (no schema available from protocol)
            let enhancedError = errorGuidance.enhanceToolError(
                error: error.localizedDescription,
                toolName: resolvedName,
                toolSchema: nil,
                attemptedParams: resolvedParameters
            )
            throw MCPError.invalidParameters(enhancedError)
        }

        /// Execute tool.
        let startTime = Date()
        let result = await tool.execute(parameters: resolvedParameters, context: context)
        let executionTime = Date().timeIntervalSince(startTime)

        if result.success {
            logger.debug("Tool \(resolvedName) executed successfully in \(String(format: "%.3f", executionTime))s")
        } else {
            // Enhance failed tool results with guidance
            let enhancedOutput = errorGuidance.enhanceToolError(
                error: result.output.content,
                toolName: resolvedName,
                toolSchema: nil,
                attemptedParams: resolvedParameters
            )
            
            // Return enhanced result with guidance
            return MCPToolResult(
                success: false,
                output: MCPOutput(
                    content: enhancedOutput,
                    mimeType: result.output.mimeType
                ),
                toolName: resolvedName
            )
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

    /// Register a new tool dynamically (e.g., new tools via MCP servers) CRITICAL: After calling this, must call updateAvailableTools() to reflect in availableTools array.
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
            /// Consolidated memory operations (search, store, recall_history)
            memoryOperationsTool,

            /// Dedicated todo operations (standard tool pattern, separate from memory)
            TodoOperationsTool(),

            /// Math operations (calculate, convert, formula)
            MathOperationsTool()
        ]

        /// Add image generation tool if service is available.
        let imageGenTool = ImageGenerationTool()
        if let imageService = self.imageGenerationService {
            imageGenTool.setService(imageService)
            logger.debug("ImageGenerationService injected into ImageGenerationTool")
        }
        candidateTools.append(imageGenTool)

        /// Add macOS integration tools.
        candidateTools.append(CalendarTool())
        candidateTools.append(ContactsTool())
        candidateTools.append(NotesTool())
        candidateTools.append(SpotlightTool())
        candidateTools.append(WeatherTool())

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
        /// Core collaboration (always first)
        "user_collaboration",

        /// Memory and task management
        "memory_operations",
        "todo_operations",

        /// Web operations
        "web_operations",

        /// Document operations
        "document_operations",

        /// File operations
        "file_operations",

        /// Math operations
        "math_operations",

        /// macOS integration
        "calendar_operations",
        "contacts_operations",
        "notes_operations",
        "spotlight_search",
        "weather_operations",

        /// Image generation (ALICE remote)
        "image_generation"
    ]

    /// Operation aliases - maps operation names to their parent tool with default operation
    /// This handles cases where AI calls "file_search" instead of "file_operations" with operation="file_search"
    /// Critical for MiniMax models that tend to call operations directly
    private let operationAliases: [String: (tool: String, operation: String)] = [
        /// file_operations operations
        "file_search": ("file_operations", "file_search"),
        "list_dir": ("file_operations", "list_dir"),
        "read_file": ("file_operations", "read_file"),
        "write_file": ("file_operations", "write_file"),
        "create_file": ("file_operations", "create_file"),
        "delete_file": ("file_operations", "delete_file"),
        "grep_search": ("file_operations", "grep_search"),
        "semantic_search": ("file_operations", "semantic_search"),
        "file_exists": ("file_operations", "file_exists"),
        "get_file_info": ("file_operations", "get_file_info"),
        "rename_file": ("file_operations", "rename_file"),
        "append_file": ("file_operations", "append_file"),
        "replace_string": ("file_operations", "replace_string"),
        "insert_at_line": ("file_operations", "insert_at_line"),
        "create_directory": ("file_operations", "create_directory"),
        "get_errors": ("file_operations", "get_errors"),
        "read_tool_result": ("file_operations", "read_tool_result"),
        "list_dir_recursive": ("file_operations", "list_dir_recursive"),

        /// version_control operations (git)
        "git": ("version_control", "status"),
        "status": ("version_control", "status"),
        "log": ("version_control", "log"),
        "diff": ("version_control", "diff"),
        "commit": ("version_control", "commit"),
        "push": ("version_control", "push"),
        "pull": ("version_control", "pull"),
        "branch": ("version_control", "branch"),
        "stash": ("version_control", "stash"),
        "tag": ("version_control", "tag"),

        /// terminal_operations operations
        "shell": ("terminal_operations", "exec"),
        "exec": ("terminal_operations", "exec"),
        "terminal_exec": ("terminal_operations", "exec"),
        "run_command": ("terminal_operations", "exec"),

        /// memory_operations operations
        "store_memory": ("memory_operations", "store"),
        "retrieve_memory": ("memory_operations", "retrieve"),
        "search_memory": ("memory_operations", "search"),
        "list_memory": ("memory_operations", "list"),
        "delete_memory": ("memory_operations", "delete"),
        "recall_sessions": ("memory_operations", "recall_sessions"),
        "add_discovery": ("memory_operations", "add_discovery"),
        "add_solution": ("memory_operations", "add_solution"),
        "add_pattern": ("memory_operations", "add_pattern"),

        /// web_operations operations
        "search_web": ("web_operations", "search_web"),
        "fetch_url": ("web_operations", "fetch_url"),
        "web_search": ("web_operations", "search_web"),

        /// todo_operations operations
        "todo_read": ("todo_operations", "read"),
        "todo_write": ("todo_operations", "write"),
        "todo_update": ("todo_operations", "update"),
        "todo_add": ("todo_operations", "add"),

        /// code_intelligence operations
        "list_usages": ("code_intelligence", "list_usages"),
        "search_history": ("code_intelligence", "search_history"),

        /// user_collaboration operations
        "request_input": ("user_collaboration", "request_input"),

        /// agent_operations operations
        "spawn_agent": ("agent_operations", "spawn"),
        "list_agents": ("agent_operations", "list"),
        "agent_inbox": ("agent_operations", "inbox"),
        "agent_status": ("agent_operations", "status"),
        "kill_agent": ("agent_operations", "kill"),
        "send_to_agent": ("agent_operations", "send"),
        "broadcast_agents": ("agent_operations", "broadcast"),

        /// remote_execution operations
        "execute_remote": ("remote_execution", "execute_remote"),
        "execute_parallel": ("remote_execution", "execute_parallel"),
        "prepare_remote": ("remote_execution", "prepare_remote"),
        "cleanup_remote": ("remote_execution", "cleanup_remote"),
        "check_remote": ("remote_execution", "check_remote"),

        /// document_operations operations
        "document_create": ("document_operations", "document_create"),
        "document_import": ("document_operations", "document_import"),
        "document_list": ("document_operations", "document_list"),
        "document_delete": ("document_operations", "document_delete"),

        /// image_generation operations
        "generate_image": ("image_generation", "generate_image"),

        /// math_operations - default to calculate when called directly without operation
        "math_operations": ("math_operations", "calculate"),

        /// apply_patch - single operation tool
        "apply_patch": ("apply_patch", "patch"),

        /// calendar_operations operations
        "list_events": ("calendar_operations", "list_events"),
        "create_event": ("calendar_operations", "create_event"),
        "search_events": ("calendar_operations", "search_events"),
        "delete_event": ("calendar_operations", "delete_event"),
        "list_reminders": ("calendar_operations", "list_reminders"),
        "create_reminder": ("calendar_operations", "create_reminder"),
        "complete_reminder": ("calendar_operations", "complete_reminder"),
        "delete_reminder": ("calendar_operations", "delete_reminder"),
        "list_reminder_lists": ("calendar_operations", "list_reminder_lists"),

        /// contacts_operations operations
        "search_contacts": ("contacts_operations", "search_contacts"),
        "get_contact": ("contacts_operations", "get_contact"),
        "create_contact": ("contacts_operations", "create_contact"),
        "update_contact": ("contacts_operations", "update_contact"),
        "list_groups": ("contacts_operations", "list_groups"),
        "search_group": ("contacts_operations", "search_group"),

        /// notes_operations operations
        "search_notes": ("notes_operations", "search_notes"),
        "get_note": ("notes_operations", "get_note"),
        "create_note": ("notes_operations", "create_note"),
        "list_folders": ("notes_operations", "list_folders"),
        "list_notes": ("notes_operations", "list_notes"),
        "append_note": ("notes_operations", "append_note"),

        /// spotlight_search operations
        "search_files": ("spotlight_search", "search_files"),
        "search_content": ("spotlight_search", "search_content"),
        "search_metadata": ("spotlight_search", "search_metadata"),
        "file_info": ("spotlight_search", "file_info"),
        "recent_files": ("spotlight_search", "recent_files"),

        /// weather_operations operations
        "current_weather": ("weather_operations", "current"),
        "weather_forecast": ("weather_operations", "forecast"),
        "hourly_weather": ("weather_operations", "hourly"),
    ]

    public func registerTool(_ tool: any MCPTool, name: String) {
        registeredTools[name] = tool
        logger.debug("Registered tool in registry: \(name)")
    }

    /// Get alias info for a tool name if it's an operation alias
    /// Returns (tool: String, operation: String) if the name is an alias, nil otherwise
    public func getAliasInfo(for name: String) -> (tool: String, operation: String)? {
        return operationAliases[name]
    }

    /// Check if a name is an alias for an operation
    public func isOperationAlias(_ name: String) -> Bool {
        return operationAliases[name] != nil
    }

    public func getTool(name: String) -> (any MCPTool)? {
        /// First, try exact match
        if let tool = registeredTools[name] {
            return tool
        }

        /// Check if name is an alias for an operation
        if let aliasInfo = operationAliases[name] {
            logger.debug("OPERATION_ALIAS: Resolving '\(name)' to '\(aliasInfo.tool)' with operation='\(aliasInfo.operation)'")
            return registeredTools[aliasInfo.tool]
        }

        return nil
    }

    public func getToolNames() -> [String] {
        return Array(registeredTools.keys)
    }

    /// Get all registered tools in consistent order, excluding user-disabled tools.
    /// Returns tools in explicit order defined in toolOrder array.
    /// Checks UserDefaults for disabled tools list and filters them out.
    public func getToolsInOrder() -> [any MCPTool] {
        let disabledTools: Set<String>
        if let stored = UserDefaults.standard.stringArray(forKey: "tools.disabledBuiltinTools") {
            disabledTools = Set(stored)
        } else {
            disabledTools = []
        }
        return toolOrder.compactMap { toolName in
            if disabledTools.contains(toolName) {
                return nil
            }
            return registeredTools[toolName]
        }
    }
}
