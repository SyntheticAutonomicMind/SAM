// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP tool for dynamically increasing the maximum iteration limit during execution
/// Allows agents to request more iterations when approaching the limit for complex tasks
public final class IncreaseMaxIterationsTool: MCPTool {

    // MARK: - Protocol Conformance

    public let name = "increase_max_iterations"
    public let description = """
    Request to increase the maximum iteration limit for complex tasks.

    USE WHEN:
    - Approaching the iteration limit (e.g., at 280/300 iterations)
    - Complex task requires more iterations than initially allocated
    - Making steady progress but need more time to complete work

    REQUIREMENTS:
    - Dynamic Iterations must be ENABLED in conversation settings
    - Provide total iterations needed (not additional)
    - Include clear reason explaining why more iterations are needed

    WORKFLOW:
    1. Check current iteration count vs maxIterations
    2. Estimate total iterations needed to complete work
    3. Call this tool with requested total and reason
    4. System updates maxIterations if Dynamic Iterations enabled
    5. Continue working with increased limit

    EXAMPLES:
    - "Need 500 total iterations to complete refactoring of 50 files"
    - "Require 1000 iterations for comprehensive test coverage implementation"
    - "Working through complex bug fix, estimate 400 iterations total"

    NOTE: Tool fails if Dynamic Iterations is disabled. User must enable it first.
    """

    public var parameters: [String: MCPToolParameter] {
        return [
            "requested_iterations": MCPToolParameter(
                type: .integer,
                description: "Total number of iterations you estimate you'll need (not additional, but total). Must be greater than current maxIterations.",
                required: true
            ),
            "reason": MCPToolParameter(
                type: .string,
                description: "Clear explanation of why you need more iterations. Describe the work remaining and why it requires this many iterations.",
                required: true
            )
        ]
    }

    private let logger = Logging.Logger(label: "com.sam.mcp.IncreaseMaxIterationsTool")

    // MARK: - Lifecycle

    public func initialize() async throws {
        logger.debug("IncreaseMaxIterationsTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        /// Validate requested_iterations exists and is positive
        guard let requestedIterations = parameters["requested_iterations"] as? Int,
              requestedIterations > 0 else {
            throw MCPError.invalidParameters("requested_iterations must be a positive integer")
        }

        /// Validate reason exists and is non-empty
        guard let reason = parameters["reason"] as? String, !reason.isEmpty else {
            throw MCPError.invalidParameters("reason parameter is required and must not be empty")
        }

        return true
    }

    // MARK: - Tool Execution

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        logger.debug("IncreaseMaxIterationsTool executing")

        /// Validate required parameters
        guard let requestedIterations = parameters["requested_iterations"] as? Int else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "ERROR: 'requested_iterations' parameter is required and must be an integer")
            )
        }

        guard let reason = parameters["reason"] as? String, !reason.isEmpty else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "ERROR: 'reason' parameter is required and must not be empty")
            )
        }

        /// Check if iteration controller is available
        guard let iterationController = context.iterationController else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "ERROR: Dynamic Iterations is not enabled for this conversation. Enable it in the toolbar to use this tool.")
            )
        }

        /// Get current state
        let currentIterations = iterationController.currentIteration
        let currentMax = iterationController.maxIterations

        /// Validate requested value is greater than current max
        guard requestedIterations > currentMax else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "ERROR: Requested iterations (\(requestedIterations)) must be greater than current maxIterations (\(currentMax)). Current iteration: \(currentIterations)/\(currentMax)")
            )
        }

        /// Update maxIterations
        iterationController.updateMaxIterations(requestedIterations, reason: reason)

        logger.debug("DYNAMIC_ITERATIONS: Increased from \(currentMax) to \(requestedIterations) - Reason: \(reason)")

        return MCPToolResult(
            toolName: name,
            success: true,
            output: MCPOutput(
                content: """
                SUCCESS: Maximum iterations increased from \(currentMax) to \(requestedIterations).

                Current progress: \(currentIterations)/\(requestedIterations) iterations used.
                Remaining: \(requestedIterations - currentIterations) iterations available.

                Reason: \(reason)

                You can now continue working with the increased iteration limit.
                """,
                mimeType: "text/plain",
                additionalData: [
                    "previousMax": currentMax,
                    "newMax": requestedIterations,
                    "currentIteration": currentIterations,
                    "reason": reason
                ]
            )
        )
    }

    // MARK: - Cleanup

    public func cleanup() async {
        logger.debug("IncreaseMaxIterationsTool cleanup completed")
    }
}
