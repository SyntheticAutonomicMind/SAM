// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Injects status signal reminders into agent context EVERY turn.
public class StatusSignalReminderInjector {
    private let logger = Logging.Logger(label: "com.sam.StatusSignalReminderInjector")

    public nonisolated(unsafe) static let shared = StatusSignalReminderInjector()

    private init() {
        logger.debug("StatusSignalReminderInjector initialized - will inject reminder every turn")
    }

    /// Check if reminder should be injected based on workflow mode.
    /// CRITICAL: Only inject when workflow mode is ENABLED in ChatWidget.
    public func shouldInjectReminder(isWorkflowMode: Bool) -> Bool {
        /// Only inject reminders when workflow mode is explicitly enabled by user.
        /// Workflow mode is controlled by the toggle in ChatWidget.
        /// When disabled, the agent should NOT receive workflow signals reminders.
        if !isWorkflowMode {
            logger.debug("Status signal reminder SKIPPED - workflow mode disabled")
            return false
        }

        logger.debug("Status signal reminder will be injected - workflow mode enabled")
        return true
    }

    /// Format status signal reminder for injection into context.
    /// Provides clear guidance on when to emit status signals and what response to expect.
    public func formatStatusSignalReminder() -> String {
        return "After each step that produces output (file, search result, generated content), emit {\"status\":\"continue\"} if more work remains, or {\"status\":\"complete\"} if all work is done. The system will respond with \"continue\" to acknowledge and prompt the next step. Planning/todos alone do NOT justify continue - execute a WORK tool first."
    }
}
