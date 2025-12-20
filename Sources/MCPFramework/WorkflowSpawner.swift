// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// WorkflowSpawner.swift SAM Protocol for spawning isolated subagent workflows Allows RunSubagentTool to delegate work without direct dependency on AgentOrchestrator.

import Foundation

/// Protocol for spawning isolated subagent workflows This abstraction allows MCP tools (like run_subagent) to spawn nested workflows without directly depending on higher-level modules like APIFramework.
public protocol WorkflowSpawner {
    /// Spawn an isolated subagent workflow Creates a new conversation and runs a complete workflow with fresh context.
    @MainActor
    func spawnSubagentWorkflow(
        parentConversationId: UUID,
        task: String,
        instructions: String,
        model: String?,
        maxIterations: Int,
        temperature: Double?,
        topP: Double?,
        enableTerminalAccess: Bool?,
        enableReasoning: Bool?,
        systemPromptId: String?,
        enableWorkflowMode: Bool?,
        enableDynamicIterations: Bool?,
        sharedTopicId: String?,
        excludeTools: [String]
    ) async throws -> String
}

/// Result from a subagent workflow.
public struct SubagentResult {
    /// Brief task description.
    public let task: String

    /// Subagent conversation ID (for debugging/linking).
    public let conversationId: UUID

    /// Concise summary of subagent work.
    public let summary: String

    /// Number of iterations used.
    public let iterationsUsed: Int

    /// Whether subagent completed successfully.
    public let success: Bool

    /// Error message if failed.
    public let error: String?

    public init(
        task: String,
        conversationId: UUID,
        summary: String,
        iterationsUsed: Int,
        success: Bool,
        error: String? = nil
    ) {
        self.task = task
        self.conversationId = conversationId
        self.summary = summary
        self.iterationsUsed = iterationsUsed
        self.success = success
        self.error = error
    }
}
