// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Base protocol for consolidated MCP tools Consolidated MCPs combine multiple related tools into a single tool with operation-based routing.
public protocol ConsolidatedMCP: MCPTool {
    /// Operations supported by this consolidated MCP All operation names should be listed here for error messages and validation.
    var supportedOperations: [String] { get }

    /// Validate that an operation name is supported Default implementation checks if operation is in supportedOperations array.
    func validateOperation(_ operation: String) -> Bool

    /// Default operation to use when `operation` is omitted AND cannot be inferred
    /// from other parameters. LLMs sometimes call consolidated tools with completely
    /// empty arguments `{}`, leaving nothing to infer from. Each tool should
    /// specify the most common/default operation. Default: first supported operation.
    var defaultOperation: String { get }

    /// Route to specific operation implementation This is where consolidated tools implement operation-specific logic - Parameters: - operation: The operation name (e.g., "search_memory") - parameters: Tool parameters including operation-specific params - context: Execution context with conversation ID, user info, etc.
    @MainActor
    func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult

    /// Generate helpful error message when operation is invalid Default implementation shows available operations and example usage.
    func operationError(
        _ operation: String,
        message: String
    ) -> MCPToolResult

    /// Attempt to infer the operation from parameters when the `operation` parameter is omitted.
    /// LLMs frequently omit the `operation` parameter when calling consolidated tools.
    /// Default implementation returns nil (no inference). Override to provide inference.
    /// - Parameter parameters: The parameters dictionary passed to execute().
    /// - Returns: The inferred operation name, or nil if it cannot be inferred.
    func inferOperation(from parameters: [String: Any]) -> String?
}

// MARK: - Default Implementations

public extension ConsolidatedMCP {
    /// Default execute implementation for consolidated tools Extracts operation parameter and routes to appropriate handler.
    @MainActor
    func execute(
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        let logger = Logging.Logger(label: "com.sam.mcp.ConsolidatedMCP.\(name)")

        var params = parameters

        /// Extract operation parameter, with fallback to inference, then default.
        /// LLMs frequently omit the `operation` parameter on consolidated tools.
        /// Try inference first, then fall back to defaultOperation.
        var operation: String? = params["operation"] as? String
        if operation == nil {
            if let inferred = inferOperation(from: params) {
                logger.info("INFERRED_OPERATION: '\(name)' inferred operation='\(inferred)' from parameters")
                operation = inferred
                params["operation"] = inferred
            } else if !defaultOperation.isEmpty {
                logger.info("DEFAULT_OPERATION: '\(name)' using default operation='\(defaultOperation)' (no operation provided, no inference possible)")
                operation = defaultOperation
                params["operation"] = defaultOperation
            }
        }

        guard let resolvedOperation = operation else {
            logger.error("Missing 'operation' parameter for \(self.name)")
            return operationError(
                "",
                message: "Missing 'operation' parameter"
            )
        }

        /// Validate operation.
        guard validateOperation(resolvedOperation) else {
            logger.error("Unknown operation '\(resolvedOperation)' for \(self.name)")
            return operationError(
                resolvedOperation,
                message: "Unknown operation '\(resolvedOperation)'"
            )
        }

        /// Route to operation handler.
        logger.debug("Routing \(self.name) to operation: \(resolvedOperation)")
        return await routeOperation(resolvedOperation, parameters: params, context: context)
    }

    /// Default operation validation Checks if operation is in supportedOperations array.
    func validateOperation(_ operation: String) -> Bool {
        return supportedOperations.contains(operation)
    }

    /// Default: first supported operation. Override when the most common
    /// operation is not first in the list.
    var defaultOperation: String {
        return supportedOperations.first ?? ""
    }

    /// Default: no operation inference. Override in concrete tools.
    func inferOperation(from parameters: [String: Any]) -> String? {
        return nil
    }

    /// Override of MCPTool.validateParameters that allows `operation` inference
    /// for consolidated tools. If the operation is provided, validate it.
    /// If it's missing but can be inferred, allow it. Otherwise reject.
    func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        if let operation = parameters["operation"] as? String {
            guard validateOperation(operation) else {
                throw MCPError.invalidParameters("Unknown operation '\(operation)'. Valid operations: \(supportedOperations.joined(separator: ", "))")
            }
            return true
        }
        // No explicit operation, but inference or default may save us.
        if inferOperation(from: parameters) != nil || !defaultOperation.isEmpty {
            return true
        }
        throw MCPError.invalidParameters("Missing 'operation' parameter")
    }

    /// Default error message generation Shows available operations and example usage.
    func operationError(_ operation: String, message: String) -> MCPToolResult {
        let errorMessage = """
        ERROR: \(message)

        Available operations for '\(name)':
        \(supportedOperations.map { "  - \($0)" }.joined(separator: "\n"))

        Example usage:
        {
          "tool": "\(name)",
          "operation": "\(supportedOperations.first ?? "operation_name")",
          ... other parameters depending on operation
        }

        Tip: Each operation may have different required parameters.
        """

        return MCPToolResult(
            toolName: name,
            success: false,
            output: MCPOutput(content: errorMessage)
        )
    }
}

// MARK: - Helper Methods

/// Parameter extraction error.
public enum ParameterError: Error {
    case missing(String)
    case invalidType(String)

    public var message: String {
        switch self {
        case .missing(let msg): return msg
        case .invalidType(let msg): return msg
        }
    }
}

/// Helper functions for consolidated MCPs to extract operation-specific parameters.
public extension ConsolidatedMCP {
    /// Extract required string parameter.
    func requireString(_ parameters: [String: Any], key: String) -> Result<String, ParameterError> {
        guard let value = parameters[key] as? String else {
            return .failure(.missing("Missing required parameter '\(key)' (string)"))
        }
        return .success(value)
    }

    /// Extract optional string parameter.
    func optionalString(_ parameters: [String: Any], key: String, default defaultValue: String? = nil) -> String? {
        return (parameters[key] as? String) ?? defaultValue
    }

    /// Extract required integer parameter.
    func requireInt(_ parameters: [String: Any], key: String) -> Result<Int, ParameterError> {
        if let value = parameters[key] as? Int {
            return .success(value)
        }
        if let value = parameters[key] as? Double {
            return .success(Int(value))
        }
        return .failure(.missing("Missing required parameter '\(key)' (integer)"))
    }

    /// Extract optional integer parameter.
    func optionalInt(_ parameters: [String: Any], key: String, default defaultValue: Int? = nil) -> Int? {
        if let value = parameters[key] as? Int {
            return value
        }
        if let value = parameters[key] as? Double {
            return Int(value)
        }
        return defaultValue
    }

    /// Extract required double parameter.
    func requireDouble(_ parameters: [String: Any], key: String) -> Result<Double, ParameterError> {
        if let value = parameters[key] as? Double {
            return .success(value)
        }
        if let value = parameters[key] as? Int {
            return .success(Double(value))
        }
        return .failure(.missing("Missing required parameter '\(key)' (number)"))
    }

    /// Extract optional double parameter.
    func optionalDouble(_ parameters: [String: Any], key: String, default defaultValue: Double? = nil) -> Double? {
        if let value = parameters[key] as? Double {
            return value
        }
        if let value = parameters[key] as? Int {
            return Double(value)
        }
        return defaultValue
    }

    /// Extract required boolean parameter.
    func requireBool(_ parameters: [String: Any], key: String) -> Result<Bool, ParameterError> {
        guard let value = parameters[key] as? Bool else {
            return .failure(.missing("Missing required parameter '\(key)' (boolean)"))
        }
        return .success(value)
    }

    /// Extract optional boolean parameter.
    func optionalBool(_ parameters: [String: Any], key: String, default defaultValue: Bool? = nil) -> Bool? {
        return (parameters[key] as? Bool) ?? defaultValue
    }

    /// Extract required array parameter.
    func requireArray<T>(_ parameters: [String: Any], key: String) -> Result<[T], ParameterError> {
        guard let value = parameters[key] as? [T] else {
            return .failure(.missing("Missing required parameter '\(key)' (array)"))
        }
        return .success(value)
    }

    /// Extract optional array parameter.
    func optionalArray<T>(_ parameters: [String: Any], key: String, default defaultValue: [T]? = nil) -> [T]? {
        return (parameters[key] as? [T]) ?? defaultValue
    }

    /// Create error result with custom message.
    func errorResult(_ message: String) -> MCPToolResult {
        return MCPToolResult(
            toolName: name,
            success: false,
            output: MCPOutput(content: "ERROR: \(message)")
        )
    }

    /// Create success result with content.
    func successResult(_ content: String, additionalData: [String: Any] = [:]) -> MCPToolResult {
        return MCPToolResult(
            toolName: name,
            success: true,
            output: MCPOutput(content: content, additionalData: additionalData)
        )
    }
}
