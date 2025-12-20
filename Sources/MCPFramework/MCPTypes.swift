// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

// MARK: - Protocol Conformance

/// Protocol for terminal command execution in UI This protocol allows MCP tools to execute commands in the visible embedded terminal without creating a module dependency on UserInterface.
@MainActor
public protocol TerminalCommandExecutor: AnyObject {
    /// Execute a command in the terminal and display output in UI - Parameter command: The shell command to execute - Returns: Command output (stdout + stderr combined).
    func executeCommand(_ command: String) async -> String
}

/// Protocol for accessing orchestrator iteration control from tools.
@MainActor
public protocol IterationController: AnyObject {
    /// Current iteration number
    var currentIteration: Int { get }

    /// Maximum iterations allowed
    var maxIterations: Int { get }

    /// Update the maximum iterations limit
    /// - Parameters:
    /// - newValue: The new maximum iteration limit
    /// - reason: Explanation for the increase
    func updateMaxIterations(_ newValue: Int, reason: String)
}

// MARK: - Protocol Conformance

/// Execution context for MCP tool operations.
public struct MCPExecutionContext: @unchecked Sendable {
    public let conversationId: UUID?
    public let userId: String?
    public let sessionId: UUID
    public let timestamp: Date
    public let metadata: [String: Any]

    /// Tool call ID from the LLM (e.g., GitHub Copilot's "call_XYZ..." format) Critical for user_collaboration tool to match responses with requests.
    public let toolCallId: String?

    /// Flag indicating if this tool is being called by an external API client vs SAM's internal autonomous workflow.
    public let isExternalAPICall: Bool

    /// Flag indicating if this tool execution originated from a direct user request vs autonomous agent decision.
    public let isUserInitiated: Bool

    /// Original user request text for security audit logging Captures what the user actually asked for to validate tool appropriateness.
    public let userRequestText: String?

    /// Working directory for this conversation All file operations should resolve relative paths against this directory Terminal commands should execute in this directory by default.
    public let workingDirectory: String?

    /// Terminal manager for this conversation (if UI terminal is available) When set, terminal operations will execute in the visible terminal When nil, terminal operations use invisible Process instances.
    public let terminalManager: AnyObject?

    /// Orchestrator for iteration control (allows tools to increase maxIterations dynamically).
    public let iterationController: IterationController?

    /// Effective scope ID for memory/data isolation
    /// When shared data DISABLED: equals conversationId
    /// When shared data ENABLED: equals sharedTopicId
    /// Memory operations use this for scoping to enable topic-shared memories
    public let effectiveScopeId: UUID?

    public init(
        conversationId: UUID? = nil,
        userId: String? = nil,
        sessionId: UUID = UUID(),
        timestamp: Date = Date(),
        metadata: [String: Any] = [:],
        toolCallId: String? = nil,
        isExternalAPICall: Bool = false,
        isUserInitiated: Bool = false,
        userRequestText: String? = nil,
        workingDirectory: String? = nil,
        terminalManager: AnyObject? = nil,
        iterationController: IterationController? = nil,
        effectiveScopeId: UUID? = nil
    ) {
        self.conversationId = conversationId
        self.userId = userId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.metadata = metadata
        self.toolCallId = toolCallId
        self.isExternalAPICall = isExternalAPICall
        self.isUserInitiated = isUserInitiated
        self.userRequestText = userRequestText
        self.workingDirectory = workingDirectory
        self.terminalManager = terminalManager
        self.iterationController = iterationController
        self.effectiveScopeId = effectiveScopeId ?? conversationId  // Default to conversationId if not specified
    }
}

/// Core MCP Tool protocol defining the interface for all MCP tools SAM's MCP tool architecture for extensible LLM tool integration.
public protocol MCPTool: Sendable {
    /// Unique identifier for the tool.
    var name: String { get }

    /// Human-readable description of what the tool does.
    var description: String { get }

    /// Parameter definitions for tool input validation.
    var parameters: [String: MCPToolParameter] { get }

    /// Initialize the tool (async setup if needed).
    @MainActor
    func initialize() async throws

    /// Execute the tool with provided parameters and context.
    @MainActor
    func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult

    /// Validate that provided parameters match the tool's requirements.
    func validateParameters(_ parameters: [String: Any]) throws -> Bool

    // MARK: - Execution Control Properties

    /// Whether this tool execution blocks the workflow (must complete before workflow continues) Examples: user_collaboration (waits for user), foreground terminal commands Default: false (non-blocking, can run in parallel).
    var requiresBlocking: Bool { get }

    /// Whether this tool must execute serially (one at a time, no parallelization) Examples: file operations to prevent race conditions Default: false (can run in parallel with other tools).
    var requiresSerial: Bool { get }
}

/// Extension providing default values for execution control.
public extension MCPTool {
    /// Default: tools don't block workflow unless explicitly overridden.
    var requiresBlocking: Bool { false }

    /// Default: tools can run in parallel unless explicitly overridden.
    var requiresSerial: Bool { false }
}

/// Parameter definition for MCP tools.
public struct MCPToolParameter {
    public let type: MCPParameterType
    public let description: String
    public let required: Bool
    public let enumValues: [String]?
    public let arrayElementType: MCPParameterType?

    public init(
        type: MCPParameterType,
        description: String,
        required: Bool = false,
        enumValues: [String]? = nil,
        arrayElementType: MCPParameterType? = nil
    ) {
        self.type = type
        self.description = description
        self.required = required
        self.enumValues = enumValues
        self.arrayElementType = arrayElementType
    }
}

/// Parameter type enumeration.
public enum MCPParameterType {
    case string
    case integer
    case boolean
    case array
    case object(properties: [String: MCPToolParameter])

    public var description: String {
        switch self {
        case .string: return "string"
        case .integer: return "integer"
        case .boolean: return "boolean"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

// MARK: - MCP Progress Events (for nested tool hierarchy)

/// Progress event emitted by MCP tools during execution Enables parent tools to report sub-tool executions for nested UI display.
/// Note: ToolDisplayData is defined in ConfigurationSystem to avoid circular dependencies
/// The display field is typed as Any? and should be cast to ToolDisplayData in consuming code
public struct MCPProgressEvent: @unchecked Sendable {
    /// Type of progress event.
    public enum EventType: String, Sendable {
        case toolStarted
        case toolCompleted
        case toolFailed
        case progress
        case userMessage
    }

    public let eventType: EventType
    public let toolName: String
    public let parentToolName: String?

    /// Structured display data (preferred method for UI rendering)
    /// Type: ToolDisplayData? (from ConfigurationSystem, stored as Any? to avoid circular dependency)
    public let display: Any?

    public let status: String?

    /// String-based message (deprecated, kept for backward compatibility)
    public let message: String?

    public let details: [String]?
    public let timestamp: Date

    public init(
        eventType: EventType,
        toolName: String,
        parentToolName: String? = nil,
        display: Any? = nil,
        status: String? = nil,
        message: String? = nil,
        details: [String]? = nil,
        timestamp: Date = Date()
    ) {
        self.eventType = eventType
        self.toolName = toolName
        self.parentToolName = parentToolName
        self.display = display
        self.status = status
        self.message = message
        self.details = details
        self.timestamp = timestamp
    }
}

// MARK: - MCP Tool Result

public struct MCPToolResult: Sendable {
    public let toolName: String
    public let executionId: UUID
    public let success: Bool
    public let output: MCPOutput
    public let metadata: MCPResultMetadata
    public let performance: MCPPerformanceMetrics?
    public let progressEvents: [MCPProgressEvent]

    public init(
        toolName: String,
        executionId: UUID = UUID(),
        success: Bool,
        output: MCPOutput,
        metadata: MCPResultMetadata = MCPResultMetadata(),
        performance: MCPPerformanceMetrics? = nil,
        progressEvents: [MCPProgressEvent] = []
    ) {
        self.toolName = toolName
        self.executionId = executionId
        self.success = success
        self.output = output
        self.metadata = metadata
        self.performance = performance
        self.progressEvents = progressEvents
    }

    /// Convenience initializer for simple results.
    public init(success: Bool, output: MCPOutput, toolName: String = "unknown") {
        self.init(
            toolName: toolName,
            success: success,
            output: output,
            progressEvents: []
        )
    }
}

/// Output data from MCP tool execution.
public struct MCPOutput: @unchecked Sendable {
    public let content: String
    public let mimeType: String
    public let additionalData: [String: Any]

    public init(
        content: String,
        mimeType: String = "text/plain",
        additionalData: [String: Any] = [:]
    ) {
        self.content = content
        self.mimeType = mimeType
        self.additionalData = additionalData
    }
}

/// Metadata for MCP tool results.
public struct MCPResultMetadata: Sendable {
    public let timestamp: Date
    public let version: String
    public let additionalContext: [String: String]

    public init(
        timestamp: Date = Date(),
        version: String = "1.0",
        additionalContext: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.version = version
        self.additionalContext = additionalContext
    }
}

/// Performance metrics for MCP tool execution.
public struct MCPPerformanceMetrics: Sendable {
    public let executionTimeMs: Double
    public let memoryUsageBytes: UInt64?
    public let networkRequestCount: Int?

    public init(
        executionTimeMs: Double,
        memoryUsageBytes: UInt64? = nil,
        networkRequestCount: Int? = nil
    ) {
        self.executionTimeMs = executionTimeMs
        self.memoryUsageBytes = memoryUsageBytes
        self.networkRequestCount = networkRequestCount
    }
}

// MARK: - Error Types

/// MCP error types for standardized error handling.
public enum MCPError: Error, LocalizedError {
    case toolNotFound(String)
    case invalidParameters(String)
    case executionFailed(String)
    case timeout(TimeInterval)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case let .toolNotFound(toolName):
            return "MCP tool not found: \(toolName)"

        case let .invalidParameters(message):
            return "Invalid parameters: \(message)"

        case let .executionFailed(message):
            return "Tool execution failed: \(message)"

        case let .timeout(duration):
            return "Operation timed out after \(duration) seconds"

        case let .permissionDenied(operation):
            return "Permission denied: \(operation)"
        }
    }
}

// MARK: - Protocol Conformance

/// Memory content types for categorization.
public enum MemoryContentType: String, CaseIterable {
    case interaction = "interaction"
    case fact = "fact"
    case preference = "preference"
    case task = "task"
    case document = "document"
}

/// Memory entry protocol.
public protocol MemoryEntry: Sendable {
    var id: UUID { get }
    var content: String { get }
    var context: String { get }
    var contentType: MemoryContentType { get }
    var importance: Double { get }
    var timestamp: Date { get }
    var tags: [String] { get }
    var relevanceScore: Double? { get }
}

/// Memory statistics protocol.
public protocol MemoryStatistics: Sendable {
    var totalMemories: Int { get }
    var interactionCount: Int { get }
    var factCount: Int { get }
    var preferenceCount: Int { get }
    var taskCount: Int { get }
    var documentCount: Int { get }
    var recentMemories: Int { get }
    var averageImportance: Double { get }
}

/// Memory manager protocol (to avoid importing ConversationEngine).
public protocol MemoryManagerProtocol: AnyObject, Sendable {
    func searchMemories(query: String, limit: Int, similarityThreshold: Double?, conversationId: UUID?) async throws -> [MemoryEntry]
    @MainActor
    func storeMemory(content: String, contentType: MemoryContentType, context: String, conversationId: String?, tags: [String]) async throws -> UUID
    func getMemoryStatistics() async throws -> MemoryStatistics
    func getConversationMemories(conversationId: String, limit: Int) async throws -> [MemoryEntry]
    func getRecentMemories(limit: Int) async throws -> [MemoryEntry]
}

// MARK: - Default MCPTool Implementations

/// Default implementations for MCPTool protocol.
public extension MCPTool {
    func initialize() async throws {
        /// Default: no initialization required.
    }

    func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        /// Default implementation validates required parameters exist.
        for (paramName, paramDef) in self.parameters {
            if paramDef.required {
                guard parameters[paramName] != nil else {
                    throw MCPError.invalidParameters("Required parameter '\(paramName)' is missing")
                }
            }
        }
        return true
    }
}
