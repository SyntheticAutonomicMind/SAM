// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Injects todo list context into agent prompts when todos exist.
public class TodoReminderInjector {
    private let logger = Logging.Logger(label: "com.sam.TodoReminderInjector")

    public nonisolated(unsafe) static let shared = TodoReminderInjector()
    private init() {}

    /// Inject when any todos exist.
    public func shouldInjectReminder(
        conversationId: UUID,
        currentResponseCount: Int,
        activeTodoCount: Int
    ) -> Bool {
        return activeTodoCount > 0
    }

    /// Format todo context for injection.
    public func formatTodoReminder(
        conversationId: UUID,
        todoManager: TodoManager
    ) -> String? {
        let todoList = todoManager.readTodoList(for: conversationId.uuidString)
        let stats = todoManager.getProgressStatistics(for: conversationId.uuidString)

        guard stats.totalTodos > 0 else { return nil }

        var reminder = "<todoList>\n"

        if stats.completedTodos > 0 {
            reminder += "Completed: \(stats.completedTodos)\n"
        }

        if stats.inProgressTodos > 0 {
            let titles = todoList.items.filter { $0.status == .inProgress }
                .map { "[\($0.id)] \($0.title)" }.joined(separator: ", ")
            reminder += "In Progress: \(titles)\n"
        }

        if stats.notStartedTodos > 0 {
            let titles = todoList.items.filter { $0.status == .notStarted }
                .map { "[\($0.id)] \($0.title)" }.joined(separator: ", ")
            reminder += "Not Started: \(titles)\n"
        }

        let blocked = todoList.items.filter { $0.status == .blocked }
        if !blocked.isEmpty {
            let titles = blocked.map { todo in
                var t = "[\(todo.id)] \(todo.title)"
                if let reason = todo.blockedReason { t += " (\(reason))" }
                return t
            }.joined(separator: ", ")
            reminder += "Blocked: \(titles)\n"
        }

        if stats.completedTodos == stats.totalTodos {
            reminder += "All tasks complete.\n"
        }

        reminder += "</todoList>"
        return reminder
    }
}
