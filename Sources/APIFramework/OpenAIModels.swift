// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Vapor
import ConfigurationSystem

// MARK: - OpenAI API Request/Response Models

public struct OpenAITool: Content {
    public let type: String
    public let function: OpenAIFunction

    public init(type: String = "function", function: OpenAIFunction) {
        self.type = type
        self.function = function
    }
}

/// OpenAI function definition.
public struct OpenAIFunction: Content {
    public let name: String
    public let description: String
    public let parametersJson: String

    public init(name: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.description = description

        /// Convert parameters to JSON string for Sendable compliance.
        if let data = try? JSONSerialization.data(withJSONObject: parameters),
           let json = String(data: data, encoding: .utf8) {
            self.parametersJson = json
        } else {
            self.parametersJson = "{}"
        }
    }

    public init(name: String, description: String, parametersJson: String) {
        self.name = name
        self.description = description
        self.parametersJson = parametersJson
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case parametersJson = "parameters"
    }
}

/// Helper for encoding/decoding Any values.
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)

        case let int as Int:
            try container.encode(int)

        case let double as Double:
            try container.encode(double)

        case let string as String:
            try container.encode(string)

        case let array as [Any]:
            try container.encode(array.map(AnyCodable.init))

        case let dict as [String: Any]:
            try container.encode(dict.mapValues(AnyCodable.init))

        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Cannot encode value"))
        }
    }
}

/// OpenAI-compatible chat completion request.
public struct OpenAIChatRequest: Content {
    public let model: String
    public let messages: [OpenAIChatMessage]
    public let temperature: Double?
    public let topP: Double?
    public let repetitionPenalty: Double?
    public let maxTokens: Int?
    public let stream: Bool?
    public let tools: [OpenAITool]?

    /// SAM-specific extensions for advanced configuration.
    public let samConfig: SAMConfig?

    /// OpenAI-compatible shared memory and context parameters.
    public let contextId: String?
    public let enableMemory: Bool?
    public let sessionId: String?

    /// SAM conversation ID (UUID) for conversation-scoped operations Maps to ConversationModel.id - used with exported conversations.
    public let conversationId: String?

    /// GitHub Copilot session continuity marker (from previous response) Prevents multiple premium billing charges during tool calling iterations.
    public let statefulMarker: String?

    /// Iteration number for tool calling loop (0 = initial user request, 1+ = agent continuation) Used to set X-Initiator header: 0 = 'user', 1+ = 'agent' (fixes billing bug).
    public let iterationNumber: Int?

    /// Topic folder ID for conversation context (e.g., "vscode-copilot-chat" from reference/ directory)
    public let topic: String?

    /// Mini-prompt names to enable for this conversation
    public let miniPrompts: [String]?

    public init(model: String, messages: [OpenAIChatMessage], temperature: Double? = nil, topP: Double? = nil, repetitionPenalty: Double? = nil, maxTokens: Int? = nil, stream: Bool? = nil, tools: [OpenAITool]? = nil, samConfig: SAMConfig? = nil, contextId: String? = nil, enableMemory: Bool? = nil, sessionId: String? = nil, conversationId: String? = nil, statefulMarker: String? = nil, iterationNumber: Int? = nil, topic: String? = nil, miniPrompts: [String]? = nil) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.maxTokens = maxTokens
        self.stream = stream
        self.tools = tools
        self.samConfig = samConfig
        self.contextId = contextId
        self.enableMemory = enableMemory
        self.sessionId = sessionId
        self.conversationId = conversationId
        self.statefulMarker = statefulMarker
        self.iterationNumber = iterationNumber
        self.topic = topic
        self.miniPrompts = miniPrompts
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, tools
        case topP = "top_p"
        case repetitionPenalty = "repetition_penalty"
        case maxTokens = "max_tokens"
        case samConfig = "sam_config"
        case contextId = "context_id"
        case enableMemory = "enable_memory"
        case sessionId = "session_id"
        case conversationId = "conversation_id"  // Support snake_case (standard API format)
        case statefulMarker = "stateful_marker"
        case iterationNumber = "iteration_number"
        case topic
        case miniPrompts = "mini_prompts"
    }
}

/// SAM-specific configuration extensions.
public struct SAMConfig: Content {
    public let sharedMemoryEnabled: Bool?
    public let mcpToolsEnabled: Bool?
    public let memoryCollectionId: String?
    public let conversationTitle: String?
    public let maxIterations: Int?
    public let enableReasoning: Bool?
    public let workingDirectory: String?
    public let systemPromptId: String?
    public let isExternalAPICall: Bool?
    public let loopDetectorConfig: LoopDetector.Configuration?
    public let enableTerminalAccess: Bool?
    public let enableWorkflowMode: Bool?
    public let enableDynamicIterations: Bool?

    public init(sharedMemoryEnabled: Bool? = nil, mcpToolsEnabled: Bool? = nil, memoryCollectionId: String? = nil, conversationTitle: String? = nil, maxIterations: Int? = nil, enableReasoning: Bool? = nil, workingDirectory: String? = nil, systemPromptId: String? = nil, isExternalAPICall: Bool? = nil, loopDetectorConfig: LoopDetector.Configuration? = nil, enableTerminalAccess: Bool? = nil, enableWorkflowMode: Bool? = nil, enableDynamicIterations: Bool? = nil) {
        self.sharedMemoryEnabled = sharedMemoryEnabled
        self.mcpToolsEnabled = mcpToolsEnabled
        self.memoryCollectionId = memoryCollectionId
        self.conversationTitle = conversationTitle
        self.maxIterations = maxIterations
        self.enableReasoning = enableReasoning
        self.workingDirectory = workingDirectory
        self.systemPromptId = systemPromptId
        self.isExternalAPICall = isExternalAPICall
        self.loopDetectorConfig = loopDetectorConfig
        self.enableTerminalAccess = enableTerminalAccess
        self.enableWorkflowMode = enableWorkflowMode
        self.enableDynamicIterations = enableDynamicIterations
    }

    enum CodingKeys: String, CodingKey {
        case sharedMemoryEnabled = "shared_memory_enabled"
        case mcpToolsEnabled = "mcp_tools_enabled"
        case memoryCollectionId = "memory_collection_id"
        case conversationTitle = "conversation_title"
        case maxIterations = "max_iterations"
        case enableReasoning = "enable_reasoning"
        case workingDirectory = "working_directory"
        case systemPromptId = "system_prompt_id"
        case isExternalAPICall = "is_external_api_call"
        case loopDetectorConfig = "loop_detector_config"
        case enableTerminalAccess = "enable_terminal_access"
        case enableWorkflowMode = "enable_workflow_mode"
        case enableDynamicIterations = "enable_dynamic_iterations"
    }
}

public enum ServerOpenAIRole: String, Codable {
    case system, user, assistant, tool
}

/// OpenAI chat message DESIGN NOTE: Content is optional to support OpenAI tool calling where assistant messages may contain only tool_calls without text content.
public struct OpenAIChatMessage: Content, Sendable {
    public let id: String?  // Message ID for stateful marker tracking
    public let role: String
    public let content: String?
    public let toolCalls: [OpenAIToolCall]?
    public let toolCallId: String?

    /// Standard message constructor (backward compatible).
    public init(role: String, content: String) {
        self.id = nil  // Legacy messages don't have IDs
        self.role = role
        self.content = content
        self.toolCalls = nil
        self.toolCallId = nil
    }

    /// Tool calling constructor (future use).
    public init(role: String, content: String?, toolCalls: [OpenAIToolCall]?) {
        self.id = nil
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = nil
    }

    /// Tool result constructor (future use).
    public init(role: String, content: String, toolCallId: String) {
        self.id = nil
        self.role = role
        self.content = content
        self.toolCalls = nil
        self.toolCallId = toolCallId
    }
    
    /// Message constructor with ID for stateful marker tracking.
    public init(id: String?, role: String, content: String?, toolCalls: [OpenAIToolCall]? = nil, toolCallId: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
}

/// OpenAI tool call structure.
public struct OpenAIToolCall: Content, Sendable {
    public let id: String
    public let type: String
    public let function: OpenAIFunctionCall
    public let index: Int?

    public init(id: String, type: String = "function", function: OpenAIFunctionCall, index: Int? = nil) {
        self.id = id
        self.type = type
        self.function = function
        self.index = index
    }
}

/// OpenAI function call structure.
public struct OpenAIFunctionCall: Content, Sendable {
    public let name: String
    public let arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

/// OpenAI-compatible chat completion response.
public struct ServerOpenAIChatResponse: Content, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [OpenAIChatChoice]
    public let usage: ServerOpenAIUsage

    /// GitHub Copilot response ID for conversation continuity For Chat Completions API: equals id field For Responses API: extracted from completed event.
    public let statefulMarker: String?

    /// SAM-specific enhanced metadata (provider info, model capabilities, workflow details, cost estimates)
    /// Optional to maintain backward compatibility - only included when SAM processes the request
    public let samMetadata: SAMResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
        case statefulMarker = "stateful_marker"
        case samMetadata = "sam_metadata"
    }

    public init(id: String, object: String, created: Int, model: String, choices: [OpenAIChatChoice], usage: ServerOpenAIUsage, statefulMarker: String? = nil, samMetadata: SAMResponseMetadata? = nil) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
        self.statefulMarker = statefulMarker ?? id
        self.samMetadata = samMetadata
    }
}

/// OpenAI chat choice.
/// Content filter result for a specific category
public struct ContentFilterCategoryResult: Content, Sendable {
    public let filtered: Bool
    public let severity: String?

    public init(filtered: Bool, severity: String? = nil) {
        self.filtered = filtered
        self.severity = severity
    }
}

/// Content filter results from API response
public struct ContentFilterResults: Content, Sendable {
    public let violence: ContentFilterCategoryResult?
    public let hate: ContentFilterCategoryResult?
    public let sexual: ContentFilterCategoryResult?
    public let selfHarm: ContentFilterCategoryResult?

    enum CodingKeys: String, CodingKey {
        case violence, hate, sexual
        case selfHarm = "self_harm"
    }

    public init(violence: ContentFilterCategoryResult? = nil,
                hate: ContentFilterCategoryResult? = nil,
                sexual: ContentFilterCategoryResult? = nil,
                selfHarm: ContentFilterCategoryResult? = nil) {
        self.violence = violence
        self.hate = hate
        self.sexual = sexual
        self.selfHarm = selfHarm
    }

    /// Get a user-friendly description of which filter(s) triggered
    public func getTriggeredFilters() -> String? {
        var triggered: [String] = []
        if violence?.filtered == true { triggered.append("violence") }
        if hate?.filtered == true { triggered.append("hate") }
        if sexual?.filtered == true { triggered.append("sexual") }
        if selfHarm?.filtered == true { triggered.append("self-harm") }

        if triggered.isEmpty {
            return nil
        } else if triggered.count == 1 {
            return triggered[0]
        } else {
            return triggered.dropLast().joined(separator: ", ") + " and " + triggered.last!
        }
    }
}

public struct OpenAIChatChoice: Content, Sendable {
    public let index: Int
    public let message: OpenAIChatMessage
    public let finishReason: String
    public let contentFilterResults: ContentFilterResults?

    enum CodingKeys: String, CodingKey {
        case index, message
        case finishReason = "finish_reason"
        case contentFilterResults = "content_filter_results"
    }

    public init(index: Int, message: OpenAIChatMessage, finishReason: String, contentFilterResults: ContentFilterResults? = nil) {
        self.index = index
        self.message = message
        self.finishReason = finishReason
        self.contentFilterResults = contentFilterResults
    }
}

/// OpenAI usage statistics.
public struct ServerOpenAIUsage: Content, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

// MARK: - SAM Enhanced Metadata

/// SAM-specific metadata extension for API responses.
/// Provides additional context beyond standard OpenAI format.
public struct SAMResponseMetadata: Content, Sendable {
    /// Provider information
    public let provider: SAMProviderInfo

    /// Model capabilities and limits
    public let modelInfo: SAMModelInfo

    /// Workflow execution details (for autonomous requests)
    public let workflow: SAMWorkflowInfo?

    /// Cost estimation (when available)
    public let costEstimate: SAMCostEstimate?

    /// Raw provider response metadata (passthrough)
    public let providerMetadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case provider
        case modelInfo = "model_info"
        case workflow
        case costEstimate = "cost_estimate"
        case providerMetadata = "provider_metadata"
    }

    public init(
        provider: SAMProviderInfo,
        modelInfo: SAMModelInfo,
        workflow: SAMWorkflowInfo? = nil,
        costEstimate: SAMCostEstimate? = nil,
        providerMetadata: [String: String]? = nil
    ) {
        self.provider = provider
        self.modelInfo = modelInfo
        self.workflow = workflow
        self.costEstimate = costEstimate
        self.providerMetadata = providerMetadata
    }
}

/// Information about the provider that fulfilled the request.
public struct SAMProviderInfo: Content, Sendable {
    /// Provider type (openai, anthropic, github_copilot, mlx, gguf, custom)
    public let type: String

    /// Provider display name
    public let name: String

    /// Whether this is a local (on-device) or remote (API) provider
    public let isLocal: Bool

    /// Base URL (for remote providers, sanitized)
    public let baseUrl: String?

    enum CodingKeys: String, CodingKey {
        case type, name
        case isLocal = "is_local"
        case baseUrl = "base_url"
    }

    public init(type: String, name: String, isLocal: Bool, baseUrl: String? = nil) {
        self.type = type
        self.name = name
        self.isLocal = isLocal
        self.baseUrl = baseUrl
    }
}

/// Model capability and sizing information.
public struct SAMModelInfo: Content, Sendable {
    /// Maximum context window size (tokens)
    public let contextWindow: Int

    /// Maximum output tokens (if known)
    public let maxOutputTokens: Int?

    /// Whether model supports tool/function calling
    public let supportsTools: Bool

    /// Whether model supports vision/images
    public let supportsVision: Bool

    /// Whether model supports streaming
    public let supportsStreaming: Bool

    /// Model family (e.g., "gpt-4", "claude-3", "llama")
    public let family: String?

    enum CodingKeys: String, CodingKey {
        case contextWindow = "context_window"
        case maxOutputTokens = "max_output_tokens"
        case supportsTools = "supports_tools"
        case supportsVision = "supports_vision"
        case supportsStreaming = "supports_streaming"
        case family
    }

    public init(
        contextWindow: Int,
        maxOutputTokens: Int? = nil,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        supportsStreaming: Bool = true,
        family: String? = nil
    ) {
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.supportsStreaming = supportsStreaming
        self.family = family
    }
}

/// Workflow execution information for autonomous requests.
public struct SAMWorkflowInfo: Content, Sendable {
    /// Number of iterations executed
    public let iterations: Int

    /// Maximum iterations allowed
    public let maxIterations: Int

    /// Number of tool calls made
    public let toolCallCount: Int

    /// Names of tools used (deduplicated)
    public let toolsUsed: [String]

    /// Total workflow duration in seconds
    public let durationSeconds: Double

    /// Completion reason
    public let completionReason: String

    /// Whether any errors occurred
    public let hadErrors: Bool

    enum CodingKeys: String, CodingKey {
        case iterations
        case maxIterations = "max_iterations"
        case toolCallCount = "tool_call_count"
        case toolsUsed = "tools_used"
        case durationSeconds = "duration_seconds"
        case completionReason = "completion_reason"
        case hadErrors = "had_errors"
    }

    public init(
        iterations: Int,
        maxIterations: Int,
        toolCallCount: Int,
        toolsUsed: [String],
        durationSeconds: Double,
        completionReason: String,
        hadErrors: Bool
    ) {
        self.iterations = iterations
        self.maxIterations = maxIterations
        self.toolCallCount = toolCallCount
        self.toolsUsed = toolsUsed
        self.durationSeconds = durationSeconds
        self.completionReason = completionReason
        self.hadErrors = hadErrors
    }
}

/// Cost estimation for the request.
public struct SAMCostEstimate: Content, Sendable {
    /// Estimated cost in USD (when pricing data available)
    public let estimatedCostUsd: Double?

    /// Cost per 1K prompt tokens (if known)
    public let promptCostPer1k: Double?

    /// Cost per 1K completion tokens (if known)
    public let completionCostPer1k: Double?

    /// Currency (always "USD" for now)
    public let currency: String

    /// Note about estimation accuracy
    public let note: String?

    enum CodingKeys: String, CodingKey {
        case estimatedCostUsd = "estimated_cost_usd"
        case promptCostPer1k = "prompt_cost_per_1k"
        case completionCostPer1k = "completion_cost_per_1k"
        case currency
        case note
    }

    public init(
        estimatedCostUsd: Double? = nil,
        promptCostPer1k: Double? = nil,
        completionCostPer1k: Double? = nil,
        currency: String = "USD",
        note: String? = nil
    ) {
        self.estimatedCostUsd = estimatedCostUsd
        self.promptCostPer1k = promptCostPer1k
        self.completionCostPer1k = completionCostPer1k
        self.currency = currency
        self.note = note
    }
}

/// OpenAI models list response.
public struct ServerOpenAIModelsResponse: Content {
    public let object: String
    public let data: [ServerOpenAIModel]

    public init(object: String, data: [ServerOpenAIModel]) {
        self.object = object
        self.data = data
    }
}

/// OpenAI model information.
public struct ServerOpenAIModel: Content {
    public let id: String
    public let object: String
    public let created: Int
    public let ownedBy: String

    enum CodingKeys: String, CodingKey {
        case id, object, created
        case ownedBy = "owned_by"
    }

    public init(id: String, object: String, created: Int, ownedBy: String) {
        self.id = id
        self.object = object
        self.created = created
        self.ownedBy = ownedBy
    }
}

// MARK: - Streaming Response Models

/// OpenAI-compatible streaming chat completion chunk.
public struct ServerOpenAIChatStreamChunk: Content, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [OpenAIChatStreamChoice]
    public let isToolMessage: Bool?

    /// Tool metadata fields (for rich UI display and persistence).
    public let toolName: String?
    public let toolIcon: String?
    public let toolStatus: String?

    /// Structured tool display data (preferred for UI rendering)
    public let toolDisplayData: ToolDisplayData?

    public let toolDetails: [String]?
    public let parentToolName: String?
    public let toolExecutionId: String?
    public let toolMetadata: [String: String]?

    /// ID of message in MessageBus (for tracking streaming updates)
    /// AgentOrchestrator creates message before yielding chunk and includes ID
    /// This prevents duplicate message creation by ChatWidget
    public let messageId: UUID?

    public init(
        id: String,
        object: String,
        created: Int,
        model: String,
        choices: [OpenAIChatStreamChoice],
        isToolMessage: Bool? = nil,
        toolName: String? = nil,
        toolIcon: String? = nil,
        toolStatus: String? = nil,
        toolDisplayData: ToolDisplayData? = nil,
        toolDetails: [String]? = nil,
        parentToolName: String? = nil,
        toolExecutionId: String? = nil,
        toolMetadata: [String: String]? = nil,
        messageId: UUID? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.isToolMessage = isToolMessage
        self.toolName = toolName
        self.toolIcon = toolIcon
        self.toolStatus = toolStatus
        self.toolDisplayData = toolDisplayData
        self.toolDetails = toolDetails
        self.parentToolName = parentToolName
        self.toolExecutionId = toolExecutionId
        self.toolMetadata = toolMetadata
        self.messageId = messageId
    }
}

/// OpenAI streaming chat choice.
public struct OpenAIChatStreamChoice: Content, Sendable {
    public let index: Int
    public let delta: OpenAIChatDelta
    public let finishReason: String?
    public let contentFilterResults: ContentFilterResults?

    enum CodingKeys: String, CodingKey {
        case index, delta
        case finishReason = "finish_reason"
        case contentFilterResults = "content_filter_results"
    }

    public init(index: Int, delta: OpenAIChatDelta, finishReason: String? = nil, contentFilterResults: ContentFilterResults? = nil) {
        self.index = index
        self.delta = delta
        self.finishReason = finishReason
        self.contentFilterResults = contentFilterResults
    }
}

/// OpenAI streaming message delta.
public struct OpenAIChatDelta: Content, Sendable {
    public let role: String?
    public let content: String?
    public let toolCalls: [OpenAIToolCall]?
    /// GitHub Copilot session continuity marker - preserves session across tool calling iterations.
    public let statefulMarker: String?

    public init(role: String? = nil, content: String? = nil, toolCalls: [OpenAIToolCall]? = nil, statefulMarker: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.statefulMarker = statefulMarker
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case statefulMarker = "stateful_marker"
    }
}

// MARK: - MCP Debug Response Types

/// MCP tools list response for debugging.
public struct MCPToolsResponse: Content {
    public let tools: [MCPToolInfo]
    public let count: Int
    public let initialized: Bool

    public init(tools: [MCPToolInfo], count: Int, initialized: Bool) {
        self.tools = tools
        self.count = count
        self.initialized = initialized
    }
}

/// MCP tool information.
public struct MCPToolInfo: Content {
    public let name: String
    public let description: String
    public let parameterCount: Int

    public init(name: String, description: String, parameterCount: Int) {
        self.name = name
        self.description = description
        self.parameterCount = parameterCount
    }
}

/// MCP execution response for debugging.
public struct MCPExecutionResponse: Content {
    public let success: Bool
    public let toolName: String
    public let output: String
    public let executionId: String
    public let error: String?

    public init(success: Bool, toolName: String, output: String, executionId: String, error: String? = nil) {
        self.success = success
        self.toolName = toolName
        self.output = output
        self.executionId = executionId
        self.error = error
    }
}

/// MCP execution request (simplified for testing).
public struct MCPExecutionRequest: Content {
    public let toolName: String
    public let parametersJson: String
    /// Optional: Conversation ID to use for scoped execution
    public let conversationId: String?
    /// Optional: Working directory to use for file/terminal operations (defaults to active conversation's working dir)
    public let workingDirectory: String?
    /// Optional: Mark as user-initiated to bypass certain security checks
    public let isUserInitiated: Bool?

    public init(toolName: String, parametersJson: String, conversationId: String? = nil, workingDirectory: String? = nil, isUserInitiated: Bool? = nil) {
        self.toolName = toolName
        self.parametersJson = parametersJson
        self.conversationId = conversationId
        self.workingDirectory = workingDirectory
        self.isUserInitiated = isUserInitiated
    }
}
