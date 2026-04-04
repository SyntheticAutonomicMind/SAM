// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConversationEngine
import MCPFramework
import ConfigurationSystem
import SecurityFramework

/// Safe string operations to prevent index crashes with multi-byte UTF-8 characters.
fileprivate extension String {
    /// Safely get a prefix of the string without crashing on invalid indices.
    func safePrefix(_ maxLength: Int) -> String {
        guard !isEmpty else { return "" }
        guard maxLength > 0 else { return "" }

        /// Use unicodeScalars for safe multi-byte handling.
        let scalars = self.unicodeScalars
        guard scalars.count > maxLength else { return self }

        let endIndex = scalars.index(scalars.startIndex, offsetBy: maxLength)
        return String(scalars[..<endIndex])
    }
}

/// Autonomous agent orchestrator implementing VS Code Copilot's tool calling loop pattern This orchestrator sits above the EndpointManager layer and enables autonomous multi-step workflows.
@MainActor
public class AgentOrchestrator: ObservableObject, IterationController {
    internal let logger = Logging.Logger(label: "com.sam.orchestrator")
    internal let endpointManager: EndpointManager
    internal let conversationService: SharedConversationService
    internal let conversationManager: ConversationManager
    public private(set) var maxIterations: Int
    internal var onProgress: ((String) -> Void)?
    internal var currentTodoList: [TodoItem] = []

    /// Current iteration number (exposed for IterationController protocol)
    public private(set) var currentIteration: Int = 0

    /// Cancellation flag for stopping autonomous workflows
    internal var isCancellationRequested = false

    /// Tool card readiness tracking
    /// When tool execution is about to start, toolCardsPending is set to execution IDs
    /// UI acknowledges by setting toolCardsReady to the same IDs
    @Published public var toolCardsPending: Set<String> = []
    @Published public var toolCardsReady: Set<String> = []

    /// Token counter for smart context management Monitors token usage and triggers pruning at 70% threshold.
    internal let tokenCounter: TokenCounter = TokenCounter()

    /// Tool result storage for handling large tool outputs
    /// Persists results to disk for retrieval via read_tool_result
    /// Replaces the memory-only ToolResultCache for proper persistence
    internal let toolResultStorage = ToolResultStorage()

    /// Flag indicating if this orchestrator is being called by an external API client vs SAM's internal autonomous workflow.
    internal let isExternalAPICall: Bool

    /// Performance monitor for workflow metrics (optional) When set, reports workflow, loop detection, and context filtering metrics.
    public weak var performanceMonitor: PerformanceMonitor?

    /// Universal tool call extractor - supports all formats (OpenAI, Ministral, Qwen, Hermes).
    internal let toolCallExtractor = ToolCallExtractor()

    /// YaRN Context Processor for intelligent context management Uses mega 128M token profile supporting massive document analysis (60-100MB+ documents).
    internal var yarnProcessor: YaRNContextProcessor?

    /// Tool call stack for tracking nested tool hierarchy When tool A calls tool B, A is on the stack, enabling B to know its parent Stack entries are tool names (e.g., ["researching", "web_operations"]).
    internal var toolCallStack: [String] = []

    /// Premature stop retry limit (CLIO-style).
    /// If model returns empty response after active tool use, nudge once.
    internal let maxPrematureStopRetries: Int = 1
    internal let maxTodoNudgeRetries: Int = 3


    public init(
        endpointManager: EndpointManager,
        conversationService: SharedConversationService,
        conversationManager: ConversationManager,
        maxIterations: Int = WorkflowConfiguration.defaultMaxIterations,
        onProgress: ((String) -> Void)? = nil,
        isExternalAPICall: Bool = false
    ) {
        self.endpointManager = endpointManager
        self.conversationService = conversationService
        self.conversationManager = conversationManager
        self.maxIterations = maxIterations
        self.onProgress = onProgress
        self.isExternalAPICall = isExternalAPICall

        /// Initialize YARN processor with mega 128M token profile for massive document workflows.
        self.yarnProcessor = YaRNContextProcessor(
            memoryManager: conversationManager.memoryManager,
            tokenEstimator: { [weak tokenCounter] text in
                guard let tokenCounter = tokenCounter else { return text.count / 4 }
                return await tokenCounter.estimateTokensRemote(text: text)
            },
            config: .mega
        )
    }

    /// Cancel any ongoing autonomous workflow
    /// Sets cancellation flag that's checked at multiple points in the workflow loop
    public func cancelWorkflow() {
        logger.info("CANCELLATION_REQUESTED: Setting cancellation flag")
        isCancellationRequested = true
    }

    // MARK: - System Message Helpers

    /// Create a system message with proper formatting for the model
    /// For Claude models: wraps content in <system-reminder> tags and uses user role
    /// CRITICAL: All system reminders sent as "user" role for better model compliance
    /// GPT models often deprioritize mid-conversation "system" messages, treating them as metadata
    /// By sending as "user", the model treats it as direct instruction from the conversation flow
    /// VS CODE COPILOT PATTERN: Use XML tags for ALL models (not just Claude)
    func createSystemReminder(content: String, model: String) -> OpenAIChatMessage {
        /// Use XML tags universally - VS Code uses structured tags for all models
        let wrappedContent = "<system-reminder>\n\(content)\n</system-reminder>"
        return OpenAIChatMessage(role: "user", content: wrappedContent)
    }

    /// Ensure message alternation for Claude API compatibility
    /// Claude requires strict user/assistant alternation, no empty messages, and no consecutive same-role messages
    /// This function fixes message arrays to comply with Claude's requirements while preserving compatibility with other models
    func ensureMessageAlternation(_ messages: [OpenAIChatMessage]) -> [OpenAIChatMessage] {
        /// DIAGNOSTIC: Log input messages
        logger.debug("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logger.debug("ALTERNATION_INPUT: Received \(messages.count) messages")
        for (i, msg) in messages.enumerated() {
            let contentLen = msg.content?.count ?? 0
            let toolCallsCount = msg.toolCalls?.count ?? 0
            let toolCallId = msg.toolCallId ?? "none"
            let contentPreview = msg.content?.prefix(100) ?? "nil"
            logger.debug("  IN[\(i)]: role=\(msg.role) contentLen=\(contentLen) toolCalls=\(toolCallsCount) toolCallId=\(toolCallId) preview=\"\(contentPreview)...\"")
        }
        
        var fixed: [OpenAIChatMessage] = []
        var lastRole: String?

        for message in messages {
            /// Skip empty messages (invalid for Claude)
            /// BUT: Never skip assistant messages with tool_calls - these have empty content
            /// but the tool_calls array is essential for the API to match tool results
            let trimmedContent = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasToolCalls = message.toolCalls != nil && !(message.toolCalls?.isEmpty ?? true)
            guard !trimmedContent.isEmpty || hasToolCalls else {
                logger.debug("ALTERNATION_SKIP_EMPTY: role=\(message.role) (content empty, no tool_calls)")
                continue
            }

            /// Handle tool messages separately - they don't participate in alternation
            if message.role == "tool" {
                fixed.append(message)
                /// Reset lastRole so the next assistant/user message after tool results
                /// won't be merged with the one before the tool results.
                /// Tool messages break the "consecutive same role" sequence.
                lastRole = "tool"
                logger.debug("ALTERNATION_PRESERVE_TOOL: role=tool preserved (contentLen=\(message.content?.count ?? 0))")
                continue
            }

            /// CRITICAL: Preserve Claude batched tool results - these must NOT be merged
            /// The __CLAUDE_BATCHED_TOOL_RESULTS__ marker MUST be at the start of content
            /// for AnthropicMessageConverter to detect and convert to tool_result blocks
            if message.role == "user",
               let content = message.content,
               content.hasPrefix("__CLAUDE_BATCHED_TOOL_RESULTS__") {
                fixed.append(message)
                lastRole = message.role
                logger.debug("ALTERNATION_PRESERVE_BATCHED_TOOLS: Preserved Claude batched tool results (contentLen=\(content.count))")
                continue
            }

            /// Merge consecutive same-role messages
            if message.role == lastRole {
                /// Can only merge user and assistant messages (not system or tool)
                if message.role == "user" || message.role == "assistant" {
                    if let last = fixed.popLast() {
                        /// Merge content with double newline separator
                        let lastContent = last.content ?? ""
                        let currentContent = message.content ?? ""
                        let mergedContent: String
                        if lastContent.isEmpty {
                            mergedContent = currentContent
                        } else if currentContent.isEmpty {
                            mergedContent = lastContent
                        } else {
                            mergedContent = lastContent + "\n\n" + currentContent
                        }

                        /// Combine tool calls from both messages (don't lose any)
                        let combinedToolCalls: [OpenAIToolCall]?
                        let lastCalls = last.toolCalls ?? []
                        let currentCalls = message.toolCalls ?? []
                        if !lastCalls.isEmpty || !currentCalls.isEmpty {
                            combinedToolCalls = lastCalls + currentCalls
                        } else {
                            combinedToolCalls = nil
                        }

                        /// Create new merged message
                        let mergedMessage: OpenAIChatMessage
                        if let toolCalls = combinedToolCalls, !toolCalls.isEmpty {
                            mergedMessage = OpenAIChatMessage(role: last.role, content: mergedContent.isEmpty ? nil : mergedContent, toolCalls: toolCalls)
                        } else if let toolCallId = last.toolCallId {
                            mergedMessage = OpenAIChatMessage(role: last.role, content: mergedContent, toolCallId: toolCallId)
                        } else {
                            mergedMessage = OpenAIChatMessage(role: last.role, content: mergedContent)
                        }

                        fixed.append(mergedMessage)
                        logger.debug("MESSAGE_ALTERNATION: Merged consecutive \(message.role) messages (toolCalls: \(combinedToolCalls?.count ?? 0))")
                    }
                } else {
                    /// For system messages, just append (don't merge)
                    fixed.append(message)
                }
            } else {
                fixed.append(message)
                lastRole = message.role
            }
        }

        /// Final validation: ensure alternation between user and assistant
        /// System messages are allowed anywhere, but user/assistant must alternate
        var validated: [OpenAIChatMessage] = []
        var lastNonSystemRole: String?

        for message in fixed {
            if message.role == "system" || message.role == "tool" {
                /// System and tool messages don't break alternation
                validated.append(message)
                continue
            }

            if message.role == lastNonSystemRole {
                /// Still consecutive after merge - this shouldn't happen, but handle it
                logger.warning("MESSAGE_ALTERNATION: Found consecutive \(message.role) messages after merge attempt - appending anyway")
            }

            validated.append(message)
            lastNonSystemRole = message.role
        }

        let originalCount = messages.count
        let fixedCount = validated.count
        if originalCount != fixedCount {
            logger.info("MESSAGE_ALTERNATION: Fixed message array - \(originalCount) → \(fixedCount) messages (\(originalCount - fixedCount) removed/merged)")
        }

        /// DIAGNOSTIC: Log output messages
        logger.debug("ALTERNATION_OUTPUT: Returning \(validated.count) messages (removed/merged \(messages.count - validated.count))")
        for (i, msg) in validated.enumerated() {
            let contentLen = msg.content?.count ?? 0
            let toolCallsCount = msg.toolCalls?.count ?? 0
            let toolCallId = msg.toolCallId ?? "none"
            logger.debug("  OUT[\(i)]: role=\(msg.role) contentLen=\(contentLen) toolCalls=\(toolCallsCount) toolCallId=\(toolCallId)")
        }
        logger.debug("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        return validated
    }

    /// Batch consecutive tool result messages for Claude API
    /// Claude Messages API requires ALL tool results from one iteration to be in a SINGLE user message
    /// This function converts: [tool1, tool2, tool3] → [user_with_batched_tools]
    /// Only used for Claude models to fix the tool result batching issue
    func batchToolResultsForClaude(_ messages: [OpenAIChatMessage]) -> [OpenAIChatMessage] {
        var processed: [OpenAIChatMessage] = []
        var pendingToolResults: [(toolCallId: String, content: String)] = []
        
        for message in messages {
            if message.role == "tool" {
                /// Accumulate tool results
                if let toolCallId = message.toolCallId {
                    pendingToolResults.append((toolCallId, message.content ?? ""))
                    logger.debug("CLAUDE_TOOL_BATCH: Accumulated tool result (id: \(toolCallId))")
                }
            } else {
                /// Flush pending tool results before this message
                if !pendingToolResults.isEmpty {
                    /// Create a single user message with ALL tool results as metadata
                    /// The AnthropicMessageConverter will convert these to tool_result content blocks
                    logger.info("CLAUDE_TOOL_BATCH: Flushing \(pendingToolResults.count) tool results as batched metadata")
                    
                    /// Store tool results as JSON in the message content
                    /// Format: Special marker that AnthropicMessageConverter can detect
                    let batchedData = try? JSONSerialization.data(
                        withJSONObject: pendingToolResults.map { ["tool_use_id": $0.toolCallId, "content": $0.content] },
                        options: []
                    )
                    let batchedJson = batchedData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    
                    /// Create user message with special marker for batched tools
                    let batchedMessage = OpenAIChatMessage(
                        role: "user",
                        content: "__CLAUDE_BATCHED_TOOL_RESULTS__\n\(batchedJson)"
                    )
                    processed.append(batchedMessage)
                    pendingToolResults.removeAll()
                }
                
                /// Add the current non-tool message
                processed.append(message)
            }
        }
        
        /// Flush any remaining tool results at the end
        if !pendingToolResults.isEmpty {
            logger.info("CLAUDE_TOOL_BATCH: Flushing final \(pendingToolResults.count) tool results")
            let batchedData = try? JSONSerialization.data(
                withJSONObject: pendingToolResults.map { ["tool_use_id": $0.toolCallId, "content": $0.content] },
                options: []
            )
            let batchedJson = batchedData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            
            let batchedMessage = OpenAIChatMessage(
                role: "user",
                content: "__CLAUDE_BATCHED_TOOL_RESULTS__\n\(batchedJson)"
            )
            processed.append(batchedMessage)
        }
        
        logger.debug("CLAUDE_TOOL_BATCH: Processed \(messages.count) → \(processed.count) messages")
        return processed
    }


    // MARK: - Session Auto-Naming

    /// Extract session naming marker from AI response and rename the conversation
    /// Marker format: <!--session:{"title":"3-6 word summary"}-->
    /// Only acts when conversation title starts with "New Conversation"
    func extractAndApplySessionName(from rawResponse: String, conversationId: UUID) {
        guard rawResponse.contains("<!--session:") else { return }

        guard let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }),
              conversation.title.hasPrefix("New Conversation") else { return }

        /// Extract title using regex: <!--session:{"title":"..."}-->
        let pattern = #"<!--session:\{[^}]*"title"\s*:\s*"([^"]{3,80})"[^}]*\}-->"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: rawResponse, options: [], range: NSRange(rawResponse.startIndex..., in: rawResponse)),
              let titleRange = Range(match.range(at: 1), in: rawResponse) else { return }

        let title = String(rawResponse[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 3 else { return }

        logger.info("SESSION_NAMING: AI provided title '\(title)' for conversation \(conversationId.uuidString.prefix(8))")
        conversationManager.renameConversation(conversation, to: title)
    }

    /// Fallback: auto-name from first user message when AI doesn't provide a marker.
    /// Strips filler words, capitalizes, truncates to ~50 chars at word boundary.
    func fallbackAutoName(conversationId: UUID) {
        guard let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }),
              conversation.title.hasPrefix("New Conversation") else { return }

        /// Find first user message
        guard let firstUserMessage = conversation.messages.first(where: { $0.isFromUser }),
              !firstUserMessage.content.isEmpty else { return }

        var name = firstUserMessage.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""

        /// Collapse whitespace
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        /// Strip common filler phrases at the start
        let fillerPrefixes = [
            "hey ", "hi ", "hello ", "please ", "can you ", "could you ",
            "i want to ", "i need to ", "i'd like to ", "let's ", "lets "
        ]
        for prefix in fillerPrefixes {
            if name.lowercased().hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
                break
            }
        }

        /// Capitalize first letter
        if let first = name.first {
            name = first.uppercased() + name.dropFirst()
        }

        /// Truncate to ~50 chars at word boundary
        if name.count > 50 {
            name = String(name.prefix(50))
            if let lastSpace = name.lastIndex(of: " ") {
                name = String(name[name.startIndex..<lastSpace])
            }
        }

        guard name.count >= 3 else { return }

        logger.info("SESSION_NAMING: Fallback auto-name '\(name)' for conversation \(conversationId.uuidString.prefix(8))")
        conversationManager.renameConversation(conversation, to: name)
    }

    /// Strip system-reminder tags from response content
    /// When Claude echoes back <system-reminder> content, we need to filter it out
    /// before showing to user or saving to conversation
    func stripSystemReminders(from content: String) -> String {
        /// Quick exit if no tags present
        if content.isEmpty || !content.contains("system-reminder") {
            return content
        }

        var cleaned = content
        let originalLength = content.count

        /// Pattern 1: Remove well-formed <system-reminder>...</system-reminder> blocks
        /// Use .dotMatchesLineSeparators to handle multiline content
        /// Use non-greedy matching (.*?) to handle multiple blocks
        let wellFormedPattern = "<system-reminder[^>]*>.*?</system-reminder>"
        if let regex = try? NSRegularExpression(pattern: wellFormedPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }

        /// Pattern 2: Handle orphaned or malformed closing tags
        /// Examples: </system-reminder>-reminder>, </system-reminder>, etc.
        let orphanedClosingPattern = "</system-reminder[^>]*>"
        if let regex = try? NSRegularExpression(pattern: orphanedClosingPattern, options: .caseInsensitive) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }

        /// Pattern 3: Handle orphaned opening tags
        /// In case there are unclosed opening tags
        let orphanedOpeningPattern = "<system-reminder[^>]*>"
        if let regex = try? NSRegularExpression(pattern: orphanedOpeningPattern, options: .caseInsensitive) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }

        /// Trim excess whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        /// Log if filtering occurred (helps debug visibility issues)
        if cleaned.count != originalLength {
            logger.debug("STRIPPED_SYSTEM_REMINDERS", metadata: [
                "originalLength": .stringConvertible(originalLength),
                "cleanedLength": .stringConvertible(cleaned.count),
                "removedBytes": .stringConvertible(originalLength - cleaned.count),
                "hadTags": .stringConvertible(true)
            ])
        }

        return cleaned
    }

    // MARK: - IterationController Protocol

    /// Update the maximum iterations limit dynamically during execution
    /// - Parameters:
    /// - newValue: The new maximum iteration limit
    /// - reason: Explanation for the increase
    public func updateMaxIterations(_ newValue: Int, reason: String) {
        let oldValue = maxIterations
        maxIterations = newValue
        logger.debug("DYNAMIC_ITERATIONS: Increased from \(oldValue) to \(newValue) - Reason: \(reason)")
        onProgress?("Max iterations increased to \(newValue): \(reason)")
    }

    /// Update current iteration count (called internally during execution loop)
    internal func updateCurrentIteration(_ value: Int) {
        currentIteration = value
    }

    /// Track if we've already fetched model capabilities for each provider type.
    private var hasAttemptedCapabilitiesFetch: [String: Bool] = [:]

    /// Lazy fetch model capabilities from provider API on first use This ensures the provider is fully initialized before we attempt to fetch capabilities Supports: - GitHub Copilot: /models endpoint with max_input_tokens - OpenAI: /v1/models endpoint - Gemini: models.list API with inputTokenLimit - Anthropic: Uses hardcoded values (API doesn't expose).
    func lazyFetchModelCapabilitiesIfNeeded(for model: String) async {
        /// Determine provider type from model name.
        let providerType: String
        let modelLower = model.lowercased()

        /// Check for explicit provider prefix FIRST (e.g., "github_copilot/gpt-5-mini")
        if modelLower.contains("github_copilot/") {
            providerType = "github_copilot"
        } else if modelLower.starts(with: "gpt-") || modelLower.starts(with: "o1-") || modelLower.starts(with: "claude-") {
            /// Implicit GitHub Copilot (models without provider prefix)
            providerType = "github_copilot"
        } else if modelLower.starts(with: "openai/") {
            providerType = "openai"
        } else if modelLower.contains("gemini") {
            providerType = "gemini"
        } else if modelLower.contains("claude") {
            providerType = "anthropic"
        } else if let providerTypeName = endpointManager.getProviderTypeForModel(model),
                  providerTypeName == "OpenRouterProvider" {
            /// OpenRouter model detected via provider registry.
            providerType = "openrouter"
        } else {
            /// Unknown provider, skip.
            return
        }

        /// Only fetch once per provider.
        guard hasAttemptedCapabilitiesFetch[providerType] != true else { return }

        // MARK: - as attempted (even if it fails, don't retry on every request)
        hasAttemptedCapabilitiesFetch[providerType] = true

        logger.debug("LAZY_FETCH: First \(providerType) model request (\(model)), fetching capabilities from API")

        do {
            var capabilities: [String: Int]?

            switch providerType {
            case "github_copilot":
                capabilities = try await endpointManager.getGitHubCopilotModelCapabilities()

            case "openai":
                /// Get OpenAI provider and fetch capabilities.
                if let provider = endpointManager.getProvider(id: "openai") as? OpenAIProvider {
                    capabilities = try await provider.fetchModelCapabilities()
                }

            case "openrouter":
                /// Get OpenRouter provider and fetch capabilities from /v1/models endpoint.
                /// OpenRouter returns context_length in the top_provider block per model.
                if let provider = endpointManager.getFirstProvider(ofType: OpenRouterProvider.self) {
                    capabilities = try await provider.fetchModelCapabilities()
                    logger.debug("LAZY_FETCH: Fetched \(capabilities?.count ?? 0) model context sizes from OpenRouter")
                }

            case "anthropic":
                /// Anthropic API doesn't expose model metadata - use hardcoded values.
                logger.debug("LAZY_FETCH: Anthropic uses hardcoded context sizes (API doesn't expose)")
                return

            default:
                logger.debug("LAZY_FETCH: Unknown provider type '\(providerType)', skipping")
                return
            }

            if let capabilities = capabilities {
                await tokenCounter.setContextSizes(capabilities)
                logger.debug("LAZY_FETCH: Successfully fetched \(capabilities.count) model capabilities from \(providerType) API")
            } else {
                logger.debug("LAZY_FETCH: \(providerType) provider not available - using hardcoded context sizes")
            }
        } catch {
            logger.warning("LAZY_FETCH: Failed to fetch \(providerType) model capabilities: \(error) - using hardcoded fallbacks")
        }
    }
/// **Architecture**: - **Model-Agnostic**: Works with MLX, OpenAI, GitHub Copilot, Anthropic - **Autonomous**: No user prompting needed between tool executions - **Safe**: Iteration limits prevent infinite loops - **Transparent**: Full tool execution history tracked.

    // MARK: - Streaming Tool Call Accumulation

    /// Accumulates a single tool call across multiple streaming chunks Uses incremental accumulation pattern for robust streaming handling.
    private class StreamingToolCall {
        var id: String?
        var name: String?
        var type: String = "function"
        var arguments: String = ""

        func update(_ toolCall: OpenAIToolCall) {
            /// Accumulate id (usually only in first chunk).
            if !toolCall.id.isEmpty {
                self.id = toolCall.id
            }

            /// Accumulate type (usually only in first chunk).
            if !toolCall.type.isEmpty {
                self.type = toolCall.type
            }

            /// Accumulate function name (usually only in first chunk).
            if !toolCall.function.name.isEmpty {
                self.name = toolCall.function.name
            }

            /// Concatenate arguments incrementally across chunks.
            if !toolCall.function.arguments.isEmpty {
                self.arguments += toolCall.function.arguments
            }
        }

        func isComplete() -> Bool {
            return id != nil && name != nil && !arguments.isEmpty
        }

        func toOpenAIToolCall() -> OpenAIToolCall? {
            guard let id = id, let name = name else { return nil }
            return OpenAIToolCall(
                id: id,
                type: type,
                function: OpenAIFunctionCall(name: name, arguments: arguments)
            )
        }
    }

    /// Manages multiple tool calls during streaming using index-based accumulation Handles partial tool call data across multiple chunks for robust streaming.
    class StreamingToolCalls {
        private var toolCalls: [StreamingToolCall] = []

        func update(toolCallsArray: [OpenAIToolCall]) {
            for toolCall in toolCallsArray {
                /// Use index to identify which tool call to update If no index, append as new tool call.
                let index = toolCall.index ?? toolCalls.count

                /// Ensure array is large enough.
                while toolCalls.count <= index {
                    toolCalls.append(StreamingToolCall())
                }

                /// Update the tool call at this index.
                toolCalls[index].update(toolCall)
            }
        }

        func getCompletedToolCalls() -> [OpenAIToolCall] {
            return toolCalls.compactMap { $0.toOpenAIToolCall() }
        }

        func hasToolCalls() -> Bool {
            return !toolCalls.isEmpty
        }

        func count() -> Int {
            return toolCalls.count
        }
    }

    // MARK: - Workflow Execution Context

    // MARK: - er Detection

    // MARK: - er Detection

    /// Structured result from marker detection.
    private struct MarkerFlags {
        /// Only STOP marker remains for fatal error handling
        var detectedStop: Bool = false  // Agent Loop Escape

        /// Pattern that matched (for telemetry).
        var matchedPattern: String?
        var matchedSnippet: String?
    }

    /// Unified marker detection - detects all control signals in raw LLM response This is the SINGLE SOURCE OF TRUTH for marker detection Call this on raw response BEFORE filtering markers out for user display - Parameter rawResponse: Unfiltered LLM response text - Returns: Structured MarkerFlags with all detected markers.
    private func detectMarkers(in rawResponse: String) -> MarkerFlags {
        var flags = MarkerFlags()
        let lower = rawResponse.lowercased()

        /// JSON FORMAT DETECTION: Only STOP marker remains (for fatal errors)
        let jsonStopPattern = #"\{\s*"status"\s*:\s*"stop"\s*\}"#  // Agent Loop Escape

        // Agent Loop Escape - Detect stop status
        if lower.range(of: jsonStopPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            flags.detectedStop = true
            flags.matchedPattern = "JSON: {\"status\": \"stop\"}"
        }

        return flags
    }

    /// Centralized marker processing helper with COMPLETE phase management This is the SINGLE LOCATION for all workflow phase transitions and directive injections CRITICAL REFACTORING: This method now handles: - Marker detection - Phase transitions - Plan parsing and task creation - Execution directive injection - Step advancement - Completion handling The main loop should ONLY call LLM, call this method, execute tools, and repeat.
    private func processMarkerEvent(
        context: inout WorkflowExecutionContext,
        conversationId: UUID,
        rawResponse: String,
        finishReason: String? = nil,
        requestId: String? = nil,
        isToolOutput: Bool = false,
        toolName: String? = nil
    ) async -> Bool {
    /// Filter internal markers (preserve formatting/newlines) and store the clean response.
    context.lastResponse = filterInternalMarkersNoTrim(from: rawResponse)
        context.currentRoundLLMResponse = context.lastResponse
        if let fr = finishReason { context.lastFinishReason = fr }

        /// Extract session naming marker from response and rename conversation
        extractAndApplySessionName(from: rawResponse, conversationId: conversationId)

        /// Detect markers in the raw response.
        let markers = detectMarkers(in: rawResponse)

        /// Assign detected markers to context for workflow continuation logic.
        context.detectedStopMarker = markers.detectedStop  // Agent Loop Escape (ONLY remaining marker)

        /// Check for stop status (agent is stuck and giving up).
        /// Trust the model's decision - if it signals stop, respect it.
        if markers.detectedStop {
            logger.warning("WORKFLOW_STOPPED", metadata: [
                "conversationId": .string(conversationId.uuidString),
                "reason": .string("Agent signaled stop status - unable to proceed")
            ])
            context.shouldContinue = false
            context.completionReason = .error

            return true
        }

        /// Workflow completion is now determined by the orchestrator flow diagram:
        /// - No tool calls + no active todos + workflow switch off = natural stop
        /// - Agent should not control completion via markers

        return false
    }

    // Auto-continue forcing removed (CLIO-style).
    // The model decides when it's done by not calling tools.
    // SAM respects that decision instead of overriding it.



    private struct WorkflowExecutionContext {
        // MARK: - Core State

        /// Current iteration number (0-based, matches WorkflowRound.iterationNumber for billing).
        var iteration: Int

        /// Maximum iterations allowed before workflow termination.
        var maxIterations: Int

        /// Complete history of workflow rounds (one per iteration).
        var workflowRounds: [WorkflowRound]

        // MARK: - Current Round Tracking

        /// Tool calls made in current iteration (reset at start of each iteration).
        var currentRoundToolCalls: [ToolCallInfo]

        /// Tool results for current iteration (keyed by tool call ID).
        var currentRoundToolResults: [String: String]

        /// Timestamp when current round started.
        var currentRoundStartTime: Date

        /// LLM response text for current iteration.
        var currentRoundLLMResponse: String?

        // MARK: - Workflow History

        /// Internal messages sent to LLM (tool calls + results).
        /// These persist across iterations to maintain workflow context.
        var internalMessages: [OpenAIChatMessage]

        /// Ephemeral messages for current iteration only (reminders, status).
        /// These are cleared at the start of each iteration to prevent accumulation.
        /// Used for: ITERATION STATUS, auto-continue reminders, todo reminders.
        var ephemeralMessages: [OpenAIChatMessage]

        // MARK: - LLM Response State

        /// Last LLM response content.
        var lastResponse: String

        /// Raw LLM response preserving provider-specific tags (e.g., MiniMax <think> tags).
        /// Used when building internal messages for API round-trips.
        var rawLastResponse: String?

        /// Last finish_reason from LLM.
        var lastFinishReason: String

        /// Whether final response has been added to conversation.
        var finalResponseAddedToConversation: Bool

        // MARK: Agent Loop Escape Route

        /// Track tool failures per iteration to detect stuck loops.
        /// Key: tool name, Value: (iteration number, consecutive failure count)
        var toolFailureTracking: [String: (iteration: Int, failureCount: Int)]

        /// Track which tools were used in the last iteration to prevent repetition.
        var lastIterationToolNames: Set<String>
        
        /// FIX #8: Track if previous iteration had tool results for alternation enforcement
        /// When true: agent processed tool data last iteration and should call tools THIS iteration
        var lastIterationHadToolResults: Bool

        /// Fingerprints of all tool calls executed in this workflow (tool_name + sorted_args hash).
        /// Used to detect when the model calls the same tools with the same arguments repeatedly.
        var previousToolCallSignatures: Set<String>

        /// Count of consecutive iterations where ALL tool calls were duplicates.
        var duplicateToolCallCount: Int

        // MARK: - Continuation Status

        /// Whether to use continuation response from previous iteration.
        var useContinuationResponse: Bool

        /// Tool calls from continuation_status (if any).
        var continuationToolCalls: [ToolCall]?

        /// Detected internal markers from the raw LLM response (set BEFORE filtering).
        /// These markers are deprecated and no longer used
        /// Continuation is controlled by orchestrator flow diagram
        var detectedStopMarker: Bool  // Agent Loop Escape

        // MARK: - GitHub Copilot Session State

        /// GitHub Copilot stateful marker for session continuity (prevents duplicate billing).
        var currentStatefulMarker: String?

        /// Conversation message count when currentStatefulMarker was captured.
        /// Used for delta-only message slicing to avoid timing dependencies.
        var statefulMarkerMessageCount: Int?

        /// Number of internal messages sent in last LLM request (for stateful marker tracking).
        var sentInternalMessagesCount: Int

        // MARK: - Workflow Metadata

        /// Whether any tools have been executed in this workflow.
        var toolsExecutedInWorkflow: Bool

        /// Message IDs retrieved via Phase 3 retrieval (prevents duplication).
        var retrievedMessageIds: Set<UUID>

        /// Whether any errors occurred during workflow.
        var hadErrors: Bool

        /// Errors encountered during workflow.
        var errors: [Error]

        // MARK: - Configuration

        /// Conversation ID for this workflow.
        let conversationId: UUID

        /// Model being used for this workflow.
        let model: String

        /// SAM configuration (if provided).
        let samConfig: SAMConfig?

        /// Whether this is a streaming workflow (strategy flag).
        let isStreaming: Bool

        /// Conversation session for safe async operations (Task 19: Prevent state leakage)
        /// Session snapshots conversation context preventing data leakage when user switches conversations
        var session: ConversationSession?

        // MARK: - Workflow Control

        /// Whether workflow should continue (false to terminate early).
        var shouldContinue: Bool

        /// Reason for workflow completion (if shouldContinue is false).
        var completionReason: CompletionReason?

    /// Number of premature stop retries (CLIO-style: nudge once on empty response after tool use).
    var prematureStopRetries: Int

    /// Number of todo continuation nudges (when AI stops with incomplete todos).
    var todoNudgeRetries: Int

    /// Pending todo nudge message to inject at the start of the next iteration.
    /// Stored here because ephemeral messages are cleared at iteration start.
    var pendingTodoNudgeMessage: OpenAIChatMessage?

        // MARK: - Lifecycle

        init(
            conversationId: UUID,
            model: String,
            maxIterations: Int,
            samConfig: SAMConfig? = nil,
            isStreaming: Bool = false,
            currentStatefulMarker: String? = nil
        ) {
            /// Core state.
            self.iteration = 0
            self.maxIterations = maxIterations
            self.workflowRounds = []

            /// Current round tracking.
            self.currentRoundToolCalls = []
            self.currentRoundToolResults = [:]
            self.currentRoundStartTime = Date()
            self.currentRoundLLMResponse = nil

            /// Workflow history.
            self.internalMessages = []
            self.ephemeralMessages = []

            /// LLM response state.
            self.lastResponse = ""
            self.rawLastResponse = nil
            self.lastFinishReason = ""
            self.finalResponseAddedToConversation = false

            /// Agent Loop Escape Route.
            self.toolFailureTracking = [:]
            self.lastIterationToolNames = []
            self.lastIterationHadToolResults = false
            self.previousToolCallSignatures = []
            self.duplicateToolCallCount = 0

            /// Continuation status.
            self.useContinuationResponse = false
            self.continuationToolCalls = nil

            self.detectedStopMarker = false  // Agent Loop Escape

            /// GitHub Copilot session state.
            self.currentStatefulMarker = currentStatefulMarker
            self.statefulMarkerMessageCount = nil
            self.sentInternalMessagesCount = 0

            /// Workflow metadata.
            self.toolsExecutedInWorkflow = false
            self.retrievedMessageIds = []
            self.hadErrors = false
            self.errors = []

            /// Configuration.
            self.conversationId = conversationId
            self.model = model
            self.samConfig = samConfig
            self.isStreaming = isStreaming
            self.session = nil  // Set by caller after creating session

            /// Workflow control.
            self.shouldContinue = true
            self.completionReason = nil
            self.prematureStopRetries = 0
            self.todoNudgeRetries = 0
            self.pendingTodoNudgeMessage = nil
        }
    }
    /// Validates and executes a phase transition.

    // MARK: - Helper Methods

    /// Complete the current iteration and capture WorkflowRound This is the SINGLE endpoint for iteration completion in the entire AgentOrchestrator.
    private func completeIteration(
        context: inout WorkflowExecutionContext,
        responseStatus: String,
        metadata: [String: String] = [:]
    ) {
        /// Calculate duration for this round.
        let duration = Date().timeIntervalSince(context.currentRoundStartTime)

        /// Create WorkflowRound from current tracking state.
        let round = WorkflowRound(
            iterationNumber: context.iteration,
            toolCalls: context.currentRoundToolCalls,
            toolResults: context.currentRoundToolResults,
            llmResponseText: context.currentRoundLLMResponse,
            responseStatus: responseStatus,
            metadata: metadata,
            timestamp: context.currentRoundStartTime,
            duration: duration
        )

        /// Add to workflow history.
        context.workflowRounds.append(round)

        /// Log round completion telemetry.
        logger.debug("ROUND_COMPLETE", metadata: [
            "iteration": .stringConvertible(context.iteration),
            "toolCalls": .stringConvertible(round.toolCalls.count),
            "status": .string(responseStatus),
            "duration": .stringConvertible(duration),
            "totalRounds": .stringConvertible(context.workflowRounds.count)
        ])

        /// Reset round tracking for next iteration.
        context.currentRoundToolCalls = []
        context.currentRoundToolResults = [:]
        context.currentRoundStartTime = Date()
        context.currentRoundLLMResponse = nil

        /// Agent Loop Escape - Track tools used in this iteration
        context.lastIterationToolNames = Set(round.toolCalls.map { $0.name })
        
        /// FIX #8: Do NOT reset lastIterationHadToolResults here
        /// It needs to persist into next iteration so graduated intervention can check it
        /// It will be reset at START of next iteration after check completes
    }




    /// Filter internal messages based on workflow round quality to keep context clean This removes messages from failed/error rounds while preserving high-value content.
    private func filterInternalMessagesByRoundQuality(
        messages: [OpenAIChatMessage],
        workflowRounds: [WorkflowRound]
    ) -> [OpenAIChatMessage] {
        /// Quick path: if no rounds or few messages, skip filtering.
        guard !workflowRounds.isEmpty, messages.count > 20 else {
            return messages
        }

        /// Identify low-value rounds (all tools failed, errors, no thinking) CRITICAL FIX: Only filter rounds where ALL tools failed Do NOT filter rounds with ANY successful tool - AI needs to see what worked!.
        let lowValueRounds = workflowRounds.filter { round in
            let allToolsFailed = !round.toolCalls.isEmpty && round.toolCalls.allSatisfy { !$0.success }

            /// Only filter if EVERY tool in the round failed.
            return allToolsFailed
        }

        /// If no low-value rounds, return all messages.
        guard !lowValueRounds.isEmpty else {
            logger.debug("CONTEXT_FILTER: No low-value rounds found, keeping all messages")
            return messages
        }

        /// Build set of tool call IDs from low-value rounds to filter.
        let filterToolCallIds = Set(lowValueRounds.flatMap { round in
            round.toolCalls.map { $0.id }
        })

        logger.debug("CONTEXT_FILTER: Filtering \(filterToolCallIds.count) tool call IDs from low-value rounds")

        /// Filter messages: remove assistant/tool messages from low-value rounds.
        let filteredMessages = messages.filter { message in
            /// Always keep user messages and system messages.
            if message.role == "user" || message.role == "system" {
                return true
            }

            /// For assistant messages with tool calls, check if any tool call is in filter set.
            if message.role == "assistant", let toolCalls = message.toolCalls {
                let hasFilteredToolCall = toolCalls.contains { toolCall in
                    filterToolCallIds.contains(toolCall.id)
                }
                return !hasFilteredToolCall
            }

            /// For tool messages, check if tool call ID is in filter set.
            if message.role == "tool", let toolCallId = message.toolCallId {
                return !filterToolCallIds.contains(toolCallId)
            }

            /// Keep other messages.
            return true
        }

        let removedCount = messages.count - filteredMessages.count
        if removedCount > 0 {
            logger.debug("CONTEXT_FILTER: Removed \(removedCount) messages from \(lowValueRounds.count) low-value rounds")

            /// Report context filtering metrics.
            if let monitor = performanceMonitor {
                /// Estimate tokens saved (rough estimate: 100 tokens per message).
                let estimatedTokensSaved = removedCount * 100

                let metrics = ContextFilteringMetrics(
                    timestamp: Date(),
                    conversationId: nil,
                    originalMessageCount: messages.count,
                    filteredMessageCount: filteredMessages.count,
                    roundsFiltered: lowValueRounds.count,
                    roundsKept: workflowRounds.count - lowValueRounds.count,
                    estimatedTokensSaved: estimatedTokensSaved
                )

                Task { @MainActor in
                    monitor.recordContextFiltering(metrics)
                }
            }
        }

        return filteredMessages
    }

    /// Report workflow completion metrics to PerformanceMonitor.
    private func reportWorkflowMetrics(
        context: WorkflowExecutionContext,
        conversationId: UUID?,
        performanceMonitor: PerformanceMonitor?
    ) {
        guard let monitor = performanceMonitor else { return }

        /// Calculate workflow statistics.
        let totalDuration = context.workflowRounds.reduce(0.0) { $0 + ($1.duration ?? 0.0) }
        let totalToolCalls = context.workflowRounds.reduce(0) { $0 + $1.toolCalls.count }
        let successfulTools = context.workflowRounds.reduce(0) { total, round in
            total + round.toolCalls.filter { $0.success }.count
        }
        let failedTools = totalToolCalls - successfulTools
        let errorRounds = context.workflowRounds.filter { $0.responseStatus.contains("error") }.count

        let metrics = WorkflowMetrics(
            timestamp: Date(),
            conversationId: conversationId,
            totalIterations: context.workflowRounds.count,
            totalDuration: totalDuration,
            totalToolCalls: totalToolCalls,
            successfulToolCalls: successfulTools,
            failedToolCalls: failedTools,
            thinkingRounds: 0,
            errorRounds: errorRounds,
            completionReason: context.completionReason.map { "\($0)" } ?? "unknown"
        )

        Task { @MainActor in
            monitor.recordWorkflow(metrics)
        }

        logger.debug("WORKFLOW_METRICS_REPORTED", metadata: [
            "iterations": .stringConvertible(metrics.totalIterations),
            "toolCalls": .stringConvertible(metrics.totalToolCalls),
            "successRate": .stringConvertible(metrics.toolSuccessRate),
            "thinkingRounds": .stringConvertible(metrics.thinkingRounds),
            "errorRounds": .stringConvertible(metrics.errorRounds)
        ])
    }

    // MARK: - Lifecycle
    public func runAutonomousWorkflow(
        conversationId: UUID,
        initialMessage: String,
        model: String,
        samConfig: SAMConfig? = nil,
        onProgress: ((String) -> Void)? = nil,
        streamContinuation: AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error>.Continuation? = nil
    ) async throws -> AgentResult {
        let workflowStartTime = Date()

        /// WORKFLOW_START - Comprehensive workflow initialization logging.
        logger.debug("WORKFLOW_START", metadata: [
            "conversationId": .string(conversationId.uuidString),
            "model": .string(model),
            "maxIterations": .stringConvertible(maxIterations),
            "isExternalAPICall": .stringConvertible(isExternalAPICall),
            "timestamp": .string(ISO8601DateFormatter().string(from: workflowStartTime))
        ])

        logger.debug("SUCCESS: Starting autonomous workflow for conversation \(conversationId.uuidString)")

        /// Ensure conversation exists - create if needed (API calls may use new UUIDs).
        var conversation = conversationManager.conversations.first(where: { $0.id == conversationId })
        if conversation == nil {
            logger.info("CONVERSATION_CREATION: Creating new conversation for API request", metadata: [
                "conversationId": .string(conversationId.uuidString)
            ])
            let newConv = ConversationModel.withId(conversationId, title: "API Conversation")
            conversationManager.conversations.append(newConv)
            conversation = newConv
            conversationManager.saveConversations()
        }

        /// Add initial user message to conversation ONLY if not already present (prevents duplicate from UI) ChatWidget syncs user message before calling API, so we check first.
        if let conversation = conversation {
            let userMessageAlreadyExists = conversation.messages.contains(where: {
                $0.isFromUser && $0.content == initialMessage
            })

            if !userMessageAlreadyExists {
                conversation.messageBus?.addUserMessage(content: initialMessage)
                /// MessageBus handles persistence automatically
                logger.debug("SUCCESS: Added initial user message to conversation (not present)")
            } else {
                logger.debug("SKIPPED: User message already in conversation (from UI sync)")
            }
        }

        /// Retrieve previous GitHub Copilot response ID for session continuity This prevents duplicate premium quota charges by maintaining previous_response_id.
        var initialStatefulMarker: String?

        if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
            /// Check conversation-level lastGitHubCopilotResponseId first.
            /// This is the authoritative source after workflow completion persistence.
            if let responseId = conversation.lastGitHubCopilotResponseId {
                initialStatefulMarker = responseId
                logger.debug("SUCCESS: Retrieved GitHub Copilot response ID from conversation: \(responseId.prefix(20))...")
            } else if let lastAssistantMessage = conversation.messages.last(where: { !$0.isFromUser }),
                      let responseId = lastAssistantMessage.githubCopilotResponseId {
                /// Fallback: Check last assistant message (legacy path)
                initialStatefulMarker = responseId
                logger.debug("SUCCESS: Retrieved GitHub Copilot response ID from last message: \(responseId.prefix(20))...")
            } else {
                logger.debug("CHECKPOINT_DEBUG: No previous GitHub Copilot response ID found")
            }

            if let lastAssistantMessage = conversation.messages.last(where: { !$0.isFromUser }) {
                /// Detect if last workflow is complete Workflow continuation - check if previous workflow completed.
                let lastContent = lastAssistantMessage.content.lowercased()
                if lastContent.contains("[workflow_complete]") || lastContent.contains("workflow_complete") {
                    logger.info("CONVERSATION_MODE_DETECTED: Last workflow complete")
                } else {
                    logger.debug("WORKFLOW_MODE_DETECTED: Continuing previous workflow")
                }
            } else {
                logger.debug("CHECKPOINT_DEBUG: No assistant messages found in conversation")
            }
        } else {
            logger.debug("CHECKPOINT_DEBUG: Conversation not found in conversationManager.conversations, ID=\(conversationId.uuidString)")
        }

        /// Initialize workflow execution context with all state.
        var context = WorkflowExecutionContext(
            conversationId: conversationId,
            model: model,
            maxIterations: self.maxIterations,
            samConfig: samConfig,
            isStreaming: false,
            currentStatefulMarker: initialStatefulMarker
        )

        /// CRITICAL: Create conversation session to prevent data leakage (Task 19)
        /// Session snapshots conversation context - even if user switches conversations,
        /// this workflow continues with original conversation's context
        guard let session = conversationManager.createSession(for: conversationId) else {
            logger.error("Failed to create session for conversation \(conversationId)")
            throw SessionError.conversationNotFound
        }
        context.session = session
        logger.debug("Created session for autonomous workflow", metadata: [
            "conversationId": .string(conversationId.uuidString),
            "sessionAge": .stringConvertible(0)
        ])

        /// Autonomous loop - continues until workflow complete or limit hit.
        while context.shouldContinue && context.iteration < context.maxIterations {
            /// RESET ROUND TRACKING at start of iteration.
            context.currentRoundStartTime = Date()
            context.currentRoundToolCalls = []
            context.currentRoundToolResults = [:]

            /// ITERATION_START - Track iteration boundaries and cancellation status.
            logger.debug("ITERATION_START", metadata: [
                "iteration": .stringConvertible(context.iteration + 1),
                "maxIterations": .stringConvertible(context.maxIterations),
                "cancellationRequested": .stringConvertible(Task.isCancelled),
                "toolsExecutedSoFar": .stringConvertible(context.toolsExecutedInWorkflow)
            ])

            logger.debug("SUCCESS: Iteration \(context.iteration + 1)/\(context.maxIterations)")
            onProgress?("Iteration \(context.iteration + 1)/\(context.maxIterations)")

            /// Check for cancellation and exit gracefully.
            if Task.isCancelled {
                logger.warning("WORKFLOW_CANCELLED", metadata: [
                    "iteration": .stringConvertible(context.iteration),
                    "lastOperation": .string("iteration start"),
                    "totalRounds": .stringConvertible(context.workflowRounds.count)
                ])
                break
            }

            /// Reset continuation tracking at start of each iteration.
            context.useContinuationResponse = false
            context.continuationToolCalls = nil

            /// CRITICAL: Clear ephemeral messages at start of each iteration.
            /// This prevents accumulation of status/reminder messages across iterations.
            /// FIX #7: DO NOT preserve TOOL_RESULT_CHUNK - they should only appear once per tool call
            /// If agent wants more chunks, it calls read_tool_result which creates a NEW chunk message
            /// Preserving chunks causes infinite loops where agent sees same chunk repeatedly
            
            /// DIAGNOSTIC: Log ephemeral message types before clearing
            if !context.ephemeralMessages.isEmpty {
                let messageTypes = context.ephemeralMessages.compactMap { message -> String? in
                    guard let content = message.content else { return nil }
                    if content.contains("ITERATION STATUS") { return "ITERATION_STATUS" }
                    if content.contains("[TOOL_RESULT_CHUNK]") { return "TOOL_RESULT_CHUNK" }
                    if content.contains("TODO_REMINDER") { return "TODO_REMINDER" }
                    if content.contains("AUTO_CONTINUE") { return "AUTO_CONTINUE" }
                    if content.contains("WORKFLOW REMINDER") { return "WORKFLOW_REMINDER" }
                    if content.contains("WARNING:") { return "WARNING" }
                    return "OTHER"
                }
                logger.debug("EPHEMERAL_CLEAR: Clearing \(context.ephemeralMessages.count) ephemeral messages", metadata: [
                    "types": .string(messageTypes.joined(separator: ", ")),
                    "iteration": .stringConvertible(context.iteration + 1)
                ])
            }
            
            /// Clear all ephemeral messages (no preservation needed)
            context.ephemeralMessages.removeAll()

            /// Inject pending todo nudge message from previous iteration.
            /// Must happen AFTER clearing ephemeral messages so the nudge survives the clear.
            if let pendingMessage = context.pendingTodoNudgeMessage {
                context.ephemeralMessages.append(pendingMessage)
                context.pendingTodoNudgeMessage = nil
                logger.info("TODO_NUDGE: Injected pending todo nudge message into ephemeral (survived clear)")
            }

            /// Active todo guard: when incomplete todos exist, inject a reminder
            /// requiring the agent to include a todo_operations tool call in its response.
            /// This keeps the workflow loop alive (tool_calls -> continue looping).
            if context.iteration > 0 {
                let todoStats = TodoManager.shared.getProgressStatistics(for: conversationId.uuidString)
                let incompleteTodos = todoStats.notStartedTodos + todoStats.inProgressTodos
                if incompleteTodos > 0 && todoStats.totalTodos > 0 {
                    context.ephemeralMessages.append(createSystemReminder(
                        content: "[SYSTEM: You have \(incompleteTodos) incomplete todo items remaining. For each todo: deliver the content (write the text, code, analysis, etc.) AND include a todo_operations tool call to mark it complete and start the next one. Both content AND tool call must be in the same response. Responding without a tool call will terminate the workflow.]",
                        model: model
                    ))
                    logger.debug("TODO_GUARD: Injected active todo reminder (\(incompleteTodos) incomplete)")
                }
            }

            /// Context-aware continuation for non-first iterations
            if context.iteration > 0 {
                let hasToolResults = context.toolsExecutedInWorkflow
                let iterationCount = context.iteration
                let nudge: String
                if hasToolResults && iterationCount >= 3 {
                    // Model has been going for several rounds with tools - nudge hard toward synthesis
                    nudge = "You have gathered sufficient data. Present your findings to the user now."
                } else if hasToolResults {
                    nudge = "Continue working on the task."
                } else {
                    nudge = "Continue working on the task."
                }
                context.ephemeralMessages.append(createSystemReminder(
                    content: nudge,
                    model: model
                ))
            }

            do {
                /// LLM_CALL_START - Track LLM request initiation.
                logger.debug("LLM_CALL_START", metadata: [
                    "iteration": .stringConvertible(context.iteration + 1),
                    "provider": .string(model),
                    "inputMessageCount": .stringConvertible(context.internalMessages.count),
                    "ephemeralMessageCount": .stringConvertible(context.ephemeralMessages.count),
                    "hasStatefulMarker": .stringConvertible(context.currentStatefulMarker != nil),
                    "hasPendingAutoContinue": .stringConvertible(context.ephemeralMessages.count > 1)
                ])

                /// Apply intelligent context filtering before LLM call Filter out messages from low-value rounds (all tools failed, errors with no thinking) RE-ENABLED: Testing with fixed tool system.
                let filteredMessages = filterInternalMessagesByRoundQuality(
                    messages: context.internalMessages,
                    workflowRounds: context.workflowRounds
                )

                /// Combine persistent messages + ephemeral messages for this iteration.
                /// Ephemeral messages come AFTER persistent to be most recent in context.
                let messagesForLLM = filteredMessages + context.ephemeralMessages

                /// Call LLM with combined messages.
                /// UNIFIED PATH: Support both streaming and non-streaming based on continuation parameter
                /// RATE LIMIT HANDLING: Retry indefinitely on rate limit errors (they always clear)
                var response: LLMResponse
                var rateLimitRetryCount = 0
                /// Rate limit retries are unlimited - rate limits always clear eventually.
                /// Uses 15s floor with exponential backoff: 15s, 30s, 60s, 120s, 300s (cap).
                let rateLimitBaseDelay: Double = 15.0
                let rateLimitMaxDelay: Double = 300.0

                if let continuation = streamContinuation {
                    /// STREAMING MODE - Call callLLMStreaming
                    let requestId = UUID().uuidString
                    let created = Int(Date().timeIntervalSince1970)
                    
                    while true {
                        do {
                            response = try await self.callLLMStreaming(
                                conversationId: conversationId,
                                message: context.iteration == 0 ? initialMessage : "Please continue",
                                model: model,
                                internalMessages: messagesForLLM,
                                iteration: context.iteration,
                                continuation: continuation,
                                requestId: requestId,
                                created: created,
                                samConfig: samConfig,
                                statefulMarker: context.currentStatefulMarker,
                                statefulMarkerMessageCount: context.statefulMarkerMessageCount,
                                sentInternalMessagesCount: context.sentInternalMessagesCount,
                                retrievedMessageIds: &context.retrievedMessageIds
                            )
                            break  /// Success - exit retry loop
                        } catch let error as ProviderError {
                            if case .rateLimitExceeded(let message) = error {
                                rateLimitRetryCount += 1
                                /// Rate limits always clear - retry indefinitely with exponential backoff.
                                /// Floor: 15s, doubling: 15/30/60/120/300 (cap).
                                let backoffDelay = min(rateLimitMaxDelay, rateLimitBaseDelay * pow(2.0, Double(rateLimitRetryCount - 1)))
                                logger.warning("RATE_LIMIT_RETRY_STREAMING: Attempt \(rateLimitRetryCount) after \(String(format: "%.1f", backoffDelay))s delay (no max retries - rate limits always clear)")

                                /// Notify UI that we hit a rate limit and are retrying.
                                let providerName = endpointManager.getProviderTypeForModel(model) ?? "Provider"
                                await MainActor.run {
                                    NotificationCenter.default.post(
                                        name: .providerRateLimitHit,
                                        object: nil,
                                        userInfo: [
                                            "retryAfterSeconds": backoffDelay,
                                            "providerName": providerName,
                                            "message": message
                                        ]
                                    )
                                }

                                try await Task.sleep(for: .seconds(backoffDelay))

                                /// Notify UI that retry is starting.
                                await MainActor.run {
                                    NotificationCenter.default.post(name: .providerRateLimitRetrying, object: nil)
                                }

                                continue  /// Retry
                            } else {
                                throw error  /// Re-throw non-rate-limit errors
                            }
                        }
                    }
                } else {
                    /// NON-STREAMING MODE - Call callLLM
                    while true {
                        do {
                            response = try await self.callLLM(
                                conversationId: conversationId,
                                message: context.iteration == 0 ? initialMessage : "Please continue",
                                model: model,
                                internalMessages: messagesForLLM,
                                iteration: context.iteration,
                                samConfig: samConfig,
                                statefulMarker: context.currentStatefulMarker,
                                sentInternalMessagesCount: context.sentInternalMessagesCount,
                                retrievedMessageIds: &context.retrievedMessageIds
                            )
                            break  /// Success - exit retry loop
                        } catch let error as ProviderError {
                            if case .rateLimitExceeded(let message) = error {
                                rateLimitRetryCount += 1
                                /// Rate limits always clear - retry indefinitely with exponential backoff.
                                let backoffDelay = min(rateLimitMaxDelay, rateLimitBaseDelay * pow(2.0, Double(rateLimitRetryCount - 1)))
                                logger.warning("RATE_LIMIT_RETRY: Attempt \(rateLimitRetryCount) after \(String(format: "%.1f", backoffDelay))s delay (no max retries - rate limits always clear)")

                                /// Notify UI that we hit a rate limit and are retrying.
                                let providerName = endpointManager.getProviderTypeForModel(model) ?? "Provider"
                                await MainActor.run {
                                    NotificationCenter.default.post(
                                        name: .providerRateLimitHit,
                                        object: nil,
                                        userInfo: [
                                            "retryAfterSeconds": backoffDelay,
                                            "providerName": providerName,
                                            "message": message
                                        ]
                                    )
                                }

                                try await Task.sleep(for: .seconds(backoffDelay))

                                /// Notify UI that retry is starting.
                                await MainActor.run {
                                    NotificationCenter.default.post(name: .providerRateLimitRetrying, object: nil)
                                }

                                continue  /// Retry
                            } else {
                                throw error  /// Re-throw non-rate-limit errors
                            }
                        }
                    }
                }

                /// Track how many internal messages we sent in this request (for next iteration).
                context.sentInternalMessagesCount = context.internalMessages.count

                /// Capture raw response so we can detect internal markers BEFORE filtering.
                let rawResponse = response.content

                /// Centralized marker processing.
                let handled = await processMarkerEvent(
                    context: &context,
                    conversationId: conversationId,
                    rawResponse: rawResponse,
                    finishReason: response.finishReason,
                    requestId: nil,
                    isToolOutput: false,
                    toolName: nil
                )

                /// Preserve raw content with provider-specific tags for API round-trips.
                context.rawLastResponse = response.rawContent

                if handled {
                    continue
                }

                /// PERSISTENCE FIX: Add message to conversation immediately (matches streaming path behavior) This ensures all workflow messages (planning, individual steps, etc.) are saved Previously, only the FINAL response was saved, causing all intermediate messages to disappear.
                if !context.lastResponse.isEmpty,
                   let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                    /// Check for duplicates before adding.
                    let isDuplicate = conversation.messages.contains(where: {
                        !$0.isFromUser && $0.content == context.lastResponse
                    })

                    if !isDuplicate {
                        logger.debug("MESSAGE_PERSISTENCE: Adding response to conversation (iteration=\(context.iteration), length=\(context.lastResponse.count))")
                        /// CRITICAL FIX: In STREAMING mode, MessageBus creates messages during chunking
                        /// In NON-STREAMING mode, no MessageBus involvement - we must create message here
                        /// Check streamContinuation to determine which mode we're in
                        if streamContinuation == nil {
                            /// Non-streaming mode - manually add message
                            conversation.messageBus?.addAssistantMessage(
                                id: UUID(),
                                content: context.lastResponse,
                                timestamp: Date()
                            )
                            logger.debug("MESSAGE_PERSISTENCE: Created message via MessageBus (non-streaming mode)")
                        } else {
                            /// Streaming mode - MessageBus already created message during chunking
                            logger.debug("MESSAGE_PERSISTENCE: Message already created during streaming (skipping)")
                        }
                        conversationManager.saveConversations()
                        context.finalResponseAddedToConversation = true
                        logger.debug("MESSAGE_PERSISTENCE: Response saved successfully", metadata: [
                            "messageCount": .stringConvertible(conversation.messages.count)
                        ])
                    } else {
                        logger.debug("MESSAGE_PERSISTENCE: SKIPPED - Duplicate response detected")
                    }
                }

                /// LLM_CALL_COMPLETE - Track LLM response and finish reason.
                logger.debug("LLM_CALL_COMPLETE", metadata: [
                    "iteration": .stringConvertible(context.iteration + 1),
                    "finishReason": .string(response.finishReason),
                    "hasToolCalls": .stringConvertible(response.toolCalls != nil && !response.toolCalls!.isEmpty),
                    "toolCallCount": .stringConvertible(response.toolCalls?.count ?? 0),
                    "responseLength": .stringConvertible(response.content.count)
                ])

                /// Capture statefulMarker for next iteration (GitHub Copilot session continuity).
                if let marker = response.statefulMarker {
                    context.currentStatefulMarker = marker
                    logger.debug("SUCCESS: Updated statefulMarker for next iteration: \(marker.safePrefix(20))...")
                }

                logger.debug("SUCCESS: LLM response received, finish_reason=\(context.lastFinishReason)")
                logger.debug("DEBUG_WORKFLOW: iteration=\(context.iteration), toolsExecutedInWorkflow=\(context.toolsExecutedInWorkflow), lastResponse.count=\(context.lastResponse.count), lastFinishReason=\(context.lastFinishReason)")

                /// Track LLM response characteristics for debugging collaboration issues.
                logger.debug("DEBUG_COLLABORATION_BUG: iteration=\(context.iteration), isEmpty=\(response.content.isEmpty), contentLength=\(response.content.count), finishReason=\(response.finishReason)")
                if !response.content.isEmpty {
                    logger.debug("DEBUG_COLLABORATION_BUG: content.prefix(200)=\"\(response.content.safePrefix(200))\"")
                }

                /// Note: Iteration response tracked in workflowRounds via currentRoundLLMResponse.

                /// This violated Claude API's rule about alternating user/assistant messages
                /// In delta-only mode, internalMessages should ONLY contain tool calls and tool results
                /// Assistant responses are already in conversation.messages and will be sent via statefulMarker continuation
                /// CRITICAL: Commenting out this block fixes the "consecutive assistant messages" 400 error
                /*
                if context.lastFinishReason != "tool_calls" && !context.lastResponse.isEmpty {
                    context.internalMessages.append(OpenAIChatMessage(
                        role: "assistant",
                        content: context.lastResponse
                    ))
                    logger.debug("CONTINUATION_CONTEXT: Added assistant response to internalMessages for continuation check")
                }
                */

                /// Check workflow phase and handle completion processMarkerEvent already handled all phase transitions and directive injections We just need to check if workflow is complete and handle tool calls.

                /// Check if workflow is complete.
                if !context.shouldContinue {
                    logger.info("WORKFLOW_COMPLETE", metadata: [
                        "conversationId": .string(conversationId.uuidString),
                        "iterations": .stringConvertible(context.iteration + 1)
                    ])
                    completeIteration(context: &context, responseStatus: "workflow_complete")
                    break
                }

                /// If no tool calls, check for premature stop or natural completion.
                /// CLIO-style: model decides when it's done by not calling tools.
                if context.lastFinishReason != "tool_calls" {
                    
                    /// Premature stop detection (matches CLIO WorkflowOrchestrator):
                    /// If previous iterations executed tools AND current response is empty,
                    /// this is likely a premature API stop, not a genuine final answer.
                    if context.toolsExecutedInWorkflow && context.prematureStopRetries < maxPrematureStopRetries {
                        let contentLength = context.lastResponse.count
                        
                        if contentLength == 0 {
                            /// Empty response after active tool calling - nudge model to continue
                            context.prematureStopRetries += 1
                            logger.info("PREMATURE_STOP: Empty response after tool use - nudging (attempt \(context.prematureStopRetries)/\(maxPrematureStopRetries))")
                            
                            context.ephemeralMessages.append(createSystemReminder(
                                content: "[SYSTEM: Your previous response ended without content. You were actively using tools and appear to have stopped mid-workflow. Please continue where you left off - review your recent tool results and proceed.]",
                                model: model
                            ))
                            
                            completeIteration(context: &context, responseStatus: "premature_stop_nudge")
                            context.iteration += 1
                            self.updateCurrentIteration(context.iteration)
                            continue
                        }
                    }
                    
                    /// Incomplete todo detection: if AI stops with unfinished todos, nudge to continue.
                    /// This prevents the pattern where AI creates a todo list then waits for user input.
                    /// Uses pendingTodoNudgeMessage to survive ephemeral clear at iteration start.
                    if context.toolsExecutedInWorkflow && context.todoNudgeRetries < maxTodoNudgeRetries {
                        let todoStats = TodoManager.shared.getProgressStatistics(for: conversationId.uuidString)
                        let incompleteTodos = todoStats.notStartedTodos + todoStats.inProgressTodos

                        if incompleteTodos > 0 && todoStats.totalTodos > 0 {
                            context.todoNudgeRetries += 1
                            logger.info("TODO_NUDGE: \(incompleteTodos) incomplete todos - nudging agent to continue (attempt \(context.todoNudgeRetries)/\(maxTodoNudgeRetries))")

                            /// Store in pending field so it survives the ephemeral clear at iteration start.
                            context.pendingTodoNudgeMessage = createSystemReminder(
                                content: "[SYSTEM: You responded without any tool calls but have \(incompleteTodos) incomplete todo items. Your workflow will terminate unless you include tool calls. You MUST: 1) Output the deliverable content for the current todo (the actual work product), 2) Call todo_operations to mark it complete and start the next one. Both content AND tool call in the same response.]",
                                model: model
                            )

                            /// Remove the last assistant message to prevent the AI from seeing
                            /// its own previous output and repeating it verbatim.
                            if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }),
                               let messageBus = conversation.messageBus {
                                let messages = messageBus.messages
                                if let lastAssistant = messages.last(where: { !$0.isFromUser && !$0.isToolMessage }) {
                                    messageBus.removeMessage(id: lastAssistant.id)
                                    logger.info("TODO_NUDGE: Removed last assistant message to prevent repetition", metadata: [
                                        "messageId": .string(lastAssistant.id.uuidString),
                                        "contentPreview": .string(String(lastAssistant.content.prefix(80)))
                                    ])
                                }
                            }

                            completeIteration(context: &context, responseStatus: "todo_nudge")
                            context.iteration += 1
                            self.updateCurrentIteration(context.iteration)
                            continue
                        }
                    }

                    /// Model returned content with no tool calls - workflow is done.
                    /// Trust the model's judgment (CLIO principle).
                    logger.info("WORKFLOW_COMPLETE: Natural termination - model returned content without tool calls", metadata: [
                        "iteration": .stringConvertible(context.iteration),
                        "conversationId": .string(conversationId.uuidString),
                        "responseLength": .stringConvertible(context.lastResponse.count)
                    ])
                    completeIteration(context: &context, responseStatus: "natural_completion")
                    break
                }

                /// Extract tool calls from response.
                let actualToolCalls: [ToolCall]
                if context.useContinuationResponse, let continuationCalls = context.continuationToolCalls {
                    actualToolCalls = continuationCalls
                    logger.debug("TOOL_EXECUTION: Using \(actualToolCalls.count) tool calls from continuation response")
                } else if let toolCalls = response.toolCalls {
                    actualToolCalls = toolCalls
                    logger.debug("TOOL_EXECUTION: Using \(actualToolCalls.count) tool calls from LLM response")
                } else {
                    actualToolCalls = []
                    logger.debug("TOOL_EXECUTION: No tool calls to execute")
                }

                // MARK: - Track whether tools have been executed in this workflow
                guard !actualToolCalls.isEmpty else {
                    logger.error("BUG: Reached tool execution code with empty actualToolCalls")
                    completeIteration(context: &context, responseStatus: "unexpected_empty_tools")
                    break
                }

                // MARK: - Duplicate tool call detection
                // Generate normalized fingerprints for this batch of tool calls.
                // Normalizes JSON (sorted keys, rounded floats) so re-ordered arguments match.
                let currentSignatures = Set(actualToolCalls.map { toolCall -> String in
                    "\(toolCall.name):\(Self.normalizeArguments(toolCall.arguments))"
                })
                let allDuplicate = !currentSignatures.isEmpty && currentSignatures.isSubset(of: context.previousToolCallSignatures)

                if allDuplicate {
                    context.duplicateToolCallCount += 1
                    logger.warning("DUPLICATE_TOOL_CALLS: iteration \(context.iteration), consecutive=\(context.duplicateToolCallCount), tools=\(actualToolCalls.map { $0.name })")

                    if context.duplicateToolCallCount >= 2 {
                        // Model has called the same tools with same args 3+ times total.
                        // Return cached results with a strong directive to stop calling tools.
                        logger.error("DUPLICATE_LOOP_BREAK: Forcing stop after \(context.duplicateToolCallCount + 1) identical tool call batches")

                        // Build synthetic tool results pointing back to earlier results.
                        for toolCall in actualToolCalls {
                            let cachedMessage = "[DUPLICATE CALL BLOCKED] You already called \(toolCall.name) with these exact arguments and received the result above. DO NOT call this tool again. Use the results you already have to compose your final response to the user NOW."

                            let toolResultMessage = OpenAIChatMessage(
                                role: "tool",
                                content: cachedMessage,
                                toolCallId: toolCall.id
                            )
                            context.internalMessages.append(toolResultMessage)
                        }

                        completeIteration(context: &context, responseStatus: "duplicate_loop_broken")
                        continue  // Go to next iteration - model will see the directive
                    }
                } else {
                    // New tool calls - reset duplicate counter and record signatures.
                    context.duplicateToolCallCount = 0
                }

                // Record all signatures for future duplicate detection.
                context.previousToolCallSignatures.formUnion(currentSignatures)

                context.toolsExecutedInWorkflow = true

                /// Tool execution resets premature stop counter (agent is making progress).
                context.prematureStopRetries = 0
                context.todoNudgeRetries = 0

                /// Execute all tool calls for this iteration.
                /// UNIFIED PATH: Same scheduler for streaming + non-streaming.
                let executionResults = try await self.executeToolCalls(
                    actualToolCalls,
                    iteration: context.iteration + 1,
                    conversationId: context.session?.conversationId,
                    streaming: streamContinuation.map { continuation in
                        ToolStreamingContext(
                            continuation: continuation,
                            requestId: UUID().uuidString,
                            created: Int(Date().timeIntervalSince1970),
                            model: model
                        )
                    }
                )

                /// ROUND TRACKING: Capture tool calls and results for this iteration.
                for toolCall in actualToolCalls {
                    /// Convert arguments dictionary to string for storage.
                    let argsString: String
                    if let jsonData = try? JSONSerialization.data(withJSONObject: toolCall.arguments),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        argsString = jsonString
                    } else {
                        argsString = toolCall.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                    }

                    let toolCallInfo = ToolCallInfo(
                        id: toolCall.id,
                        name: toolCall.name,
                        arguments: argsString,
                        success: true,
                        error: nil
                    )
                    context.currentRoundToolCalls.append(toolCallInfo)
                }

                /// Capture tool results.
                    var toolEmittedPlanningHandled = false

                    for execution in executionResults {
                    context.currentRoundToolResults[execution.toolCallId] = execution.result

                    /// Centralized marker handling for tool outputs.
                    if await processMarkerEvent(context: &context, conversationId: conversationId, rawResponse: execution.result, finishReason: nil, requestId: nil, isToolOutput: true, toolName: execution.toolName) {
                        toolEmittedPlanningHandled = true
                        break
                    }

                    /// Update success status using actual execution.success field (from MCPToolResult) CRITICAL FIX: Don't rely on "ERROR:" string matching, use the success field!.
                    if let index = context.currentRoundToolCalls.firstIndex(where: { $0.id == execution.toolCallId }) {
                        /// Convert arguments dictionary to string.
                        let argsString: String
                        if let jsonData = try? JSONSerialization.data(withJSONObject: execution.arguments),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            argsString = jsonString
                        } else {
                            argsString = execution.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                        }

                        context.currentRoundToolCalls[index] = ToolCallInfo(
                            id: execution.toolCallId,
                            name: execution.toolName,
                            arguments: argsString,
                            success: execution.success,
                            error: execution.success ? nil : "Tool execution failed"
                        )
                    }
                }

                /// --- MARKER DETECTION INSIDE TOOL OUTPUTS (NON-STREAMING) ---
                /// Only STOP marker remains, and tools should not emit workflow control markers
                /// Workflow completion is determined by orchestrator flow diagram

                /// TOOL_EXECUTION_BATCH_COMPLETE - Track completion of tool execution batch CRITICAL FIX: Count successful/failed tools using actual success field.
                let successfulTools = executionResults.filter { $0.success }.count
                let failedTools = executionResults.count - successfulTools
                logger.debug("TOOL_EXECUTION_BATCH_COMPLETE", metadata: [
                    "iteration": .stringConvertible(context.iteration + 1),
                    "totalTools": .stringConvertible(executionResults.count),
                    "successfulTools": .stringConvertible(successfulTools),
                    "failedTools": .stringConvertible(failedTools)
                ])
                
                /// FIX #8: Track that this iteration had tool results (for alternation enforcement)
                /// This will be checked in next iteration to remind agent to call tools if they only responded with text
                /// Also reset the flag from previous iteration now that we're executing tools again
                context.lastIterationHadToolResults = true

                /// ERROR ADAPTATION: If tools failed, inject concise guidance.
                /// Two levels: normal (fix your approach) and stuck (3+ consecutive failures).
                if failedTools > 0 {
                    let failedToolDetails = executionResults.filter { !$0.success }
                        .map { "\($0.toolName): \($0.result)" }
                        .joined(separator: "\n")

                    /// Track consecutive failures per tool
                    for execution in executionResults where !execution.success {
                        let toolName = execution.toolName
                        if let existing = context.toolFailureTracking[toolName],
                           existing.iteration == context.iteration - 1 {
                            context.toolFailureTracking[toolName] = (context.iteration, existing.failureCount + 1)
                        } else {
                            context.toolFailureTracking[toolName] = (context.iteration, 1)
                        }
                    }

                    let stuckTools = context.toolFailureTracking.filter { $0.value.failureCount >= 3 }

                    let errorGuidanceContent: String
                    if !stuckTools.isEmpty {
                        let stuckToolNames = stuckTools.map { $0.key }.joined(separator: ", ")
                        let maxFailures = stuckTools.values.map { $0.failureCount }.max() ?? 3
                        errorGuidanceContent = """
                        TOOL FAILURE LOOP: \(stuckToolNames) failed \(maxFailures)+ consecutive times.
                        Failed: \(failedToolDetails)
                        This tool is not working. STOP using it entirely.
                        Move on to other tasks or skip this test.
                        Do NOT call \(stuckToolNames) again in this session.
                        """
                        logger.error("TOOL_FAILURE_LOOP", metadata: [
                            "stuckTools": .string(stuckToolNames)
                        ])
                    } else {
                        errorGuidanceContent = """
                        TOOL ERROR: \(failedTools) tool(s) failed:
                        \(failedToolDetails)
                        Read the error, fix parameters or try a different tool. Do not retry unchanged.
                        """
                        logger.warning("TOOL_ERROR: \(failedTools) failed tools")
                    }

                    let wrappedGuidance = "<system-reminder>\n\(errorGuidanceContent)\n</system-reminder>"
                    context.ephemeralMessages.append(OpenAIChatMessage(role: "user", content: wrappedGuidance))
                }

                /// Add tool execution messages to internal tracking (NOT to conversation for UI) This keeps LLM context without polluting the UI display.

                /// 6a.
                let openAIToolCalls = actualToolCalls.map { toolCall in
                    /// Convert arguments dict to JSON string.
                    let argsData = try? JSONSerialization.data(withJSONObject: toolCall.arguments, options: [])
                    let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                    return OpenAIToolCall(
                        id: toolCall.id,
                        type: "function",
                        function: OpenAIFunctionCall(name: toolCall.name, arguments: argsString)
                    )
                }

                context.internalMessages.append(OpenAIChatMessage(
                    role: "assistant",
                    content: context.rawLastResponse ?? context.lastResponse,
                    toolCalls: openAIToolCalls
                ))

                logger.debug("SUCCESS: Added assistant message with \(openAIToolCalls.count) tool_calls to internal tracking")

                /// 6b. Add tool results to internal messages
               /// For large results (>8KB), persist them to disk and send preview + marker
               for execution in executionResults {
                    // SECURITY: Sanitize tool output before sending to AI provider
                    // Strips invisible characters and redacts secrets (PII, API keys, etc.)
                    let sanitizedResult = SecurityPipeline.sanitizeToolOutput(execution.result)

                    let processedContent = toolResultStorage.processToolResult(
                        toolCallId: execution.toolCallId,
                        content: sanitizedResult,
                        conversationId: conversationId
                    )

                    context.internalMessages.append(OpenAIChatMessage(
                        role: "tool",
                        content: processedContent,
                        toolCallId: execution.toolCallId
                    ))
                }

                logger.debug("SUCCESS: Added \(executionResults.count) tool result messages to internal tracking (with size optimization)")

                /// 6c: Add tool execution messages to conversation for persistence
                /// EXCEPTION: Skip user_collaboration - its result shouldn't appear as a tool card
                /// CRITICAL: Use MessageBus for proper message management and performance
                /// CRITICAL FIX: Skip if streaming (streaming path already created tool messages)
                if streamContinuation == nil {
                    await MainActor.run {
                        guard let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) else {
                            return
                        }

                        for execution in executionResults {
                            /// Skip collaboration tool results - they're internal workflow only
                            if execution.toolName == "user_collaboration" {
                                self.logger.info("Skipping tool card for user_collaboration (internal workflow only)")
                                continue
                            }

                            /// Determine status based on execution.success
                            let status: ConfigurationSystem.ToolStatus = execution.success ? .success : .error

                            /// Add tool message via MessageBus (not legacy conversation.addToolMessage)
                            conversation.messageBus?.addToolMessage(
                                id: UUID(),
                                name: execution.toolName,
                                status: status,
                                details: execution.result,
                                toolDisplayData: nil,
                                toolCallId: execution.toolCallId
                            )
                        }

                        logger.debug("MESSAGEBUS_TOOL_PERSISTENCE: Added \(executionResults.count) tool messages via MessageBus (non-streaming)")
                    }
                } else {
                    logger.debug("MESSAGEBUS_TOOL_SKIP: Skipping tool message creation (streaming path already created them)")
                }

                /// 6d. Check for user_collaboration tool execution and inject continuation directive
                /// CRITICAL FIX: After user responds via user_collaboration, workflow must continue
                /// The user provided input expecting the agent to proceed with that new information
                let hasUserCollaboration = executionResults.contains { $0.toolName == "user_collaboration" }

                if hasUserCollaboration {
                    logger.info("USER_COLLABORATION_COMPLETE: User provided response - injecting continuation directive")

                    /// Add system message to force continuation with user's response
                    let collaborationContent = """
                        ACTION REQUIRED: Process the user's response and continue with your workflow.

                        The user has provided information you requested via user_collaboration.
                        You MUST:
                        1. Process and acknowledge the user's response
                        2. Continue working on the original task using this new information
                        3. Do NOT end the conversation - the user expects you to proceed

                        If you need additional information, call user_collaboration again.
                        If the task is complete, provide a summary of what was accomplished.
                        """
                    /// CRITICAL: Use ephemeralMessages, NOT internalMessages, to prevent accumulation across iterations
                    context.ephemeralMessages.append(createSystemReminder(content: collaborationContent, model: model))
                }

                /// Check if todo_operations, manage_todo_list or memory_operations was called and update current state.
                var hasManageTodoList = false
                for execution in executionResults {
                    /// Support todo_operations (new), legacy manage_todo_list, and memory_operations with manage_todos.
                    if execution.toolName == "todo_operations" || execution.toolName == "manage_todo_list" || execution.toolName == "memory_operations" {
                        hasManageTodoList = true
                        break
                    }
                }

                /// Check for manage_todos tool execution to track todo state.
                if hasManageTodoList {
                    logger.debug("TODO_EXECUTION: todo management tool detected, reading current state")

                    /// Read the current todo list to check for not-started items.
                    if let readResult = await conversationManager.executeMCPTool(
                        name: "todo_operations",
                        parameters: ["operation": "read"],
                        conversationId: context.session?.conversationId,
                        isExternalAPICall: self.isExternalAPICall
                    ) {
                        logger.debug("TODO_EXECUTION: Read todo list result")

                        /// Parse todos from read result.
                        let parsedTodos = parseTodoList(from: readResult.output.content)

                        /// Update current todo list for next iteration check.
                        currentTodoList = parsedTodos

                        /// Count not-started todos.
                        let notStartedCount = parsedTodos.filter { $0.status == "not-started" }.count

                        if notStartedCount > 0 {
                            logger.debug("TODO_EXECUTION: Found \(notStartedCount) not-started todos after tool execution")
                        } else {
                            logger.debug("TODO_EXECUTION: No not-started todos found after tool execution")
                        }
                    } else {
                        logger.error("TODO_EXECUTION: Failed to read todo list")
                    }
                }

                /// Store hasManageTodoList for continue marker check We'll use this to detect if agent signaled continue without updating progress.
                let didUpdateTodos = hasManageTodoList

                /// Use completeIteration() helper for consistent round tracking.
                completeIteration(context: &context, responseStatus: context.hadErrors ? "error" : "success")
                context.iteration += 1
                self.updateCurrentIteration(context.iteration)

            } catch {
                /// Check if this is a timeout error and enhance message for agent.
                let enhancedError = enhanceTimeoutError(error)

                /// WORKFLOW_ERROR - Comprehensive error logging with context.
                logger.error("WORKFLOW_ERROR", metadata: [
                    "iteration": .stringConvertible(context.iteration + 1),
                    "error": .string(enhancedError.localizedDescription),
                    "toolsExecutedInWorkflow": .stringConvertible(context.toolsExecutedInWorkflow),
                    "lastFinishReason": .string(context.lastFinishReason)
                ])

                logger.error("ERROR: Iteration \(context.iteration + 1) failed: \(enhancedError.localizedDescription)")
                context.hadErrors = true
                context.errors.append(enhancedError)

                /// Complete iteration with error status.
                completeIteration(context: &context, responseStatus: "error")

                /// Decide whether to continue or fail.
                if context.iteration == 0 {
                    /// First iteration failed - propagate error.
                    throw enhancedError
                } else {
                    /// Later iteration failed - return partial results.
                    logger.warning("WARNING: Returning partial results after error")
                    break
                }
            }
        }

        // MARK: - workflow completion with comprehensive metrics
        let completionReason: CompletionReason
        if context.hadErrors {
            completionReason = .error
        } else if context.iteration >= context.maxIterations {
            completionReason = .maxIterationsReached
        } else {
            completionReason = .workflowComplete
        }

        logger.debug("WORKFLOW_COMPLETE", metadata: [
            "completionReason": .string("\(completionReason)"),
            "totalIterations": .stringConvertible(context.iteration),
            "totalDuration": .stringConvertible(Date().timeIntervalSince(workflowStartTime)),
            "totalRounds": .stringConvertible(context.workflowRounds.count),
            "hadErrors": .stringConvertible(context.hadErrors)
        ])

        let metadata = WorkflowMetadata(
            completionReason: completionReason,
            totalDuration: Date().timeIntervalSince(workflowStartTime),
            tokensUsed: nil,
            hadErrors: context.hadErrors,
            errors: context.errors
        )

        logger.debug("SUCCESS: Autonomous workflow completed after \(context.iteration) iterations")

        /// Add final LLM response to conversation for UI visibility (ONLY if not already added).
        logger.debug("DEBUG_MISSING_RESPONSE: Checking if should add final response", metadata: [
            "lastResponseEmpty": .stringConvertible(context.lastResponse.isEmpty),
            "finalResponseAddedToConversation": .stringConvertible(context.finalResponseAddedToConversation),
            "lastResponseLength": .stringConvertible(context.lastResponse.count)
        ])

        if !context.lastResponse.isEmpty && !context.finalResponseAddedToConversation,
           let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
            logger.debug("DEBUG_MISSING_RESPONSE: Adding final response to conversation NOW")
            let cleanedResponse = stripSystemReminders(from: context.lastResponse)
            if !cleanedResponse.isEmpty {
                /// CRITICAL FIX: In STREAMING mode, MessageBus creates messages during chunking
                /// In NON-STREAMING mode, no MessageBus involvement - we must create message here
                /// Check streamContinuation to determine which mode we're in
                if streamContinuation == nil {
                    /// Non-streaming mode - manually add final message
                    conversation.messageBus?.addAssistantMessage(
                        id: UUID(),
                        content: cleanedResponse,
                        timestamp: Date()
                    )
                    conversationManager.saveConversations()
                    logger.debug("DEBUG_MISSING_RESPONSE: Created final message via MessageBus (non-streaming mode)")
                } else {
                    /// Streaming mode - MessageBus already created message during chunking
                    logger.debug("DEBUG_MISSING_RESPONSE: Final message already created during streaming (skipping)")
                }
            }
            logger.debug("DEBUG_MISSING_RESPONSE: Final response handled", metadata: [
                "messageCount": .stringConvertible(conversation.messages.count)
            ])
            
            /// Persist statefulMarker to Conversation for session continuity.
            /// This enables GitHub Copilot to use previous_response_id in next request.
            /// Without this, each request restarts billing session and loses continuation.
            if let marker = context.currentStatefulMarker {
                await MainActor.run {
                    conversation.lastGitHubCopilotResponseId = marker
                    conversationManager.saveConversations()
                }
                logger.debug("SUCCESS: Persisted statefulMarker to conversation: \(marker.prefix(20))...")
            } else {
                logger.debug("SUCCESS: Added final response to conversation (no statefulMarker)")
            }
        } else if context.finalResponseAddedToConversation {
            logger.debug("DEBUG_MISSING_RESPONSE: SKIPPED - Final response already added flag is true")
        } else if context.lastResponse.isEmpty {
            logger.warning("DEBUG_MISSING_RESPONSE: SKIPPED - lastResponse is empty")
        } else {
            logger.error("DEBUG_MISSING_RESPONSE: SKIPPED - Could not find conversation")
        }

        /// Report workflow completion metrics.
        reportWorkflowMetrics(
            context: context,
            conversationId: conversationId,
            performanceMonitor: performanceMonitor
        )

        /// PTY sessions persist for conversation lifetime, not workflow lifetime Cleanup happens when conversation is closed or app exits.

        /// Fallback auto-naming: if conversation is still unnamed after workflow, name from first user message
        fallbackAutoName(conversationId: conversationId)

        return AgentResult(
            finalResponse: context.lastResponse,
            iterations: context.iteration,
            workflowRounds: context.workflowRounds,
            metadata: metadata
        )
    }

    /// Run autonomous workflow with streaming support for real-time UI updates This method yields ServerOpenAIChatStreamChunk for each LLM token and progress message Enables true streaming UX for autonomous multi-step workflows.
    /// PHASE 5 UNIFICATION: Thin wrapper that delegates to unified runAutonomousWorkflow
    /// This maintains the streaming API while using the single unified implementation
    public func runStreamingAutonomousWorkflow(
        conversationId: UUID,
        initialMessage: String,
        model: String,
        samConfig: SAMConfig? = nil
    ) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {

        /// Reset cancellation flag at start of workflow
        isCancellationRequested = false

        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                logger.debug("TASK_ENTRY: runStreamingAutonomousWorkflow (unified wrapper)")

                /// Set up observer for user responses - emit as streaming user messages
                let responseObserver = ToolNotificationCenter.shared.observeUserResponseReceived { toolCallId, userInput, conversationId in
                    self.logger.info("COLLAB_DEBUG: Observer callback triggered for user response", metadata: [
                        "toolCallId": .string(toolCallId),
                        "userInputLength": .stringConvertible(userInput.count)
                    ])
                    
                    self.logger.info("USER_COLLAB: User response received, persisting and emitting as streaming user message", metadata: [
                        "toolCallId": .string(toolCallId),
                        "userInput": .string(userInput)
                    ])

                    /// PERSIST MESSAGE: Add user's response to conversation (PINNED for context preservation)
                    /// Must use Task @MainActor for Swift 6 concurrency compliance.
                    if let convId = conversationId {
                        Task { @MainActor in
                            if let conversation = self.conversationManager.conversations.first(where: { $0.id == convId }) {
                                /// Check MessageBus messages (source of truth) not conversation.messages
                                let isDuplicate = conversation.messageBus?.messages.contains(where: {
                                    $0.isFromUser && $0.content == userInput
                                }) ?? false

                                if !isDuplicate {
                                    let messageId = conversation.messageBus?.addUserMessage(
                                        content: userInput,
                                        timestamp: Date(),
                                        isPinned: true
                                    )
                                    self.logger.debug("Persisted user collaboration response to conversation (PINNED)", metadata: [
                                        "toolCallId": .string(toolCallId),
                                        "messageId": .string(messageId?.uuidString ?? "unknown"),
                                        "conversationId": .string(convId.uuidString)
                                    ])
                                } else {
                                    self.logger.debug("USER_COLLAB: Skipping duplicate user response persistence", metadata: [
                                        "toolCallId": .string(toolCallId)
                                    ])
                                }
                            }
                        }
                    }

                    /// Emit user's response as a user message chunk
                    let userMessageChunk = ServerOpenAIChatStreamChunk(
                        id: UUID().uuidString,
                        object: "chat.completion.chunk",
                        created: Int(Date().timeIntervalSince1970),
                        model: model,
                        choices: [
                            OpenAIChatStreamChoice(
                                index: 0,
                                delta: OpenAIChatDelta(
                                    role: "user",
                                    content: userInput
                                ),
                                finishReason: nil
                            )
                        ]
                    )
                    
                    self.logger.debug("COLLAB_DEBUG: About to yield user message chunk")
                    continuation.yield(userMessageChunk)
                    self.logger.debug("COLLAB_DEBUG: User message chunk yielded successfully")

                    self.logger.info("USER_COLLAB: User message persisted (PINNED) and emitted via streaming")
                }

                /// Set up observer for user collaboration notifications.
                /// Only emit the SSE event - ChatWidget's parseSSEEvent handler
                /// adds the prompt as a single assistant message via MessageBus.
                let observer = ToolNotificationCenter.shared.observeUserInputRequired { toolCallId, prompt, context, conversationId in
                    /// Emit SSE event for user input required
                    let userInputEvent: [String: Any] = [
                        "type": "user_input_required",
                        "toolCallId": toolCallId,
                        "prompt": prompt,
                        "context": context ?? "",
                        "conversationId": conversationId?.uuidString ?? ""
                    ]

                    /// Serialize event data to JSON string.
                    let eventJSON: String
                    do {
                        let jsonData = try JSONSerialization.data(withJSONObject: userInputEvent, options: [])
                        eventJSON = String(data: jsonData, encoding: .utf8) ?? "{}"
                    } catch {
                        eventJSON = "{\"error\": \"Failed to serialize event\"}"
                    }

                    /// Create custom chunk with special marker that client will parse
                    let customChunk = ServerOpenAIChatStreamChunk(
                        id: UUID().uuidString,
                        object: "chat.completion.chunk",
                        created: Int(Date().timeIntervalSince1970),
                        model: model,
                        choices: [
                            OpenAIChatStreamChoice(
                                index: 0,
                                delta: OpenAIChatDelta(
                                    role: nil,
                                    content: "[SAM_EVENT:user_input_required]\(eventJSON)"
                                ),
                                finishReason: nil
                            )
                        ]
                    )

                    continuation.yield(customChunk)
                    self.logger.debug("Emitted user_input_required SSE event", metadata: [
                        "toolCallId": .string(toolCallId),
                        "prompt": .string(prompt)
                    ])
                }

                defer {
                    /// Clean up observers when stream ends.
                    ToolNotificationCenter.shared.removeObserver(observer)
                    ToolNotificationCenter.shared.removeObserver(responseObserver)
                }

                do {
                    logger.debug("UNIFIED_WRAPPER: Calling runAutonomousWorkflow with streaming continuation")
                    
                    /// Call unified workflow function with streaming continuation
                    /// All workflow logic is now in runAutonomousWorkflow - this is just a thin wrapper
                    _ = try await self.runAutonomousWorkflow(
                        conversationId: conversationId,
                        initialMessage: initialMessage,
                        model: model,
                        samConfig: samConfig,
                        onProgress: nil,
                        streamContinuation: continuation
                    )
                    
                    /// Finish the stream when workflow completes
                    continuation.finish()
                    logger.debug("UNIFIED_WRAPPER: Workflow completed, stream finished")
                    
                } catch {
                    logger.error("ERROR: Streaming autonomous workflow failed: \(type(of: error)) - \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }

    }

    // MARK: - Helper Methods

    /// Normalize tool call arguments for duplicate detection.
    /// Sorts dictionary keys recursively and rounds floats to 2 decimal places
    /// so that re-ordered JSON or floating point drift produces identical fingerprints.
    static func normalizeArguments(_ args: [String: Any]) -> String {
        func normalize(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                return dict.mapValues { normalize($0) }
            } else if let array = value as? [Any] {
                return array.map { normalize($0) }
            } else if let num = value as? Double {
                // Round to 2 decimal places to absorb floating point drift
                return (num * 100).rounded() / 100
            } else if let num = value as? NSNumber {
                let d = num.doubleValue
                return (d * 100).rounded() / 100
            }
            return value
        }
        let normalized = normalize(args)
        if let data = try? JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys]
        ), let str = String(data: data, encoding: .utf8) {
            return str
        }
        // Fallback to sorted key-value pairs
        return args.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }

    // MARK: - Universal Tool Call Parser

    func extractMLXToolCalls(from content: String) -> ([ToolCall], String) {
        /// Use universal extractor.
        let (extractedCalls, cleanedContent, detectedFormat) = toolCallExtractor.extract(from: content)

        /// Convert from ToolCallExtractor.ToolCall to AgentOrchestrator.ToolCall.
        let toolCalls = extractedCalls.compactMap { extractedCall -> ToolCall? in
            /// Parse arguments JSON string to dictionary.
            guard let argsData = extractedCall.arguments.data(using: .utf8),
                  let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
                logger.warning("Failed to parse arguments JSON for tool '\(extractedCall.name)'")
                return nil
            }

            return ToolCall(
                id: extractedCall.id ?? UUID().uuidString,
                name: extractedCall.name,
                arguments: argsDict
            )
        }

        /// Log detected format for visibility.
        switch detectedFormat {
        case .openai:
            logger.debug("Universal extractor detected OpenAI format - \(toolCalls.count) tool calls")

        case .ministral:
            logger.debug("Universal extractor detected Ministral [TOOL_CALLS] format - \(toolCalls.count) tool calls")

        case .qwen:
            logger.debug("Universal extractor detected Qwen <function_call> format - \(toolCalls.count) tool calls")

        case .hermes:
            logger.debug("Universal extractor detected Hermes format - \(toolCalls.count) tool calls")

        case .jsonCodeBlock:
            logger.debug("Universal extractor detected JSON code block format - \(toolCalls.count) tool calls")

        case .bareJSON:
            logger.debug("Universal extractor detected bare JSON format - \(toolCalls.count) tool calls")

        case .none:
            logger.debug("No tool calls detected by universal extractor")
        }

        return (toolCalls, cleanedContent)
    }

    // MARK: - Context Management

}

// MARK: - Timeout Error Enhancement

/// Enhance timeout errors with helpful guidance for agents GitHub API timeouts often occur when agents send too much data (large tool responses, verbose context).
func enhanceTimeoutError(_ error: Error) -> Error {
    /// Check if this is a timeout error.
    let nsError = error as NSError
    let isTimeout = (nsError.domain == NSURLErrorDomain && nsError.code == -1001) ||
                   error.localizedDescription.lowercased().contains("timeout") ||
                   error.localizedDescription.lowercased().contains("timed out")

    guard isTimeout else {
        return error
    }

    /// Create enhanced error message with agent guidance.
    let enhancedMessage = """
    \(error.localizedDescription)

    TIMEOUT GUIDANCE:
    This timeout likely occurred because you sent too much data to the API (common with GitHub Copilot).

    IMMEDIATE ACTIONS:
    1. Reduce tool response sizes - summarize large outputs instead of including full content
    2. Split large operations into smaller chunks
    3. Use pagination for file listings and search results
    4. Avoid sending full file contents in tool responses - use summaries

    EXAMPLES:
    BAD: Including 10,000 lines of file content in tool response
    GOOD: "Found 157 matches across 12 files. Top 10 results: [summary]"

    BAD: Sending entire conversation history with every request
    GOOD: Trimming to last 5-10 relevant messages

    TRY AGAIN with smaller data chunks.
    """

    /// Create new error with enhanced message.
    return NSError(
        domain: nsError.domain,
        code: nsError.code,
        userInfo: [NSLocalizedDescriptionKey: enhancedMessage]
    )
}

/// Strip <userContext>...</userContext> blocks from message content
/// These blocks are injected into EVERY user message and stored permanently in conversation
/// For context management: Keep ONLY on the LATEST user message, strip from all older messages
/// This prevents context explosion (e.g., 13x9800 chars = 127,400 chars of duplicated content)
/// Also handles legacy [User Context: ...] format for backwards compatibility
func stripUserContextBlock(from content: String) -> String {
    var result = content

    /// Try XML format first: <userContext>...</userContext>
    if let xmlStart = result.range(of: "\n\n<userContext>") {
        if let xmlEnd = result.range(of: "</userContext>", range: xmlStart.upperBound..<result.endIndex) {
            result = String(result[..<xmlStart.lowerBound])
        }
    }

    /// Also handle legacy format: [User Context: ...] for backwards compatibility
    if let legacyStart = result.range(of: "\n\n[User Context:") {
        result = String(result[..<legacyStart.lowerBound])
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Clean tool call markers from content Removes <function_call>, <tool_call>, [TOOL_CALLS] blocks that pollute conversation history These markers are used for tool extraction but should not be shown to LLM in subsequent turns.
func cleanToolCallMarkers(from content: String) -> String {
    var cleaned = content

    /// Remove <function_call>...</function_call> blocks (Qwen, Ministral).
    cleaned = cleaned.replacingOccurrences(
        of: "<function_call>[\\s\\S]*?</function_call>",
        with: "",
        options: .regularExpression
    )

    /// Remove <tool_call>...</tool_call> blocks (Hermes).
    cleaned = cleaned.replacingOccurrences(
        of: "<tool_call>[\\s\\S]*?</tool_call>",
        with: "",
        options: .regularExpression
    )

    /// Remove [TOOL_CALLS]...[/TOOL_CALLS] blocks.
    cleaned = cleaned.replacingOccurrences(
        of: "\\[TOOL_CALLS\\][\\s\\S]*?\\[/TOOL_CALLS\\]",
        with: "",
        options: .regularExpression
    )

    /// Clean up multiple newlines left by removal.
    cleaned = cleaned.replacingOccurrences(
        of: "\n\n\n+",
        with: "\n\n",
        options: .regularExpression
    )

    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Convert an EnhancedMessage to an OpenAIChatMessage, preserving tool call structure.
/// This ensures assistant messages with tool_calls and tool result messages retain
/// their proper API format when replayed in conversation history.
func convertEnhancedToAPIMessage(_ message: ConfigurationSystem.EnhancedMessage) -> OpenAIChatMessage {
    // Tool result messages (from tool execution)
    if message.isToolMessage, let toolCallId = message.toolCallId {
        return OpenAIChatMessage(role: "tool", content: message.content, toolCallId: toolCallId)
    }

    let isAssistant = !message.isFromUser
    let role = message.isFromUser ? "user" : "assistant"
    var content = message.content

    // Clean tool call markers from assistant messages
    if isAssistant {
        content = cleanToolCallMarkers(from: content)
    }

    // Convert tool calls if present (assistant messages with tool_calls)
    if isAssistant, let simpleToolCalls = message.toolCalls, !simpleToolCalls.isEmpty {
        let openAIToolCalls = simpleToolCalls.map { simple in
            OpenAIToolCall(
                id: simple.id,
                type: simple.type,
                function: OpenAIFunctionCall(name: simple.function.name, arguments: simple.function.arguments)
            )
        }
        // Content may be empty when assistant only makes tool calls
        let messageContent = content.isEmpty ? nil : content
        return OpenAIChatMessage(role: role, content: messageContent, toolCalls: openAIToolCalls)
    }

    return OpenAIChatMessage(role: role, content: content)
}

// MARK: - Supporting Types

/// Response from LLM call.
struct LLMResponse {
    let content: String
    let finishReason: String
    let toolCalls: [ToolCall]?
    let statefulMarker: String?
    /// Raw content preserving provider-specific tags (e.g., MiniMax <think> tags).
    /// Used for API round-trips where the provider requires full content fidelity.
    /// Falls back to `content` if nil.
    let rawContent: String?

    init(content: String, finishReason: String, toolCalls: [ToolCall]? = nil, statefulMarker: String? = nil, rawContent: String? = nil) {
        self.content = content
        self.finishReason = finishReason
        self.toolCalls = toolCalls
        self.statefulMarker = statefulMarker
        self.rawContent = rawContent
    }
}

/// Tool call information from LLM response.
struct ToolCall: @unchecked Sendable {
    let id: String
    let name: String
    let arguments: [String: Any]
}

/// Sendable wrapper for tool arguments dictionary
/// @unchecked Sendable is safe here because:
/// 1. Dictionary only contains JSON-serializable types (String, Int, Bool, Array, Dictionary)
/// 2. These types are all value types or immutable references
/// 3. Dictionary is captured as immutable `let` binding before crossing actor boundaries
struct SendableArguments: @unchecked Sendable {
    let value: [String: Any]
}

/// Todo item structure for autonomous execution.
struct TodoItem {
    let id: Int
    let title: String
    let description: String
    let status: String
}
