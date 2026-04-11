// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import EventKit
import Logging

/// MCP Tool for Calendar and Reminders via EventKit.
/// Provides access to the user's calendars, events, and reminders.
public class CalendarTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "calendar_operations"

    public let description = """
    Manage the user's Calendar events and Reminders using macOS EventKit.

    OPERATIONS:
    Calendar Events:
    • list_events - List upcoming events (optional: days_ahead, calendar_name)
    • create_event - Create a calendar event (title, start_date, end_date, optional: notes, calendar_name, location)
    • search_events - Search events by keyword (query, optional: days_ahead, days_back)
    • delete_event - Delete an event by ID (event_id)

    Reminders:
    • list_reminders - List reminders (optional: list_name, include_completed)
    • create_reminder - Create a reminder (title, optional: due_date, notes, list_name, priority)
    • complete_reminder - Mark a reminder complete (reminder_id)
    • delete_reminder - Delete a reminder (reminder_id)
    • list_reminder_lists - List available reminder lists

    Date Format: ISO 8601 (e.g., "2026-04-15T10:00:00-04:00") or natural descriptions.
    Priority: 0 (none), 1 (high), 5 (medium), 9 (low) - Apple's priority scale.
    """

    public var supportedOperations: [String] {
        return [
            "list_events", "create_event", "search_events", "delete_event",
            "list_reminders", "create_reminder", "complete_reminder", "delete_reminder",
            "list_reminder_lists"
        ]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: "Calendar operation to perform",
                required: true,
                enumValues: supportedOperations
            ),
            "title": MCPToolParameter(
                type: .string,
                description: "Event or reminder title",
                required: false
            ),
            "start_date": MCPToolParameter(
                type: .string,
                description: "Event start date (ISO 8601)",
                required: false
            ),
            "end_date": MCPToolParameter(
                type: .string,
                description: "Event end date (ISO 8601)",
                required: false
            ),
            "due_date": MCPToolParameter(
                type: .string,
                description: "Reminder due date (ISO 8601)",
                required: false
            ),
            "notes": MCPToolParameter(
                type: .string,
                description: "Notes or description",
                required: false
            ),
            "location": MCPToolParameter(
                type: .string,
                description: "Event location",
                required: false
            ),
            "calendar_name": MCPToolParameter(
                type: .string,
                description: "Calendar name to use (defaults to user's default calendar)",
                required: false
            ),
            "list_name": MCPToolParameter(
                type: .string,
                description: "Reminder list name (defaults to default list)",
                required: false
            ),
            "query": MCPToolParameter(
                type: .string,
                description: "Search query for events",
                required: false
            ),
            "days_ahead": MCPToolParameter(
                type: .integer,
                description: "Number of days ahead to search (default: 7)",
                required: false
            ),
            "days_back": MCPToolParameter(
                type: .integer,
                description: "Number of days back to search (default: 0)",
                required: false
            ),
            "include_completed": MCPToolParameter(
                type: .boolean,
                description: "Include completed reminders (default: false)",
                required: false
            ),
            "priority": MCPToolParameter(
                type: .integer,
                description: "Reminder priority: 0=none, 1=high, 5=medium, 9=low",
                required: false
            ),
            "event_id": MCPToolParameter(
                type: .string,
                description: "Event identifier for delete operations",
                required: false
            ),
            "reminder_id": MCPToolParameter(
                type: .string,
                description: "Reminder identifier for complete/delete operations",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.calendar")
    private let eventStore = EKEventStore()

    @MainActor
    public func initialize() async throws {
        logger.debug("CalendarTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard parameters["operation"] is String else {
            throw MCPError.invalidParameters("Missing 'operation' parameter")
        }
        return true
    }

    @MainActor
    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        switch operation {
        case "list_events":
            return await listEvents(parameters: parameters)
        case "create_event":
            return await createEvent(parameters: parameters)
        case "search_events":
            return await searchEvents(parameters: parameters)
        case "delete_event":
            return await deleteEvent(parameters: parameters)
        case "list_reminders":
            return await listReminders(parameters: parameters)
        case "create_reminder":
            return await createReminder(parameters: parameters)
        case "complete_reminder":
            return await completeReminder(parameters: parameters)
        case "delete_reminder":
            return await deleteReminder(parameters: parameters)
        case "list_reminder_lists":
            return await listReminderLists()
        default:
            return operationError(operation, message: "Unknown operation")
        }
    }

    // MARK: - Authorization

    private func requestAccess(for entityType: EKEntityType) async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                return try await eventStore.requestFullAccessToEvents()
            } else {
                return try await eventStore.requestAccess(to: entityType)
            }
        } catch {
            logger.error("EventKit access denied for \(entityType == .event ? "events" : "reminders"): \(error)")
            return false
        }
    }

    private func requestReminderAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                return try await eventStore.requestFullAccessToReminders()
            } else {
                return try await eventStore.requestAccess(to: .reminder)
            }
        } catch {
            logger.error("EventKit reminder access denied: \(error)")
            return false
        }
    }

    // MARK: - Date Parsing

    private func parseDate(_ string: String) -> Date? {
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime]
        if let date = iso8601.date(from: string) {
            return date
        }

        // Try without timezone
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601.date(from: string) {
            return date
        }

        // Try common date-only format
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        if let date = dateOnly.date(from: string) {
            return date
        }

        // Try date + time without timezone
        let dateTime = DateFormatter()
        dateTime.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        dateTime.locale = Locale(identifier: "en_US_POSIX")
        return dateTime.date(from: string)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Calendar Events

    @MainActor
    private func listEvents(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestAccess(for: .event) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Calendar access denied. Please grant calendar permission in System Settings > Privacy & Security > Calendars."))
        }

        let daysAhead = parameters["days_ahead"] as? Int ?? 7
        let calendarName = parameters["calendar_name"] as? String

        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: daysAhead, to: startDate)!

        var calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = eventStore.calendars(for: .event).filter { $0.title.lowercased() == name.lowercased() }
            if calendars?.isEmpty == true {
                let available = eventStore.calendars(for: .event).map { $0.title }.joined(separator: ", ")
                return MCPToolResult(success: false, output: MCPOutput(content: "Calendar '\(name)' not found. Available calendars: \(available)"))
            }
        }

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        if events.isEmpty {
            return MCPToolResult(success: true, output: MCPOutput(content: "No events found in the next \(daysAhead) days."))
        }

        var output = "Events for the next \(daysAhead) days (\(events.count) found):\n\n"
        for event in events.sorted(by: { $0.startDate < $1.startDate }) {
            output += "- **\(event.title ?? "Untitled")**\n"
            output += "  Start: \(formatDate(event.startDate))\n"
            output += "  End: \(formatDate(event.endDate))\n"
            if let location = event.location, !location.isEmpty {
                output += "  Location: \(location)\n"
            }
            if let notes = event.notes, !notes.isEmpty {
                output += "  Notes: \(notes)\n"
            }
            output += "  Calendar: \(event.calendar.title)\n"
            output += "  ID: \(event.eventIdentifier ?? "unknown")\n\n"
        }

        return MCPToolResult(success: true, output: MCPOutput(content: output))
    }

    @MainActor
    private func createEvent(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestAccess(for: .event) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Calendar access denied. Please grant calendar permission in System Settings > Privacy & Security > Calendars."))
        }

        guard let title = parameters["title"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: title"))
        }
        guard let startStr = parameters["start_date"] as? String, let startDate = parseDate(startStr) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing or invalid start_date. Use ISO 8601 format (e.g., 2026-04-15T10:00:00-04:00)"))
        }

        let endDate: Date
        if let endStr = parameters["end_date"] as? String, let parsed = parseDate(endStr) {
            endDate = parsed
        } else {
            endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate)!
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = parameters["notes"] as? String
        event.location = parameters["location"] as? String

        if let calendarName = parameters["calendar_name"] as? String {
            if let calendar = eventStore.calendars(for: .event).first(where: { $0.title.lowercased() == calendarName.lowercased() }) {
                event.calendar = calendar
            } else {
                let available = eventStore.calendars(for: .event).map { $0.title }.joined(separator: ", ")
                return MCPToolResult(success: false, output: MCPOutput(content: "Calendar '\(calendarName)' not found. Available: \(available)"))
            }
        } else {
            event.calendar = eventStore.defaultCalendarForNewEvents
        }

        do {
            try eventStore.save(event, span: .thisEvent)
            logger.info("Created event: \(title)")
            return MCPToolResult(success: true, output: MCPOutput(content: "Created event '\(title)' on \(formatDate(startDate)) - \(formatDate(endDate)) in \(event.calendar.title). ID: \(event.eventIdentifier ?? "unknown")"))
        } catch {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to create event: \(error.localizedDescription)"))
        }
    }

    @MainActor
    private func searchEvents(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestAccess(for: .event) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Calendar access denied."))
        }

        guard let query = parameters["query"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: query"))
        }

        let daysAhead = parameters["days_ahead"] as? Int ?? 30
        let daysBack = parameters["days_back"] as? Int ?? 30

        let startDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date())!
        let endDate = Calendar.current.date(byAdding: .day, value: daysAhead, to: Date())!

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let allEvents = eventStore.events(matching: predicate)

        let queryLower = query.lowercased()
        let matching = allEvents.filter { event in
            (event.title?.lowercased().contains(queryLower) == true) ||
            (event.notes?.lowercased().contains(queryLower) == true) ||
            (event.location?.lowercased().contains(queryLower) == true)
        }

        if matching.isEmpty {
            return MCPToolResult(success: true, output: MCPOutput(content: "No events matching '\(query)' found in the past \(daysBack) to next \(daysAhead) days."))
        }

        var output = "Events matching '\(query)' (\(matching.count) found):\n\n"
        for event in matching.sorted(by: { $0.startDate < $1.startDate }) {
            output += "- **\(event.title ?? "Untitled")**\n"
            output += "  Start: \(formatDate(event.startDate))\n"
            output += "  End: \(formatDate(event.endDate))\n"
            if let location = event.location, !location.isEmpty {
                output += "  Location: \(location)\n"
            }
            output += "  Calendar: \(event.calendar.title)\n"
            output += "  ID: \(event.eventIdentifier ?? "unknown")\n\n"
        }

        return MCPToolResult(success: true, output: MCPOutput(content: output))
    }

    @MainActor
    private func deleteEvent(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestAccess(for: .event) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Calendar access denied."))
        }

        guard let eventId = parameters["event_id"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: event_id"))
        }

        guard let event = eventStore.event(withIdentifier: eventId) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Event not found with ID: \(eventId)"))
        }

        let title = event.title ?? "Untitled"
        do {
            try eventStore.remove(event, span: .thisEvent)
            logger.info("Deleted event: \(title)")
            return MCPToolResult(success: true, output: MCPOutput(content: "Deleted event '\(title)'."))
        } catch {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to delete event: \(error.localizedDescription)"))
        }
    }

    // MARK: - Reminders

    @MainActor
    private func listReminders(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestReminderAccess() else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Reminders access denied. Please grant permission in System Settings > Privacy & Security > Reminders."))
        }

        let includeCompleted = parameters["include_completed"] as? Bool ?? false
        let listName = parameters["list_name"] as? String

        var calendars: [EKCalendar]?
        if let name = listName {
            calendars = eventStore.calendars(for: .reminder).filter { $0.title.lowercased() == name.lowercased() }
            if calendars?.isEmpty == true {
                let available = eventStore.calendars(for: .reminder).map { $0.title }.joined(separator: ", ")
                return MCPToolResult(success: false, output: MCPOutput(content: "Reminder list '\(name)' not found. Available lists: \(available)"))
            }
        }

        let predicate: NSPredicate
        if includeCompleted {
            predicate = eventStore.predicateForReminders(in: calendars)
        } else {
            predicate = eventStore.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: calendars
            )
        }

        // Extract reminder data as Sendable types to cross actor boundary
        struct ReminderData: Sendable {
            let title: String
            let isCompleted: Bool
            let dueDate: Date?
            let priority: Int
            let notes: String?
            let calendarTitle: String
            let identifier: String
        }

        let reminderData: [ReminderData] = await withCheckedContinuation { (continuation: CheckedContinuation<[ReminderData], Never>) in
            eventStore.fetchReminders(matching: predicate) { @Sendable reminders in
                let data = (reminders ?? []).map { reminder in
                    ReminderData(
                        title: reminder.title ?? "Untitled",
                        isCompleted: reminder.isCompleted,
                        dueDate: reminder.dueDateComponents?.date,
                        priority: reminder.priority,
                        notes: reminder.notes,
                        calendarTitle: reminder.calendar.title,
                        identifier: reminder.calendarItemIdentifier
                    )
                }
                continuation.resume(returning: data)
            }
        }

        if reminderData.isEmpty {
            let scope = listName.map { " in '\($0)'" } ?? ""
            return MCPToolResult(success: true, output: MCPOutput(content: "No \(includeCompleted ? "" : "incomplete ")reminders found\(scope)."))
        }

        var output = "Reminders (\(reminderData.count) found):\n\n"
        for reminder in reminderData.sorted(by: { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }) {
            let status = reminder.isCompleted ? "[x]" : "[ ]"
            output += "\(status) **\(reminder.title)**\n"
            if let dueDate = reminder.dueDate {
                output += "  Due: \(formatDate(dueDate))\n"
            }
            if reminder.priority > 0 {
                let priorityName: String
                switch reminder.priority {
                case 1: priorityName = "High"
                case 5: priorityName = "Medium"
                case 9: priorityName = "Low"
                default: priorityName = "\(reminder.priority)"
                }
                output += "  Priority: \(priorityName)\n"
            }
            if let notes = reminder.notes, !notes.isEmpty {
                output += "  Notes: \(notes)\n"
            }
            output += "  List: \(reminder.calendarTitle)\n"
            output += "  ID: \(reminder.identifier)\n\n"
        }

        return MCPToolResult(success: true, output: MCPOutput(content: output))
    }

    @MainActor
    private func createReminder(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestReminderAccess() else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Reminders access denied. Please grant permission in System Settings > Privacy & Security > Reminders."))
        }

        guard let title = parameters["title"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: title"))
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = parameters["notes"] as? String

        if let dueDateStr = parameters["due_date"] as? String, let dueDate = parseDate(dueDateStr) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }

        if let priority = parameters["priority"] as? Int {
            reminder.priority = priority
        }

        if let listName = parameters["list_name"] as? String {
            if let calendar = eventStore.calendars(for: .reminder).first(where: { $0.title.lowercased() == listName.lowercased() }) {
                reminder.calendar = calendar
            } else {
                let available = eventStore.calendars(for: .reminder).map { $0.title }.joined(separator: ", ")
                return MCPToolResult(success: false, output: MCPOutput(content: "Reminder list '\(listName)' not found. Available: \(available)"))
            }
        } else {
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
        }

        do {
            try eventStore.save(reminder, commit: true)
            logger.info("Created reminder: \(title)")
            var result = "Created reminder '\(title)' in \(reminder.calendar.title)."
            if let due = reminder.dueDateComponents?.date {
                result += " Due: \(formatDate(due))"
            }
            result += " ID: \(reminder.calendarItemIdentifier)"
            return MCPToolResult(success: true, output: MCPOutput(content: result))
        } catch {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to create reminder: \(error.localizedDescription)"))
        }
    }

    @MainActor
    private func completeReminder(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestReminderAccess() else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Reminders access denied."))
        }

        guard let reminderId = parameters["reminder_id"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: reminder_id"))
        }

        guard let item = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Reminder not found with ID: \(reminderId)"))
        }

        item.isCompleted = true
        item.completionDate = Date()

        do {
            try eventStore.save(item, commit: true)
            logger.info("Completed reminder: \(item.title ?? "unknown")")
            return MCPToolResult(success: true, output: MCPOutput(content: "Marked '\(item.title ?? "Untitled")' as complete."))
        } catch {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to complete reminder: \(error.localizedDescription)"))
        }
    }

    @MainActor
    private func deleteReminder(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestReminderAccess() else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Reminders access denied."))
        }

        guard let reminderId = parameters["reminder_id"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: reminder_id"))
        }

        guard let item = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Reminder not found with ID: \(reminderId)"))
        }

        let title = item.title ?? "Untitled"
        do {
            try eventStore.remove(item, commit: true)
            logger.info("Deleted reminder: \(title)")
            return MCPToolResult(success: true, output: MCPOutput(content: "Deleted reminder '\(title)'."))
        } catch {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to delete reminder: \(error.localizedDescription)"))
        }
    }

    @MainActor
    private func listReminderLists() async -> MCPToolResult {
        guard await requestReminderAccess() else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Reminders access denied."))
        }

        let calendars = eventStore.calendars(for: .reminder)
        if calendars.isEmpty {
            return MCPToolResult(success: true, output: MCPOutput(content: "No reminder lists found."))
        }

        let defaultCal = eventStore.defaultCalendarForNewReminders()
        var output = "Reminder Lists (\(calendars.count)):\n\n"
        for cal in calendars.sorted(by: { $0.title < $1.title }) {
            let isDefault = cal.calendarIdentifier == defaultCal?.calendarIdentifier ? " (default)" : ""
            output += "- \(cal.title)\(isDefault)\n"
        }

        return MCPToolResult(success: true, output: MCPOutput(content: output))
    }
}
