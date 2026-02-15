// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Provides agents with clear, actionable error guidance when tool calls fail
///
/// When AI agents make bad tool calls (missing required params, invalid values, etc.),
/// they need clear error messages that help them fix the problem. This module:
///
/// 1. Categorizes tool errors (missing required, invalid operation, invalid params, etc.)
/// 2. Provides specific guidance for each error type
/// 3. Includes the correct schema from the tool definition
/// 4. Gives examples of correct usage
///
/// This prevents agents from abandoning tools after repeated failures.
public struct ToolErrorGuidance: Sendable {
    private let logger = Logger(label: "com.sam.mcp.error_guidance")
    
    public init() {}
    
    // MARK: - Error Categories
    
    public enum ErrorCategory: String, Sendable {
        case missingRequired = "missing_required"
        case invalidOperation = "invalid_operation"
        case invalidJson = "invalid_json"
        case invalidValue = "invalid_value"
        case insufficientParams = "insufficient_params"
        case fileNotFound = "file_not_found"
        case permissionDenied = "permission_denied"
        case networkError = "network_error"
        case timeout = "timeout"
        case genericError = "generic_error"
    }
    
    // MARK: - Public API
    
    /// Enhance a tool error with comprehensive guidance for the agent
    /// - Parameters:
    ///   - error: The error message from the tool
    ///   - toolName: Name of the tool that failed
    ///   - toolSchema: The tool's JSON schema (optional, for reference)
    ///   - attemptedParams: Parameters the agent tried to use
    /// - Returns: Enhanced error message with guidance
    public func enhanceToolError(
        error: String,
        toolName: String,
        toolSchema: [String: Any]? = nil,
        attemptedParams: [String: Any]? = nil
    ) -> String {
        // Categorize the error
        let category = categorizeError(error, toolName: toolName)
        
        var parts: [String] = []
        
        // 1. Clear error statement
        parts.append("TOOL ERROR: \(toolName)")
        parts.append(error)
        parts.append("")
        
        // 2. Guidance based on error category
        parts.append(getGuidanceForCategory(category, toolName: toolName, error: error, attemptedParams: attemptedParams, schema: toolSchema))
        
        // 3. Schema information (if available)
        if let schema = toolSchema {
            parts.append(formatSchemaHelp(toolName: toolName, schema: schema))
        }
        
        // 4. Examples
        parts.append(getExamplesForError(category, toolName: toolName))
        
        return parts.joined(separator: "\n")
    }
    
    /// Quick enhancement for common validation errors
    /// - Parameters:
    ///   - missingParam: Name of the missing required parameter
    ///   - toolName: Name of the tool
    ///   - availableOperations: List of valid operations (optional)
    /// - Returns: Clear error message with fix instructions
    public func missingRequiredParameter(
        _ missingParam: String,
        toolName: String,
        availableOperations: [String]? = nil
    ) -> String {
        var message = """
        TOOL ERROR: \(toolName)
        Missing required parameter: \(missingParam)
        
        WHAT WENT WRONG: You didn't include the required parameter '\(missingParam)'
        HOW TO FIX: Include '\(missingParam)' in your tool call parameters
        """
        
        if let operations = availableOperations, !operations.isEmpty {
            message += "\n\nVALID OPERATIONS: \(operations.joined(separator: ", "))"
        }
        
        return message
    }
    
    /// Quick enhancement for invalid operation errors
    /// - Parameters:
    ///   - invalidOperation: The operation that was attempted
    ///   - toolName: Name of the tool
    ///   - validOperations: List of valid operations
    /// - Returns: Clear error message with fix instructions
    public func invalidOperation(
        _ invalidOperation: String,
        toolName: String,
        validOperations: [String]
    ) -> String {
        return """
        TOOL ERROR: \(toolName)
        Invalid operation: '\(invalidOperation)'
        
        WHAT WENT WRONG: You used an invalid 'operation' value
        HOW TO FIX: Set 'operation' to one of the valid values
        
        VALID OPERATIONS: \(validOperations.joined(separator: ", "))
        
        EXAMPLE:
        {
            "operation": "\(validOperations.first ?? "valid_operation")",
            // ... other parameters
        }
        """
    }
    
    // MARK: - Private Helpers
    
    private func categorizeError(_ error: String, toolName: String) -> ErrorCategory {
        let lowercased = error.lowercased()
        
        if lowercased.contains("missing required") || lowercased.contains("required parameter") {
            return .missingRequired
        }
        if lowercased.contains("unknown operation") || lowercased.contains("unsupported") || lowercased.contains("invalid operation") {
            return .invalidOperation
        }
        if lowercased.contains("json") || lowercased.contains("parse error") || lowercased.contains("decoding") {
            return .invalidJson
        }
        if lowercased.contains("invalid value") || lowercased.contains("must be") || lowercased.contains("should be") {
            return .invalidValue
        }
        if lowercased.contains("insufficient") || lowercased.contains("need") {
            return .insufficientParams
        }
        if lowercased.contains("not found") || lowercased.contains("no such file") || lowercased.contains("does not exist") {
            return .fileNotFound
        }
        if lowercased.contains("permission") || lowercased.contains("denied") || lowercased.contains("access") {
            return .permissionDenied
        }
        if lowercased.contains("network") || lowercased.contains("connection") || lowercased.contains("unreachable") {
            return .networkError
        }
        if lowercased.contains("timeout") || lowercased.contains("timed out") {
            return .timeout
        }
        
        return .genericError
    }
    
    private func getGuidanceForCategory(
        _ category: ErrorCategory,
        toolName: String,
        error: String,
        attemptedParams: [String: Any]?,
        schema: [String: Any]?
    ) -> String {
        switch category {
        case .missingRequired:
            // Try to extract missing parameter name from error
            let pattern = try? NSRegularExpression(pattern: "parameter[s]?:?\\s*([a-z_]+)", options: .caseInsensitive)
            var missingParams = "the required parameter(s)"
            
            if let match = pattern?.firstMatch(in: error, range: NSRange(error.startIndex..., in: error)),
               let range = Range(match.range(at: 1), in: error) {
                missingParams = "'\(error[range])'"
            }
            
            return """
            WHAT WENT WRONG: You didn't include the required parameter(s): \(missingParams)
            HOW TO FIX: Include these required parameters in your tool call.
            REQUIRED: All parameters marked 'required' in the schema MUST be included.
            """
            
        case .invalidOperation:
            var validOps = ""
            if let schemaProps = schema?["properties"] as? [String: Any],
               let opDef = schemaProps["operation"] as? [String: Any],
               let enumValues = opDef["enum"] as? [String] {
                validOps = "\nVALID OPERATIONS: \(enumValues.joined(separator: ", "))"
            }
            
            return """
            WHAT WENT WRONG: You used an invalid 'operation' value.
            HOW TO FIX: Set 'operation' to one of the valid values.\(validOps)
            """
            
        case .invalidJson:
            return """
            WHAT WENT WRONG: The arguments JSON you provided is malformed.
            HOW TO FIX: Check your JSON syntax - all string values must be quoted, all braces/brackets must match.
            COMMON MISTAKES:
              - String without quotes: {path: /tmp/file}  (WRONG)
              - Missing comma: {path: "/tmp", content: "text" "more"} (WRONG)
              - Newlines in strings not escaped: {message: "line1\nline2"} (WRONG - use \\n)
              - Trailing comma: {"key": "value"} (WRONG)
            """
            
        case .invalidValue:
            return """
            WHAT WENT WRONG: One of your parameter values is invalid (wrong type, wrong range, etc.).
            HOW TO FIX: Check the schema to see what values are allowed for each parameter.
            """
            
        case .insufficientParams:
            return """
            WHAT WENT WRONG: You don't have enough information to complete this operation.
            HOW TO FIX: Check what parameters are needed and provide all of them.
            """
            
        case .fileNotFound:
            return """
            WHAT WENT WRONG: The file or directory you're trying to access doesn't exist.
            HOW TO FIX: Check the path is correct. Use the correct absolute or relative path.
            TIP: Use file_operations with operation "list_dir" to see what files exist.
            """
            
        case .permissionDenied:
            return """
            WHAT WENT WRONG: You don't have permission to access this file or directory.
            HOW TO FIX: Check file permissions or try a different path.
            """
            
        case .networkError:
            return """
            WHAT WENT WRONG: A network error occurred while executing the tool.
            HOW TO FIX: Check network connectivity. The target may be unreachable.
            """
            
        case .timeout:
            return """
            WHAT WENT WRONG: The operation timed out before completing.
            HOW TO FIX: Try again or increase the timeout parameter if available.
            """
            
        case .genericError:
            return """
            WHAT WENT WRONG: Tool execution failed.
            HOW TO FIX: Check the error message for details. Review the schema to ensure all parameters are correct.
            """
        }
    }
    
    private func formatSchemaHelp(toolName: String, schema: [String: Any]) -> String {
        var help: [String] = ["", "--- SCHEMA REFERENCE ---"]
        
        guard let properties = schema["properties"] as? [String: Any] else {
            return ""
        }
        
        let required = (schema["required"] as? [String]) ?? []
        let requiredSet = Set(required)
        
        help.append("")
        help.append("Parameters:")
        
        for (paramName, paramDef) in properties.sorted(by: { $0.key < $1.key }) {
            guard let definition = paramDef as? [String: Any] else { continue }
            
            let isRequired = requiredSet.contains(paramName)
            let requiredMark = isRequired ? " (REQUIRED)" : ""
            let type = definition["type"] as? String ?? "any"
            let description = definition["description"] as? String ?? ""
            
            help.append("  - \(paramName)\(requiredMark): \(type)")
            if !description.isEmpty {
                help.append("    \(description)")
            }
            
            // Show enum values if present
            if let enumValues = definition["enum"] as? [String] {
                help.append("    Valid values: \(enumValues.joined(separator: ", "))")
            }
        }
        
        return help.joined(separator: "\n")
    }
    
    private func getExamplesForError(_ category: ErrorCategory, toolName: String) -> String {
        // Tool-specific examples
        let examples: [String: String] = [
            "file_operations": """
            
            EXAMPLE (file_operations):
            {
                "operation": "read_file",
                "path": "path/to/file.txt"
            }
            """,
            "terminal_operations": """
            
            EXAMPLE (terminal_operations):
            {
                "operation": "exec",
                "command": "ls -la"
            }
            """,
            "version_control": """
            
            EXAMPLE (version_control):
            {
                "operation": "status"
            }
            """,
            "memory_operations": """
            
            EXAMPLE (memory_operations):
            {
                "operation": "store",
                "key": "my_key",
                "content": "data to store"
            }
            """,
            "todo_operations": """
            
            EXAMPLE (todo_operations):
            {
                "operation": "read"
            }
            """,
            "user_collaboration": """
            
            EXAMPLE (user_collaboration):
            {
                "operation": "request_input",
                "message": "What would you like me to do?"
            }
            """
        ]
        
        return examples[toolName] ?? """
        
        EXAMPLE (generic):
        {
            "operation": "the_operation_name",
            "param1": "value1",
            "param2": "value2"
        }
        """
    }
}
