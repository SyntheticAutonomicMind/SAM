// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// Represents a single todo item from an agent's todo list.
public struct AgentTodoItem: Identifiable, Codable, Equatable {
    public let id: Int
    public let title: String
    public let description: String
    public let status: String  // "not-started", "in-progress", "completed"

    public init(id: Int, title: String, description: String, status: String) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
    }

    /// Helper to get status color
    public var statusColor: String {
        switch status {
        case "completed": return "green"
        case "in-progress": return "blue"
        default: return "secondary"
        }
    }

    /// Helper to get status icon
    public var statusIcon: String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in-progress": return "circle.lefthalf.filled"
        default: return "circle"
        }
    }
}

/// Response structure from manage_todo_list tool
public struct ManageTodoListResponse: Codable {
    public let operation: String
    public let todoList: [AgentTodoItem]?

    public init(operation: String, todoList: [AgentTodoItem]?) {
        self.operation = operation
        self.todoList = todoList
    }
}
