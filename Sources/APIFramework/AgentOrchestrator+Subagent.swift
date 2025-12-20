// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// AgentOrchestrator+Subagent.swift SAM WorkflowSpawner protocol implementation for subagent delegation Implements isolated nested agent sessions for complex workflows.

import Foundation
import Logging
import MCPFramework
import ConversationEngine
import ConfigurationSystem
import SharedData

// MARK: - Protocol Conformance

extension AgentOrchestrator: WorkflowSpawner {
    /// Spawn an isolated subagent workflow Creates a new conversation and runs a complete workflow with fresh context.
    public func spawnSubagentWorkflow(
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
    ) async throws -> String {
        logger.debug("SUBAGENT_SPAWN", metadata: [
            "parentConversation": Logger.Metadata.Value.string(parentConversationId.uuidString),
            "task": Logger.Metadata.Value.string(task),
            "maxIterations": Logger.Metadata.Value.stringConvertible(maxIterations),
            "excludedTools": Logger.Metadata.Value.string(excludeTools.joined(separator: ", ")),
            "temperature": Logger.Metadata.Value.string(temperature.map { String($0) } ?? "default"),
            "enableTerminalAccess": Logger.Metadata.Value.stringConvertible(enableTerminalAccess ?? false),
            "enableReasoning": Logger.Metadata.Value.stringConvertible(enableReasoning ?? false),
            "enableWorkflowMode": Logger.Metadata.Value.stringConvertible(enableWorkflowMode ?? false),
            "enableDynamicIterations": Logger.Metadata.Value.stringConvertible(enableDynamicIterations ?? false),
            "sharedTopicId": Logger.Metadata.Value.string(sharedTopicId ?? "isolated")
        ])

        let startTime = Date()

        /// Create isolated subagent conversation WITHOUT switching to it
        /// Don't use createNewConversation() as it auto-switches activeConversation
        /// Instead, manually create conversation with unique title and add it to the list
        let subagentConversation = await MainActor.run {
            /// Generate unique title for subagent (similar to generateUniqueConversationTitle)
            let baseName = "Subagent: \(task)"
            let existingTitles = Set(conversationManager.conversations.map { $0.title })
            var uniqueTitle = baseName
            if existingTitles.contains(baseName) {
                var number = 2
                while existingTitles.contains("\(baseName) (\(number))") {
                    number += 1
                }
                uniqueTitle = "\(baseName) (\(number))"
            }

            let conv = ConversationModel(title: uniqueTitle)

            /// Use user's preferred default system prompt (or SAM Default if not set)
            let promptManager = SystemPromptManager.shared
            let defaultPromptUUID = UUID(uuidString: promptManager.defaultSystemPromptId)
                ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            conv.settings.selectedSystemPromptId = defaultPromptUUID

            /// Add to conversations list WITHOUT changing activeConversation
            conversationManager.conversations.append(conv)
            conversationManager.saveConversations()

            return conv
        }

        let subagentConversationId = subagentConversation.id

        /// Set subagent-specific properties and metadata.
        await MainActor.run {
            subagentConversation.isSubagent = true
            subagentConversation.parentConversationId = parentConversationId
            subagentConversation.isWorking = true
            subagentConversation.isProcessing = true  // CRITICAL FIX: Show as busy in UI

            /// Apply configuration parameters from parent agent
            if let temp = temperature {
                subagentConversation.settings.temperature = temp
            }
            if let tp = topP {
                subagentConversation.settings.topP = tp
            }
            if let terminalAccess = enableTerminalAccess {
                subagentConversation.settings.enableTerminalAccess = terminalAccess
            }
            if let reasoning = enableReasoning {
                subagentConversation.settings.enableReasoning = reasoning
            }
            if let workflowMode = enableWorkflowMode {
                subagentConversation.settings.enableWorkflowMode = workflowMode
            }
            if let dynamicIterations = enableDynamicIterations {
                subagentConversation.settings.enableDynamicIterations = dynamicIterations
            }
            if let promptIdString = systemPromptId, let promptUUID = UUID(uuidString: promptIdString) {
                subagentConversation.settings.selectedSystemPromptId = promptUUID
            }

            /// Configure shared topic if provided
            if let topicIdString = sharedTopicId, let topicUUID = UUID(uuidString: topicIdString) {
                // Get topic from SharedTopicManager
                do {
                    let topicManager = SharedTopicManager()
                    let topics = try topicManager.listTopics()
                    if let topic = topics.first(where: { $0.id == topicIdString }) {
                        subagentConversation.settings.useSharedData = true
                        subagentConversation.settings.sharedTopicId = topicUUID
                        subagentConversation.settings.sharedTopicName = topic.name
                        logger.debug("Subagent using shared topic: \(topic.name)")
                    } else {
                        logger.warning("Shared topic not found: \(topicIdString) - subagent will use isolated conversation")
                    }
                } catch {
                    logger.error("Failed to fetch shared topics: \(error) - subagent will use isolated conversation")
                }
            }

            /// Update parent conversation's subagent list.
            if let parentConv = conversationManager.conversations.first(where: { $0.id == parentConversationId }) {
                parentConv.subagentIds.append(subagentConversationId)
            }

            /// Save to persist metadata immediately.
            conversationManager.saveConversations()
        }

        /// Use parent's model if not specified.
        let parentModel = await MainActor.run {
            conversationManager.conversations.first(where: { $0.id == parentConversationId })?.settings.selectedModel
        }
        let modelToUse = model ?? parentModel ?? "gpt-4"

        logger.debug("SUBAGENT_CONFIG", metadata: [
            "conversationId": Logger.Metadata.Value.string(subagentConversationId.uuidString),
            "model": Logger.Metadata.Value.string(modelToUse),
            "maxIterations": Logger.Metadata.Value.stringConvertible(maxIterations)
        ])

        /// Set subagent conversation's model to the requested model
        /// Issue #4: Subagent using parent's model instead of requested model
        await MainActor.run {
            if let subagentConv = conversationManager.conversations.first(where: { $0.id == subagentConversationId }) {
                subagentConv.settings.selectedModel = modelToUse
                conversationManager.saveConversations()
            }
        }

        /// Run isolated workflow.
        let result = try await self.runAutonomousWorkflow(
            conversationId: subagentConversationId,
            initialMessage: instructions,
            model: modelToUse,
            samConfig: SAMConfig(
                maxIterations: maxIterations,
                enableReasoning: enableReasoning,
                enableTerminalAccess: enableTerminalAccess,
                enableWorkflowMode: enableWorkflowMode,
                enableDynamicIterations: enableDynamicIterations
            ),
            onProgress: nil
        )

        let duration = Date().timeIntervalSince(startTime)

        /// Mark subagent as complete.
        await MainActor.run {
            if let subagentConv = conversationManager.conversations.first(where: { $0.id == subagentConversationId }) {
                subagentConv.isWorking = false
                subagentConv.isProcessing = false  // CRITICAL FIX: No longer busy
                conversationManager.saveConversations()
            }
        }

        logger.debug("SUBAGENT_COMPLETE", metadata: [
            "task": Logger.Metadata.Value.string(task),
            "conversationId": Logger.Metadata.Value.string(subagentConversationId.uuidString),
            "success": Logger.Metadata.Value.stringConvertible(result.isSuccess),
            "iterations": Logger.Metadata.Value.stringConvertible(result.iterations),
            "duration": Logger.Metadata.Value.stringConvertible(duration)
        ])

        /// Return concise summary (not full transcript).
        let summary = generateSubagentSummary(
            task: task,
            conversationId: subagentConversationId,
            result: result,
            duration: duration
        )

        /// Don't switch away from parent conversation
        /// We never switched to subagent conversation, so no need to switch back
        /// The parent conversation remains active throughout subagent execution

        return summary
    }

    /// Generate system prompt for subagent Subagents have restricted capabilities (no run_subagent, focused scope).
    private func generateSubagentSystemPrompt(
        task: String,
        excludedTools: [String]
    ) -> String {
        let excludedToolsList = excludedTools.isEmpty ? "none" : excludedTools.joined(separator: ", ")

        return """
        You are a focused subagent executing a specific delegated task.

        TASK: \(task)

        CAPABILITIES:
        - Full tool access EXCEPT: \(excludedToolsList)
        - File operations, terminal, memory, thinking all available
        - Limited iteration budget - work efficiently

        YOUR JOB:
        - Execute the delegated task completely
        - Provide clear, actionable results
        - Work efficiently within iteration budget
        - Think before acting (use think tool)

        RESTRICTIONS:
        - Do NOT try to spawn more subagents (recursion prevented)
        - Stay focused on your specific task
        - Do NOT try to access parent conversation context
        - Do NOT try to modify files outside your task scope

        GUIDELINES:
        - Use think tool to plan your approach
        - Execute systematically and efficiently
        - Summarize findings clearly
        - Report completion or blockers explicitly

        IMPORTANT: You are a specialized worker, not a planner. Execute your task and report results concisely.
        """
    }

    /// Generate concise summary from subagent result.
    private func generateSubagentSummary(
        task: String,
        conversationId: UUID,
        result: AgentResult,
        duration: TimeInterval
    ) -> String {
        /// Use finalResponse from AgentResult (last LLM response).
        let response = result.finalResponse

        /// Truncate if too long (keep summary concise).
        let maxLength = 2000
        let summary = response.count > maxLength
            ? String(response.prefix(maxLength)) + "\n\n[Summary truncated - \(response.count) chars total. Full details in subagent conversation \(conversationId)]"
            : response

        /// Format completion status.
        let status = result.isSuccess ? "SUCCESS: Complete" : "Failed (\(result.metadata.completionReason.rawValue))"

        /// List tools used.
        let toolsUsed = Set(result.workflowRounds.flatMap { $0.toolCalls.map { $0.name } })
        let toolsSummary = toolsUsed.isEmpty ? "None" : toolsUsed.sorted().joined(separator: ", ")

        return """
        ═══════════════════════════════════════
        SUBAGENT TASK: \(task)
        Conversation ID: \(conversationId)
        ═══════════════════════════════════════

        STATUS: \(status)
        ITERATIONS: \(result.iterations)
        DURATION: \(String(format: "%.2f", duration))s
        TOOLS USED: \(toolsSummary)

        RESULTS:
        \(summary)

        ═══════════════════════════════════════
        Subagent Conversation ID: \(conversationId)
        (View full details in conversation history)
        ═══════════════════════════════════════
        """
    }
}

// MARK: - Subagent Errors

enum SubagentError: Error, LocalizedError {
    case conversationCreationFailed
    case parentConversationNotFound

    var errorDescription: String? {
        switch self {
        case .conversationCreationFailed:
            return "Failed to create subagent conversation"

        case .parentConversationNotFound:
            return "Parent conversation not found"
        }
    }
}
