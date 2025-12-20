// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Popover view showing agent's current todo list
public struct TodoListPopover: View {
    let todos: [AgentTodoItem]

    public init(todos: [AgentTodoItem]) {
        self.todos = todos
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            /// Header
            HStack {
                Image(systemName: "checklist")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text("Agent Todo List")
                    .font(.headline)
                Spacer()
                Text("(\(todos.count))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            if todos.isEmpty {
                /// Empty state
                VStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No active todos")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("The agent hasn't created a todo list yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                /// Todo list
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(todos) { todo in
                            todoRow(todo)

                            if todo.id != todos.last?.id {
                                Divider()
                                    .padding(.leading, 48)
                            }
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
        }
        .frame(width: 400)
    }

    /// Individual todo row
    private func todoRow(_ todo: AgentTodoItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            /// Status icon
            Image(systemName: todo.statusIcon)
                .font(.system(size: 16))
                .foregroundColor(statusColor(for: todo.status))
                .frame(width: 24, height: 24)

            /// Content
            VStack(alignment: .leading, spacing: 4) {
                /// Title
                Text(todo.title)
                    .font(.system(.body, design: .default))
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                /// Description
                if !todo.description.isEmpty {
                    Text(todo.description)
                        .font(.system(.caption, design: .default))
                        .foregroundColor(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }

                /// Status badge
                Text(statusText(for: todo.status))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(statusColor(for: todo.status))
                    .cornerRadius(4)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Get color for status
    private func statusColor(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in-progress": return .blue
        default: return .secondary
        }
    }

    /// Get display text for status
    private func statusText(for status: String) -> String {
        switch status {
        case "completed": return "COMPLETED"
        case "in-progress": return "IN PROGRESS"
        case "not-started": return "NOT STARTED"
        default: return status.uppercased()
        }
    }
}

#Preview {
    TodoListPopover(todos: [
        AgentTodoItem(id: 1, title: "Fix authorization bug", description: "Add MCPAuthorizationGuard checks to executeMCPTool", status: "completed"),
        AgentTodoItem(id: 2, title: "Test security fix", description: "Verify OneDrive access prompts user", status: "in-progress"),
        AgentTodoItem(id: 3, title: "Write documentation", description: "Document the security model in SECURITY.md", status: "not-started")
    ])
}
