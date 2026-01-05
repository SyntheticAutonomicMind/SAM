// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Injects todo list context into agent prompts with every request (like VS Code Copilot).
/// This keeps the agent aware of task status and enforces progress rules.
public class TodoReminderInjector {
    private let logger = Logging.Logger(label: "com.sam.TodoReminderInjector")

    /// Configuration - inject every request when todos exist (VS Code approach).
    private struct ReminderConfig {
        static let enabled = true
        /// Minimum todos to trigger injection (1 = always when todos exist).
        static let minTodosForReminder = 1
    }

    public nonisolated(unsafe) static let shared = TodoReminderInjector()

    private init() {
        logger.debug("TodoReminderInjector initialized (inject every request when todos exist)")
    }

    /// Check if reminder should be injected - ALWAYS inject when todos exist.
    /// This matches VS Code Copilot's approach of injecting TodoListContextPrompt with every user message.
    public func shouldInjectReminder(
        conversationId: UUID,
        currentResponseCount: Int,
        activeTodoCount: Int
    ) -> Bool {
        guard ReminderConfig.enabled else { return false }

        /// Inject if ANY todos exist (not just 2+).
        return activeTodoCount >= ReminderConfig.minTodosForReminder
    }

    /// Format todo context for injection into prompt.
    /// Injected with every request to keep agent aware of task status.
    /// Includes progress rules that match VS Code Copilot's approach.
    public func formatTodoReminder(
        conversationId: UUID,
        todoManager: TodoManager
    ) -> String? {
        let todoList = todoManager.readTodoList(for: conversationId.uuidString)
        let stats = todoManager.getProgressStatistics(for: conversationId.uuidString)

        /// No todos?.
        guard stats.totalTodos > 0 else {
            return nil
        }

        var reminder = """
        <todoList>
        """

        /// Status summary.
        if stats.completedTodos > 0 {
            reminder += "Completed: \(stats.completedTodos)\n"
        }

        if stats.inProgressTodos > 0 {
            let inProgressTodos = todoList.items.filter { $0.status == .inProgress }
            let titles = inProgressTodos.map { "[\($0.id)] \($0.title)" }.joined(separator: ", ")
            reminder += "In Progress: \(titles)\n"
        }

        if stats.notStartedTodos > 0 {
            let notStartedTodos = todoList.items.filter { $0.status == .notStarted }
            let titles = notStartedTodos.map { "[\($0.id)] \($0.title)" }.joined(separator: ", ")
            reminder += "Not Started: \(titles)\n"
        }

        /// Show blocked todos.
        let blockedTodos = todoList.items.filter { $0.status == .blocked }
        if !blockedTodos.isEmpty {
            let blockedTitles = blockedTodos.map { todo in
                var title = "[\(todo.id)] \(todo.title)"
                if let reason = todo.blockedReason {
                    title += " (\(reason))"
                }
                return title
            }.joined(separator: ", ")
            reminder += "Blocked: \(blockedTitles)\n"
        }

        /// Progress rules - critical for maintaining todo list (from VS Code Copilot).
        /// Enhanced with explicit "AFTER work" reminder since agents forget to update after completing tasks.
        /// CRITICAL: Only ask agent to mark in-progress if there IS a task that's not started yet.
        let needsInProgressMarking = stats.inProgressTodos == 0 && stats.notStartedTodos > 0
        let hasInProgressTask = stats.inProgressTodos > 0

        if stats.completedTodos == stats.totalTodos && stats.totalTodos > 0 {
            // All tasks complete - guide agent on what to do next
            reminder += """

        All \(stats.totalTodos) previous tasks completed.

        YOU MUST NOW DECIDE:
        - If more work is needed → Call additional tools and continue working
        - If all work is truly complete → Provide a BRIEF final message summarizing what was accomplished
        
        DO NOT repeat the work you already did. DO NOT re-tell stories, re-create content, or duplicate outputs.
        Just acknowledge completion and summarize the session's accomplishments concisely.
        </todoList>
        """
        } else if hasInProgressTask {
            // Task already in-progress - agent should continue working, NOT re-mark
            reminder += """

        CURRENT TASK IN PROGRESS - You must complete it now.

        WORKFLOW (follow exactly):
        1. DO THE ACTUAL WORK following your system prompt instructions (use tools as required, provide content to user)
        2. AFTER the work is done → call todo_operations to mark "completed"
        
        DO NOT mark it completed without doing the work first.
        DO NOT call todo_operations to mark in-progress again (it's already in-progress).
        
        FOLLOW YOUR SYSTEM PROMPT while completing the work, THEN mark it completed.
        </todoList>
        """
        } else if needsInProgressMarking {
            // No task in progress but tasks remain - agent should pick one
            reminder += """

        NO TASK CURRENTLY IN PROGRESS - Pick one and begin.

        WORKFLOW (follow exactly):
        1. Mark the next task "in-progress": call todo_operations(operation: "update", todoUpdates: [{"id": <task_id>, "status": "in-progress"}])
        2. DO THE ACTUAL WORK following your system prompt instructions (use tools as required, provide content to user)
        3. Mark it "completed": call todo_operations(operation: "update", todoUpdates: [{"id": <task_id>, "status": "completed"}])
        
        CRITICAL: Steps 1-2-3 must happen across MULTIPLE iterations.
        DO NOT mark a task completed in the same iteration you marked it in-progress.
        FOLLOW YOUR SYSTEM PROMPT while doing the work between marking in-progress and completed.
        </todoList>
        """
        } else {
            // Edge case - no tasks at all (shouldn't happen since we check stats.totalTodos > 0 above)
            reminder += """
        </todoList>
        """
        }

        return reminder
    }
}
