// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// WorkflowConfiguration.swift SAM Centralized workflow configuration constants Single source of truth for workflow parameters.

import Foundation

/// Centralized workflow configuration Consolidates previously scattered constants into single source of truth.
public struct WorkflowConfiguration {
    /// Default maximum iterations for autonomous workflow execution Can be customized by users in Preferences → General → Workflow Settings Range: 1-1000, Default: 300 Used by AgentOrchestrator, SAMAPIServer, and ChatWidget INCREASED from 100 to 300 (November 13, 2025) to support complex workflows: - SSH sessions + package installation + builds (llama.cpp install workflow) - Multi-step debugging and troubleshooting - Extended file editing and refactoring sessions.
    public static var defaultMaxIterations: Int {
        /// Read from UserDefaults if set, otherwise use hardcoded default.
        let stored = UserDefaults.standard.integer(forKey: "workflow.maxIterations")
        return stored > 0 ? stored : 300
    }

    /// Iteration threshold for user confirmation (80% of max) When iteration reaches this threshold, prompt user to continue or stop.
    public static var confirmationThreshold: Int {
        return Int(Double(defaultMaxIterations) * 0.8)
    }

    /// Future: Add other workflow constants here as needed - defaultTimeout - defaultRetryAttempts - etc.
}
