// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Dedicated Todo Operations MCP Tool
/// Follows standard tool pattern with operation parameter directly
/// Separated from memory_operations to avoid parameter confusion
public class TodoOperationsTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "todo_operations"

    /// Force serial execution to prevent race conditions in todo state updates
    public var requiresSerial: Bool { true }

    public let description = """
    Manage a structured todo list to track progress and plan tasks. Use this tool VERY frequently to ensure task visibility and proper planning.

    OPERATIONS:
    • read - Get current todo list
    • write - Create/replace todo list (requires todoList array)
    • update - Partial update (requires todoUpdates array)
    • add - Add new todos to existing list (requires newTodos array)

    ═══════════════════════════════════════════════════════════════
    WORKFLOW - READ THIS CAREFULLY, FOLLOW EXACTLY:
    ═══════════════════════════════════════════════════════════════

    STEP 1 - CREATE THE LIST (First time only):
    When user asks for multi-step work and NO todo list exists yet:
    → Call: {"operation": "write", "todoList": [{"id": 1, "title": "...", "description": "...", "status": "not-started"}]}
    → This creates the list with all todos marked "not-started"
    
    ❌ CRITICAL ERROR TO AVOID:
    Do NOT try to mark a todo as "in-progress" if the list doesn't exist yet!
    Always create the list FIRST with 'write', then update status with 'update'.

    STEP 2 - MARK ONE TODO IN-PROGRESS:
    After list exists, before starting work on a todo:
    → Call: {"operation": "update", "todoUpdates": [{"id": 1, "status": "in-progress"}]}
    → Only ONE todo can be in-progress at a time

    STEP 3 - DO THE WORK:
    Execute the actual task using appropriate tools (research, files, etc.)

    STEP 4 - MARK TODO COMPLETE:
    Immediately after finishing the work:
    → Call: {"operation": "update", "todoUpdates": [{"id": 1, "status": "completed"}]}
    → Do this IMMEDIATELY, don't batch multiple completions

    STEP 5 - REPEAT:
    Go back to STEP 2 for next todo

    ═══════════════════════════════════════════════════════════════

    WHEN TO USE THIS TOOL:
    - Complex multi-step work requiring planning and tracking
    - User provides multiple tasks or requests (numbered/comma-separated)
    - After receiving new instructions requiring multiple steps
    - When breaking down larger tasks into smaller actionable steps
    - To give users visibility into your progress and planning

    WHEN NOT TO USE:
    - Single, trivial tasks completable in one step
    - Purely conversational/informational requests
    - Simple code samples or explanations

    ADDING NEW TASKS (when list already exists):
    Use 'add' operation to append new todos:
    • Automatically preserves completed todos
    • Auto-assigns IDs starting after highest existing ID
    • Example: {"operation": "add", "newTodos": [{"title": "New task", "description": "Details"}]}

    PROGRESS RULES:
    • Describing progress in your response is NOT the same as updating - you MUST call this tool
    • Before ending your turn: call update to mark any completed work

    STATUS: not-started | in-progress (max 1) | completed | blocked
    """

    public var supportedOperations: [String] {
        return ["read", "write", "update", "add"]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: "Todo operation: 'read', 'write', 'update', or 'add'",
                required: true,
                enumValues: ["read", "write", "update", "add"]
            ),
            "todoList": MCPToolParameter(
                type: .array,
                description: "Complete array of all todos (required for write operation)",
                required: false,
                arrayElementType: .object(properties: [
                    "id": MCPToolParameter(type: .integer, description: "Unique ID (sequential numbers from 1)", required: true),
                    "title": MCPToolParameter(type: .string, description: "Todo label (3-7 words)", required: true),
                    "description": MCPToolParameter(type: .string, description: "Context, requirements, file paths, etc.", required: true),
                    "status": MCPToolParameter(type: .string, description: "not-started | in-progress (max 1) | completed | blocked", required: true, enumValues: ["not-started", "in-progress", "completed", "blocked"]),
                    "priority": MCPToolParameter(type: .string, description: "Priority level (optional): low | medium | high | critical", required: false, enumValues: ["low", "medium", "high", "critical"]),
                    "dependencies": MCPToolParameter(type: .array, description: "Array of todo IDs this task depends on (optional)", required: false, arrayElementType: .integer),
                    "canRunParallel": MCPToolParameter(type: .boolean, description: "Whether task can run in parallel with others (optional)", required: false),
                    "parallelGroup": MCPToolParameter(type: .string, description: "Grouping identifier for parallel tasks (optional)", required: false),
                    "progress": MCPToolParameter(type: .string, description: "Progress percentage 0.0-1.0 as decimal string (optional)", required: false),
                    "blockedReason": MCPToolParameter(type: .string, description: "Reason why task is blocked (required if status=blocked)", required: false)
                ])
            ),
            "newTodos": MCPToolParameter(
                type: .array,
                description: "New todos to add (required for add operation). IDs will be auto-assigned starting after the highest existing ID.",
                required: false,
                arrayElementType: .object(properties: [
                    "title": MCPToolParameter(type: .string, description: "Todo label (3-7 words)", required: true),
                    "description": MCPToolParameter(type: .string, description: "Context, requirements, file paths, etc.", required: true),
                    "status": MCPToolParameter(type: .string, description: "not-started | in-progress (max 1) | completed | blocked", required: false, enumValues: ["not-started", "in-progress", "completed", "blocked"]),
                    "priority": MCPToolParameter(type: .string, description: "Priority level (optional): low | medium | high | critical", required: false, enumValues: ["low", "medium", "high", "critical"])
                ])
            ),
            "todoUpdates": MCPToolParameter(
                type: .array,
                description: """
                    Partial todo updates (required for update operation).
                    Array of updates where each update has:
                    - id (required): Todo ID to update
                    - Any fields to change (status, title, description, progress, etc.)

                    Example: [{"id": 1, "status": "completed"}, {"id": 2, "status": "in-progress"}]
                    """,
                required: false,
                arrayElementType: .object(properties: [
                    "id": MCPToolParameter(type: .integer, description: "ID of todo to update", required: true)
                ])
            )
        ]
    }

    private let logger = Logging.Logger(label: "com.sam.mcp.TodoOperationsTool")
    private let todoManager = TodoManager.shared

    public init() {
        logger.debug("TodoOperationsTool initialized (dedicated todo management)")
        ToolDisplayInfoRegistry.shared.register("todo_operations", provider: TodoOperationsTool.self)
    }

    @MainActor
    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        let startTime = Date()

        // Validate parameters before routing
        if let validationError = validateParameters(operation: operation, parameters: parameters) {
            return validationError
        }

        let conversationId = context.conversationId?.uuidString ?? "default"
        logger.debug("Todo operation '\(operation)' for conversation: \(conversationId)")

        let result: MCPToolResult
        switch operation {
        case "read":
            result = await handleReadTodos(conversationId: conversationId)

        case "write":
            guard let todoListData = parameters["todoList"] as? [[String: Any]] else {
                return operationError(operation, message: "'write' operation requires 'todoList' parameter")
            }
            result = await handleWriteTodos(todoListData: todoListData, conversationId: conversationId)

        case "update":
            guard let todoUpdatesData = parameters["todoUpdates"] as? [[String: Any]] else {
                return operationError(operation, message: "'update' operation requires 'todoUpdates' parameter")
            }
            result = await handleUpdateTodos(todoUpdatesData: todoUpdatesData, conversationId: conversationId)

        case "add":
            guard let newTodosData = parameters["newTodos"] as? [[String: Any]] else {
                return operationError(operation, message: "'add' operation requires 'newTodos' parameter")
            }
            result = await handleAddTodos(newTodosData: newTodosData, conversationId: conversationId)

        default:
            logger.error("Unknown operation: \(operation)")
            result = operationError(operation, message: "Unknown operation. Use: read, write, update, or add")
        }

        let executionTime = Date().timeIntervalSince(startTime) * 1000
        logger.debug("\(name).\(operation) completed in \(String(format: "%.3f", executionTime))ms")

        return result
    }

    // MARK: - Parameter Validation

    private func validateParameters(operation: String, parameters: [String: Any]) -> MCPToolResult? {
        switch operation {
        case "read":
            // No additional parameters required
            return nil

        case "write":
            guard parameters["todoList"] is [[String: Any]] else {
                return operationError("write", message: """
                    Missing required parameter 'todoList'.

                    Usage: {"operation": "write", "todoList": [{"id": 1, "title": "...", "description": "...", "status": "not-started"}]}
                    """)
            }

        case "update":
            guard parameters["todoUpdates"] is [[String: Any]] else {
                return operationError("update", message: """
                    Missing required parameter 'todoUpdates'.

                    Usage: {"operation": "update", "todoUpdates": [{"id": 1, "status": "completed"}]}
                    """)
            }

        case "add":
            guard parameters["newTodos"] is [[String: Any]] else {
                return operationError("add", message: """
                    Missing required parameter 'newTodos'.

                    Usage: {"operation": "add", "newTodos": [{"title": "New task", "description": "Details"}]}
                    IDs are auto-assigned. Existing todos (including completed) are preserved.
                    """)
            }

        default:
            break
        }

        return nil
    }

    // MARK: - Todo Operations

    @MainActor
    private func handleReadTodos(conversationId: String) async -> MCPToolResult {
        logger.debug("Reading todo list for conversation: \(conversationId)")

        let todoList = todoManager.readTodoList(for: conversationId)
        let stats = todoManager.getProgressStatistics(for: conversationId)

        var output = "CURRENT TODO LIST:\n\n"

        if todoList.items.isEmpty {
            output += "No todos currently defined.\n"
        } else {
            output += "Progress: \(stats.completedTodos)/\(stats.totalTodos) completed (\(String(format: "%.1f", stats.completionRate * 100))%)\n\n"

            // Group todos by status for better readability
            let notStartedTodos = todoList.items.filter { $0.status == .notStarted }.sorted { $0.id < $1.id }
            let inProgressTodos = todoList.items.filter { $0.status == .inProgress }.sorted { $0.id < $1.id }
            let blockedTodos = todoList.items.filter { $0.status == .blocked }.sorted { $0.id < $1.id }
            let completedTodos = todoList.items.filter { $0.status == .completed }.sorted { $0.id < $1.id }

            if !inProgressTodos.isEmpty {
                output += "IN PROGRESS:\n"
                for todo in inProgressTodos {
                    output += "  \(todo.id). \(todo.title)"
                    if let priority = todo.priority {
                        output += " [Priority: \(priority.displayName)]"
                    }
                    if let progress = todo.progress {
                        output += " (\(String(format: "%.0f", progress * 100))% complete)"
                    }
                    output += "\n"
                    output += "     → \(todo.description)\n"

                    if let deps = todo.dependencies, !deps.isEmpty {
                        let blockingDeps = todo.getBlockingDependencies(in: todoList.items)
                        if !blockingDeps.isEmpty {
                            output += "     WARNING: Blocked by: \(blockingDeps.map { String($0) }.joined(separator: ", "))\n"
                        }
                    }
                }
                output += "\n"
            }

            if !blockedTodos.isEmpty {
                output += "BLOCKED:\n"
                for todo in blockedTodos {
                    output += "  \(todo.id). \(todo.title)\n"
                    output += "     → \(todo.description)\n"
                    if let reason = todo.blockedReason {
                        output += "     Blocked: \(reason)\n"
                    }
                }
                output += "\n"
            }

            if !notStartedTodos.isEmpty {
                output += "NOT STARTED:\n"
                for todo in notStartedTodos {
                    output += "  \(todo.id). \(todo.title)"
                    if let priority = todo.priority {
                        output += " [Priority: \(priority.displayName)]"
                    }
                    output += "\n"
                    output += "     → \(todo.description)\n"
                }
                output += "\n"
            }

            if !completedTodos.isEmpty {
                output += "SUCCESS: COMPLETED:\n"
                for todo in completedTodos {
                    output += "  \(todo.id). \(todo.title)\n"
                }
                output += "\n"
            }

            // ALL_TASKS_COMPLETE signal when reading a fully completed list
            if stats.completedTodos == stats.totalTodos && stats.totalTodos > 0 {
                output += "All \(stats.totalTodos) previous tasks completed. Ready for new work. Use operation 'add' to add new tasks.\n"
                logger.info("ALL_TASKS_COMPLETE: Read fully completed list (\(stats.completedTodos)/\(stats.totalTodos))")
            }
        }

        output += "Last updated: \(formatDate(todoList.updatedAt))"

        logger.debug("Successfully read todo list with \(todoList.items.count) items")
        return successResult(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor
    private func handleWriteTodos(todoListData: [[String: Any]], conversationId: String) async -> MCPToolResult {
        logger.debug("Writing todo list with \(todoListData.count) items")

        // Read existing todo list for progress protection
        let existingList = todoManager.readTodoList(for: conversationId)
        let existingStats = todoManager.getProgressStatistics(for: conversationId)

        // Build map of completed todos to protect
        var completedTodos: [Int: String] = [:]
        for existingItem in existingList.items where existingItem.status == .completed {
            completedTodos[existingItem.id] = existingItem.title
        }

        // Parse and validate todo items
        var todoItems: [TodoManager.TodoItem] = []

        for (index, itemData) in todoListData.enumerated() {
            guard let id = itemData["id"] as? Int else {
                return errorResult("Missing 'id' field for todo item at index \(index)")
            }

            guard let title = itemData["title"] as? String, !title.isEmpty else {
                return errorResult("Missing or empty 'title' field for todo item \(id)")
            }

            let description = itemData["description"] as? String ?? ""

            guard let statusString = itemData["status"] as? String else {
                return errorResult("Missing 'status' field for todo item \(id)")
            }

            guard let status = TodoManager.TodoItem.TodoStatus(rawValue: statusString) else {
                return errorResult("Invalid status '\(statusString)' for todo item \(id). Must be 'not-started', 'in-progress', 'completed', or 'blocked'")
            }

            // Parse optional fields
            var priority: TodoManager.TodoItem.Priority?
            if let priorityStr = itemData["priority"] as? String {
                priority = TodoManager.TodoItem.Priority(rawValue: priorityStr)
            }

            let dependencies = itemData["dependencies"] as? [Int]
            let canRunParallel = itemData["canRunParallel"] as? Bool
            let parallelGroup = itemData["parallelGroup"] as? String

            var progress: Double?
            if let progressValue = itemData["progress"] as? Double {
                progress = progressValue
            } else if let progressValue = itemData["progress"] as? Int {
                progress = Double(progressValue)
            }

            let blockedReason = itemData["blockedReason"] as? String

            let todoItem = TodoManager.TodoItem(
                id: id,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                conversationId: conversationId,
                status: status,
                priority: priority,
                dependencies: dependencies,
                canRunParallel: canRunParallel,
                parallelGroup: parallelGroup,
                progress: progress,
                blockedReason: blockedReason,
                subtasks: nil
            )

            todoItems.append(todoItem)
        }

        // Validate business rules
        let validationErrors = todoManager.validateTodoList(todoItems)
        if !validationErrors.isEmpty {
            var errorOutput = "Todo list validation failed:\n\n"
            for error in validationErrors {
                if let todoId = error.todoId {
                    errorOutput += "  - Todo \(todoId): \(error.message)\n"
                } else {
                    errorOutput += "  - \(error.message)\n"
                }
            }
            return errorResult(errorOutput)
        }

        // Progress protection: check if completed todos were deleted
        let newTodoIds = Set(todoItems.map { $0.id })
        var deletedCompletedTodos: [(id: Int, title: String)] = []
        for (completedId, completedTitle) in completedTodos {
            if !newTodoIds.contains(completedId) {
                deletedCompletedTodos.append((id: completedId, title: completedTitle))
            }
        }

        if !deletedCompletedTodos.isEmpty {
            var errorOutput = "ERROR: Cannot delete completed todos:\n\n"
            for deleted in deletedCompletedTodos {
                errorOutput += "  - Todo \(deleted.id): \(deleted.title)\n"
            }
            errorOutput += "\nCompleted work must remain in the list."
            return errorResult(errorOutput)
        }

        // Write to todo manager
        let success = await todoManager.writeTodoList(for: conversationId, items: todoItems)

        if success {
            let newStats = todoManager.getProgressStatistics(for: conversationId)

            var output = "Todo list updated: \(todoItems.count) items.\n\n"
            output += "PREVIOUS STATE: \(existingStats.completedTodos) completed, \(existingStats.inProgressTodos) in-progress, \(existingStats.notStartedTodos) not-started\n"
            output += "NEW STATE: \(newStats.completedTodos) completed, \(newStats.inProgressTodos) in-progress, \(newStats.notStartedTodos) not-started\n"

            output += "\nCURRENT STATUS:\n"
            let completedTitles = todoItems.filter { $0.status == .completed }.map { $0.title }
            let inProgressTitles = todoItems.filter { $0.status == .inProgress }.map { $0.title }
            let notStartedTitles = todoItems.filter { $0.status == .notStarted }.map { $0.title }

            if !completedTitles.isEmpty {
                output += "SUCCESS: Completed: \(completedTitles.joined(separator: ", "))\n"
            }
            if !inProgressTitles.isEmpty {
                output += "In Progress: \(inProgressTitles.joined(separator: ", "))\n"
            }
            if !notStartedTitles.isEmpty {
                output += "○ Not Started: \(notStartedTitles.joined(separator: ", "))\n"
            }

            if newStats.completedTodos == todoItems.count {
                output += "\nAll tasks completed!"
            } else if newStats.notStartedTodos > 0 {
                output += "\nTodo list ready. \(newStats.notStartedTodos) item\(newStats.notStartedTodos == 1 ? "" : "s") not started."
            }

            return successResult(output)
        } else {
            return errorResult("Failed to save todo list")
        }
    }

    @MainActor
    private func handleUpdateTodos(todoUpdatesData: [[String: Any]], conversationId: String) async -> MCPToolResult {
        logger.debug("Updating todos with \(todoUpdatesData.count) update(s)")

        // Read existing todo list
        let existingList = todoManager.readTodoList(for: conversationId)

        if existingList.items.isEmpty {
            return errorResult("No todo list exists. Create one first with 'write' operation.")
        }

        // Create mutable copy
        var updatedItems = existingList.items

        // Apply each update
        var appliedUpdates: [String] = []
        var failedUpdates: [String] = []
        var noOpUpdates: [String] = []  // Track redundant updates

        for (index, updateData) in todoUpdatesData.enumerated() {
            guard let todoId = updateData["id"] as? Int else {
                failedUpdates.append("Update at index \(index): missing 'id' field")
                continue
            }

            guard let todoIndex = updatedItems.firstIndex(where: { $0.id == todoId }) else {
                failedUpdates.append("Todo #\(todoId): not found")
                continue
            }

            var item = updatedItems[todoIndex]
            var changes: [String] = []

            if let newTitle = updateData["title"] as? String {
                item.title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                changes.append("title")
            }

            if let newDescription = updateData["description"] as? String {
                item.description = newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                changes.append("description")
            }

            if let newStatusStr = updateData["status"] as? String,
               let newStatus = TodoManager.TodoItem.TodoStatus(rawValue: newStatusStr) {
                let oldStatus = item.status
                // Only record status change if it's actually different
                if oldStatus != newStatus {
                    item.status = newStatus
                    changes.append("status: \(oldStatus.rawValue)→\(newStatus.rawValue)")
                } else {
                    // Redundant update - same status
                    noOpUpdates.append("Todo #\(todoId) already has status '\(oldStatus.rawValue)'")
                }
            }

            if let newPriorityStr = updateData["priority"] as? String,
               let newPriority = TodoManager.TodoItem.Priority(rawValue: newPriorityStr) {
                item.priority = newPriority
                changes.append("priority: \(newPriority.displayName)")
            }

            if let newProgress = updateData["progress"] as? Double {
                item.progress = newProgress
                changes.append("progress: \(String(format: "%.0f%%", newProgress * 100))")
            }

            if let newBlockedReason = updateData["blockedReason"] as? String {
                item.blockedReason = newBlockedReason
                changes.append("blockedReason")
            }

            if let newDependencies = updateData["dependencies"] as? [Int] {
                item.dependencies = newDependencies
                changes.append("dependencies")
            }

            updatedItems[todoIndex] = item

            // Only record if there were actual changes
            if !changes.isEmpty {
                appliedUpdates.append("Todo #\(todoId) (\(item.title)): \(changes.joined(separator: ", "))")
            }
        }

        // Validate updated list
        let validationErrors = todoManager.validateTodoList(updatedItems)
        if !validationErrors.isEmpty {
            var errorOutput = "Update validation failed:\n\n"
            for error in validationErrors {
                if let todoId = error.todoId {
                    errorOutput += "  - Todo \(todoId): \(error.message)\n"
                } else {
                    errorOutput += "  - \(error.message)\n"
                }
            }
            return errorResult(errorOutput)
        }

        // Write updated list
        let success = await todoManager.writeTodoList(for: conversationId, items: updatedItems)

        if success {
            let stats = todoManager.getProgressStatistics(for: conversationId)

            var output = "Todo updates applied: \(appliedUpdates.count) successful"
            if !failedUpdates.isEmpty {
                output += ", \(failedUpdates.count) failed"
            }
            if !noOpUpdates.isEmpty {
                output += ", \(noOpUpdates.count) redundant (no change)"
            }
            output += "\n\n"

            if !appliedUpdates.isEmpty {
                output += "UPDATES APPLIED:\n"
                for update in appliedUpdates {
                    output += "  SUCCESS: \(update)\n"
                }
                output += "\n"
            }

            if !failedUpdates.isEmpty {
                output += "FAILED UPDATES:\n"
                for failure in failedUpdates {
                    output += "  \(failure)\n"
                }
                output += "\n"
            }

            // Inform agent about redundant updates to help break loops
            if !noOpUpdates.isEmpty {
                output += "REDUNDANT (no change needed):\n"
                for noOp in noOpUpdates {
                    output += "  \(noOp)\n"
                }
                output += "Note: You don't need to re-mark a task that's already in the correct status.\n\n"
            }

            output += "CURRENT STATUS: \(stats.completedTodos)/\(stats.totalTodos) completed (\(String(format: "%.0f%%", stats.completionRate * 100)))\n"

            let completedTitles = updatedItems.filter { $0.status == .completed }.map { $0.title }
            let inProgressTitles = updatedItems.filter { $0.status == .inProgress }.map { $0.title }
            let notStartedTitles = updatedItems.filter { $0.status == .notStarted }.map { $0.title }

            if !completedTitles.isEmpty {
                output += "SUCCESS: Completed: \(completedTitles.joined(separator: ", "))\n"
            }
            if !inProgressTitles.isEmpty {
                output += "→ In Progress: \(inProgressTitles.joined(separator: ", "))\n"
            }
            if !notStartedTitles.isEmpty {
                output += "○ Not Started: \(notStartedTitles.joined(separator: ", "))\n"
            }

            // ALL_TASKS_COMPLETE signal: Tell agent to summarize when all todos are done
            if stats.completedTodos == stats.totalTodos && stats.totalTodos > 0 {
                output += "\nAll \(stats.totalTodos) previous tasks completed. Ready for new work. Use operation 'add' to add new tasks."
                logger.info("ALL_TASKS_COMPLETE: Todo list fully completed (\(stats.completedTodos)/\(stats.totalTodos))")
            }

            return successResult(output.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            return errorResult("Failed to save updated todo list")
        }
    }

    // MARK: - Add Todos Operation

    @MainActor
    private func handleAddTodos(newTodosData: [[String: Any]], conversationId: String) async -> MCPToolResult {
        logger.debug("Adding \(newTodosData.count) new todos")

        // Read existing todo list to preserve all items
        let existingList = todoManager.readTodoList(for: conversationId)
        var allItems = existingList.items

        // Find the highest existing ID to continue numbering
        let maxExistingId = allItems.map { $0.id }.max() ?? 0

        // Parse and add new todos
        var addedTodos: [String] = []
        var nextId = maxExistingId + 1

        for (index, itemData) in newTodosData.enumerated() {
            guard let title = itemData["title"] as? String, !title.isEmpty else {
                return errorResult("Missing or empty 'title' field for new todo at index \(index)")
            }

            let description = itemData["description"] as? String ?? ""

            // Default status is not-started unless specified
            let statusString = itemData["status"] as? String ?? "not-started"
            guard let status = TodoManager.TodoItem.TodoStatus(rawValue: statusString) else {
                return errorResult("Invalid status '\(statusString)' for new todo '\(title)'. Must be 'not-started', 'in-progress', 'completed', or 'blocked'")
            }

            // Parse optional priority
            var priority: TodoManager.TodoItem.Priority?
            if let priorityStr = itemData["priority"] as? String {
                priority = TodoManager.TodoItem.Priority(rawValue: priorityStr)
            }

            let newTodo = TodoManager.TodoItem(
                id: nextId,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                conversationId: conversationId,
                status: status,
                priority: priority,
                dependencies: nil,
                canRunParallel: nil,
                parallelGroup: nil,
                progress: nil,
                blockedReason: nil,
                subtasks: nil
            )

            allItems.append(newTodo)
            addedTodos.append("#\(nextId): \(title)")
            nextId += 1
        }

        // Validate the complete list (including new items)
        let validationErrors = todoManager.validateTodoList(allItems)
        if !validationErrors.isEmpty {
            var errorOutput = "Validation failed after adding todos:\n\n"
            for error in validationErrors {
                if let todoId = error.todoId {
                    errorOutput += "  - Todo \(todoId): \(error.message)\n"
                } else {
                    errorOutput += "  - \(error.message)\n"
                }
            }
            return errorResult(errorOutput)
        }

        // Write the combined list
        let success = await todoManager.writeTodoList(for: conversationId, items: allItems)

        if success {
            let stats = todoManager.getProgressStatistics(for: conversationId)

            var output = "SUCCESS: Added \(addedTodos.count) new todo(s).\n\n"
            output += "NEW TODOS:\n"
            for added in addedTodos {
                output += "  + \(added)\n"
            }
            output += "\n"

            output += "CURRENT STATUS: \(stats.completedTodos)/\(stats.totalTodos) total (\(stats.notStartedTodos) not started, \(stats.inProgressTodos) in progress, \(stats.completedTodos) completed)\n"

            // List all current todos
            let notStartedTitles = allItems.filter { $0.status == .notStarted }.map { "#\($0.id): \($0.title)" }
            let inProgressTitles = allItems.filter { $0.status == .inProgress }.map { "#\($0.id): \($0.title)" }
            let completedTitles = allItems.filter { $0.status == .completed }.map { "#\($0.id): \($0.title)" }

            if !notStartedTitles.isEmpty {
                output += "\n○ Not Started: \(notStartedTitles.joined(separator: ", "))"
            }
            if !inProgressTitles.isEmpty {
                output += "\n→ In Progress: \(inProgressTitles.joined(separator: ", "))"
            }
            if !completedTitles.isEmpty {
                output += "\nSUCCESS: Completed: \(completedTitles.joined(separator: ", "))"
            }

            logger.info("Added \(addedTodos.count) todos to conversation \(conversationId)")
            return successResult(output.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            return errorResult("Failed to save todo list with new items")
        }
    }

    // MARK: - Helper Methods

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Protocol Conformance

extension TodoOperationsTool: ToolDisplayInfoProvider {
    public static func extractDisplayInfo(from arguments: [String: Any]) -> String? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        switch operation.lowercased() {
        case "read":
            return "Reading todo list"

        case "write":
            if let todos = arguments["todoList"] as? [[String: Any]] {
                let inProgress = todos.filter { ($0["status"] as? String) == "in-progress" }
                let completed = todos.filter { ($0["status"] as? String) == "completed" }

                if !completed.isEmpty {
                    if let lastCompleted = completed.last, let title = lastCompleted["title"] as? String {
                        let preview = title.count > 35 ? String(title.prefix(32)) + "..." : title
                        return "SUCCESS: Completed: \(preview)"
                    }
                    return "Updating todo list (\(completed.count) completed)"
                } else if let inProgressTodo = inProgress.first, let title = inProgressTodo["title"] as? String {
                    let preview = title.count > 35 ? String(title.prefix(32)) + "..." : title
                    return "Starting: \(preview)"
                }
                return "Creating todo list (\(todos.count) tasks)"
            }
            return "Writing todo list"

        case "update":
            if let updates = arguments["todoUpdates"] as? [[String: Any]] {
                if updates.count == 1, let update = updates.first {
                    if let todoId = update["id"] as? Int {
                        if let newStatus = update["status"] as? String {
                            return "Updating todo #\(todoId): \(newStatus)"
                        }
                        return "Updating todo #\(todoId)"
                    }
                }
                return "Updating \(updates.count) todos"
            }
            return "Updating todos"

        case "add":
            if let newTodos = arguments["newTodos"] as? [[String: Any]] {
                if newTodos.count == 1, let todo = newTodos.first, let title = todo["title"] as? String {
                    let preview = title.count > 35 ? String(title.prefix(32)) + "..." : title
                    return "Adding task: \(preview)"
                }
                return "Adding \(newTodos.count) new tasks"
            }
            return "Adding tasks"

        default:
            return nil
        }
    }

    public static func extractToolDetails(from arguments: [String: Any]) -> [String]? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        switch operation.lowercased() {
        case "read":
            return ["Operation: Read current todo list"]

        case "write":
            if let todos = arguments["todoList"] as? [[String: Any]] {
                var details: [String] = []
                let inProgress = todos.filter { ($0["status"] as? String) == "in-progress" }
                let completed = todos.filter { ($0["status"] as? String) == "completed" }
                let notStarted = todos.filter { ($0["status"] as? String) == "not-started" }

                details.append("Total tasks: \(todos.count)")

                if !completed.isEmpty {
                    details.append("SUCCESS: Completed: \(completed.count) task(s)")
                }

                if !inProgress.isEmpty {
                    if let title = inProgress.first?["title"] as? String {
                        let preview = title.count > 40 ? String(title.prefix(37)) + "..." : title
                        details.append("→ In progress: \(preview)")
                    }
                }

                if !notStarted.isEmpty {
                    details.append("◦ Not started: \(notStarted.count) task(s)")
                }

                return details
            }
            return ["Operation: Write todo list"]

        case "update":
            if let updates = arguments["todoUpdates"] as? [[String: Any]] {
                var details: [String] = []
                details.append("Updates: \(updates.count) todo(s)")

                for update in updates.prefix(3) {
                    if let todoId = update["id"] as? Int {
                        var changes: [String] = []
                        if update["status"] != nil { changes.append("status") }
                        if update["progress"] != nil { changes.append("progress") }
                        if !changes.isEmpty {
                            details.append("Todo #\(todoId): \(changes.joined(separator: ", "))")
                        }
                    }
                }

                return details
            }
            return ["Operation: Update todos"]

        default:
            return nil
        }
    }
}
