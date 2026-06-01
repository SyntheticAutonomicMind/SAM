// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

// MARK: - GitHub Copilot Models API

/// GitHub Copilot /models API response
/// **Purpose**: Describes available models and their capabilities (context windows, features, category)
/// **API endpoint**: GET https://api.githubcopilot.com/models
/// **Response structure** (updated June 2026 - usage-based billing):
/// ```json
/// {
///   "data": [{
///     "id": "gpt-5-mini",
///     "name": "GPT-5 mini",
///     "capabilities": { "limits": { ... }, "supports": { ... } },
///     "model_picker_category": "lightweight",
///     "model_picker_enabled": true,
///     "vendor": "Azure OpenAI",
///     "preview": false,
///     "policy": { "state": "enabled" },
///     "supported_endpoints": ["/chat/completions", "/responses"]
///   }]
/// }
/// ```
/// **Why needed**: GitHub Copilot doesn't include model capabilities in chat responses.
/// **Billing change (June 2026)**: The `billing` field (is_premium/multiplier) has been removed
/// from the API. All models are now billed per-token via AI Credits. The `model_picker_category`
/// field (powerful/versatile/lightweight) replaces the free/premium distinction.
public struct GitHubCopilotModelsResponse: Codable {
    public let data: [GitHubCopilotModelInfo]

    public init(data: [GitHubCopilotModelInfo]) {
        self.data = data
    }
}

/// Model policy for GitHub Copilot.
public struct ModelPolicy: Codable {
    public let state: String  // "enabled", "disabled", "unconfigured"
    public let terms: String?

    public init(state: String, terms: String?) {
        self.state = state
        self.terms = terms
    }
}

/// Supported API endpoints for a model.
public enum ModelSupportedEndpoint: String, Codable {
    case chatCompletions = "/chat/completions"
    case responses = "/responses"
    case messages = "/v1/messages"
    case wsResponses = "ws:/responses"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ModelSupportedEndpoint(rawValue: rawValue) ?? .unknown
    }

    case unknown = "_unknown"
}

/// Model picker category for GitHub Copilot models (replaces free/premium billing distinction).
/// As of June 2026, all models are billed per-token via AI Credits.
/// The category indicates the model's cost tier and capability level.
public enum ModelPickerCategory: String, Codable, Sendable {
    case powerful
    case versatile
    case lightweight
    case unknown
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ModelPickerCategory(rawValue: rawValue) ?? .unknown
    }
}

/// GitHub Copilot model information.
public struct GitHubCopilotModelInfo: Codable {
    public let id: String
    public let name: String?
    public let capabilities: ModelCapabilities?
    public let enabled: Bool?
    public let billing: ModelBilling?  // Legacy: removed from API June 2026, kept for backward compat
    public let policy: ModelPolicy?
    public let supportedEndpoints: [ModelSupportedEndpoint]?
    public let modelPickerCategory: ModelPickerCategory?
    public let modelPickerEnabled: Bool?
    public let vendor: String?
    public let preview: Bool?
    public let warningMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, name, capabilities, enabled, billing, policy, vendor, preview
        case supportedEndpoints = "supported_endpoints"
        case modelPickerCategory = "model_picker_category"
        case modelPickerEnabled = "model_picker_enabled"
        case warningMessage = "warning_message"
    }

    /// Get context window size from nested structure.
    public var maxInputTokens: Int? {
        /// CRITICAL: Use max_prompt_tokens instead of max_context_window_tokens
        /// GitHub Copilot enforces PROMPT limit, not total context limit.
        /// Example: gpt-5-mini has 264k context but only 128k prompt tokens allowed.
        /// Fallback to context window if prompt limit unavailable (older API responses).
        return capabilities?.limits?.maxPromptTokens ?? capabilities?.limits?.maxContextWindowTokens
    }

    public var maxOutputTokens: Int? {
        return capabilities?.limits?.maxOutputTokens
    }

    /// Get model picker category (replaces free/premium distinction).
    public var category: ModelPickerCategory {
        return modelPickerCategory ?? .unknown
    }
    
    /// Whether this model is shown in the model picker.
    public var isPickerEnabled: Bool {
        return modelPickerEnabled ?? enabled ?? false
    }
    
    /// Get model family from capabilities.
    public var family: String? {
        return capabilities?.family
    }

    /// Get premium status and multiplier from billing info.
    /// Legacy: billing field removed from API June 2026. Returns false/nil for new responses.
    public var isPremium: Bool {
        return billing?.isPremium ?? false
    }

    public var premiumMultiplier: Double? {
        return billing?.multiplier
    }

    public struct ModelCapabilities: Codable, Sendable {
        public let family: String?
        public let limits: ModelLimits?
        public let supports: ModelSupports?
        public let tokenizer: String?
        public let type: String?

        public struct ModelLimits: Codable, Sendable {
            public let maxContextWindowTokens: Int?
            public let maxOutputTokens: Int?
            public let maxPromptTokens: Int?
            public let maxNonStreamingOutputTokens: Int?
            public let vision: ModelVision?

            enum CodingKeys: String, CodingKey {
                case maxContextWindowTokens = "max_context_window_tokens"
                case maxOutputTokens = "max_output_tokens"
                case maxPromptTokens = "max_prompt_tokens"
                case maxNonStreamingOutputTokens = "max_non_streaming_output_tokens"
                case vision
            }
        }
        
        /// Vision capabilities for a model.
        public struct ModelVision: Codable, Sendable {
            public let maxPromptImageSize: Int?
            public let maxPromptImages: Int?
            public let supportedMediaTypes: [String]?
            
            enum CodingKeys: String, CodingKey {
                case maxPromptImageSize = "max_prompt_image_size"
                case maxPromptImages = "max_prompt_images"
                case supportedMediaTypes = "supported_media_types"
            }
        }
    }
    
    /// Model support capabilities (adaptive thinking, tool calls, etc.)
    public struct ModelSupports: Codable, Sendable {
        public let adaptiveThinking: Bool?
        public let maxThinkingBudget: Int?
        public let minThinkingBudget: Int?
        public let reasoningEffort: [String]?
        public let parallelToolCalls: Bool?
        public let streaming: Bool?
        public let structuredOutputs: Bool?
        public let toolCalls: Bool?
        public let vision: Bool?
        
        enum CodingKeys: String, CodingKey {
            case adaptiveThinking = "adaptive_thinking"
            case maxThinkingBudget = "max_thinking_budget"
            case minThinkingBudget = "min_thinking_budget"
            case reasoningEffort = "reasoning_effort"
            case parallelToolCalls = "parallel_tool_calls"
            case streaming
            case structuredOutputs = "structured_outputs"
            case toolCalls = "tool_calls"
            case vision
        }
    }

    public struct ModelBilling: Codable, Sendable {
        public let isPremium: Bool
        public let multiplier: Double?
        public let restrictedTo: [String]?

        enum CodingKeys: String, CodingKey {
            case isPremium = "is_premium"
            case multiplier
            case restrictedTo = "restricted_to"
        }

        public init(isPremium: Bool, multiplier: Double?, restrictedTo: [String]?) {
            self.isPremium = isPremium
            self.multiplier = multiplier
            self.restrictedTo = restrictedTo
        }
    }

    public init(id: String, name: String?, capabilities: ModelCapabilities?, enabled: Bool?, billing: ModelBilling?) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
        self.enabled = enabled
        self.billing = billing
        self.policy = nil
        self.supportedEndpoints = nil
        self.modelPickerCategory = nil
        self.modelPickerEnabled = nil
        self.vendor = nil
        self.preview = nil
        self.warningMessage = nil
    }

    /// Check if model is available for use (enabled policy state).
    public var isAvailable: Bool {
        // If policy exists, check if state is "enabled"
        // If no policy, default to available (backwards compatibility)
        return policy?.state == "enabled" || policy == nil
    }
}

/// Billing cache entry for persistence
/// Legacy: used for backward compatibility with annual plan subscribers still on PRU billing.
public struct BillingCacheEntry: Codable {
    public let isPremium: Bool  // Legacy: always false for usage-based billing
    public let multiplier: Double?  // Legacy: always nil for usage-based billing
    public let category: String?  // New: model_picker_category value
    public let vendor: String?  // New: model vendor

    public init(isPremium: Bool, multiplier: Double?, category: String? = nil, vendor: String? = nil) {
        self.isPremium = isPremium
        self.multiplier = multiplier
        self.category = category
        self.vendor = vendor
    }

    enum CodingKeys: String, CodingKey {
        case isPremium = "is_premium"
        case multiplier
        case category
        case vendor
    }
}
 
// MARK: - GitHub Copilot Usage (AI Credits)
 
/// Token-based usage information returned in chat completion responses.
/// As of June 2026, GitHub Copilot uses AI Credits (1 credit = $0.01 USD) instead of
/// premium request units. Each response includes `copilot_usage` with per-token costs.
public struct CopilotUsage: Codable, Sendable {
    public let tokenDetails: [CopilotTokenDetail]
    public let totalNanoAIU: Int64
    
    enum CodingKeys: String, CodingKey {
        case tokenDetails = "token_details"
        case totalNanoAIU = "total_nano_aiu"
    }
    
    /// Convert nano AI units to AI credits (1 credit = $0.01, 1 nano AIU = 10^-9 credit)
    public var totalAICredits: Double {
        return Double(totalNanoAIU) / 1_000_000_000.0
    }
    
    /// Convert nano AI units to USD
    public var totalCostUSD: Double {
        return totalAICredits * 0.01
    }
    
    /// Input tokens consumed
    public var inputTokens: Int {
        tokenDetails.first(where: { $0.tokenType == .input })?.tokenCount ?? 0
    }
    
    /// Output tokens consumed
    public var outputTokens: Int {
        tokenDetails.first(where: { $0.tokenType == .output })?.tokenCount ?? 0
    }
    
    /// Cached tokens read
    public var cachedTokens: Int {
        tokenDetails.first(where: { $0.tokenType == .cacheRead })?.tokenCount ?? 0
    }
}
 
/// Per-token-type cost detail in a Copilot usage response.
public struct CopilotTokenDetail: Codable, Sendable {
    public let batchSize: Int64
    public let costPerBatch: Int64
    public let tokenCount: Int
    public let tokenType: CopilotTokenType
    
    enum CodingKeys: String, CodingKey {
        case batchSize = "batch_size"
        case costPerBatch = "cost_per_batch"
        case tokenCount = "token_count"
        case tokenType = "token_type"
    }
    
    /// Price per million tokens in USD
    public var pricePerMillionUSD: Double {
        guard batchSize > 0 else { return 0 }
        // costPerBatch is in nano AI units per batchSize tokens
        // 1 nano AIU = 10^-9 AI credits = 10^-11 USD
        return Double(costPerBatch) * 0.01 / 1_000_000_000.0 * (1_000_000.0 / Double(batchSize))
    }
}
 
/// Token type in Copilot usage response.
public enum CopilotTokenType: String, Codable, Sendable {
    case input
    case cacheRead = "cache_read"
    case cacheWrite = "cache_write"
    case output
    case unknown
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = CopilotTokenType(rawValue: rawValue) ?? .unknown
    }
}

// MARK: - GitHub Copilot Responses API Models

/// GitHub Copilot Responses API request body
/// 
/// Extended GitHub Copilot API supporting stateful conversation tracking.
///
/// Key differences from Chat Completions API:
/// - Uses `input` array instead of `messages` (different structure)
/// - Supports `previousResponseId` for conversation checkpoints
/// - Returns structured event stream with response_id metadata
///
/// Why separate API: Responses API enables better conversation continuity:
/// - Server-side conversation state tracking
/// - Reduces need to replay full message history
/// - Better billing accuracy (single session vs multiple)
///
/// Request structure follows GitHub Copilot Responses API specification.
/// Uses different structure than Chat Completions API with 'input' array and 'previous_response_id'.
public struct ResponsesRequest: Codable {
    public let model: String
    public let input: [ResponsesInputItem]
    public let previousResponseId: String?
    public let stream: Bool
    public let tools: [ResponsesFunctionTool]?
    public let maxOutputTokens: Int?
    public let toolChoice: String?
    public let store: Bool
    public let truncation: String?
    public let reasoning: ResponsesReasoning?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case previousResponseId = "previous_response_id"
        case stream
        case tools
        case maxOutputTokens = "max_output_tokens"
        case toolChoice = "tool_choice"
        case store
        case truncation
        case reasoning
    }

    public init(model: String, input: [ResponsesInputItem], previousResponseId: String?, stream: Bool, tools: [ResponsesFunctionTool]?, maxOutputTokens: Int?, toolChoice: String?, store: Bool = false, truncation: String? = "disabled", reasoning: ResponsesReasoning? = ResponsesReasoning()) {
        self.model = model
        self.input = input
        self.previousResponseId = previousResponseId
        self.stream = stream
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.toolChoice = toolChoice
        self.store = store
        self.truncation = truncation
        self.reasoning = reasoning
    }
}

/// Responses API reasoning configuration.
public struct ResponsesReasoning: Codable {
    public let effort: String

    public init(effort: String = "medium") {
        self.effort = effort
    }
}

/// Responses API input item - can be message, function_call, or function_call_output.
public enum ResponsesInputItem: Codable {
    case message(ResponsesInputMessage)
    case functionCall(ResponsesFunctionCallInput)
    case functionCallOutput(ResponsesFunctionCallOutputInput)

    enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "message":
            let message = try ResponsesInputMessage(from: decoder)
            self = .message(message)

        case "function_call":
            let functionCall = try ResponsesFunctionCallInput(from: decoder)
            self = .functionCall(functionCall)

        case "function_call_output":
            let output = try ResponsesFunctionCallOutputInput(from: decoder)
            self = .functionCallOutput(output)

        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown input item type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .message(let message):
            try message.encode(to: encoder)

        case .functionCall(let functionCall):
            try functionCall.encode(to: encoder)

        case .functionCallOutput(let output):
            try output.encode(to: encoder)
        }
    }
}

/// Responses API message input.
public struct ResponsesInputMessage: Codable {
    public var type: String = "message"
    public let role: String
    public let content: [ResponsesContentItem]

    enum CodingKeys: String, CodingKey {
        case role
        case content
        /// Exclude 'type' - always has default value "message".
    }

    public init(role: String, content: [ResponsesContentItem]) {
        self.role = role
        self.content = content
    }
}

/// Responses API content item.
public enum ResponsesContentItem: Codable {
    case inputText(ResponsesInputTextContent)
    case outputText(ResponsesOutputTextContent)

    enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "input_text":
            let text = try ResponsesInputTextContent(from: decoder)
            self = .inputText(text)

        case "output_text":
            let text = try ResponsesOutputTextContent(from: decoder)
            self = .outputText(text)

        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content item type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .inputText(let text):
            try text.encode(to: encoder)
        case .outputText(let text):
            try text.encode(to: encoder)
        }
    }
}

/// Responses API input text content (for user/developer messages).
public struct ResponsesInputTextContent: Codable {
    public var type: String = "input_text"
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// Responses API output text content (for assistant messages).
public struct ResponsesOutputTextContent: Codable {
    public var type: String = "output_text"
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// Responses API function call input.
public struct ResponsesFunctionCallInput: Codable {
    public var type: String = "function_call"
    public let name: String
    public let arguments: String
    public let callId: String

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case arguments
        case callId = "call_id"
    }

    public init(name: String, arguments: String, callId: String) {
        self.name = name
        self.arguments = arguments
        self.callId = callId
    }

    /// Custom decoder: handles arguments as either a JSON string (spec-required)
    /// or a JSON object (some servers send this instead).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "function_call"
        self.name = try container.decode(String.self, forKey: .name)
        self.callId = try container.decode(String.self, forKey: .callId)

        if let stringArgs = try? container.decode(String.self, forKey: .arguments) {
            self.arguments = stringArgs
        } else {
            let objectArgs = try container.decode([String: AnyCodable].self, forKey: .arguments)
            let data = try JSONSerialization.data(withJSONObject: objectArgs.mapValues { $0.value }, options: [])
            self.arguments = String(data: data, encoding: .utf8) ?? "{}"
        }
    }
}

/// Responses API function call output input.
public struct ResponsesFunctionCallOutputInput: Codable {
    public var type: String = "function_call_output"
    public let callId: String
    public let output: String

    enum CodingKeys: String, CodingKey {
        case type
        case callId = "call_id"
        case output
    }

    public init(callId: String, output: String) {
        self.callId = callId
        self.output = output
    }
}

/// Responses API function tool.
public struct ResponsesFunctionTool: Codable {
    public var type: String = "function"
    public let name: String
    public let description: String
    /// Parameters stored as raw JSON data to preserve structure during encoding.
    public let parametersData: Data
    public let strict: Bool = false

    enum CodingKeys: String, CodingKey {
        case type, name, description, parameters, strict
    }

    public init(name: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.description = description
        self.parametersData = (try? JSONSerialization.data(withJSONObject: parameters)) ?? Data()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decode(String.self, forKey: .description)
        /// Decode parameters however they come.
        if let rawJSON = try? container.decode(RawJSON.self, forKey: .parameters) {
            self.parametersData = rawJSON.data
        } else {
            self.parametersData = Data()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(strict, forKey: .strict)

        /// Encode parameters as a raw JSON object (not as a string).
        let rawJSON = RawJSON(data: parametersData)
        try container.encode(rawJSON, forKey: .parameters)
    }
}

/// Helper type that preserves raw JSON structure through Codable encoding/decoding.
/// Encodes as a native JSON object/array/value rather than a string or base64.
private struct RawJSON: Codable {
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        /// Try decoding as various JSON types and re-serialize.
        if let dict = try? container.decode([String: RawJSON].self) {
            let rebuilt = dict.mapValues { (try? JSONSerialization.jsonObject(with: $0.data)) ?? NSNull() }
            self.data = (try? JSONSerialization.data(withJSONObject: rebuilt)) ?? Data()
        } else if let string = try? container.decode(String.self) {
            /// Maybe it's a JSON string - try parsing it.
            if let parsed = string.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: parsed)) != nil {
                self.data = parsed
            } else {
                self.data = (try? JSONSerialization.data(withJSONObject: string)) ?? Data()
            }
        } else {
            self.data = Data()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        guard !data.isEmpty,
              let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            try container.encode([String: String]())
            return
        }
        /// Re-encode via a CodableAny wrapper.
        let wrapped = CodableAny(jsonObject)
        try container.encode(wrapped)
    }
}

/// Wraps Any JSON value for Codable encoding.
private enum CodableAny: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([CodableAny])
    case object([String: CodableAny])

    init(_ value: Any) {
        if let s = value as? String { self = .string(s) }
        else if let n = value as? NSNumber {
            // Check for boolean before numeric (NSNumber bridges both)
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if n.doubleValue == Double(n.intValue) {
                self = .int(n.intValue)
            } else {
                self = .double(n.doubleValue)
            }
        }
        else if let a = value as? [Any] { self = .array(a.map { CodableAny($0) }) }
        else if let d = value as? [String: Any] { self = .object(d.mapValues { CodableAny($0) }) }
        else if value is NSNull { self = .null }
        else { self = .null }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let a = try? container.decode([CodableAny].self) { self = .array(a) }
        else if let o = try? container.decode([String: CodableAny].self) { self = .object(o) }
        else if container.decodeNil() { self = .null }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - Responses API SSE Events

/// GitHub Copilot Responses API streaming event.
public enum ResponsesStreamEvent: Codable {
    case error(ResponsesErrorEvent)
    case outputTextDelta(ResponsesOutputTextDeltaEvent)
    case outputItemAdded(ResponsesOutputItemAddedEvent)
    case outputItemDone(ResponsesOutputItemDoneEvent)
    case completed(ResponsesCompletedEvent)
    case ignored

    enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "error":
            let event = try ResponsesErrorEvent(from: decoder)
            self = .error(event)

        case "response.output_text.delta":
            let event = try ResponsesOutputTextDeltaEvent(from: decoder)
            self = .outputTextDelta(event)

        case "response.output_item.added":
            let event = try ResponsesOutputItemAddedEvent(from: decoder)
            self = .outputItemAdded(event)

        case "response.output_item.done":
            let event = try ResponsesOutputItemDoneEvent(from: decoder)
            self = .outputItemDone(event)

        case "response.completed":
            let event = try ResponsesCompletedEvent(from: decoder)
            self = .completed(event)

        case "response.created",
             "response.in_progress",
             "response.content_part.added",
             "response.content_part.done",
             "response.output_text.done",
             "response.function_call_arguments.delta",
             "response.function_call_arguments.done",
             "response.reasoning_summary_text.delta",
             "response.reasoning_summary_text.done":
            /// Informational events - safely ignored.
            /// Tool call args come via outputItemDone with complete data.
            self = .ignored

        default:
            /// Truly unknown event types.
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown event type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .error(let event):
            try event.encode(to: encoder)

        case .outputTextDelta(let event):
            try event.encode(to: encoder)

        case .outputItemAdded(let event):
            try event.encode(to: encoder)

        case .outputItemDone(let event):
            try event.encode(to: encoder)

        case .completed(let event):
            try event.encode(to: encoder)

        case .ignored:
            break
        }
    }
}

/// Responses API error event.
public struct ResponsesErrorEvent: Codable {
    public var type: String = "error"
    public let code: String?
    public let message: String
    public let param: String?

    public init(code: String?, message: String, param: String?) {
        self.code = code
        self.message = message
        self.param = param
    }
}

/// Responses API output text delta event.
public struct ResponsesOutputTextDeltaEvent: Codable {
    public var type: String = "response.output_text.delta"
    public let delta: String

    public init(delta: String) {
        self.delta = delta
    }
}

/// Responses API output item added event.
public struct ResponsesOutputItemAddedEvent: Codable {
    public var type: String = "response.output_item.added"
    public let item: ResponsesOutputItemAdded

    public init(item: ResponsesOutputItemAdded) {
        self.item = item
    }
}

public struct ResponsesOutputItemAdded: Codable {
    public let type: String
    public let name: String?

    public init(type: String, name: String?) {
        self.type = type
        self.name = name
    }
}

/// Responses API output item done event.
public struct ResponsesOutputItemDoneEvent: Codable {
    public var type: String = "response.output_item.done"
    public let item: ResponsesOutputItemDone

    public init(item: ResponsesOutputItemDone) {
        self.item = item
    }
}

public struct ResponsesOutputItemDone: Codable {
    public let type: String
    public let callId: String?
    public let name: String?
    public let arguments: String?

    enum CodingKeys: String, CodingKey {
        case type
        case callId = "call_id"
        case name
        case arguments
    }

    public init(type: String, callId: String?, name: String?, arguments: String?) {
        self.type = type
        self.callId = callId
        self.name = name
        self.arguments = arguments
    }

    /// Custom decoder: handles arguments as either a JSON string or a JSON object.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.callId = try container.decodeIfPresent(String.self, forKey: .callId)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)

        if let stringArgs = try? container.decodeIfPresent(String.self, forKey: .arguments) {
            self.arguments = stringArgs
        } else if let objectArgs = try? container.decode([String: AnyCodable].self, forKey: .arguments) {
            let data = try JSONSerialization.data(withJSONObject: objectArgs.mapValues { $0.value }, options: [])
            self.arguments = String(data: data, encoding: .utf8) ?? "{}"
        } else {
            self.arguments = nil
        }
    }
}

/// Responses API completed event - CRITICAL: Contains statefulMarker in response.id.
public struct ResponsesCompletedEvent: Codable {
    public var type: String = "response.completed"
    public let response: ResponsesCompletedResponse

    public init(response: ResponsesCompletedResponse) {
        self.response = response
    }
}

public struct ResponsesCompletedResponse: Codable {
    public let id: String
    public let createdAt: Int
    public let usage: ResponsesUsage?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case usage
    }

    public init(id: String, createdAt: Int, usage: ResponsesUsage?) {
        self.id = id
        self.createdAt = createdAt
        self.usage = usage
    }
}

public struct ResponsesUsage: Codable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }

    public init(inputTokens: Int, outputTokens: Int, totalTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}
