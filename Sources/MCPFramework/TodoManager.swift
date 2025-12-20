// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Per-conversation todo list management backend for MCP tools Provides persistent todo tracking integrated with conversation state.
public class TodoManager: ObservableObject, @unchecked Sendable {

    // MARK: - Types

    public struct TodoItem: Identifiable, Codable {
        public let id: Int
        public var title: String
        public var description: String
        public var status: TodoStatus
        public let conversationId: String
        public let createdAt: Date
        public var updatedAt: Date

        /// PHASE 1 ENHANCEMENTS: Agent Planning Features All fields optional for backward compatibility.
        public var priority: Priority?
        public var dependencies: [Int]?
        public var canRunParallel: Bool?
        public var parallelGroup: String?
        public var progress: Double?
        public var blockedReason: String?

        /// Phase 2 placeholder for future subtask support Designed to be easily extensible.
        public var subtasks: [SubtaskItem]?

        public enum TodoStatus: String, Codable, CaseIterable {
            case notStarted = "not-started"
            case inProgress = "in-progress"
            case completed = "completed"
            case blocked = "blocked"

            public var displayName: String {
                switch self {
                case .notStarted: return "Not Started"
                case .inProgress: return "In Progress"
                case .completed: return "Completed"
                case .blocked: return "Blocked"
                }
            }
        }

        public enum Priority: String, Codable, CaseIterable {
            case low = "low"
            case medium = "medium"
            case high = "high"
            case critical = "critical"

            public var displayName: String {
                switch self {
                case .low: return "Low"
                case .medium: return "Medium"
                case .high: return "High"
                case .critical: return "Critical"
                }
            }

            /// Numeric weight for sorting/prioritization.
            public var weight: Int {
                switch self {
                case .low: return 1
                case .medium: return 2
                case .high: return 3
                case .critical: return 4
                }
            }
        }

        /// Phase 2: Subtask support (one level deep, extensible for future).
        public struct SubtaskItem: Codable, Identifiable {
            public let id: String
            public var title: String
            public var status: TodoStatus
            public var progress: Double?

            public init(id: String, title: String, status: TodoStatus = .notStarted, progress: Double? = nil) {
                self.id = id
                self.title = title
                self.status = status
                self.progress = progress
            }
        }

        public init(
            id: Int,
            title: String,
            description: String,
            conversationId: String,
            status: TodoStatus = .notStarted,
            priority: Priority? = nil,
            dependencies: [Int]? = nil,
            canRunParallel: Bool? = nil,
            parallelGroup: String? = nil,
            progress: Double? = nil,
            blockedReason: String? = nil,
            subtasks: [SubtaskItem]? = nil
        ) {
            self.id = id
            self.title = title
            self.description = description
            self.conversationId = conversationId
            self.status = status
            self.createdAt = Date()
            self.updatedAt = Date()

            /// Phase 1 enhancements.
            self.priority = priority
            self.dependencies = dependencies
            self.canRunParallel = canRunParallel
            self.parallelGroup = parallelGroup
            self.progress = progress
            self.blockedReason = blockedReason

            /// Phase 2 placeholder.
            self.subtasks = subtasks
        }

        /// Helper to get effective priority (default to medium if not set).
        public var effectivePriority: Priority {
            return priority ?? .medium
        }

        /// Helper to check if todo has unmet dependencies.
        public func hasUnmetDependencies(in todoList: [TodoItem]) -> Bool {
            guard let deps = dependencies, !deps.isEmpty else {
                return false
            }

            for depId in deps {
                if let dependencyTodo = todoList.first(where: { $0.id == depId }) {
                    if dependencyTodo.status != .completed {
                        return true
                    }
                } else {
                    /// Dependency doesn't exist - treat as unmet.
                    return true
                }
            }

            return false
        }

        /// Helper to get list of blocking dependency IDs.
        public func getBlockingDependencies(in todoList: [TodoItem]) -> [Int] {
            guard let deps = dependencies, !deps.isEmpty else {
                return []
            }

            return deps.filter { depId in
                if let dependencyTodo = todoList.first(where: { $0.id == depId }) {
                    return dependencyTodo.status != .completed
                }
                return true
            }
        }
    }

    public struct TodoList: Codable {
        public var items: [TodoItem]
        public let conversationId: String
        public let createdAt: Date
        public var updatedAt: Date

        public init(conversationId: String, items: [TodoItem] = []) {
            self.conversationId = conversationId
            self.items = items
            self.createdAt = Date()
            self.updatedAt = Date()
        }

        mutating func updateTimestamp() {
            updatedAt = Date()
        }
    }

    public struct TodoProgressStatistics: Codable {
        public let totalTodos: Int
        public let completedTodos: Int
        public let inProgressTodos: Int
        public let notStartedTodos: Int
        public let completionRate: Double
        public let conversationId: String

        public var isComplete: Bool {
            return totalTodos > 0 && completedTodos == totalTodos
        }

        public var hasWork: Bool {
            return totalTodos > 0
        }
    }

    // MARK: - Published Properties

    @Published public var todoLists: [String: TodoList] = [:]

    // MARK: - Helper Methods

    private let logger = Logging.Logger(label: "com.sam.mcp.TodoManager")
    private let userDefaults = UserDefaults.standard
    private let todoListsKey = "SAM_TodoLists_MCP"
    private let queue = DispatchQueue(label: "com.sam.mcp.TodoManager.queue")

    // MARK: - Shared Instance

    public nonisolated(unsafe) static let shared = TodoManager()

    private init() {
        loadTodoLists()
    }

    // MARK: - Validation Logic (Phase 1)

    public struct ValidationError {
        public let todoId: Int?
        public let message: String

        public init(todoId: Int? = nil, message: String) {
            self.todoId = todoId
            self.message = message
        }
    }

    /// Validate a todo list for correctness Returns array of validation errors (empty if valid).
    public func validateTodoList(_ todos: [TodoItem]) -> [ValidationError] {
        var errors: [ValidationError] = []

        /// Build ID set for quick lookups.
        let todoIds = Set(todos.map { $0.id })

        for todo in todos {
            /// VALIDATION 1: Dependencies must exist.
            if let deps = todo.dependencies {
                for depId in deps {
                    if !todoIds.contains(depId) {
                        errors.append(ValidationError(
                            todoId: todo.id,
                            message: "Todo \(todo.id) depends on non-existent todo \(depId)"
                        ))
                    }
                }
            }

            /// VALIDATION 2: Circular dependency detection.
            if hasCircularDependency(todoId: todo.id, in: todos) {
                errors.append(ValidationError(
                    todoId: todo.id,
                    message: "Todo \(todo.id) has circular dependency (directly or indirectly depends on itself)"
                ))
            }

            /// VALIDATION 3: Blocked status requires reason.
            if todo.status == .blocked && (todo.blockedReason?.isEmpty ?? true) {
                errors.append(ValidationError(
                    todoId: todo.id,
                    message: "Todo \(todo.id) is marked as blocked but has no blockedReason"
                ))
            }

            /// VALIDATION 4: Progress must be in valid range.
            if let progress = todo.progress {
                if !(0.0...1.0).contains(progress) {
                    errors.append(ValidationError(
                        todoId: todo.id,
                        message: "Todo \(todo.id) has invalid progress \(progress). Must be between 0.0 and 1.0"
                    ))
                }
            }

            /// VALIDATION 5: Progress should match status (warnings, not errors).
            if let progress = todo.progress {
                if todo.status == .completed && progress < 1.0 {
                    logger.warning("Todo \(todo.id) is completed but progress is \(progress) (expected 1.0)")
                } else if todo.status == .notStarted && progress > 0.0 {
                    logger.warning("Todo \(todo.id) is not-started but progress is \(progress) (expected 0.0)")
                }
            }
        }

        return errors
    }

    /// Check if a todo has a circular dependency (uses graph traversal).
    private func hasCircularDependency(todoId: Int, in todos: [TodoItem], visited: Set<Int> = []) -> Bool {
        /// If we've already visited this node, we found a cycle.
        if visited.contains(todoId) {
            return true
        }

        /// Find the todo.
        guard let todo = todos.first(where: { $0.id == todoId }) else {
            return false
        }

        /// If no dependencies, no cycle.
        guard let deps = todo.dependencies, !deps.isEmpty else {
            return false
        }

        // MARK: - this node as visited
        var newVisited = visited
        newVisited.insert(todoId)

        /// Recursively check each dependency.
        for depId in deps {
            if hasCircularDependency(todoId: depId, in: todos, visited: newVisited) {
                return true
            }
        }

        return false
    }

    // MARK: - Core Todo Operations for MCP Tools

    /// Write complete todo list for a specific conversation (replaces entire list) Returns true on success, false on validation failure.
    @MainActor
    public func writeTodoList(for conversationId: String, items: [TodoItem]) async -> Bool {
        /// Validate todo list before writing.
        let validationErrors = validateTodoList(items)
        if !validationErrors.isEmpty {
            logger.error("Todo list validation failed with \(validationErrors.count) errors:")
            for error in validationErrors {
                if let todoId = error.todoId {
                    logger.error("  - Todo \(todoId): \(error.message)")
                } else {
                    logger.error("  - \(error.message)")
                }
            }
            return false
        }

        /// Ensure all items have the correct conversation ID.
        let correctedItems = items.map { item in
            TodoItem(
                id: item.id,
                title: item.title,
                description: item.description,
                conversationId: conversationId,
                status: item.status,
                priority: item.priority,
                dependencies: item.dependencies,
                canRunParallel: item.canRunParallel,
                parallelGroup: item.parallelGroup,
                progress: item.progress,
                blockedReason: item.blockedReason,
                subtasks: item.subtasks
            )
        }

        /// Validate that only ONE item is in-progress at a time (SAM 1.0 protocol).
        let inProgressItems = correctedItems.filter { $0.status == .inProgress }
        if inProgressItems.count > 1 {
            logger.warning("Protocol violation: Multiple items marked as in-progress for conversation \(conversationId)")

            /// Fix by marking all but the first as not-started.
            var finalItems = correctedItems
            for i in 1..<inProgressItems.count {
                if let index = finalItems.firstIndex(where: { $0.id == inProgressItems[i].id }) {
                    finalItems[index].status = .notStarted
                    finalItems[index].updatedAt = Date()
                    logger.debug("Corrected item \(inProgressItems[i].id) to not-started")
                }
            }

            queue.sync {
                todoLists[conversationId] = TodoList(conversationId: conversationId, items: finalItems)
            }
        } else {
            queue.sync {
                todoLists[conversationId] = TodoList(conversationId: conversationId, items: correctedItems)
            }
        }

        queue.sync {
            todoLists[conversationId]?.updateTimestamp()
            saveTodoLists()
        }

        logger.debug("Successfully wrote todo list for conversation \(conversationId)")
        return true
    }

    /// Read current todo list for a specific conversation.
    public func readTodoList(for conversationId: String) -> TodoList {
        return todoLists[conversationId] ?? TodoList(conversationId: conversationId)
    }

    /// Add a new todo to a conversation's list (with optional Phase 1 enhancements).
    public func addTodo(
        title: String,
        description: String,
        to conversationId: String,
        priority: TodoItem.Priority? = nil,
        dependencies: [Int]? = nil,
        canRunParallel: Bool? = nil,
        parallelGroup: String? = nil
    ) async -> Int {
        let existingList = todoLists[conversationId] ?? TodoList(conversationId: conversationId)
        let nextId = (existingList.items.map { $0.id }.max() ?? 0) + 1
        let newTodo = TodoItem(
            id: nextId,
            title: title,
            description: description,
            conversationId: conversationId,
            status: .notStarted,
            priority: priority,
            dependencies: dependencies,
            canRunParallel: canRunParallel,
            parallelGroup: parallelGroup
        )

        var updatedList = existingList
        updatedList.items.append(newTodo)
        updatedList.updateTimestamp()

        todoLists[conversationId] = updatedList
        saveTodoLists()

        return nextId
    }

    // MARK: - as in-progress)
    public func startTodo(_ todoId: Int, in conversationId: String) async -> Bool {
        guard var todoList = todoLists[conversationId] else {
            logger.error("No todo list found for conversation \(conversationId)")
            return false
        }

        /// First, ensure no other todo is in-progress for this conversation.
        for i in 0..<todoList.items.count {
            if todoList.items[i].status == .inProgress {
                todoList.items[i].status = .notStarted
                todoList.items[i].updatedAt = Date()
            }
        }

        // MARK: - the specified todo as in-progress
        if let index = todoList.items.firstIndex(where: { $0.id == todoId }) {
            todoList.items[index].status = .inProgress
            todoList.items[index].updatedAt = Date()

            todoList.updateTimestamp()
            todoLists[conversationId] = todoList
            saveTodoLists()

            return true
        } else {
            logger.error("Todo \(todoId) not found in conversation \(conversationId)")
            return false
        }
    }

    /// Complete a specific todo.
    public func completeTodo(_ todoId: Int, in conversationId: String) async -> Bool {
        guard var todoList = todoLists[conversationId] else {
            logger.error("No todo list found for conversation \(conversationId)")
            return false
        }

        if let index = todoList.items.firstIndex(where: { $0.id == todoId }) {
            todoList.items[index].status = .completed
            todoList.items[index].updatedAt = Date()

            todoList.updateTimestamp()
            todoLists[conversationId] = todoList
            saveTodoLists()

            return true
        } else {
            logger.error("Todo \(todoId) not found in conversation \(conversationId)")
            return false
        }
    }

    /// Get progress statistics for a conversation.
    public func getProgressStatistics(for conversationId: String) -> TodoProgressStatistics {
        let todoList = todoLists[conversationId] ?? TodoList(conversationId: conversationId)

        let total = todoList.items.count
        let completed = todoList.items.filter { $0.status == .completed }.count
        let inProgress = todoList.items.filter { $0.status == .inProgress }.count
        let notStarted = todoList.items.filter { $0.status == .notStarted }.count

        let completionRate = total > 0 ? Double(completed) / Double(total) : 0.0

        return TodoProgressStatistics(
            totalTodos: total,
            completedTodos: completed,
            inProgressTodos: inProgress,
            notStartedTodos: notStarted,
            completionRate: completionRate,
            conversationId: conversationId
        )
    }

    /// Clear all todos for a specific conversation.
    public func clearTodos(for conversationId: String) async -> Bool {
        todoLists.removeValue(forKey: conversationId)
        saveTodoLists()
        return true
    }

    // MARK: - Persistence

    private func saveTodoLists() {
        do {
            let data = try JSONEncoder().encode(todoLists)
            userDefaults.set(data, forKey: todoListsKey)
        } catch {
            logger.error("Failed to save todo lists: \(error)")
        }
    }

    private func loadTodoLists() {
        guard let data = userDefaults.data(forKey: todoListsKey) else {
            return
        }

        do {
            self.todoLists = try JSONDecoder().decode([String: TodoList].self, from: data)
        } catch {
            logger.error("Failed to load todo lists: \(error)")
            self.todoLists = [:]
        }
    }
}
