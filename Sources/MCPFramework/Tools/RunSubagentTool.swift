// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// RunSubagentTool.swift SAM Implements subagent delegation for large-scale workflows MCP tool for spawning isolated nested agent sessions.

import Foundation
import Logging

/// Run Subagent MCP Tool Spawns an isolated nested agent workflow for delegation and chunking large tasks.
public class RunSubagentTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "run_subagent"
    public let description = """
    Spawn an isolated subagent workflow for research, delegation, or chunking large tasks.

    USE THIS WHEN:
    - Processing large documents (chunk into groups)
    - Research before implementation ("First research X")
    - Parallel work streams (multiple focused subagents)
    - Complex workflows need decomposition

    SUBAGENT CHARACTERISTICS:
    - Runs in isolated conversation (no context pollution)
    - Fresh iteration budget (doesn't burn main agent's iterations)
    - Returns summary only (not full transcript)
    - Cannot spawn more subagents (recursion prevented)

    EXAMPLE: 32-Chapter Book Review
    - Main agent: Plan chunking strategy
    - Subagent 1: Review chapters 1-5 (returns summary)
    - Subagent 2: Review chapters 6-10 (returns summary)
    - ... (repeat for all groups)
    - Main agent: Synthesize all summaries

    PARAMETERS:
    - task: Brief task description (e.g., "Review chapters 1-5")
    - instructions: Detailed instructions for subagent
    - maxIterations: Iteration limit (default: 15)
    """

    public var supportedOperations: [String] {
        return ["run"]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: "Operation to perform (always 'run' for subagents, can be omitted)",
                required: false
            ),
            "task": MCPToolParameter(
                type: .string,
                description: "Brief task description (shown in UI progress)",
                required: true
            ),
            "instructions": MCPToolParameter(
                type: .string,
                description: "Detailed instructions for the subagent to follow",
                required: false
            ),
            "model": MCPToolParameter(
                type: .string,
                description: "Model to use for subagent (default: parent's model)",
                required: false
            ),
            "maxIterations": MCPToolParameter(
                type: .integer,
                description: "Maximum iterations for subagent (default: 15)",
                required: false
            ),
            "temperature": MCPToolParameter(
                type: .string,
                description: "Sampling temperature (0.0-2.0). Lower=focused, Higher=creative (default: parent's temperature)",
                required: false
            ),
            "topP": MCPToolParameter(
                type: .string,
                description: "Top-p sampling (0.0-1.0). Alternative to temperature (default: parent's topP)",
                required: false
            ),
            "enableTerminalAccess": MCPToolParameter(
                type: .boolean,
                description: "Allow subagent to execute terminal commands (default: false for security)",
                required: false
            ),
            "enableReasoning": MCPToolParameter(
                type: .boolean,
                description: "Enable chain-of-thought reasoning mode (default: parent's setting)",
                required: false
            ),
            "systemPromptId": MCPToolParameter(
                type: .string,
                description: "System prompt UUID for specialized personality (default: parent's prompt)",
                required: false
            ),
            "enableWorkflowMode": MCPToolParameter(
                type: .boolean,
                description: "Allow subagent to spawn nested workflows (default: false to prevent deep recursion)",
                required: false
            ),
            "enableDynamicIterations": MCPToolParameter(
                type: .boolean,
                description: "Allow subagent to request iteration increases (default: false)",
                required: false
            ),
            "sharedTopicId": MCPToolParameter(
                type: .string,
                description: "UUID of shared topic for subagent to use. If provided, subagent works in same shared workspace as parent. If omitted, subagent uses isolated conversation (default: isolated)",
                required: false
            )
        ]
    }

    private let logger = Logging.Logger(label: "com.sam.mcp.RunSubagentTool")

    /// Workflow spawner (protocol-based dependency injection) Injected by MCPToolService during initialization.
    private var workflowSpawner: WorkflowSpawner?

    public init() {
        logger.debug("RunSubagentTool initialized")

        /// Register with ToolDisplayInfoRegistry for proper progress indicators.
        ToolDisplayInfoRegistry.shared.register("run_subagent", provider: RunSubagentTool.self)
    }

    /// Inject workflow spawner (called by MCPToolService).
    public func setWorkflowSpawner(_ spawner: WorkflowSpawner) {
        self.workflowSpawner = spawner
        logger.debug("WorkflowSpawner injected into RunSubagentTool")
    }

    @MainActor
    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        guard operation == "run" else {
            return operationError(operation, message: "Unknown operation. Use 'run'.")
        }

        return await runSubagent(parameters: parameters, context: context)
    }

    /// Run isolated subagent workflow.
    @MainActor
    private func runSubagent(
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        let startTime = Date()

        /// Validate dependency injection.
        guard let workflowSpawner = self.workflowSpawner else {
            return errorResult("CONFIGURATION_ERROR: WorkflowSpawner not injected into RunSubagentTool")
        }

        /// Validate conversation ID.
        guard let parentConversationId = context.conversationId else {
            return errorResult("MISSING_CONTEXT: conversationId required for subagent spawning")
        }

        /// Extract required parameters.
        guard let task = parameters["task"] as? String, !task.isEmpty else {
            return errorResult("Missing required parameter 'task'")
        }

        guard let instructions = parameters["instructions"] as? String, !instructions.isEmpty else {
            return errorResult("Missing required parameter 'instructions'")
        }

        /// Extract optional configuration parameters.
        let maxIterations = parameters["maxIterations"] as? Int ?? 15
        let model = parameters["model"] as? String

        /// Parse temperature and topP from string parameters
        let temperature: Double? = {
            if let tempString = parameters["temperature"] as? String {
                return Double(tempString)
            } else if let tempDouble = parameters["temperature"] as? Double {
                return tempDouble
            }
            return nil
        }()

        let topP: Double? = {
            if let topPString = parameters["topP"] as? String {
                return Double(topPString)
            } else if let topPDouble = parameters["topP"] as? Double {
                return topPDouble
            }
            return nil
        }()

        let enableTerminalAccess = parameters["enableTerminalAccess"] as? Bool
        let enableReasoning = parameters["enableReasoning"] as? Bool
        let systemPromptId = parameters["systemPromptId"] as? String
        let enableWorkflowMode = parameters["enableWorkflowMode"] as? Bool
        let enableDynamicIterations = parameters["enableDynamicIterations"] as? Bool
        let sharedTopicId = parameters["sharedTopicId"] as? String

        logger.debug("SUBAGENT_START", metadata: [
            "task": .string(task),
            "parentConversation": .string(parentConversationId.uuidString),
            "maxIterations": .stringConvertible(maxIterations),
            "model": .string(model ?? "default"),
            "temperature": .string(temperature.map { String($0) } ?? "default"),
            "enableTerminalAccess": .stringConvertible(enableTerminalAccess ?? false),
            "enableReasoning": .stringConvertible(enableReasoning ?? false),
            "enableWorkflowMode": .stringConvertible(enableWorkflowMode ?? false),
            "sharedTopicId": .string(sharedTopicId ?? "isolated")
        ])

        /// Spawn subagent workflow via protocol with full configuration.
        do {
            let summary = try await workflowSpawner.spawnSubagentWorkflow(
                parentConversationId: parentConversationId,
                task: task,
                instructions: instructions,
                model: model,
                maxIterations: maxIterations,
                temperature: temperature,
                topP: topP,
                enableTerminalAccess: enableTerminalAccess,
                enableReasoning: enableReasoning,
                systemPromptId: systemPromptId,
                enableWorkflowMode: enableWorkflowMode,
                enableDynamicIterations: enableDynamicIterations,
                sharedTopicId: sharedTopicId,
                excludeTools: ["run_subagent"]
            )

            let duration = Date().timeIntervalSince(startTime)
            logger.debug("SUBAGENT_COMPLETE", metadata: [
                "task": .string(task),
                "duration": .stringConvertible(duration)
            ])

            /// Return concise summary.
            return successResult("""
                SUBAGENT TASK: \(task)

                \(summary)

                Duration: \(String(format: "%.2f", duration))s
                """
            )

        } catch {
            logger.error("SUBAGENT_ERROR", metadata: [
                "task": .string(task),
                "error": .string(error.localizedDescription)
            ])
            return errorResult("Subagent failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Protocol Conformance

extension RunSubagentTool: ToolDisplayInfoProvider {
    public static func extractDisplayInfo(from arguments: [String: Any]) -> String? {
        if let task = arguments["task"] as? String {
            return "Spawning subagent: \(task)"
        }
        return "Running subagent"
    }

    public static func extractToolDetails(from arguments: [String: Any]) -> [String]? {
        var details: [String] = []

        if let task = arguments["task"] as? String {
            let preview = task.count > 70 ? String(task.prefix(67)) + "..." : task
            details.append("Task: \(preview)")
        }

        if let model = arguments["model"] as? String {
            details.append("Model: \(model)")
        }

        if let tools = arguments["tools"] as? [String] {
            if tools.isEmpty {
                details.append("Tools: All available")
            } else {
                details.append("Tools: \(tools.joined(separator: ", "))")
            }
        }

        details.append("Creating specialized agent instance")

        return details.isEmpty ? nil : details
    }
}
