// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConversationEngine
import MCPFramework
import ConfigurationSystem

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
    private let endpointManager: EndpointManager
    private let conversationService: SharedConversationService
    internal let conversationManager: ConversationManager
    public private(set) var maxIterations: Int
    private var onProgress: ((String) -> Void)?
    private var currentTodoList: [TodoItem] = []

    /// Current iteration number (exposed for IterationController protocol)
    public private(set) var currentIteration: Int = 0

    /// Cancellation flag for stopping autonomous workflows
    private var isCancellationRequested = false

    /// Tool card readiness tracking
    /// When tool execution is about to start, toolCardsPending is set to execution IDs
    /// UI acknowledges by setting toolCardsReady to the same IDs
    @Published public var toolCardsPending: Set<String> = []
    @Published public var toolCardsReady: Set<String> = []

    /// Token counter for smart context management Monitors token usage and triggers pruning at 70% threshold.
    private let tokenCounter: TokenCounter = TokenCounter()

    /// Tool result storage for handling large tool outputs
    /// Persists results to disk for retrieval via read_tool_result
    /// Replaces the memory-only ToolResultCache for proper persistence
    private let toolResultStorage = ToolResultStorage()

    /// Flag indicating if this orchestrator is being called by an external API client vs SAM's internal autonomous workflow.
    private let isExternalAPICall: Bool

    /// Terminal manager for visible terminal integration When set, terminal_operations will execute in the visible UI terminal.
    nonisolated(unsafe) private let terminalManager: AnyObject?

    /// Performance monitor for workflow metrics (optional) When set, reports workflow, loop detection, and context filtering metrics.
    public weak var performanceMonitor: PerformanceMonitor?

    /// Universal tool call extractor - supports all formats (OpenAI, Ministral, Qwen, Hermes).
    private let toolCallExtractor = ToolCallExtractor()

    /// YaRN Context Processor for intelligent context management Uses mega 128M token profile supporting massive document analysis (60-100MB+ documents).
    private var yarnProcessor: YaRNContextProcessor?

    /// Tool call stack for tracking nested tool hierarchy When tool A calls tool B, A is on the stack, enabling B to know its parent Stack entries are tool names (e.g., ["researching", "web_operations"]).
    private var toolCallStack: [String] = []

    /// Auto-continue injection retry limit to avoid infinite loops when forcing continuation.
    /// Maximum consecutive auto-continue attempts without tool execution.
    /// Resets to 0 when agent executes tools (making progress).
    /// Higher limit is safe because it resets on progress.
    private let autoContinueRetryLimit: Int = 5

    /// Tools that are ALWAYS planning tools (never produce tangible work output)
    /// All other tools are considered WORK tools that produce real output.
    /// This simplification works because:
    /// - todo_operations is now a separate tool from memory_operations
    /// - memory_operations (search/store) is actual work
    /// - think is planning
    /// - Everything else produces deliverables
    private static let ALWAYS_PLANNING_TOOLS: Set<String> = [
        "think",
        "todo_operations"  // Todo management is workflow control, not work
    ]

    /// Check if a tool call is a WORK tool (produces tangible output)
    /// Simplified: Everything except think and todo_operations is work.
    /// This avoids false positives where store_memory was incorrectly flagged as "planning"
    /// when user explicitly requested "store X as memory" (which IS the deliverable).
    private static func isWorkToolCall(_ toolName: String, arguments: [String: Any]) -> Bool {
        // Only think and todo_operations are planning tools
        // Everything else (including memory_operations) produces real work output
        return !ALWAYS_PLANNING_TOOLS.contains(toolName)
    }

    /// Planning loop counter per conversation (persists across API calls) Tracks how many times [PLANNING_COMPLETE] was emitted without successful plan parsing Key: conversationId, Value: counter (resets when plan successfully parsed).
    private var planningLoopCounters: [UUID: Int] = [:]

    public init(
        endpointManager: EndpointManager,
        conversationService: SharedConversationService,
        conversationManager: ConversationManager,
        maxIterations: Int = WorkflowConfiguration.defaultMaxIterations,
        onProgress: ((String) -> Void)? = nil,
        isExternalAPICall: Bool = false,
        terminalManager: AnyObject? = nil
    ) {
        self.endpointManager = endpointManager
        self.conversationService = conversationService
        self.conversationManager = conversationManager
        self.maxIterations = maxIterations
        self.onProgress = onProgress
        self.isExternalAPICall = isExternalAPICall
        self.terminalManager = terminalManager

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
    private func createSystemReminder(content: String, model: String) -> OpenAIChatMessage {
        /// Use XML tags universally - VS Code uses structured tags for all models
        let wrappedContent = "<system-reminder>\n\(content)\n</system-reminder>"
        return OpenAIChatMessage(role: "user", content: wrappedContent)
    }

    /// Ensure message alternation for Claude API compatibility
    /// Claude requires strict user/assistant alternation, no empty messages, and no consecutive same-role messages
    /// This function fixes message arrays to comply with Claude's requirements while preserving compatibility with other models
    private func ensureMessageAlternation(_ messages: [OpenAIChatMessage]) -> [OpenAIChatMessage] {
        var fixed: [OpenAIChatMessage] = []
        var lastRole: String?

        for message in messages {
            /// Skip empty messages (invalid for Claude)
            let trimmedContent = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedContent.isEmpty else {
                logger.debug("MESSAGE_ALTERNATION: Skipping empty message (role=\(message.role))")
                continue
            }

            /// Handle tool messages separately - they don't participate in alternation
            if message.role == "tool" {
                fixed.append(message)
                continue
            }

            /// Merge consecutive same-role messages
            if message.role == lastRole {
                /// Can only merge user and assistant messages (not system or tool)
                if message.role == "user" || message.role == "assistant" {
                    if let last = fixed.popLast() {
                        /// Merge content with double newline separator
                        let mergedContent = (last.content ?? "") + "\n\n" + (message.content ?? "")

                        /// Create new merged message preserving tool calls if present
                        let mergedMessage: OpenAIChatMessage
                        if let currentToolCalls = message.toolCalls, !currentToolCalls.isEmpty {
                            mergedMessage = OpenAIChatMessage(role: last.role, content: mergedContent, toolCalls: currentToolCalls)
                        } else if let lastToolCalls = last.toolCalls {
                            mergedMessage = OpenAIChatMessage(role: last.role, content: mergedContent, toolCalls: lastToolCalls)
                        } else if let toolCallId = last.toolCallId {
                            mergedMessage = OpenAIChatMessage(role: last.role, content: mergedContent, toolCallId: toolCallId)
                        } else {
                            mergedMessage = OpenAIChatMessage(role: last.role, content: mergedContent)
                        }

                        fixed.append(mergedMessage)
                        logger.debug("MESSAGE_ALTERNATION: Merged consecutive \(message.role) messages")
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

        return validated
    }

    /// Batch consecutive tool result messages for Claude API
    /// Claude Messages API requires ALL tool results from one iteration to be in a SINGLE user message
    /// This function converts: [tool1, tool2, tool3] → [user_with_batched_tools]
    /// Only used for Claude models to fix the tool result batching issue
    private func batchToolResultsForClaude(_ messages: [OpenAIChatMessage]) -> [OpenAIChatMessage] {
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

    /// Strip system-reminder tags from response content
    /// When Claude echoes back <system-reminder> content, we need to filter it out
    /// before showing to user or saving to conversation
    private func stripSystemReminders(from content: String) -> String {
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
    private func lazyFetchModelCapabilitiesIfNeeded(for model: String) async {
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
    private class StreamingToolCalls {
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
        var detectedWorkflowComplete: Bool = false
        var detectedContinue: Bool = false
        var detectedStop: Bool = false  // Agent Loop Escape

        /// Pattern that matched (for telemetry).
        var matchedPattern: String?
        var matchedSnippet: String?
    }

    /// Unified marker detection - detects all control signals in raw LLM response This is the SINGLE SOURCE OF TRUTH for marker detection Call this on raw response BEFORE filtering markers out for user display - Parameter rawResponse: Unfiltered LLM response text - Returns: Structured MarkerFlags with all detected markers.
    private func detectMarkers(in rawResponse: String) -> MarkerFlags {
        var flags = MarkerFlags()
        let lower = rawResponse.lowercased()

        /// JSON FORMAT DETECTION (NEW PREFERRED FORMAT) Look for {"status": "continue"} or {"status": "complete"} or {"status": "stop"} on own line This prevents duplication and is easier to parse/strip.
        let jsonContinuePattern = #"\{\s*"status"\s*:\s*"continue"\s*\}"#
        let jsonCompletePattern = #"\{\s*"status"\s*:\s*"complete"\s*\}"#
        let jsonStopPattern = #"\{\s*"status"\s*:\s*"stop"\s*\}"#  // Agent Loop Escape

        if lower.range(of: jsonContinuePattern, options: [.regularExpression, .caseInsensitive]) != nil {
            flags.detectedContinue = true
            flags.matchedPattern = "JSON: {\"status\": \"continue\"}"
        }

        if lower.range(of: jsonCompletePattern, options: [.regularExpression, .caseInsensitive]) != nil {
            flags.detectedWorkflowComplete = true
            flags.matchedPattern = "JSON: {\"status\": \"complete\"}"
        }

        // Agent Loop Escape - Detect stop status
        if lower.range(of: jsonStopPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            flags.detectedStop = true
            flags.matchedPattern = "JSON: {\"status\": \"stop\"}"
        }

        if !flags.detectedContinue {
            flags.detectedContinue = lower.contains("[continue]")
            if flags.detectedContinue {
                flags.matchedPattern = "LEGACY: [CONTINUE]"
            }
        }

        if !flags.detectedWorkflowComplete {
            flags.detectedWorkflowComplete = lower.contains("[workflow_complete]") ||
                                              lower.contains("[workflow_done]")
            if flags.detectedWorkflowComplete {
                flags.matchedPattern = "LEGACY: [WORKFLOW_COMPLETE]"
            }
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

        /// Detect markers in the raw response.
        let markers = detectMarkers(in: rawResponse)

        /// Assign detected markers to context for workflow continuation logic.
        context.detectedContinueMarker = markers.detectedContinue
        context.detectedWorkflowCompleteMarker = markers.detectedWorkflowComplete
        context.detectedStopMarker = markers.detectedStop  // Agent Loop Escape

        /// Check for stop status (agent is stuck and giving up).
        if markers.detectedStop {
            /// CRITICAL FIX: Block stop if there are incomplete todos
            /// Agent sometimes says it will work, creates todos, then stops without executing
            /// This prevents premature termination when work is still pending
            let incompleteTodos = currentTodoList.filter { $0.status.lowercased() != "completed" }
            
            if !incompleteTodos.isEmpty {
                logger.warning("BLOCKED_PREMATURE_STOP: Agent tried to stop with \(incompleteTodos.count) incomplete todos - converting to continue", metadata: [
                    "conversationId": .string(conversationId.uuidString),
                    "incompleteTodos": .stringConvertible(incompleteTodos.count),
                    "totalTodos": .stringConvertible(currentTodoList.count)
                ])
                
                /// Override stop with continue - agent must complete its work
                context.detectedStopMarker = false
                context.detectedContinueMarker = true
                
                /// Inject a strong reminder that work is incomplete
                context.shouldContinue = true
                return true  /// Continue workflow
            }
            
            logger.warning("WORKFLOW_STOPPED", metadata: [
                "conversationId": .string(conversationId.uuidString),
                "reason": .string("Agent signaled stop status - unable to proceed")
            ])
            context.shouldContinue = false
            context.completionReason = .error

            return true
        }

        /// Check for workflow completion.
        if markers.detectedWorkflowComplete {
            logger.info("WORKFLOW_COMPLETE_DETECTED", metadata: [
                "conversationId": .string(conversationId.uuidString)
            ])
            context.shouldContinue = false
            context.completionReason = .workflowComplete
            return true
        }

        return false
    }

    /// If the workflow naturally terminated but there are incomplete todos, inject a user message to force continuation.
    /// Inject auto-continue directive if todos are incomplete
    /// - Parameters:
    ///   - context: Workflow execution context (modified in place)
    ///   - conversationId: UUID of the conversation
    ///   - model: Model name to determine proper message formatting (Claude vs GPT)
    ///   - enableWorkflowMode: Whether workflow mode is enabled (only remove messages in workflow mode)
    /// - Returns: true if directive was injected, false otherwise
    private func injectAutoContinueIfTodosIncomplete(
        context: inout WorkflowExecutionContext,
        conversationId: UUID,
        model: String,
        enableWorkflowMode: Bool
    ) async -> Bool {
        /// Don't attempt if workflow already marked complete.
        guard !context.detectedWorkflowCompleteMarker else { return false }

        /// Respect retry limit to avoid infinite auto-continue loops.
        if context.autoContinueAttempts >= autoContinueRetryLimit {
            logger.debug("AUTO_CONTINUE: retry limit reached (", metadata: ["attempts": .stringConvertible(context.autoContinueAttempts)])
            return false
        }

        /// Attempt to read the todo list via todo_operations.
        if let readResult = await conversationManager.executeMCPTool(
            name: "todo_operations",
            parameters: ["operation": "read"],
            conversationId: context.session?.conversationId,
            isExternalAPICall: self.isExternalAPICall,
            iterationController: self
        ) {
            logger.debug("AUTO_CONTINUE: Retrieved todo list for continuation check")

            /// Parse todos and update currentTodoList.
            let parsedTodos = parseTodoList(from: readResult.output.content)
            currentTodoList = parsedTodos

            let incomplete = parsedTodos.filter { $0.status.lowercased() != "completed" }
            if !incomplete.isEmpty {
                context.autoContinueAttempts += 1
                logger.debug("AUTO_CONTINUE: \(incomplete.count) of \(parsedTodos.count) todos incomplete - injecting continue directive (attempt \(context.autoContinueAttempts))")

                /// Include current status to help agent understand state
                let inProgress = incomplete.filter { $0.status.lowercased() == "in-progress" }
                let notStarted = incomplete.filter { $0.status.lowercased() == "not-started" }

                /// GRADUATED AUTO-CONTINUE RESPONSES
                /// Escalate from gentle reminder → stronger intervention → failure warning
                /// This breaks the planning-confirmation loop where agent keeps saying "I'll start..."
                /// 
                /// CRITICAL: Use BOTH autoContinueAttempts AND planningOnlyIterations to determine level
                /// If agent has been calling only planning tools (planningOnlyIterations > 0), escalate faster
                let effectiveLevel = max(context.autoContinueAttempts, context.planningOnlyIterations)

                let promptContent: String

                switch effectiveLevel {
                case 1:
                    /// First level: Standard reminder (current behavior)
                    promptContent = buildAutoContinueLevel1(inProgress: inProgress, notStarted: notStarted)

                case 2:
                    /// Second level: Call out the pattern and demand action
                    promptContent = buildAutoContinueLevel2(inProgress: inProgress, notStarted: notStarted)

                default:
                    /// Third+ level: Final warning - you're in a failure loop
                    promptContent = buildAutoContinueLevel3(inProgress: inProgress, notStarted: notStarted)
                }

                logger.info("AUTO_CONTINUE: Level \(effectiveLevel) intervention injected", metadata: [
                    "autoContinueAttempts": .stringConvertible(context.autoContinueAttempts),
                    "planningOnlyIterations": .stringConvertible(context.planningOnlyIterations),
                    "effectiveLevel": .stringConvertible(effectiveLevel)
                ])

                /// Create properly formatted message based on model type:
                /// - Claude models: wrap in <system-reminder> tags, send as "user" role
                /// - GPT models: no tags, send as "system" role
                let reminderMessage = createSystemReminder(content: promptContent, model: model)

                /// CRITICAL FIX: Store in pendingAutoContinueMessage instead of ephemeralMessages
                /// The bug was: message was appended to ephemeral, then `continue` goes to next iteration,
                /// which immediately clears ephemeral before the LLM can see it!
                /// Now: Store in pending field, inject at START of next iteration AFTER clearing ephemeral
                context.pendingAutoContinueMessage = reminderMessage
                logger.info("AUTO_CONTINUE: Stored intervention in pendingAutoContinueMessage (will be injected at start of next iteration)")

                /// CRITICAL FIX FOR INFINITE LOOP BUG:
                /// When auto-continue triggers after {"status":"stop"}, the agent's PREVIOUS assistant message
                /// is still in the conversation. When the agent sees both its own previous response AND the
                /// auto-continue reminder, it interprets this as "continue from where I was" and REPEATS
                /// the same message verbatim, causing an infinite loop.
                ///
                /// FIX: Remove the last assistant message from the conversation before continuing.
                /// This ensures the agent only sees the reminder, not its own previous output.
                ///
                /// IMPORTANT: Only remove messages when workflow mode is enabled. In normal chat mode,
                /// users expect messages to persist even with incomplete todos.
                if enableWorkflowMode {
                    if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }),
                       let messageBus = conversation.messageBus {
                        /// Find and remove the last assistant message
                        let messages = messageBus.messages
                        if let lastAssistant = messages.last(where: { !$0.isFromUser }) {
                            messageBus.removeMessage(id: lastAssistant.id)
                            logger.info("AUTO_CONTINUE: Removed last assistant message to prevent infinite loop (workflow mode)", metadata: [
                                "messageId": .string(lastAssistant.id.uuidString),
                                "contentPreview": .string(String(lastAssistant.content.prefix(100)))
                            ])
                        }
                    }
                } else {
                    logger.debug("AUTO_CONTINUE: Keeping message visible (workflow mode disabled)")
                }

                return true
            } else {
                logger.debug("AUTO_CONTINUE: No incomplete todos found - not injecting")
            }
        } else {
            logger.debug("AUTO_CONTINUE: Failed to read todo list via manage_todo_list")
        }

        return false
    }

    // MARK: - Graduated Auto-Continue Response Builders

    /// Level 1: Action-forcing reminder - skip planning, execute work
    /// Used on first auto-continue attempt
    /// Key insight from SAM: Don't reinforce todo management, force WORK tool execution
    private func buildAutoContinueLevel1(inProgress: [TodoItem], notStarted: [TodoItem]) -> String {
        if let firstTask = inProgress.first ?? notStarted.first {
            var prompt = "EXECUTE NOW - Do not restate your plan or update todos. "
            prompt += "Your next action MUST be a tool call that produces actual work output. "
            prompt += "\n\nCurrent task: \"\(firstTask.title)\""
            if !firstTask.description.isEmpty {
                prompt += "\nDescription: \(firstTask.description)"
            }
            prompt += "\n\nUse your available tools to execute this task directly."
            prompt += "\nDo NOT output any text before your tool call. Just call the tool."
            prompt += "\nAfter getting results, THEN update your todo status."
            return prompt
        }

        var prompt = "EXECUTE NOW - Do not restate your plan or update todos. "
        prompt += "Your next action MUST be a tool call that produces actual work output. "
        prompt += "\n\nDo NOT output any text before your tool call. Just call the tool."
        prompt += "\nAfter getting results, THEN update your todo status."
        return prompt
    }

    /// Level 2: Stronger intervention - explicitly break the planning loop
    /// Used on second auto-continue attempt - agent is definitely stuck
    /// Key insight: The reminder itself was reinforcing the loop by talking about todos
    private func buildAutoContinueLevel2(inProgress: [TodoItem], notStarted: [TodoItem]) -> String {
        var prompt = "PLANNING LOOP DETECTED - You have outlined your plan multiple times without executing. "
        prompt += "This is a failure pattern. STOP planning. START executing."
        prompt += "\n\n=== WHAT YOU'VE BEEN DOING (WRONG) ==="
        prompt += "\nPlan → Outline todos → Restate plan → Update todos → Restate plan..."

        if let firstTask = inProgress.first ?? notStarted.first {
            prompt += "\n\n=== WHAT YOU MUST DO NOW (CORRECT) ==="
            prompt += "\nCall a tool immediately that produces actual work output."
            prompt += "\nNo text output. No todo updates. Just execute."
            prompt += "\n\n=== YOUR TASK ==="
            prompt += "\n\"\(firstTask.title)\""
            if !firstTask.description.isEmpty {
                prompt += "\n\(firstTask.description)"
            }
            prompt += "\n\nUse your available tools to complete this task. Your response must START with a tool call, not text."
        } else {
            prompt += "\n\n=== WHAT YOU MUST DO NOW (CORRECT) ==="
            prompt += "\nCall a tool immediately. No text output. No todo updates. Just execute."
        }

        return prompt
    }

    /// Level 3: Final warning with escape hatch
    /// Used on third+ auto-continue attempt - last chance
    /// Key insight: Provide both a clear action path AND an escape route
    private func buildAutoContinueLevel3(inProgress: [TodoItem], notStarted: [TodoItem]) -> String {
        var prompt = "FINAL WARNING: You are stuck in an infinite planning loop. "
        prompt += "You have been asked to execute 3+ times but produced no work output."
        prompt += "\n\n=== THE PROBLEM ==="
        prompt += "\nYou keep restating your plan instead of doing the work."
        prompt += "\nOutlining steps is NOT progress. Updating todos is NOT progress."
        prompt += "\nOnly actual work tool output is progress."
        prompt += "\n\n=== YOUR OPTIONS ==="
        prompt += "\n\nOPTION 1 - Execute now:"

        if let firstTask = inProgress.first ?? notStarted.first {
            prompt += "\nTask: \"\(firstTask.title)\""
            prompt += "\nUse your available tools to DO this task immediately."
            prompt += "\nDo not explain. Do not plan. Just call the tool."
        }

        prompt += "\n\nOPTION 2 - Give up gracefully:"
        prompt += "\nIf you genuinely cannot execute this task, emit: {\"status\":\"stop\"}"
        prompt += "\nThis will end the workflow and inform the user you could not proceed."
        prompt += "\n\n=== INVALID RESPONSES ==="
        prompt += "\n- Any text that restates the plan"
        prompt += "\n- Calling todo_operations to read/update todos"
        prompt += "\n- Saying 'I will now...' or 'Let me...'"
        prompt += "\n- Asking clarifying questions (too late for that)"
        prompt += "\n\nYou must either EXECUTE with a work tool or STOP. No other response is acceptable."
        return prompt
    }

    /// Container for ALL workflow state during autonomous execution This struct provides a single source of truth for workflow state, enabling unified handling of both streaming and non-streaming paths.
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

        /// DEPRECATED: Thinking steps from think tool (if any) for current iteration.
        var currentRoundThinkingSteps: [String]?

        /// Structured thinking captured from LLM (Phase 1 enhancement).
        var currentRoundStructuredThinking: [ThinkingStep]?

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

        /// Whether agent has been warned about stop status option.
        var hasSeenStopStatusGuidance: Bool

        // MARK: - Continuation Status

        /// Whether to use continuation response from previous iteration.
        var useContinuationResponse: Bool

        /// Tool calls from continuation_status (if any).
        var continuationToolCalls: [ToolCall]?

        /// Detected internal markers from the raw LLM response (set BEFORE filtering).
        var detectedWorkflowCompleteMarker: Bool
        var detectedContinueMarker: Bool
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

    /// Number of auto-continue injections attempted for this workflow.
    var autoContinueAttempts: Int

    /// Number of consecutive iterations where ONLY planning tools (memory_operations, think) were called
    /// Used to escalate intervention when agent is stuck in planning loop
    var planningOnlyIterations: Int

    /// Pending auto-continue message to inject at start of NEXT iteration
    /// This solves the bug where auto-continue was injected then immediately cleared
    /// The message is set at end of iteration N, then injected into ephemeral at start of N+1
    var pendingAutoContinueMessage: OpenAIChatMessage?

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
            self.currentRoundThinkingSteps = nil
            self.currentRoundStructuredThinking = nil

            /// Workflow history.
            self.internalMessages = []
            self.ephemeralMessages = []

            /// LLM response state.
            self.lastResponse = ""
            self.lastFinishReason = ""
            self.finalResponseAddedToConversation = false

            /// Agent Loop Escape Route.
            self.toolFailureTracking = [:]
            self.lastIterationToolNames = []
            self.hasSeenStopStatusGuidance = false

            /// Continuation status.
            self.useContinuationResponse = false
            self.continuationToolCalls = nil

            self.detectedWorkflowCompleteMarker = false
            self.detectedContinueMarker = false
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
            self.autoContinueAttempts = 0
            self.planningOnlyIterations = 0
            self.pendingAutoContinueMessage = nil
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
            thinkingSteps: context.currentRoundThinkingSteps,
            structuredThinking: context.currentRoundStructuredThinking,
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
        context.currentRoundThinkingSteps = nil
        context.currentRoundStructuredThinking = nil

        /// Agent Loop Escape - Track tools used in this iteration
        context.lastIterationToolNames = Set(round.toolCalls.map { $0.name })
    }

    // MARK: - Helper Methods

    /// Parse thinking steps from think tool execution results Extracts structured thinking from the think tool's output, including: - Reasoning (analysis and problem understanding) - Approach (planned solution steps) - Risks (potential issues and mitigation) - Parameters: - executionResults: Array of tool execution results from current iteration - Returns: Array of thinking step strings, or nil if no think tool was executed.
    private func parseThinkingSteps(from executionResults: [ToolExecution]) -> [String]? {
        /// Find think tool execution.
        guard let thinkExecution = executionResults.first(where: { $0.toolName == "think" }) else {
            return nil
        }

        /// Extract result text.
        let thinkResult = thinkExecution.result

        /// Parse structured thinking sections if present.
        var thinkingSteps: [String] = []

        /// Look for structured sections in think tool output Common patterns from ThinkTool.swift output: - "Reasoning: ..." or "Analysis: ..." - "Approach: ..." or "Solution: ..." - "Risks: ..." or "Potential Issues: ...".

        let sections = [
            ("Reasoning", "reasoning"),
            ("Analysis", "analysis"),
            ("Approach", "approach"),
            ("Solution", "solution"),
            ("Plan", "plan"),
            ("Risks", "risks"),
            ("Potential Issues", "issues"),
            ("Concerns", "concerns")
        ]

        for (sectionName, _) in sections {
            if let sectionStart = thinkResult.range(of: "\(sectionName):", options: .caseInsensitive) {
                let startIndex = sectionStart.upperBound
                var sectionContent = String(thinkResult[startIndex...])

                /// Find end of section (next section marker or end of string).
                for (nextSection, _) in sections {
                    if let nextSectionRange = sectionContent.range(of: "\n\(nextSection):", options: .caseInsensitive) {
                        sectionContent = String(sectionContent[..<nextSectionRange.lowerBound])
                        break
                    }
                }

                /// Clean up and add to thinking steps.
                let cleaned = sectionContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    thinkingSteps.append("\(sectionName): \(cleaned)")
                }
            }
        }

        /// If no structured sections found, capture entire think output as single step.
        if thinkingSteps.isEmpty {
            let cleaned = thinkResult.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                thinkingSteps.append(cleaned)
            }
        }

        return thinkingSteps.isEmpty ? nil : thinkingSteps
    }

    /// Capture structured thinking from LLM response and tool executions Creates ThinkingStep objects with metadata for transparency and debugging.
    private func captureStructuredThinking(
        llmResponse: String?,
        executionResults: [ToolExecution],
        model: String
    ) -> [ThinkingStep]? {
        var thinkingSteps: [ThinkingStep] = []

        /// 1.
        if let thinkExecution = executionResults.first(where: { $0.toolName == "think" }) {
            let thinkResult = thinkExecution.result.trimmingCharacters(in: .whitespacesAndNewlines)

            if !thinkResult.isEmpty {
                let thinkingStep = ThinkingStep(
                    text: thinkResult,
                    timestamp: Date(),
                    tokens: nil,
                    metadata: [
                        "source": "think_tool",
                        "model": model,
                        "toolName": "think"
                    ]
                )
                thinkingSteps.append(thinkingStep)
            }
        }

        /// 2.
        if let response = llmResponse, !response.isEmpty {
            /// Look for common reasoning patterns in LLM responses.
            let reasoningPatterns = [
                "Let me think about",
                "I need to analyze",
                "First, I'\''ll",
                "My approach will be",
                "To solve this"
            ]

            let hasReasoningPattern = reasoningPatterns.contains { pattern in
                response.localizedCaseInsensitiveContains(pattern)
            }

            /// Only capture if response shows explicit reasoning (not just tool calls).
            if hasReasoningPattern && response.count > 50 && response.count < 2000 {
                let thinkingStep = ThinkingStep(
                    text: response,
                    timestamp: Date(),
                    tokens: nil,
                    metadata: [
                        "source": "llm_reasoning",
                        "model": model,
                        "implicit": "true"
                    ]
                )
                thinkingSteps.append(thinkingStep)
            }
        }

        return thinkingSteps.isEmpty ? nil : thinkingSteps
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
        let thinkingRounds = context.workflowRounds.filter { round in
            round.thinkingSteps != nil && !(round.thinkingSteps?.isEmpty ?? true)
        }.count
        let errorRounds = context.workflowRounds.filter { $0.responseStatus.contains("error") }.count

        let metrics = WorkflowMetrics(
            timestamp: Date(),
            conversationId: conversationId,
            totalIterations: context.workflowRounds.count,
            totalDuration: totalDuration,
            totalToolCalls: totalToolCalls,
            successfulToolCalls: successfulTools,
            failedToolCalls: failedTools,
            thinkingRounds: thinkingRounds,
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
        onProgress: ((String) -> Void)? = nil
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
            if let lastAssistantMessage = conversation.messages.last(where: { !$0.isFromUser }) {
                if let responseId = lastAssistantMessage.githubCopilotResponseId {
                    initialStatefulMarker = responseId
                    logger.debug("SUCCESS: Retrieved previous GitHub Copilot response ID: \(responseId.prefix(20))... for session continuity")
                } else {
                    logger.debug("CHECKPOINT_DEBUG: No previous GitHub Copilot response ID found in last assistant message")
                }

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
            context.ephemeralMessages.removeAll()

            /// CRITICAL FIX: Inject pending auto-continue message from PREVIOUS iteration
            /// This message was stored because it couldn't be seen by LLM when appended at end of iteration
            /// (since ephemeral gets cleared at start of next iteration before LLM call)
            /// IMPORTANT: Do NOT clear pendingAutoContinueMessage here - let it persist until agent makes progress
            if let pendingMessage = context.pendingAutoContinueMessage {
                context.ephemeralMessages.append(pendingMessage)
                logger.info("AUTO_CONTINUE: Re-injected pendingAutoContinueMessage (persists until agent makes progress)")
            }

            do {
                /// Inject iteration awareness into LLM context (not just UI) System sees current iteration count and can self-manage budget.
                /// CHANGED: Use ephemeralMessages instead of internalMessages to prevent accumulation.
                let iterationContent = "ITERATION STATUS: Currently on iteration \(context.iteration + 1). Maximum iterations: \(context.maxIterations)."
                context.ephemeralMessages.append(createSystemReminder(content: iterationContent, model: model))

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
                /// RATE LIMIT HANDLING: Retry up to 5 times on rate limit errors invisibly
                var response: LLMResponse
                var rateLimitRetryCount = 0
                let maxRateLimitRetries = 5

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
                        if case .rateLimitExceeded = error {
                            rateLimitRetryCount += 1
                            if rateLimitRetryCount <= maxRateLimitRetries {
                                /// Calculate exponential backoff delay
                                let backoffDelay = pow(2.0, Double(rateLimitRetryCount)) * 2.0  /// 4s, 8s, 16s, 32s, 64s
                                logger.warning("RATE_LIMIT_RETRY: Attempt \(rateLimitRetryCount)/\(maxRateLimitRetries) after \(String(format: "%.1f", backoffDelay))s delay")
                                try await Task.sleep(for: .seconds(backoffDelay))
                                continue  /// Retry
                            } else {
                                /// All retries exhausted - show user-friendly message
                                logger.error("RATE_LIMIT_EXHAUSTED: All \(maxRateLimitRetries) retries failed")
                                throw ProviderError.rateLimitExceeded("The service is busy. Please wait a moment and try again.")
                            }
                        } else {
                            throw error  /// Re-throw non-rate-limit errors
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
                        /// REMOVED: Duplicate message creation - MessageBus already created this during streaming
                        /// conversation.addMessage(text: context.lastResponse, isUser: false, githubCopilotResponseId: context.currentStatefulMarker)
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

                /// REMOVED: Do NOT add assistant responses to internalMessages
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

                /// If no tool calls, we're done with this iteration.
                if context.lastFinishReason != "tool_calls" {
                    /// No tools to execute - check if we need to continue or terminate.

                    /// If processMarkerEvent handled the iteration (injected continuation), skip to next iteration (This case is already handled by the 'handled' check above after processMarkerEvent).

                    /// NO TOOLS CALLED - Only terminate naturally (don't check continue marker here) Continue marker should ONLY be checked after tools are executed This prevents premature continuation before SAM completes actual work.

                    /// Signal 1: Agent signals workflow complete.
                    if context.detectedWorkflowCompleteMarker {
                        logger.info("WORKFLOW_COMPLETE: [WORKFLOW_COMPLETE] signal detected", metadata: [
                            "iteration": .stringConvertible(context.iteration),
                            "conversationId": .string(conversationId.uuidString)
                        ])
                        completeIteration(context: &context, responseStatus: "workflow_complete_signal")
                        break
                    }

                    /// Signal 2: Agent signals continue (simulates user typing "continue") This is how automated workflow continues without user input.
                    if context.detectedContinueMarker {
                        logger.info("WORKFLOW_CONTINUING: [CONTINUE] signal detected (automated continuation)", metadata: [
                            "iteration": .stringConvertible(context.iteration),
                            "conversationId": .string(conversationId.uuidString)
                        ])

                        /// Add "continue" message to conversation history so agent sees new user input
                        /// This prevents the agent from repeating the same output when it sees its own previous response
                        if let conv = conversation {
                            conv.messageBus?.addUserMessage(content: "<system-reminder>continue</system-reminder>", isSystemGenerated: true)
                            logger.debug("Added 'continue' system message to conversation history")
                        }

                        /// TodoReminderInjector provides periodic reminders.
                        /// Agent Loop Escape - Log if agent might be stuck
                        let usedMemoryTools = context.lastIterationToolNames.contains("memory_operations") ||
                                               context.lastIterationToolNames.contains("manage_todo_list") ||
                                               context.lastIterationToolNames.contains("todo_operations")
                        let hasRecentFailures = !context.toolFailureTracking.isEmpty

                        if usedMemoryTools && hasRecentFailures {
                            logger.warning("POTENTIAL_AGENT_BLOCK: Agent used memory/todo tools and has failures", metadata: [
                                "iteration": .stringConvertible(context.iteration),
                                "failures": .stringConvertible(context.toolFailureTracking.count)
                            ])
                        }

                        completeIteration(context: &context, responseStatus: "continue_signal")
                        /// Iteration will be incremented at bottom of loop - don't increment here
                        continue
                    }

                    /// Default: Natural termination (no continue signal) Before terminating, check for incomplete todos and inject an auto-continue directive if needed.
                    let enableWorkflowMode = conversation?.settings.enableWorkflowMode ?? false
                    if await injectAutoContinueIfTodosIncomplete(context: &context, conversationId: conversationId, model: model, enableWorkflowMode: enableWorkflowMode) {
                        logger.debug("AUTO_CONTINUE: Injected continue directive due to incomplete todos", metadata: [
                            "iteration": .stringConvertible(context.iteration)
                        ])
                        completeIteration(context: &context, responseStatus: "auto_continue_injected")
                        /// Iteration will be incremented at bottom of loop - don't increment here
                        continue
                    }

                    /// No auto-continue triggered - end workflow naturally.
                    logger.info("WORKFLOW_COMPLETE: Natural termination (no continue signal)", metadata: [
                        "iteration": .stringConvertible(context.iteration),
                        "conversationId": .string(conversationId.uuidString)
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
                
                context.toolsExecutedInWorkflow = true

                /// PLANNING LOOP DETECTION: Check if ANY work tools were called
                /// If only planning tools (think, memory_operations with manage_todos) were called, don't reset counters
                let workToolsCalled = actualToolCalls.filter { AgentOrchestrator.isWorkToolCall($0.name, arguments: $0.arguments) }
                let onlyPlanningTools = workToolsCalled.isEmpty && !actualToolCalls.isEmpty

                if onlyPlanningTools {
                    /// Agent called tools but NONE were work tools - this is a planning loop
                    context.planningOnlyIterations += 1
                    let toolNames = actualToolCalls.map { $0.name }.joined(separator: ", ")
                    logger.warning("PLANNING_LOOP_DETECTED", metadata: [
                        "iteration": .stringConvertible(context.iteration),
                        "planningOnlyIterations": .stringConvertible(context.planningOnlyIterations),
                        "toolsCalled": .string(toolNames),
                        "message": .string("Only planning tools called - NOT resetting autoContinueAttempts")
                    ])

                    /// CRITICAL FIX: Inject planning loop intervention even without [CONTINUE] marker
                    /// Claude models often don't emit [CONTINUE] but keep calling planning tools in a loop
                    /// If planningOnlyIterations > 3, inject intervention to break the loop
                    if context.planningOnlyIterations > 3 {
                        logger.warning("PLANNING_LOOP_INTERVENTION: Agent stuck in planning loop - injecting intervention", metadata: [
                            "planningOnlyIterations": .stringConvertible(context.planningOnlyIterations)
                        ])

                        let enableWorkflowMode = conversation?.settings.enableWorkflowMode ?? false
                        let injected = await injectAutoContinueIfTodosIncomplete(
                            context: &context,
                            conversationId: conversationId,
                            model: model,
                            enableWorkflowMode: enableWorkflowMode
                        )

                        if injected {
                            logger.info("PLANNING_LOOP_INTERVENTION_INJECTED: Intervention injected to break Claude planning loop", metadata: [
                                "planningOnlyIterations": .stringConvertible(context.planningOnlyIterations),
                                "autoContinueAttempts": .stringConvertible(context.autoContinueAttempts)
                            ])
                        }
                    }
                    /// DO NOT reset autoContinueAttempts - let it escalate
                } else if !workToolsCalled.isEmpty {
                    /// Agent called at least one WORK tool - real progress is being made
                    context.planningOnlyIterations = 0
                    context.autoContinueAttempts = 0
                    context.pendingAutoContinueMessage = nil  // Clear reminder - agent is making progress!
                    let workToolNames = workToolsCalled.map { $0.name }.joined(separator: ", ")
                    logger.debug("WORK_TOOL_EXECUTED", metadata: [
                        "iteration": .stringConvertible(context.iteration),
                        "workTools": .string(workToolNames),
                        "message": .string("Work tools called - resetting counters and clearing pending reminder")
                    ])
                }

                /// Execute all tool calls for this iteration.
                let executionResults = try await self.executeToolCalls(
                    actualToolCalls,
                    iteration: context.iteration + 1,
                    conversationId: context.session?.conversationId
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

                /// --- MARKER DETECTION INSIDE TOOL OUTPUTS (NON-STREAMING) --- Some tools (think/manage_todo_list/etc.) can emit control markers inside their outputs.
                for execution in executionResults {
                    let toolMarkers = detectMarkers(in: execution.result)
                    if toolMarkers.detectedWorkflowComplete {
                        logger.debug("MARKER_DETECTED_IN_TOOL_RESULT", metadata: [
                            "conversationId": .string(conversationId.uuidString),
                            "tool": .string(execution.toolName),
                            "workflow_complete": .stringConvertible(toolMarkers.detectedWorkflowComplete),
                            "matched_pattern": .string(toolMarkers.matchedPattern ?? "none")
                        ])

                        // MARK: - for graceful completion
                        logger.info("WORKFLOW_COMPLETE_MARKER_IN_TOOL: Detected workflow complete in tool output - marking workflow complete")
                        context.detectedWorkflowCompleteMarker = true
                    }
                }

                /// Capture thinking steps from think tool results.
                if let thinkingSteps = parseThinkingSteps(from: executionResults) {
                    context.currentRoundThinkingSteps = thinkingSteps
                    logger.debug("THINKING_CAPTURED", metadata: [
                        "iteration": .stringConvertible(context.iteration),
                        "stepsCount": .stringConvertible(thinkingSteps.count)
                    ])
                }

                /// Capture structured thinking for transparency and debugging.
                if let structuredThinking = captureStructuredThinking(
                    llmResponse: context.currentRoundLLMResponse,
                    executionResults: executionResults,
                    model: context.model
                ) {
                    context.currentRoundStructuredThinking = structuredThinking
                    logger.debug("STRUCTURED_THINKING_CAPTURED", metadata: [
                        "iteration": .stringConvertible(context.iteration),
                        "thinkingSteps": .stringConvertible(structuredThinking.count),
                        "sources": .string(structuredThinking.map { $0.metadata["source"] ?? "unknown" }.joined(separator: ", "))
                    ])
                }

                /// TOOL_EXECUTION_BATCH_COMPLETE - Track completion of tool execution batch CRITICAL FIX: Count successful/failed tools using actual success field.
                let successfulTools = executionResults.filter { $0.success }.count
                let failedTools = executionResults.count - successfulTools
                logger.debug("TOOL_EXECUTION_BATCH_COMPLETE", metadata: [
                    "iteration": .stringConvertible(context.iteration + 1),
                    "totalTools": .stringConvertible(executionResults.count),
                    "successfulTools": .stringConvertible(successfulTools),
                    "failedTools": .stringConvertible(failedTools)
                ])

                /// ERROR ADAPTATION: If tools failed, inject guidance to think and adapt approach.
                /// Agent Loop Escape - Track failures and provide escalating guidance
                if failedTools > 0 {
                    let failedToolDetails = executionResults.filter { !$0.success }
                        .map { "\($0.toolName): \($0.result)" }
                        .joined(separator: "\n")

                    /// Track tool failures to detect stuck loops
                    for execution in executionResults where !execution.success {
                        let toolName = execution.toolName
                        if let existing = context.toolFailureTracking[toolName] {
                            /// Same tool failing in consecutive iterations
                            if existing.iteration == context.iteration - 1 {
                                context.toolFailureTracking[toolName] = (context.iteration, existing.failureCount + 1)
                            } else {
                                /// Different iteration, reset count
                                context.toolFailureTracking[toolName] = (context.iteration, 1)
                            }
                        } else {
                            /// First failure for this tool
                            context.toolFailureTracking[toolName] = (context.iteration, 1)
                        }
                    }

                    /// Check if any tool has failed 3+ times consecutively
                    let stuckTools = context.toolFailureTracking.filter { $0.value.failureCount >= 3 }
                    let isStuck = !stuckTools.isEmpty

                    /// Determine guidance level based on failure count
                    let errorGuidanceContent: String
                    if isStuck {
                        /// STRONG guidance - tool has failed 3+ times
                        let stuckToolNames = stuckTools.map { $0.key }.joined(separator: ", ")
                        context.hasSeenStopStatusGuidance = true
                        errorGuidanceContent = """
                        CRITICAL: TOOL FAILURE LOOP DETECTED

                        The following tool(s) have failed 3+ consecutive times:
                        \(stuckToolNames)

                        \(failedTools) tool(s) failed in this iteration:
                        \(failedToolDetails)

                        YOU MUST TAKE DIFFERENT ACTION:
                        1. DO NOT retry the same tool with the same parameters
                        2. DO NOT continue if you cannot fix the problem
                        3. You have TWO options:

                        OPTION A: Try a completely different approach
                        - Use a different tool
                        - Change your strategy entirely
                        - Break the problem down differently

                        OPTION B: If you cannot proceed, signal stop
                        - Emit: {"status": "stop"}
                        - I will gracefully end the workflow
                        - Explain to the user what you tried and why you're stuck

                        Use the think tool NOW to decide which option to take.
                        """
                    } else if !context.hasSeenStopStatusGuidance {
                        /// STANDARD guidance - first time seeing stop status option
                        context.hasSeenStopStatusGuidance = true
                        errorGuidanceContent = """
                        TOOL ERROR - THINK AND ADAPT

                        \(failedTools) tool(s) failed:
                        \(failedToolDetails)

                        STOP and THINK:
                        1. Why did the tool fail? (Read the error message carefully)
                        2. What parameter should you change? (e.g., add overwrite=true, fix path, change operation)
                        3. Should you try a different tool instead?
                        4. Is this error unrecoverable?

                        DO NOT retry the same tool call without changing something.
                        DO NOT continue if you can't fix the problem.

                        If you cannot proceed after trying alternatives, emit: {"status": "stop"}
                        This will gracefully end the workflow so you can explain the issue to the user.

                        Use the think tool now to plan your adaptation, OR signal stop if truly stuck.
                        """
                    } else {
                        /// BRIEF guidance - agent has already seen stop status option
                        errorGuidanceContent = """
                        TOOL ERROR - ADAPT YOUR APPROACH

                        \(failedTools) tool(s) failed:
                        \(failedToolDetails)

                        You must either:
                        1. Try a different approach (different tool or parameters)
                        2. Signal {"status": "stop"} if you cannot proceed

                        DO NOT retry the same failed operation.
                        """
                    }

                    /// VS CODE COPILOT PATTERN: Use XML tags for ALL models
                    /// Send as user message to avoid consecutive assistant messages that violate Claude API
                    let wrappedGuidance = "<system-reminder>\n\(errorGuidanceContent)\n</system-reminder>"
                    let errorGuidance = OpenAIChatMessage(role: "user", content: wrappedGuidance)
                    context.internalMessages.append(errorGuidance)

                    if isStuck {
                        logger.error("TOOL_FAILURE_LOOP_DETECTED", metadata: [
                            "stuckTools": .string(stuckTools.map { "\($0.key):\($0.value.failureCount)" }.joined(separator: ", "))
                        ])
                    } else {
                        logger.warning("ERROR_ADAPTATION_INJECTED: Added guidance for \(failedTools) failed tools")
                    }
                }

                /// DISABLED - Intent extraction for planning visibility only Intent extraction through think tool is preserved for workflow planning visibility BUT we no longer execute via IntentProcessor - agent executes work directly via normal loop Reasoning: IntentProcessor.executeWorkflow() was never properly implemented - stepExecutor closure only emitted progress messages, didn't do actual work - resulted in "SUCCESS: Write..." messages but no actual content generation - agent is better at autonomous execution via normal tool call loop.

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
                    content: context.lastResponse,
                    toolCalls: openAIToolCalls
                ))

                logger.debug("SUCCESS: Added assistant message with \(openAIToolCalls.count) tool_calls to internal tracking")

                /// 6b. Add tool results to internal messages
                /// For large results (>8KB), persist them to disk and send preview + marker
                for execution in executionResults {
                    let processedContent = toolResultStorage.processToolResult(
                        toolCallId: execution.toolCallId,
                        content: execution.result,
                        conversationId: conversationId
                    )

                    context.internalMessages.append(OpenAIChatMessage(
                        role: "tool",
                        content: processedContent,
                        toolCallId: execution.toolCallId
                    ))
                }

                logger.debug("SUCCESS: Added \(executionResults.count) tool result messages to internal tracking (with size optimization)")

                /// 6c: Add tool execution messages to conversation for persistence (Issue #2 fix)
                /// This ensures tool cards appear in subagent conversations and API exports
                /// EXCEPTION: Skip user_collaboration - its result shouldn't appear as a tool card
                /// CRITICAL: Use MessageBus for proper message management and performance
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

                    logger.debug("MESSAGEBUS_TOOL_PERSISTENCE: Added \(executionResults.count) tool messages via MessageBus")
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
                    context.internalMessages.append(createSystemReminder(content: collaborationContent, model: model))
                }

                let hasThinkTool = executionResults.contains { $0.toolName == "think" }
                let hasManageTodos = executionResults.contains {
                    $0.toolName == "todo_operations" || $0.toolName == "manage_todo_list" || $0.toolName == "memory_operations"
                }

                if hasThinkTool || hasManageTodos {
                    let planningToolsUsed = executionResults.filter {
                        $0.toolName == "think" || $0.toolName == "todo_operations" || $0.toolName == "manage_todo_list" || $0.toolName == "memory_operations"
                    }.map { $0.toolName }.joined(separator: ", ")

                    logger.debug("PLANNING_INTERVENTION: Detected planning tools (\(planningToolsUsed)) - system message injection REMOVED (was causing GitHub Copilot 400 errors)")

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
                /// REMOVED: Duplicate message creation - MessageBus already created this during streaming
                /// conversation.addMessage(text: cleanedResponse, isUser: false, githubCopilotResponseId: context.currentStatefulMarker)
                /// conversationManager.saveConversations()
            }
            logger.debug("DEBUG_MISSING_RESPONSE: Final response handled via MessageBus", metadata: [
                "messageCount": .stringConvertible(conversation.messages.count)
            ])
            if let marker = context.currentStatefulMarker {
                logger.debug("SUCCESS: Added final response to conversation with GitHub Copilot response ID: \(marker.prefix(20))...")
            } else {
                logger.debug("SUCCESS: Added final response to conversation")
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

        return AgentResult(
            finalResponse: context.lastResponse,
            iterations: context.iteration,
            workflowRounds: context.workflowRounds,
            metadata: metadata
        )
    }

    /// Run autonomous workflow with streaming support for real-time UI updates This method yields ServerOpenAIChatStreamChunk for each LLM token and progress message Enables true streaming UX for autonomous multi-step workflows.
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
                logger.debug("TASK_ENTRY: runStreamingAutonomousWorkflow Task block started")

                /// Set up observer for user responses - emit as streaming user messages
                let responseObserver = ToolNotificationCenter.shared.observeUserResponseReceived { toolCallId, userInput, _ in
                    self.logger.info("COLLAB_DEBUG: Observer callback triggered for user response", metadata: [
                        "toolCallId": .string(toolCallId),
                        "userInputLength": .stringConvertible(userInput.count)
                    ])
                    
                    self.logger.info("USER_COLLAB: User response received, emitting as streaming user message", metadata: [
                        "toolCallId": .string(toolCallId),
                        "userInput": .string(userInput)
                    ])

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

                    self.logger.info("USER_COLLAB: User message emitted via streaming")
                }

                /// Set up observer for user collaboration notifications.
                let observer = ToolNotificationCenter.shared.observeUserInputRequired { toolCallId, prompt, context, conversationId in
                    /// FIRST: Emit visible assistant message showing the collaboration request This makes the tool call visible in the UI BEFORE the input prompt appears.
                    let collaborationMessage = "SUCCESS: User Collaboration: \(prompt)"

                    /// PERSIST MESSAGE: Add to conversation so it doesn't disappear after UI refresh.
                    if let convId = conversationId {
                        Task { @MainActor in
                            if let conversation = self.conversationManager.conversations.first(where: { $0.id == convId }) {
                                let isDuplicate = conversation.messages.contains(where: {
                                    !$0.isFromUser && $0.content == collaborationMessage
                                })

                                if !isDuplicate {
                                    /// FEATURE: Pin collaboration message for context persistence
                                    /// Agents should remember what they asked and what users answered
                                    conversation.messageBus?.addAssistantMessage(
                                        id: UUID(),
                                        content: collaborationMessage,
                                        timestamp: Date(),
                                        isPinned: true
                                    )
                                    /// MessageBus handles persistence automatically
                                    self.logger.debug("Persisted collaboration message to conversation (PINNED)", metadata: [
                                        "toolCallId": .string(toolCallId),
                                        "conversationId": .string(convId.uuidString)
                                    ])
                                }
                            }
                        }
                    }

                    let messageChunk = ServerOpenAIChatStreamChunk(
                        id: UUID().uuidString,
                        object: "chat.completion.chunk",
                        created: Int(Date().timeIntervalSince1970),
                        model: model,
                        choices: [
                            OpenAIChatStreamChoice(
                                index: 0,
                                delta: OpenAIChatDelta(
                                    role: "assistant",
                                    content: collaborationMessage
                                ),
                                finishReason: nil
                            )
                        ]
                    )
                    continuation.yield(messageChunk)

                    self.logger.debug("Emitted collaboration message to UI", metadata: [
                        "toolCallId": .string(toolCallId),
                        "message": .string(collaborationMessage)
                    ])

                    /// THEN: Emit custom SSE event for user input required We embed the event as a special marker in the content that the client will parse.
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

                    /// Create custom chunk with special marker that client will parse Format: [SAM_EVENT:user_input_required]<JSON>.
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

                /// Set up observer for image display notifications.
                let imageObserver = ToolNotificationCenter.shared.observeImageDisplay { toolCallId, imagePaths, prompt, conversationId in
                    /// Create SSE event for image display.
                    let imageDisplayEvent: [String: Any] = [
                        "type": "image_display",
                        "toolCallId": toolCallId,
                        "imagePaths": imagePaths,
                        "prompt": prompt,
                        "conversationId": conversationId?.uuidString ?? ""
                    ]

                    /// Serialize event data to JSON string.
                    let eventJSON: String
                    do {
                        let jsonData = try JSONSerialization.data(withJSONObject: imageDisplayEvent, options: [])
                        eventJSON = String(data: jsonData, encoding: .utf8) ?? "{}"
                    } catch {
                        eventJSON = "{\"error\": \"Failed to serialize event\"}"
                    }

                    /// Emit SSE event with special marker for ChatWidget to parse.
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
                                    content: "[SAM_EVENT:image_display]\(eventJSON)"
                                ),
                                finishReason: nil
                            )
                        ]
                    )

                    continuation.yield(customChunk)
                    self.logger.debug("Emitted image_display SSE event", metadata: [
                        "toolCallId": .string(toolCallId),
                        "imageCount": .stringConvertible(imagePaths.count)
                    ])
                }

                defer {
                    /// Clean up observers when stream ends.
                    ToolNotificationCenter.shared.removeObserver(observer)
                    ToolNotificationCenter.shared.removeObserver(responseObserver)
                    ToolNotificationCenter.shared.removeObserver(imageObserver)

                    /// PTY sessions persist for conversation lifetime, not workflow lifetime Cleanup happens when conversation is closed or app exits.
                }

                do {
                    let workflowStartTime = Date()

                    /// WORKFLOW_START - Comprehensive workflow initialization logging (STREAMING).
                    logger.debug("WORKFLOW_START_STREAMING", metadata: [
                        "conversationId": .string(conversationId.uuidString),
                        "model": .string(model),
                        "maxIterations": .stringConvertible(maxIterations),
                        "timestamp": .string(ISO8601DateFormatter().string(from: workflowStartTime))
                    ])

                    logger.debug("SUCCESS: Starting STREAMING autonomous workflow for conversation \(conversationId.uuidString)")

                    /// Ensure conversation exists - create if needed (API calls may use new UUIDs).
                    var conversation = conversationManager.conversations.first(where: { $0.id == conversationId })
                    if conversation == nil {
                        logger.info("CONVERSATION_CREATION_STREAMING: Creating new conversation for API request", metadata: [
                            "conversationId": .string(conversationId.uuidString)
                        ])
                        let newConv = ConversationModel.withId(conversationId, title: "API Conversation")
                        conversationManager.conversations.append(newConv)
                        conversation = newConv
                        conversationManager.saveConversations()
                    }

                    /// Add initial user message to conversation ONLY if not already present (prevents duplicate from UI) ChatWidget syncs user message before calling API, so we check first.
                    if let conversation = conversation {
                        /// Track if this is a NEW conversation (for conversationId bug investigation).
                        let isNewConversation = conversation.messages.isEmpty
                        let messageCount = conversation.messages.count
                        logger.debug("CONV_DEBUG: conversation.messages.count=\(messageCount), isNewConversation=\(isNewConversation)", metadata: [
                            "conversationId": .string(conversationId.uuidString),
                            "messageCount": .stringConvertible(messageCount),
                            "isNew": .stringConvertible(isNewConversation)
                        ])

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

                    let requestId = UUID().uuidString
                    let created = Int(Date().timeIntervalSince1970)

                    /// Retrieve previous GitHub Copilot response ID for session continuity.
                    var initialStatefulMarker: String?

                    if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                        /// PRIORITY 1: Use persisted marker from conversation object.
                        if let marker = conversation.lastGitHubCopilotResponseId {
                            initialStatefulMarker = marker
                            logger.debug("SUCCESS: Retrieved GitHub Copilot response ID: \(marker.prefix(20))... (streaming)")
                        }
                        /// PRIORITY 2: Fallback to last assistant message's marker.
                        else if let lastAssistantMessage = conversation.messages.last(where: { !$0.isFromUser }),
                                let responseId = lastAssistantMessage.githubCopilotResponseId {
                            initialStatefulMarker = responseId
                            logger.debug("SUCCESS: Retrieved GitHub Copilot response ID from last message: \(responseId.prefix(20))... (streaming fallback)")
                        } else {
                            logger.debug("INFO: No previous GitHub Copilot response ID found")
                        }

                        /// Detect if last workflow is complete (STREAMING) If [WORKFLOW_COMPLETE] was detected in the last message, start in conversational mode.
                        if let lastAssistantMessage = conversation.messages.last(where: { !$0.isFromUser }) {
                            let lastContent = lastAssistantMessage.content.lowercased()
                            if lastContent.contains("[workflow_complete]") || lastContent.contains("workflow_complete") {
                                logger.info("CONVERSATION_MODE_DETECTED (streaming): Last workflow complete")
                            } else {
                                logger.debug("WORKFLOW_MODE_DETECTED (streaming): Continuing previous workflow")
                            }
                        }
                    } else {
                        logger.warning("WARNING: Conversation not found - cannot retrieve statefulMarker")
                    }

                    /// Initialize workflow execution context.
                    var context = WorkflowExecutionContext(
                        conversationId: conversationId,
                        model: model,
                        maxIterations: self.maxIterations,
                        samConfig: samConfig,
                        isStreaming: true,
                        currentStatefulMarker: initialStatefulMarker
                    )

                    /// CRITICAL: Create conversation session to prevent data leakage (Task 19)
                    /// Session snapshots conversation context - even if user switches conversations,
                    /// this workflow continues with original conversation's context
                    guard let session = conversationManager.createSession(for: conversationId) else {
                        logger.error("Failed to create session for streaming workflow")
                        continuation.finish(throwing: SessionError.conversationNotFound)
                        return
                    }
                    context.session = session
                    logger.debug("Created session for streaming workflow", metadata: [
                        "conversationId": .string(conversationId.uuidString)
                    ])

                    logger.debug("BEFORE_WHILE_LOOP: About to start autonomous loop with \(context.maxIterations) max iterations")

                    /// Autonomous loop - continues until workflow complete or limit hit.
                    while context.shouldContinue && context.iteration < context.maxIterations {
                        /// ITERATION_START - Track iteration boundaries and cancellation status (STREAMING).
                        logger.debug("ITERATION_START_STREAMING", metadata: [
                            "context.iteration": .stringConvertible(context.iteration + 1),
                            "maxIterations": .stringConvertible(self.maxIterations),
                            "cancellationRequested": .stringConvertible(Task.isCancelled),
                            "toolsExecutedSoFar": .stringConvertible(context.toolsExecutedInWorkflow)
                        ])

                        /// Check cancellation at start of each iteration.
                        if isCancellationRequested {
                            logger.info("WORKFLOW_CANCELLED: Cancellation flag set, exiting workflow")
                            continuation.finish()
                            return
                        }
                        try Task.checkCancellation()

                        logger.debug("SUCCESS: Streaming iteration \(context.iteration + 1)/\(self.maxIterations), statefulMarker=\(context.currentStatefulMarker != nil ? "present" : "nil")")

                        /// Reset continuation tracking at start of each iteration.
                        context.useContinuationResponse = false
                        context.continuationToolCalls = nil

                        /// CRITICAL: Clear ephemeral messages at start of each iteration.
                        /// This prevents accumulation of status/reminder messages across iterations.
                        context.ephemeralMessages.removeAll()

                        /// CRITICAL FIX: Inject pending auto-continue message from PREVIOUS iteration
                        /// This message was stored because it couldn't be seen by LLM when appended at end of iteration
                        /// (since ephemeral gets cleared at start of next iteration before LLM call)
                        if let pendingMessage = context.pendingAutoContinueMessage {
                            context.ephemeralMessages.append(pendingMessage)
                            context.pendingAutoContinueMessage = nil  // Clear after injection
                            logger.info("AUTO_CONTINUE_STREAMING: Injected pendingAutoContinueMessage into ephemeral (from previous iteration)")
                        }

                        logger.debug("ITERATION_START_STREAMING: Starting iteration \(context.iteration + 1) of \(self.maxIterations)")

                        /// LLM_CALL_START - Track LLM request initiation (STREAMING).
                        logger.debug("LLM_CALL_START_STREAMING", metadata: [
                            "context.iteration": .stringConvertible(context.iteration + 1),
                            "provider": .string(model),
                            "inputMessageCount": .stringConvertible(context.internalMessages.count),
                            "ephemeralMessageCount": .stringConvertible(context.ephemeralMessages.count),
                            "hasStatefulMarker": .stringConvertible(context.currentStatefulMarker != nil),
                            "hasPendingAutoContinue": .stringConvertible(context.ephemeralMessages.count > 0)
                        ])

                        /// Apply intelligent context filtering before LLM call (STREAMING) Filter out messages from low-value rounds (all tools failed, errors with no thinking) RE-ENABLED: Testing with fixed tool system.
                        let filteredMessages = filterInternalMessagesByRoundQuality(
                            messages: context.internalMessages,
                            workflowRounds: context.workflowRounds
                        )

                        /// Combine persistent messages + ephemeral messages for this iteration.
                        /// Ephemeral messages come AFTER persistent to be most recent in context.
                        let messagesForLLM = filteredMessages + context.ephemeralMessages

                        logger.debug("DEBUG_BEFORE_LLM_STREAMING: About to call LLM")

                        /// Call LLM and get STREAMING response.
                        /// RATE LIMIT HANDLING: Retry up to 5 times on rate limit errors invisibly
                        var llmResponse: LLMResponse
                        var rateLimitRetryCount = 0
                        let maxRateLimitRetries = 5

                        while true {
                            do {
                                llmResponse = try await self.callLLMStreaming(
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
                                if case .rateLimitExceeded = error {
                                    rateLimitRetryCount += 1
                                    if rateLimitRetryCount <= maxRateLimitRetries {
                                        /// Calculate exponential backoff delay
                                        let backoffDelay = pow(2.0, Double(rateLimitRetryCount)) * 2.0  /// 4s, 8s, 16s, 32s, 64s
                                        logger.warning("RATE_LIMIT_RETRY_STREAMING: Attempt \(rateLimitRetryCount)/\(maxRateLimitRetries) after \(String(format: "%.1f", backoffDelay))s delay")
                                        try await Task.sleep(for: .seconds(backoffDelay))
                                        continue  /// Retry
                                    } else {
                                        /// All retries exhausted - show user-friendly message
                                        logger.error("RATE_LIMIT_EXHAUSTED_STREAMING: All \(maxRateLimitRetries) retries failed")
                                        throw ProviderError.rateLimitExceeded("The service is busy. Please wait a moment and try again.")
                                    }
                                } else {
                                    throw error  /// Re-throw non-rate-limit errors
                                }
                            }
                        }

                        /// Track how many internal messages we sent in this request (for next iteration).
                        context.sentInternalMessagesCount = context.internalMessages.count

                        /// Capture raw streaming response so we can detect internal markers BEFORE filtering.
                        let rawStreamingResponse = llmResponse.content

                        /// Centralized marker processing for streaming responses.
                        let handled = await processMarkerEvent(
                            context: &context,
                            conversationId: conversationId,
                            rawResponse: rawStreamingResponse,
                            finishReason: llmResponse.finishReason,
                            requestId: requestId,
                            isToolOutput: false,
                            toolName: nil
                        )
                        if handled {
                            /// Save message BEFORE continuing When handled=true, processMarkerEvent injected a directive and we're about to continue the loop But we must persist the LLM's response (the one that contained the marker) to prevent data loss.
                            await MainActor.run {
                                if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                                    if !context.lastResponse.isEmpty {
                                        let isDuplicate = conversation.messages.contains(where: {
                                            !$0.isFromUser && $0.content == context.lastResponse
                                        })
                                        if !isDuplicate {
                                            logger.debug("MESSAGE_PERSISTENCE_BEFORE_HANDLED_CONTINUE", metadata: [
                                                "iteration": .stringConvertible(context.iteration),
                                                "length": .stringConvertible(context.lastResponse.count)
                                            ])
                                            let cleanedResponse = stripSystemReminders(from: context.lastResponse)
                                            if !cleanedResponse.isEmpty {
                                                /// REMOVED: Duplicate message creation - MessageBus already created this during streaming
                                                /// conversation.addMessage(text: cleanedResponse, isUser: false, githubCopilotResponseId: context.currentStatefulMarker)
                                                /// conversationManager.saveConversations()
                                                context.finalResponseAddedToConversation = true
                                            }
                                        }
                                    }
                                }
                            }
                            continue
                        }

                        /// LLM_CALL_COMPLETE - Track LLM response and finish reason (STREAMING).
                        logger.debug("LLM_CALL_COMPLETE_STREAMING", metadata: [
                            "context.iteration": .stringConvertible(context.iteration + 1),
                            "finishReason": .string(llmResponse.finishReason),
                            "hasToolCalls": .stringConvertible(llmResponse.toolCalls != nil && !llmResponse.toolCalls!.isEmpty),
                            "toolCallCount": .stringConvertible(llmResponse.toolCalls?.count ?? 0),
                            "responseLength": .stringConvertible(llmResponse.content.count)
                        ])

                        /// Check cancellation after LLM call.
                        try Task.checkCancellation()

                        logger.debug("DEBUG_MISSING_RESPONSE: LLM response received from callLLMStreaming", metadata: [
                            "context.iteration": .stringConvertible(context.iteration),
                            "contentLength": .stringConvertible(context.lastResponse.count),
                            "contentPreview": .string(String(context.lastResponse.safePrefix(150))),
                            "finishReason": .string(context.lastFinishReason),
                            "toolCallsCount": .stringConvertible(llmResponse.toolCalls?.count ?? 0)
                        ])

                        /// Capture statefulMarker for next iteration (GitHub Copilot session continuity).
                        if let marker = llmResponse.statefulMarker {
                            context.currentStatefulMarker = marker
                            /// Capture message count for delta-only slicing in next iteration
                            /// This avoids timing dependencies - we know exactly where to slice from
                            if let conversation = await MainActor.run(body: {
                                conversationManager.conversations.first(where: { $0.id == conversationId })
                            }) {
                                context.statefulMarkerMessageCount = conversation.messages.count
                                logger.debug("BILLING_DEBUG: Captured statefulMarker from LLM response: \(marker.prefix(20))... at message count \(conversation.messages.count)")
                            } else {
                                logger.debug("BILLING_DEBUG: Captured statefulMarker from LLM response: \(marker.prefix(20))...")
                            }
                            logger.debug("SUCCESS: Updated statefulMarker for next context.iteration: \(marker.prefix(20))...")
                        } else {
                            logger.warning("BILLING_WARNING: LLM response had NO statefulMarker!")
                        }

                        /// processMarkerEvent() already handled all phase transitions All planning/execution logic has been moved to processMarkerEvent() to prevent duplication Check if workflow is complete.
                        if !context.shouldContinue {
                            logger.info("WORKFLOW_COMPLETE_STREAMING", metadata: [
                                "conversationId": .string(conversationId.uuidString),
                                "iterations": .stringConvertible(context.iteration + 1)
                            ])
                            completeIteration(context: &context, responseStatus: "workflow_complete_phase_streaming")
                            break
                        }

                        logger.debug("SUCCESS: LLM streaming response complete, finish_reason=\(context.lastFinishReason)")

                        /// Add LLM's response content to conversation (matches non-streaming behavior) Content should ALWAYS be added if non-empty - prevents missing chapter content.
                        logger.debug("DEBUG_MISSING_RESPONSE: About to attempt adding response to conversation", metadata: [
                            "context.iteration": .stringConvertible(context.iteration),
                            "lastResponseLength": .stringConvertible(context.lastResponse.count),
                            "lastResponsePreview": .string(String(context.lastResponse.safePrefix(100))),
                            "finishReason": .string(context.lastFinishReason)
                        ])

                        // MARK: - completed) - Content streams to user but NEVER gets saved to conversation - User sees content during stream, but it vanishes after! NEW BEHAVIOR (FIXED): - Save content if it's substantial (>50 chars), regardless of tool_calls - Prevents losing real content when agent delivers + uses tools together - Still skip pure "thinking" messages (< 50 chars like "SUCCESS: Thinking...")
                        await MainActor.run {
                            if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                                /// Always save messages that have a githubCopilotResponseId, regardless of length These messages are checkpoints for billing session continuity - without them, message slicing fails.
                                let hasStatefulMarker = context.currentStatefulMarker != nil
                                let isSubstantial = context.lastResponse.count > 50

                                /// TOOL PROGRESS FILTER: Never save streaming tool progress messages, even with statefulMarker These are just UI progress indicators ("Running terminal command", "SUCCESS: Getting..."), not real content.
                                let isToolProgressMessage = context.lastResponse.hasPrefix("Running") ||
                                                           context.lastResponse.hasPrefix("SUCCESS:") ||
                                                           context.lastResponse == "Running terminal command" ||
                                                           context.lastResponse.contains("Getting terminal history")

                                /// Save if: (1) NOT tool progress, AND ((2) has tool calls OR (3) has statefulMarker OR (4) substantial content).
                                let hasToolCalls = llmResponse.toolCalls != nil && !llmResponse.toolCalls!.isEmpty
                                if (hasToolCalls || (!context.lastResponse.isEmpty && !isToolProgressMessage && (hasStatefulMarker || isSubstantial))) {
                                    logger.debug("DEBUG_WORKFLOW_STREAMING: iteration=\(context.iteration), toolsExecutedInWorkflow=\(context.toolsExecutedInWorkflow), lastResponse.count=\(context.lastResponse.count), lastFinishReason=\(context.lastFinishReason), hasStatefulMarker=\(hasStatefulMarker), hasToolCalls=\(hasToolCalls)")

                                    /// Check for duplicate before adding (prevents duplicate thinking messages).
                                    let isDuplicate = conversation.messages.contains(where: {
                                        !$0.isFromUser && $0.content == context.lastResponse
                                    })

                                    if !isDuplicate {
                                        logger.debug("DEBUG_MISSING_RESPONSE: Adding response to conversation (finish_reason=\(context.lastFinishReason), hasToolCalls=\(hasToolCalls))")
                                        logger.debug("BILLING_DEBUG: About to add message with githubCopilotResponseId=\(context.currentStatefulMarker?.prefix(20) ?? "nil"), length=\(context.lastResponse.count)")
                                        let cleanedResponse = stripSystemReminders(from: context.lastResponse)
                                        if !cleanedResponse.isEmpty || hasToolCalls {
                                            /// REMOVED: Duplicate message creation - MessageBus already created this during streaming
                                            /// conversation.addMessage(text: cleanedResponse, isUser: false, githubCopilotResponseId: context.currentStatefulMarker)
                                            /// PERSISTENCE FIX: Save immediately after adding message to prevent data loss.
                                            /// conversationManager.saveConversations()
                                            context.finalResponseAddedToConversation = true
                                        }
                                        logger.debug("DEBUG_MISSING_RESPONSE: Response added successfully to conversation", metadata: [
                                            "messageCount": .stringConvertible(conversation.messages.count)
                                        ])
                                        if let marker = context.currentStatefulMarker {
                                            logger.debug("BILLING_SUCCESS: Added LLM response to conversation with githubCopilotResponseId: \(marker.prefix(20))...")
                                            logger.debug("SUCCESS: Added LLM response content to conversation with GitHub Copilot response ID: \(marker.prefix(20))... (\(context.lastResponse.count) chars)")
                                        } else {
                                            logger.warning("BILLING_WARNING: Added message WITHOUT githubCopilotResponseId (context.currentStatefulMarker was NIL)")
                                            logger.debug("SUCCESS: Added LLM response content to conversation (\(context.lastResponse.count) chars)")
                                        }
                                    } else {
                                        logger.warning("DEBUG_MISSING_RESPONSE: SKIPPED - Duplicate response detected in conversation")
                                        logger.debug("SKIPPED: Duplicate LLM response content already in conversation")
                                    }
                                } else if context.lastResponse.count <= 5 && !hasToolCalls {
                                    /// Only skip VERY short responses WITHOUT tool calls (likely thinking indicators or single characters).
                                    logger.debug("DEBUG_MISSING_RESPONSE: SKIPPED - Response too short (\(context.lastResponse.count) chars) with no tool calls, likely just thinking indicator")
                                } else {
                                    logger.warning("DEBUG_MISSING_RESPONSE: SKIPPED - context.lastResponse is empty")
                                }

                                /// Always preserve githubCopilotResponseId for session continuity Without this, checkpoint slicing fails → multiple premium charges.
                                if let marker = context.currentStatefulMarker {
                                    conversation.lastGitHubCopilotResponseId = marker
                                    conversationManager.saveConversations()
                                    logger.debug("BILLING_FIX: Saved lastGitHubCopilotResponseId to conversation: \(marker.prefix(20))...")
                                }
                            } else {
                                logger.error("DEBUG_MISSING_RESPONSE: ERROR - Could not find conversation \(conversationId)")
                                logger.warning("WARNING: Could not find conversation \(conversationId) to add LLM response")
                            }
                        }

                        /// Check finish_reason for continuation signal.
                        if context.lastFinishReason != "tool_calls" {
                            /// Q&A MODE DETECTION (applies to conversations with active workflow AND tools already executed) If user asked a question MID-WORKFLOW (after tools have been used) and agent answered without tools, we're in conversational Q&A, not workflow execution Don't inject workflow continuation prompts during Q&A!.
                            if context.toolsExecutedInWorkflow {
                                let lastUserMessage = await MainActor.run {
                                    conversationManager.conversations
                                        .first(where: { $0.id == conversationId })?
                                        .messages
                                        .last(where: { $0.isFromUser })
                                }

                                let isUserAskingQuestion = lastUserMessage?.content.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") ?? false
                                let agentUsedTools = llmResponse.toolCalls?.isEmpty == false

                                if isUserAskingQuestion && !agentUsedTools {
                                    /// Q&A MODE: User asked a question mid-workflow, agent answered without tools This is a clarifying question, not workflow continuation.
                                    logger.debug("QA_MODE_DETECTED_STREAMING", metadata: [
                                        "conversationId": .string(conversationId.uuidString),
                                        "userQuestion": .string(lastUserMessage?.content.prefix(100).description ?? ""),
                                        "toolsExecutedInWorkflow": .stringConvertible(context.toolsExecutedInWorkflow)
                                    ])

                                    /// BREAK from loop to end conversation, wait for next user input Using 'continue' would loop back and call LLM again!.
                                    let doneChunk = ServerOpenAIChatStreamChunk(
                                        id: requestId,
                                        object: "chat.completion.chunk",
                                        created: created,
                                        model: model,
                                        choices: [OpenAIChatStreamChoice(
                                            index: 0,
                                            delta: OpenAIChatDelta(content: ""),
                                            finishReason: "stop"
                                        )]
                                    )
                                    continuation.yield(doneChunk)
                                    continuation.finish()
                                    break
                                }
                            }

                            /// Check if agent signaled workflow completion.
                            if context.detectedWorkflowCompleteMarker {
                                logger.info("WORKFLOW_COMPLETE_STREAMING: Agent signaled [WORKFLOW_COMPLETE] - terminating")

                                /// Send final done chunk.
                                let doneChunk = ServerOpenAIChatStreamChunk(
                                    id: requestId,
                                    object: "chat.completion.chunk",
                                    created: created,
                                    model: model,
                                    choices: [OpenAIChatStreamChoice(
                                        index: 0,
                                        delta: OpenAIChatDelta(content: ""),
                                        finishReason: "stop"
                                    )]
                                )
                                continuation.yield(doneChunk)
                                continuation.finish()
                                break
                            }

                            /// Check if agent signaled continue (simulates user typing "continue") This is how automated workflow continues without user input.
                            if context.detectedContinueMarker {
                                logger.info("WORKFLOW_CONTINUING_STREAMING: [CONTINUE] signal detected (automated continuation)")

                                /// Add "continue" message to conversation history so agent sees new user input
                                /// This prevents the agent from repeating the same output when it sees its own previous response
                                if let conv = conversation {
                                    conv.messageBus?.addUserMessage(content: "<system-reminder>continue</system-reminder>", isSystemGenerated: true)
                                    logger.debug("STREAMING: Added 'continue' system message to conversation history")
                                }

                                /// CRITICAL: Check if agent is in planning loop (emitting continue without doing work)
                                /// If planningOnlyIterations > 2, inject auto-continue intervention to break the loop
                                if context.planningOnlyIterations > 2 {
                                    logger.warning("PLANNING_LOOP_WITH_CONTINUE: Agent emitted continue signal but has done no real work", metadata: [
                                        "iteration": .stringConvertible(context.iteration),
                                        "planningOnlyIterations": .stringConvertible(context.planningOnlyIterations)
                                    ])

                                    /// Inject auto-continue intervention to break the planning loop
                                    /// Use the planningOnlyIterations count to determine intervention level
                                    let enableWorkflowMode = conversation?.settings.enableWorkflowMode ?? false
                                    let injected = await injectAutoContinueIfTodosIncomplete(
                                        context: &context,
                                        conversationId: conversationId,
                                        model: model,
                                        enableWorkflowMode: enableWorkflowMode
                                    )

                                    if injected {
                                        logger.info("PLANNING_LOOP_INTERVENTION_STREAMING: Auto-continue intervention injected to break planning loop", metadata: [
                                            "planningOnlyIterations": .stringConvertible(context.planningOnlyIterations),
                                            "autoContinueAttempts": .stringConvertible(context.autoContinueAttempts)
                                        ])
                                    }
                                }

                                /// Agent Loop Escape - Log if agent might be stuck
                                let usedMemoryTools = context.lastIterationToolNames.contains("memory_operations") ||
                                                       context.lastIterationToolNames.contains("manage_todo_list") ||
                                                       context.lastIterationToolNames.contains("todo_operations")
                                let hasRecentFailures = !context.toolFailureTracking.isEmpty

                                if usedMemoryTools && hasRecentFailures {
                                    logger.warning("POTENTIAL_AGENT_BLOCK_STREAMING: Agent used memory/todo tools and has failures", metadata: [
                                        "iteration": .stringConvertible(context.iteration),
                                        "failures": .stringConvertible(context.toolFailureTracking.count)
                                    ])
                                }

                                /// Iteration will be incremented at bottom of loop - don't increment here
                                continue
                            }

                            /// Natural termination (no tools, no signals) Before finishing the streaming session, attempt auto-continue if there are incomplete todos present.
                            let enableWorkflowMode = conversation?.settings.enableWorkflowMode ?? false
                            if await injectAutoContinueIfTodosIncomplete(context: &context, conversationId: conversationId, model: model, enableWorkflowMode: enableWorkflowMode) {
                                logger.debug("AUTO_CONTINUE_STREAMING: Injected continue directive due to incomplete todos", metadata: [
                                    "iteration": .stringConvertible(context.iteration)
                                ])
                                completeIteration(context: &context, responseStatus: "auto_continue_injected_streaming")
                                /// Iteration will be incremented at bottom of loop - don't increment here
                                continue
                            }

                            logger.info("WORKFLOW_COMPLETE_STREAMING: Natural termination (no continue signal)", metadata: [
                                "iteration": .stringConvertible(context.iteration)
                            ])

                            /// Send final done chunk.
                            let doneChunk = ServerOpenAIChatStreamChunk(
                                id: requestId,
                                object: "chat.completion.chunk",
                                created: created,
                                model: model,
                                choices: [OpenAIChatStreamChoice(
                                    index: 0,
                                    delta: OpenAIChatDelta(content: ""),
                                    finishReason: "stop"
                                )]
                            )
                            continuation.yield(doneChunk)
                            continuation.finish()
                            break
                        }

                        /// Parse and validate tool calls Use continuationToolCalls if we got work tools from continuation, synthetic tool, or llmResponse.toolCalls.
                        let toolCalls: [ToolCall]
                        if context.useContinuationResponse {
                            guard let calls = context.continuationToolCalls, !calls.isEmpty else {
                                logger.warning("WARNING: context.useContinuationResponse=true but context.continuationToolCalls is empty")
                                continuation.finish()
                                return
                            }
                            toolCalls = calls
                        } else {
                            guard let calls = llmResponse.toolCalls, !calls.isEmpty else {
                                logger.warning("WARNING: finish_reason=tool_calls but no actual tool calls found")
                                continuation.finish()
                                return
                            }
                            toolCalls = calls
                        }

                        /// TOOL_CALLS_PARSED - Track tool call extraction (STREAMING).
                        logger.debug("TOOL_CALLS_PARSED_STREAMING", metadata: [
                            "context.iteration": .stringConvertible(context.iteration + 1),
                            "toolCallCount": .stringConvertible(toolCalls.count),
                            "toolNames": .string(toolCalls.map { $0.name }.joined(separator: ", ")),
                            "usedContinuationResponse": .stringConvertible(context.useContinuationResponse)
                        ])

                        /// ALWAYS yield content chunk when tool_calls are present Even if content is empty - this creates the assistant message that tool cards attach to GitHub Copilot sends content as complete message when tool_calls are present, NOT as delta chunks during streaming.
                        logger.debug("CONTENT_WITH_TOOLS: Yielding \(context.lastResponse.count) chars of content before tool execution")

                        let contentChunk = ServerOpenAIChatStreamChunk(
                            id: requestId,
                            object: "chat.completion.chunk",
                            created: created,
                            model: model,
                            choices: [OpenAIChatStreamChoice(
                                index: 0,
                                delta: OpenAIChatDelta(content: context.lastResponse.isEmpty ? "" : context.lastResponse),
                                finishReason: nil
                            )]
                        )
                        continuation.yield(contentChunk)

                        /// TOOL_EXECUTION_BATCH_START - Track start of tool execution batch (STREAMING).
                        logger.debug("TOOL_EXECUTION_BATCH_START_STREAMING", metadata: [
                            "context.iteration": .stringConvertible(context.iteration + 1),
                            "toolCount": .stringConvertible(toolCalls.count),
                            "toolNames": .string(toolCalls.map { $0.name }.joined(separator: ", "))
                        ])

                        logger.debug("SUCCESS: Found \(toolCalls.count) tool calls to execute")

                        // MARK: - Track whether tools have been executed in this workflow
                        context.toolsExecutedInWorkflow = true

                        /// PLANNING LOOP DETECTION (STREAMING): Check if ANY work tools were called
                        /// If only planning tools (think, memory_operations with manage_todos) were called, don't reset counters
                        let workToolsCalled = toolCalls.filter { AgentOrchestrator.isWorkToolCall($0.name, arguments: $0.arguments) }
                        let onlyPlanningTools = workToolsCalled.isEmpty && !toolCalls.isEmpty

                        if onlyPlanningTools {
                            /// Agent called tools but NONE were work tools - this is a planning loop
                            context.planningOnlyIterations += 1
                            let toolNames = toolCalls.map { $0.name }.joined(separator: ", ")
                            logger.warning("PLANNING_LOOP_DETECTED_STREAMING", metadata: [
                                "iteration": .stringConvertible(context.iteration),
                                "planningOnlyIterations": .stringConvertible(context.planningOnlyIterations),
                                "toolsCalled": .string(toolNames),
                                "message": .string("Only planning tools called - NOT resetting autoContinueAttempts")
                            ])

                            /// CRITICAL FIX: Inject planning loop intervention even without [CONTINUE] marker
                            /// Claude models often don't emit [CONTINUE] but keep calling planning tools in a loop
                            /// If planningOnlyIterations > 3, inject intervention to break the loop
                            if context.planningOnlyIterations > 3 {
                                logger.warning("PLANNING_LOOP_INTERVENTION_STREAMING: Agent stuck in planning loop - injecting intervention", metadata: [
                                    "planningOnlyIterations": .stringConvertible(context.planningOnlyIterations)
                                ])

                                let enableWorkflowMode = conversation?.settings.enableWorkflowMode ?? false
                                let injected = await injectAutoContinueIfTodosIncomplete(
                                    context: &context,
                                    conversationId: conversationId,
                                    model: model,
                                    enableWorkflowMode: enableWorkflowMode
                                )

                                if injected {
                                    logger.info("PLANNING_LOOP_INTERVENTION_INJECTED_STREAMING: Intervention injected to break Claude planning loop", metadata: [
                                        "planningOnlyIterations": .stringConvertible(context.planningOnlyIterations),
                                        "autoContinueAttempts": .stringConvertible(context.autoContinueAttempts)
                                    ])
                                }
                            }
                            /// DO NOT reset autoContinueAttempts - let it escalate
                        } else if !workToolsCalled.isEmpty {
                            /// Agent called at least one WORK tool - real progress is being made
                            context.planningOnlyIterations = 0
                            context.autoContinueAttempts = 0
                            let workToolNames = workToolsCalled.map { $0.name }.joined(separator: ", ")
                            logger.debug("WORK_TOOL_EXECUTED_STREAMING", metadata: [
                                "iteration": .stringConvertible(context.iteration),
                                "workTools": .string(workToolNames),
                                "message": .string("Work tools called - resetting planningOnlyIterations and autoContinueAttempts")
                            ])
                        }

                        /// End the current message (assistant's response with tool calls).
                        let finishChunk = ServerOpenAIChatStreamChunk(
                            id: requestId,
                            object: "chat.completion.chunk",
                            created: created,
                            model: model,
                            choices: [OpenAIChatStreamChoice(
                                index: 0,
                                delta: OpenAIChatDelta(content: nil),
                                finishReason: "stop"
                            )]
                        )
                        continuation.yield(finishChunk)

                        /// Execute tools and update internal messages Check cancellation before tool execution.
                        try Task.checkCancellation()

                        /// Pass continuation to yield progress chunks during tool execution This enables real-time streaming of tool progress instead of batching after completion.
                        var executionResults: [ToolExecution]
                        if !toolCalls.isEmpty {
                            executionResults = try await self.executeToolCallsStreaming(
                                toolCalls,
                                iteration: context.iteration,
                                continuation: continuation,
                                requestId: requestId,
                                created: created,
                                model: model,
                                conversationId: context.session?.conversationId
                            )
                        } else {
                            /// All tools were blocked/filtered.
                            executionResults = []
                        }

                        /// TOOL_EXECUTION_BATCH_COMPLETE - Track completion of tool execution batch (STREAMING).
                        let successfulTools = executionResults.filter { $0.success }.count
                        let failedTools = executionResults.count - successfulTools
                        logger.debug("TOOL_EXECUTION_BATCH_COMPLETE_STREAMING", metadata: [
                            "context.iteration": .stringConvertible(context.iteration + 1),
                            "totalTools": .stringConvertible(executionResults.count),
                            "successfulTools": .stringConvertible(successfulTools),
                            "failedTools": .stringConvertible(failedTools)
                        ])

                        /// ERROR ADAPTATION (STREAMING PATH): If tools failed, inject guidance
                        /// Agent Loop Escape - Track failures and provide escalating guidance
                        if failedTools > 0 {
                            let failedToolDetails = executionResults.filter { !$0.success }
                                .map { "\($0.toolName): \($0.result)" }
                                .joined(separator: "\n")

                            /// Track tool failures to detect stuck loops
                            for execution in executionResults where !execution.success {
                                let toolName = execution.toolName
                                if let existing = context.toolFailureTracking[toolName] {
                                    if existing.iteration == context.iteration - 1 {
                                        context.toolFailureTracking[toolName] = (context.iteration, existing.failureCount + 1)
                                    } else {
                                        context.toolFailureTracking[toolName] = (context.iteration, 1)
                                    }
                                } else {
                                    context.toolFailureTracking[toolName] = (context.iteration, 1)
                                }
                            }

                            let stuckTools = context.toolFailureTracking.filter { $0.value.failureCount >= 3 }
                            let isStuck = !stuckTools.isEmpty

                            let errorGuidanceContent: String
                            if isStuck {
                                let stuckToolNames = stuckTools.map { $0.key }.joined(separator: ", ")
                                context.hasSeenStopStatusGuidance = true
                                errorGuidanceContent = """
                                CRITICAL: TOOL FAILURE LOOP DETECTED

                                The following tool(s) have failed 3+ consecutive times:
                                \(stuckToolNames)

                                \(failedTools) tool(s) failed in this iteration:
                                \(failedToolDetails)

                                YOU MUST TAKE DIFFERENT ACTION:
                                1. DO NOT retry the same tool with the same parameters
                                2. DO NOT continue if you cannot fix the problem
                                3. You have TWO options:

                                OPTION A: Try a completely different approach
                                - Use a different tool
                                - Change your strategy entirely
                                - Break the problem down differently

                                OPTION B: If you cannot proceed, signal stop
                                - Emit: {"status": "stop"}
                                - I will gracefully end the workflow
                                - Explain to the user what you tried and why you're stuck

                                Use the think tool NOW to decide which option to take.
                                """
                            } else if !context.hasSeenStopStatusGuidance {
                                context.hasSeenStopStatusGuidance = true
                                errorGuidanceContent = """
                                TOOL ERROR - THINK AND ADAPT

                                \(failedTools) tool(s) failed:
                                \(failedToolDetails)

                                STOP and THINK:
                                1. Why did the tool fail? (Read the error message carefully)
                                2. What parameter should you change?
                                3. Should you try a different tool instead?
                                4. Is this error unrecoverable?

                                DO NOT retry the same tool call without changing something.

                                If you cannot proceed after trying alternatives, emit: {"status": "stop"}

                                Use the think tool now to plan your adaptation, OR signal stop if truly stuck.
                                """
                            } else {
                                errorGuidanceContent = """
                                TOOL ERROR - ADAPT YOUR APPROACH

                                \(failedTools) tool(s) failed:
                                \(failedToolDetails)

                                You must either:
                                1. Try a different approach (different tool or parameters)
                                2. Signal {"status": "stop"} if you cannot proceed

                                DO NOT retry the same failed operation.
                                """
                            }

                            /// VS CODE COPILOT PATTERN: Use XML tags for ALL models
                            /// Send as user message to avoid consecutive assistant messages that violate Claude API
                            let wrappedGuidance = "<system-reminder>\n\(errorGuidanceContent)\n</system-reminder>"
                            let errorGuidance = OpenAIChatMessage(role: "user", content: wrappedGuidance)
                            context.internalMessages.append(errorGuidance)

                            if isStuck {
                                logger.error("TOOL_FAILURE_LOOP_DETECTED_STREAMING", metadata: [
                                    "stuckTools": .string(stuckTools.map { "\($0.key):\($0.value.failureCount)" }.joined(separator: ", "))
                                ])
                            } else {
                                logger.warning("ERROR_ADAPTATION_INJECTED_STREAMING: Added guidance for \(failedTools) failed tools")
                            }
                        }

                        /// Add assistant message with tool calls to internal tracking.
                        let openAIToolCalls = toolCalls.map { toolCall -> OpenAIToolCall in
                            let argsString: String
                            if let jsonData = try? JSONSerialization.data(withJSONObject: toolCall.arguments),
                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                argsString = jsonString
                            } else {
                                argsString = "{}"
                            }

                            return OpenAIToolCall(
                                id: toolCall.id,
                                type: "function",
                                function: OpenAIFunctionCall(name: toolCall.name, arguments: argsString)
                            )
                        }

                        context.internalMessages.append(OpenAIChatMessage(
                            role: "assistant",
                            content: context.lastResponse,
                            toolCalls: openAIToolCalls
                        ))

                        /// Add tool result messages (with size optimization for large results)
                        for execution in executionResults {
                            let processedContent = toolResultStorage.processToolResult(
                                toolCallId: execution.toolCallId,
                                content: execution.result,
                                conversationId: conversationId
                            )

                            context.internalMessages.append(OpenAIChatMessage(
                                role: "tool",
                                content: processedContent,
                                toolCallId: execution.toolCallId
                            ))
                        }

                        /// REMOVED: Duplicate tool message persistence
                        /// Tool messages are already created via MessageBus in callLLMStreaming (line ~4740)
                        /// This legacy code was creating duplicates: 2x messages, 2x disk writes, 2x UI updates
                        /// Removing this section restores streaming performance

                        /// --- MARKER DETECTION INSIDE TOOL OUTPUTS (STREAMING) --- Detect markers inside tool outputs and promote them into the workflow context.
                        var toolEmittedPlanningHandledStreaming = false
                        for execution in executionResults {
                            let toolMarkers = detectMarkers(in: execution.result)
                            if toolMarkers.detectedWorkflowComplete {
                                logger.debug("MARKER_DETECTED_IN_TOOL_RESULT_STREAMING", metadata: [
                                    "conversationId": .string(conversationId.uuidString),
                                    "tool": .string(execution.toolName),
                                    "workflow_complete": .stringConvertible(toolMarkers.detectedWorkflowComplete),
                                    "matched_pattern": .string(toolMarkers.matchedPattern ?? "none"),
                                    "matched_snippet": .string(toolMarkers.matchedSnippet ?? "")
                                ])
                            }

                            if toolMarkers.detectedWorkflowComplete {
                                logger.info("WORKFLOW_COMPLETE_MARKER_IN_TOOL_STREAMING: Detected workflow complete in tool output - marking workflow complete")
                                context.detectedWorkflowCompleteMarker = true
                            }
                        }

                        /// Capture thinking steps from think tool results (STREAMING PATH).
                        if let thinkingSteps = parseThinkingSteps(from: executionResults) {
                            context.currentRoundThinkingSteps = thinkingSteps
                            logger.debug("THINKING_CAPTURED_STREAMING", metadata: [
                                "iteration": .stringConvertible(context.iteration),
                                "stepsCount": .stringConvertible(thinkingSteps.count)
                            ])
                        }

                        /// Capture structured thinking for transparency and debugging (STREAMING PATH).
                        if let structuredThinking = captureStructuredThinking(
                            llmResponse: context.currentRoundLLMResponse,
                            executionResults: executionResults,
                            model: context.model
                        ) {
                            context.currentRoundStructuredThinking = structuredThinking
                            logger.debug("STRUCTURED_THINKING_CAPTURED_STREAMING", metadata: [
                                "iteration": .stringConvertible(context.iteration),
                                "thinkingSteps": .stringConvertible(structuredThinking.count),
                                "sources": .string(structuredThinking.map { $0.metadata["source"] ?? "unknown" }.joined(separator: ", "))
                            ])
                        }

                        /// Check for todo management tool execution.                        /// Update todo list state if todo_operations was called.
                        for execution in executionResults {
                            /// Support todo_operations, legacy manage_todo_list, and memory_operations with manage_todos.
                            if execution.toolName == "todo_operations" || execution.toolName == "manage_todo_list" || execution.toolName == "memory_operations" {
                                logger.debug("TODO_EXECUTION: todo management tool detected (name: \(execution.toolName)), reading current state")

                                if let readResult = await conversationManager.executeMCPTool(
                                    name: "todo_operations",
                                    parameters: ["operation": "read"],
                                    conversationId: context.session?.conversationId,
                                    isExternalAPICall: self.isExternalAPICall
                                ) {
                                    let parsedTodos = parseTodoList(from: readResult.output.content)
                                    currentTodoList = parsedTodos
                                    logger.debug("TODO_EXECUTION: Updated current todo list: \(currentTodoList.count) items")
                                }
                                break
                            }
                        }

                        /// Check cancellation at end of iteration before continuing to next
                        try Task.checkCancellation()

                        context.iteration += 1
                        self.updateCurrentIteration(context.iteration)
                    }

                    /// Check why loop exited and log appropriate message
                    if context.iteration >= context.maxIterations {
                        logger.warning("WARNING: Hit maxIterations", metadata: [
                            "actualIterations": .stringConvertible(context.iteration),
                            "maxIterations": .stringConvertible(context.maxIterations)
                        ])
                        let warningChunk = ServerOpenAIChatStreamChunk(
                            id: requestId,
                            object: "chat.completion.chunk",
                            created: created,
                            model: model,
                            choices: [OpenAIChatStreamChoice(
                                index: 0,
                                delta: OpenAIChatDelta(content: "\n\nWARNING: Reached maximum iterations (\(context.iteration))\n\n"),
                                finishReason: "length"
                            )]
                        )
                        continuation.yield(warningChunk)
                    } else {
                        logger.info("WORKFLOW_COMPLETE_STREAMING: Loop exited naturally", metadata: [
                            "actualIterations": .stringConvertible(context.iteration),
                            "maxIterations": .stringConvertible(context.maxIterations),
                            "reason": .string(context.shouldContinue ? "unknown" : "shouldContinue=false")
                        ])
                    }
                    continuation.finish()

                } catch {
                    logger.error("ERROR: Streaming autonomous workflow failed: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Helper Methods

    // MARK: - Universal Tool Call Parser

    private func extractMLXToolCalls(from content: String) -> ([ToolCall], String) {
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

    /// Automatically retrieve relevant context before LLM calls Combines pinned messages + semantic memory search for comprehensive context This ensures agents never lose critical information like initial requests or key decisions.
    @MainActor
    private func retrieveRelevantContext(
        conversation: ConversationModel,
        currentUserMessage: String,
        iteration: Int = 0,
        caller: String = "UNKNOWN",
        retrievedMessageIds: inout Set<UUID>
    ) async -> String? {
        logger.debug("AUTO_RETRIEVAL: Starting automatic context retrieval for conversation \(conversation.id) iteration \(iteration) - CALLED FROM: \(caller)")

        var contextParts: [String] = []

        /// Extract all pinned messages (guaranteed critical context) CRITICAL FIX Exclude messages that match the CURRENT user request ROOT CAUSE: For new conversations, current user message gets auto-pinned (first 3 messages) PROBLEM: Phase 1 retrieves current message as "past context" → LLM sees it twice → thinks already addressed SOLUTION: Only retrieve pinned messages that are NOT the current request.
        let pinnedMessages = conversation.messages.filter {
            $0.isPinned && $0.content != currentUserMessage
        }
        if !pinnedMessages.isEmpty {
            logger.debug("AUTO_RETRIEVAL: Found \(pinnedMessages.count) pinned messages (excluding current request)")

            var pinnedContext = "=== CRITICAL CONTEXT (Pinned Messages) ===\n"
            for (index, msg) in pinnedMessages.enumerated() {
                let role = msg.isFromUser ? "USER" : "ASSISTANT"
                pinnedContext += "\n[\(role) Message \(index + 1) - Pinned, Importance: \(String(format: "%.2f", msg.importance))]:\n\(msg.content)\n"
            }
            contextParts.append(pinnedContext)
        }

        /// Semantic search for relevant memories (automatic RAG).
        do {
            let memories = try await conversationManager.memoryManager.retrieveRelevantMemories(
                for: currentUserMessage,
                conversationId: conversation.id,
                limit: 5,
                similarityThreshold: 0.3
            )

            if !memories.isEmpty {
                logger.debug("AUTO_RETRIEVAL: Retrieved \(memories.count) relevant memories via semantic search")

                var memoryContext = "\n=== RELEVANT PRIOR CONTEXT (Semantic Search) ===\n"
                for (index, memory) in memories.enumerated() {
                    memoryContext += "\n[Memory \(index + 1) - Similarity: \(String(format: "%.2f", memory.similarity)), Importance: \(String(format: "%.2f", memory.importance))]:\n\(memory.content)\n"
                }
                contextParts.append(memoryContext)
            } else {
                logger.debug("AUTO_RETRIEVAL: No relevant memories found via semantic search")
            }
        } catch {
            logger.warning("AUTO_RETRIEVAL: Memory retrieval failed: \(error), continuing without memory context")
        }

        /// Include high-importance messages not yet pinned (>=0.8 threshold) CRITICAL FIX Track retrieved message IDs to prevent duplication across iterations - Problem: Phase 3 was pulling same messages on every iteration (from conversation history) - Solution: Track which message IDs already retrieved, only include NEW high-importance messages - This preserves context (unlike skipping Phase 3 entirely) while preventing exponential growth.
        let newHighImportanceMessages = conversation.messages.filter {
            !$0.isPinned &&
            $0.importance >= 0.8 &&
            !retrievedMessageIds.contains($0.id)
        }

        if !newHighImportanceMessages.isEmpty {
            logger.debug("AUTO_RETRIEVAL: Found \(newHighImportanceMessages.count) NEW high-importance messages (iteration \(iteration), \(retrievedMessageIds.count) already retrieved)")

            var importantContext = "\n=== HIGH IMPORTANCE MESSAGES (Auto-detected) ===\n"
            for (index, msg) in newHighImportanceMessages.enumerated() {
                let role = msg.isFromUser ? "USER" : "ASSISTANT"
                importantContext += "\n[\(role) Message \(index + 1) - Importance: \(String(format: "%.2f", msg.importance))]:\n\(msg.content)\n"
            }
            contextParts.append(importantContext)

            /// Track that we've retrieved these messages.
            newHighImportanceMessages.forEach { retrievedMessageIds.insert($0.id) }
        } else if !retrievedMessageIds.isEmpty {
            logger.debug("AUTO_RETRIEVAL: No new high-importance messages (iteration \(iteration), \(retrievedMessageIds.count) already retrieved)")
        }

        /// Combine all context parts if any exist.
        if contextParts.isEmpty {
            logger.debug("AUTO_RETRIEVAL: No additional context retrieved (no pinned messages, no relevant memories, no high-importance messages)")
            return nil
        }

        let fullContext = """
        === AUTOMATIC CONTEXT RETRIEVAL ===
        The following context has been automatically retrieved to help you maintain continuity:

        \(contextParts.joined(separator: "\n"))

        === END AUTOMATIC CONTEXT ===
        """

        logger.debug("AUTO_RETRIEVAL: Generated \(fullContext.count) chars of automatic context (\(pinnedMessages.count) pinned messages, iteration \(iteration))")
        return fullContext
    }

    /// Prune conversation history by summarizing oldest 50% of messages Returns the summary text that can replace the old messages.
    @MainActor
    private func pruneConversationHistory(
        conversation: ConversationModel,
        model: String
    ) async throws -> String {
        logger.debug("CONTEXT_PRUNING: Starting conversation history pruning")

        /// Initialize contextMessages from messages if not already set This ensures we start with full history on first prune.
        if conversation.contextMessages == nil {
            await MainActor.run {
                conversation.contextMessages = conversation.messages
            }
        }

        /// Get current context messages for pruning.
        let currentContextMessages = await MainActor.run { conversation.contextMessages ?? conversation.messages }

        /// Separate pinned messages from unpinned Pinned messages (first 3 user messages, constraints, etc.) NEVER pruned.
        let pinnedMessages = currentContextMessages.filter { $0.isPinned }
        let unpinnedMessages = currentContextMessages.filter { !$0.isPinned }

        logger.debug("CONTEXT_PRUNING: Found \(pinnedMessages.count) pinned messages (will never be pruned)")
        logger.debug("CONTEXT_PRUNING: Found \(unpinnedMessages.count) unpinned messages (candidates for pruning)")

        /// Calculate how many messages to summarize (oldest 50% of UNPINNED messages).
        let messagesToSummarize = max(1, unpinnedMessages.count / 2)
        let oldMessages = Array(unpinnedMessages.prefix(messagesToSummarize))

        logger.debug("CONTEXT_PRUNING: Summarizing \(messagesToSummarize) oldest unpinned messages (out of \(unpinnedMessages.count) total unpinned)")
        logger.debug("CONTEXT_PRUNING: NOTE - Full message history (\(conversation.messages.count) messages) remains visible to user")

        /// Build conversation text to summarize.
        var conversationText = ""
        for (_, message) in oldMessages.enumerated() {
            let speaker = message.isFromUser ? "User" : "Assistant"
            conversationText += "\(speaker): \(message.content)\n\n"
        }

        /// Build summarization request.
        let summaryPrompt = """
        Summarize this conversation history concisely in 200-500 tokens:

        \(conversationText)

        Provide a factual summary that captures:
        - Main topics discussed
        - Key decisions or conclusions
        - Important context for future messages

        Be concise but preserve essential information.
        """

        /// Call LLM to generate summary (without tools).
        let summaryMessages = [
            OpenAIChatMessage(role: "system", content: "You are a helpful assistant that creates concise conversation summaries."),
            OpenAIChatMessage(role: "user", content: summaryPrompt)
        ]

        /// Include sessionId/conversationId for billing continuity!.
        let summaryRequest = OpenAIChatRequest(
            model: model,
            messages: summaryMessages,
            temperature: 0.3,
            stream: false,
            sessionId: conversation.id.uuidString
        )

        logger.debug("CONTEXT_PRUNING: Calling LLM to generate summary")
        let response = try await endpointManager.processChatCompletion(summaryRequest)

        guard let summary = response.choices.first?.message.content, !summary.isEmpty else {
            throw NSError(domain: "AgentOrchestrator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate conversation summary"])
        }

        logger.debug("CONTEXT_PRUNING: Generated summary (\(summary.count) chars)")

        /// Store summary in VectorRAG for future retrieval with ENHANCED METADATA.
        logger.debug("CONTEXT_PRUNING: Storing summary in VectorRAG with structured metadata")

        /// Extract key constraints and decisions from pinned/high importance messages for metadata.
        let pinnedConstraints = pinnedMessages.filter { $0.isFromUser && $0.importance > 0.8 }.map { $0.content }

        /// Build summary document content with STRUCTURED METADATA.
        let summaryDocument = """
        # Conversation Summary

        **Conversation ID**: \(conversation.id.uuidString)
        **Messages Summarized**: \(messagesToSummarize) out of \(unpinnedMessages.count) unpinned messages
        **Pinned Messages Preserved**: \(pinnedMessages.count) critical messages

        **Key Constraints/Requirements** (from pinned messages):
        \(pinnedConstraints.isEmpty ? "None" : pinnedConstraints.map { "- \($0)" }.joined(separator: "\n"))

        **Summary**:

        \(summary)
        """

        /// Call document_operations tool with operation=import to store summary with importance tagging.
        let importParameters: [String: Any] = [
            "operation": "import",
            "source_type": "text",
            "content": summaryDocument,
            "filename": "conversation_summary_\(conversation.id.uuidString).txt",
            "importance": 0.9
        ]

        if let importResult = await conversationManager.executeMCPTool(
            name: "document_operations",
            parameters: importParameters,
            conversationId: conversation.id,
            isExternalAPICall: false
        ) {
            logger.debug("CONTEXT_PRUNING: Summary stored in VectorRAG: \(importResult.output.content)")
        } else {
            logger.warning("CONTEXT_PRUNING: Failed to store summary in VectorRAG")
        }

        /// Update contextMessages ONLY, not the main messages array This preserves full conversation history for the user while pruning LLM context.
        await MainActor.run {
            /// Start with ALL pinned messages (always preserved).
            var newContextMessages = pinnedMessages

            /// Preserve githubCopilotResponseId from the LAST summarized message This is essential for session continuity - without it, checkpoint slicing fails Result: Multiple premium charges per conversation
            let lastSummarizedResponseId = oldMessages.last(where: { !$0.isFromUser })?.githubCopilotResponseId
            if let responseId = lastSummarizedResponseId {
                logger.debug("CONTEXT_PRUNING: Preserving GitHub Copilot response ID from summarized messages: \(responseId.prefix(20))...")
            }

            /// Add summary message (high importance for retrieval).
            let summaryMessage = Message(
                id: UUID(),
                content: "**[Previous conversation summary]**\n\n\(summary)",
                isFromUser: false,
                timestamp: Date(),
                githubCopilotResponseId: lastSummarizedResponseId,
                isPinned: false,
                importance: 0.9
            )
            newContextMessages.append(summaryMessage)

            /// Add remaining unpinned messages (after the ones that were summarized).
            let remainingUnpinned = Array(unpinnedMessages.dropFirst(messagesToSummarize))
            newContextMessages.append(contentsOf: remainingUnpinned)

            /// Sort by timestamp to maintain chronological order.
            newContextMessages.sort { $0.timestamp < $1.timestamp }

            /// Update contextMessages (messages array unchanged).
            conversation.contextMessages = newContextMessages
        }

        logger.debug("CONTEXT_PRUNING: Pruning complete, context now has \(conversation.contextMessages?.count ?? 0) messages")
        logger.debug("CONTEXT_PRUNING: - \(pinnedMessages.count) pinned (never pruned)")
        logger.debug("CONTEXT_PRUNING: - 1 summary message")
        logger.debug("CONTEXT_PRUNING: - \(unpinnedMessages.count - messagesToSummarize) remaining unpinned")
        logger.debug("CONTEXT_PRUNING: User-visible history remains at \(conversation.messages.count) messages")

        return summary
    }

    /// Check if context should be pruned before calling LLM Returns true if token count exceeds 70% of context size.
    @MainActor
    private func shouldPruneContextBeforeLLMCall(
        conversation: ConversationModel,
        internalMessages: [OpenAIChatMessage],
        currentMessage: String,
        model: String
    ) async -> (shouldPrune: Bool, currentTokens: Int, contextSize: Int) {
        /// Get system prompt.
        let defaultPromptId = await MainActor.run {
            SystemPromptManager.shared.selectedConfigurationId
        }
        let promptId = conversation.settings.selectedSystemPromptId ?? defaultPromptId
        let workflowModeEnabled = conversation.settings.enableWorkflowMode
        let dynamicIterationsEnabled = conversation.settings.enableDynamicIterations
        let systemPrompt = await MainActor.run {
            SystemPromptManager.shared.generateSystemPrompt(
                for: promptId,
                workflowModeEnabled: workflowModeEnabled,
                dynamicIterationsEnabled: dynamicIterationsEnabled
            )
        }

        /// Convert conversation messages to OpenAIChatMessage format for counting CRITICAL: Use contextMessages if available (after pruning), otherwise use full messages.
        let messagesToCount = conversation.contextMessages ?? conversation.messages
        var conversationMessages: [OpenAIChatMessage] = []
        for historyMessage in messagesToCount {
            let role = historyMessage.isFromUser ? "user" : "assistant"
            conversationMessages.append(OpenAIChatMessage(role: role, content: historyMessage.content))
        }
        conversationMessages.append(contentsOf: internalMessages)

        /// Detect if this is a local model.
        let isLocal = model.lowercased().contains("local-llama") || model.lowercased().contains("gguf") || model.lowercased().contains("mlx")

        /// Get context size for this model.
        let contextSize = await tokenCounter.getContextSize(modelName: model)

        /// Check if we should prune.
        let (currentTokens, shouldPrune, _) = await tokenCounter.shouldPruneContext(
            systemPrompt: systemPrompt,
            conversationMessages: conversationMessages,
            currentInput: currentMessage,
            contextSize: contextSize,
            model: nil,
            /// WHY: llama.cpp models need model-specific tokenizer for accurate counts Current: Uses heuristic tokenization (works but less accurate) With model: Can call llama_tokenize() for exact counts Benefit: More accurate pruning decisions, better context management.
            isLocal: isLocal
        )

        return (shouldPrune, currentTokens, contextSize)
    }

    /// Calls the LLM via EndpointManager (bypasses SAM 1.0 feedback loop).
    @MainActor
    private func callLLM(
        conversationId: UUID,
        message: String,
        model: String,
        internalMessages: [OpenAIChatMessage],
        iteration: Int,
        samConfig: SAMConfig? = nil,
        statefulMarker: String? = nil,
        statefulMarkerMessageCount: Int? = nil,
        sentInternalMessagesCount: Int = 0,
        retrievedMessageIds: inout Set<UUID>
    ) async throws -> LLMResponse {
        logger.debug("callLLM: Building OpenAI request for model '\(model)'")

        /// LAZY FETCH: Check if this is first GitHub Copilot request, fetch model capabilities if needed.
        await lazyFetchModelCapabilitiesIfNeeded(for: model)

        /// Get conversation for user messages only (not tool results).
        guard let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) else {
            logger.error("callLLM: Conversation not found: \(conversationId.uuidString)")
            return LLMResponse(
                content: "ERROR: Conversation not found",
                finishReason: "error",
                toolCalls: nil,
                statefulMarker: nil
            )
        }

        /// CONTEXT MANAGEMENT: Use YARN exclusively CRITICAL Context pruning was causing premium billing charges because it calls GitHub API to generate summaries.
        logger.debug("CONTEXT_MANAGEMENT: Using YARN for context compression (no API calls, no premium charges)")

        /// Build messages array: system prompt + conversation messages + internal tool messages.
        var messages: [OpenAIChatMessage] = []

        /// Add user-configured system prompt (includes guard rails) FIRST This was the architectural gap - API requests never included SystemPromptManager prompts.
        let defaultPromptId = await MainActor.run {
            SystemPromptManager.shared.selectedConfigurationId
        }
        let promptId = conversation.settings.selectedSystemPromptId ?? defaultPromptId
        logger.debug("DEBUG_ORCH_CONV: callLLM using conversation \(conversation.id), selectedSystemPromptId: \(conversation.settings.selectedSystemPromptId?.uuidString ?? "nil"), promptId: \(promptId?.uuidString ?? "nil")")

        let toolsEnabled = samConfig?.mcpToolsEnabled ?? true
        let workflowModeEnabled = conversation.settings.enableWorkflowMode
        let dynamicIterationsEnabled = conversation.settings.enableDynamicIterations
        var userSystemPrompt = await MainActor.run {
            SystemPromptManager.shared.generateSystemPrompt(
                for: promptId,
                toolsEnabled: toolsEnabled,
                workflowModeEnabled: workflowModeEnabled,
                dynamicIterationsEnabled: dynamicIterationsEnabled,
                model: model
            )
        }

        /// Merge personality if selected
        if let personalityId = conversation.settings.selectedPersonalityId {
            let personalityManager = PersonalityManager()
            if let personality = personalityManager.getPersonality(id: personalityId),
               personality.id != Personality.assistant.id {  // Skip if Assistant (default)
                let personalityInstructions = personality.generatePromptAdditions()
                userSystemPrompt += "\n\n" + personalityInstructions
                logger.info("Merged personality '\(personality.name)' into system prompt (\(personalityInstructions.count) chars)")
            }
        }

        /// Inject conversation ID and working directory for memory operations and file operations.
        var systemPromptAdditions = """
        \(userSystemPrompt)

        CONVERSATION_ID: \(conversationId.uuidString)
        """

        /// Add working directory context when tools are enabled
        if toolsEnabled {
            let effectiveWorkingDir = conversationManager.getEffectiveWorkingDirectory(for: conversation)
            systemPromptAdditions += """


            # WORKING DIRECTORY CONTEXT

            Your current working directory is: `\(effectiveWorkingDir)`

            All file operations and terminal commands will execute relative to this directory by default.
            You do not need to run 'pwd' or ask about the starting directory - this IS your working directory.
            """
        }

        let systemPromptWithId = systemPromptAdditions

        logger.debug("callLLM: Generated system prompt from ID: \(promptId?.uuidString ?? "default"), length: \(systemPromptWithId.count) chars, toolsEnabled: \(toolsEnabled), workflowMode: \(workflowModeEnabled)")
        logger.debug("callLLM: Guard rails present: \(systemPromptWithId.contains("TOOL SCHEMA CONFIDENTIALITY"))")

        if !userSystemPrompt.isEmpty {
            messages.append(OpenAIChatMessage(role: "system", content: systemPromptWithId))
            logger.debug("callLLM: Added user-configured system prompt to messages (with conversation ID)")
        }

        /// CLAUDE USERCONTEXT INJECTION
        /// Per Claude Messages API best practices: Extract important context from ALL pinned messages
        /// and inject as system message on EVERY request (context doesn't persist in conversation history)
        /// Reference: claude-messages.txt - "Do not rely on Turn 1 staying in history forever"
        let modelLower = model.lowercased()
        if modelLower.contains("claude") {
            /// Extract userContext from ALL pinned messages
            let pinnedMessages = conversation.messages.filter { $0.isPinned }
            var extractedContexts: [String] = []
            
            for pinnedMessage in pinnedMessages {
                let content = pinnedMessage.content
                if let userContextStart = content.range(of: "\n\n<userContext>\n"),
                   let userContextEnd = content.range(of: "\n</userContext>", range: userContextStart.upperBound..<content.endIndex) {
                    /// Extract userContext content (without tags)
                    let userContextContent = String(content[userContextStart.upperBound..<userContextEnd.lowerBound])
                    extractedContexts.append(userContextContent)
                }
            }
            
            /// If we found any userContext blocks in pinned messages, inject them
            if !extractedContexts.isEmpty {
                let claudeContextMessage = """
                ## User Context (Persistent)
                
                This context was provided in pinned messages and applies to all turns of this conversation:
                
                \(extractedContexts.joined(separator: "\n\n---\n\n"))
                """
                
                messages.append(OpenAIChatMessage(role: "system", content: claudeContextMessage))
                logger.info("CLAUDE_CONTEXT: Injected userContext from \(extractedContexts.count) pinned message(s) as system content (\(claudeContextMessage.count) chars)")
            }
        }

        /// AUTOMATIC CONTEXT RETRIEVAL Inject pinned messages + semantic search results BEFORE conversation messages This ensures critical context (initial request, key decisions) is always available CRITICAL FIX: Pass iteration number to skip Phase 3 (high-importance) for iterations > 0 - Phase 1 (pinned) and Phase 2 (semantic search) still run - they provide unique context - Phase 3 (high-importance) skipped for iterations > 0 - prevents duplicate context from internalMessages.
        if let retrievedContext = await retrieveRelevantContext(
            conversation: conversation,
            currentUserMessage: message,
            iteration: iteration,
            caller: "callLLM_NON_STREAMING_line3189",
            retrievedMessageIds: &retrievedMessageIds
        ) {
            messages.append(OpenAIChatMessage(role: "system", content: retrievedContext))
            logger.debug("callLLM: Added automatic context retrieval (\(retrievedContext.count) chars) for iteration \(iteration)")
        }

        /// REMINDER INJECTION: Deferred to right before user message for better salience
        /// (VS Code Copilot pattern: inject todo context immediately before user query)
        let activeTodoCount = TodoManager.shared.getProgressStatistics(for: conversation.id.uuidString).totalTodos
        let responseCount = conversation.messages.count
        let todoReminderContent: String?

        if TodoReminderInjector.shared.shouldInjectReminder(
            conversationId: conversation.id,
            currentResponseCount: responseCount,
            activeTodoCount: activeTodoCount
        ) {
            todoReminderContent = TodoReminderInjector.shared.formatTodoReminder(
                conversationId: conversation.id,
                todoManager: TodoManager.shared
            )
        } else {
            todoReminderContent = nil
        }

        /// MINI PROMPT REMINDER INJECTION: Remind agent of user's mini prompts (instructions)
        /// This addresses agents "forgetting" user instructions during long research sessions
        let miniPromptReminderContent: String?
        if MiniPromptReminderInjector.shared.shouldInjectReminder(
            conversationId: conversation.id,
            enabledMiniPromptIds: conversation.enabledMiniPromptIds,
            currentResponseCount: responseCount
        ) {
            miniPromptReminderContent = MiniPromptReminderInjector.shared.formatMiniPromptReminder(
                conversationId: conversation.id,
                enabledMiniPromptIds: conversation.enabledMiniPromptIds
            )
        } else {
            miniPromptReminderContent = nil
        }

        /// DOCUMENT IMPORT REMINDER INJECTION Tell agent what documents are already imported so they search memory instead of re-importing
        if DocumentImportReminderInjector.shared.shouldInjectReminder(conversationId: conversation.id) {
            if let docReminder = DocumentImportReminderInjector.shared.formatDocumentReminder(conversationId: conversation.id) {
                messages.append(createSystemReminder(content: docReminder, model: model))
                logger.debug("callLLM: Injected document import reminder (\(DocumentImportReminderInjector.shared.getImportedCount(for: conversation.id)) docs)")
            }
        }

        /// MEMORY REMINDER INJECTION: Tell agent what memories were recently stored to prevent duplicate stores
        /// This addresses the bug where agents re-store the same content across auto-continue iterations
        if MemoryReminderInjector.shared.shouldInjectReminder(conversationId: conversation.id) {
            if let memoryReminder = MemoryReminderInjector.shared.formatMemoryReminder(conversationId: conversation.id) {
                messages.append(createSystemReminder(content: memoryReminder, model: model))
                logger.debug("callLLM: Injected memory reminder (\(MemoryReminderInjector.shared.getStoredCount(for: conversation.id)) memories)")
            }
        }

        /// STATUS SIGNAL REMINDER INJECTION: Tell agent to emit status signals when workflow mode is enabled
        /// This reminds the agent to emit {"status": "continue"} or {"status": "complete"} at the end of each response
        if StatusSignalReminderInjector.shared.shouldInjectReminder(isWorkflowMode: conversation.settings.enableWorkflowMode) {
            let statusReminder = StatusSignalReminderInjector.shared.formatStatusSignalReminder()
            messages.append(createSystemReminder(content: statusReminder, model: model))
            logger.debug("callLLM: Injected status signal reminder (workflow mode enabled)")
        }

        /// Add conversation messages (user requests + LLM responses only, no tool results) CRITICAL: Use contextMessages if available (after pruning), otherwise use full messages This allows context pruning to work transparently - UI shows full history, LLM gets pruned context.
        var messagesToSend = conversation.contextMessages ?? conversation.messages

        /// Check if we have tool results to determine delta-only mode
        let hasToolResults = !internalMessages.isEmpty
        let messagesToAppend = internalMessages[...]
        logger.debug("INTERNAL_MESSAGES: Sending all \(internalMessages.count) internal messages (tool calls + results)")

        /// Delta-only slicing when statefulMarker exists (GitHub Copilot session continuity)
        /// CRITICAL FIX: Always slice when statefulMarker exists, not just for tool results!
        /// Previous bug: Only sliced when hasToolResults=true, causing Claude to loop by seeing its own responses
        ///
        /// CORRECT BEHAVIOR:
        /// 1. statefulMarker exists = delta-only mode - send ONLY messages after the marker
        /// 2. NO statefulMarker = first message or fresh start - send FULL conversation history
        ///
        /// WHY THIS PREVENTS LOOPS:
        /// - statefulMarker represents server's knowledge up to that point
        /// - Sending full history + statefulMarker = model sees its own previous responses
        /// - Claude sees "I listed directory before" → repeats same action → infinite loop!
        /// - Slicing = model only sees NEW context since last response → continues forward
        if let marker = statefulMarker {
            /// Delta-only mode: Server has full history up to marker, only need to send new messages
            /// PREFERRED: Use message count from when marker was captured (no timing dependencies)
            if let markerMessageCount = statefulMarkerMessageCount {
                /// Slice to only include messages AFTER the marker count
                let sliceIndex = markerMessageCount
                messagesToSend = Array(messagesToSend.suffix(from: min(sliceIndex, messagesToSend.count)))
                logger.debug("STATEFUL_MARKER_SLICING: Using message count \(markerMessageCount), sending \(messagesToSend.count) messages after marker (delta-only mode)")
            }
            /// FALLBACK: Search for marker in messages (timing-dependent)
            else if let markerIndex = messagesToSend.lastIndex(where: { $0.githubCopilotResponseId == marker }) {
                /// Slice to only include messages AFTER the marker (marker itself is already on server)
                messagesToSend = Array(messagesToSend.suffix(from: markerIndex + 1))
                logger.debug("STATEFUL_MARKER_SLICING: Found marker at index \(markerIndex), sending ONLY \(messagesToSend.count) messages after marker (delta-only mode, fallback method)")
            } else {
                logger.warning("STATEFUL_MARKER_WARNING: Marker \(marker.prefix(20))... not found in conversation AND no message count available, sending full history (\(messagesToSend.count) messages)")
            }
        } else {
            logger.debug("INFO: No statefulMarker, sending all \(messagesToSend.count) conversation messages")
        }

        logger.debug("DEBUG_DUPLICATION: Adding \(messagesToSend.count) conversation messages to request")

        /// When statefulMarker exists, send delta (sliced messages + tool results)
        /// This prevents duplicate assistant messages that cause Claude 400 errors
        /// CRITICAL FIX: Always use delta mode when statefulMarker exists (not just when hasToolResults)
        /// ROOT CAUSE: Sending full history + statefulMarker causes Claude to loop (sees own responses)
        /// Our approach: Sliced messagesToSend + internalMessages IS the complete delta
        /// Do NOT inject "Please continue" into messages array
        /// GitHub Copilot API: "Please continue" is query param only, NOT a synthetic message
        var currentMarker = statefulMarker  /// Make mutable copy
        if let marker = currentMarker {
            /// Delta-only mode: Server has full history up to marker, only send new context
            /// The stateful marker tells the API to continue from the previous response
            /// We send ONLY the delta: sliced conversation messages + tool results
            
            /// Add sliced conversation messages (already filtered by statefulMarkerMessageCount)
            for (index, historyMessage) in messagesToSend.enumerated() {
                let role = historyMessage.isFromUser ? "user" : "assistant"
                var cleanContent = historyMessage.content

                /// Clean tool call markers from assistant messages
                if role == "assistant" {
                    cleanContent = cleanToolCallMarkers(from: cleanContent)
                }

                messages.append(OpenAIChatMessage(role: role, content: cleanContent))
                logger.debug("DELTA_MESSAGE: Message \(index): role=\(role), content=\(cleanContent.safePrefix(50))")
            }
            
            /// Add internal messages (tool calls + results from current iteration)
            messages.append(contentsOf: messagesToAppend)
            logger.debug("STATEFUL_MARKER_DELTA_MODE: Sending \(messagesToSend.count) conversation + \(internalMessages.count) internal messages (delta-only mode)")

            /// CRITICAL FIX: Ensure messages start with USER role
            /// GitHub Copilot API requires first message to be user role
            /// If slicing resulted in only assistant/tool messages, prepend continue message
            if !messages.isEmpty && messages.first?.role != "user" {
                let continueMessage = OpenAIChatMessage(role: "user", content: "<system-reminder>continue</system-reminder>")
                messages.insert(continueMessage, at: 0)
                logger.debug("DELTA_USER_MESSAGE: Prepended <system-reminder>continue</system-reminder> (messages started with \(messages[1].role))")
            }

            /// CRITICAL: Enforce 16KB payload limit (vscode-copilot-chat pattern)
            /// Even with cached large tool results, accumulated deltas can exceed limit
            /// If trimming occurs, clear marker (it may reference removed message)
            if enforcePayloadSizeLimit(&messages, maxBytes: 16000) {
                currentMarker = nil
                logger.warning("PAYLOAD_SIZE: Cleared statefulMarker after trimming (marker may reference removed message)")
            }
        } else {
            /// Normal flow: Add conversation messages + internal messages
            /// CRITICAL FIX: Strip <userContext>...</userContext> blocks from OLD user messages
            /// These blocks are injected into every user message and stored permanently,
            /// causing context explosion (e.g., 13 messages × 9800 chars = 127,400 chars duplicated)
            /// Keep context ONLY on the LATEST user message
            let lastUserMessageIndex = messagesToSend.lastIndex(where: { $0.isFromUser })
            var strippedContextChars = 0

            for (index, historyMessage) in messagesToSend.enumerated() {
                let role = historyMessage.isFromUser ? "user" : "assistant"
                var cleanContent = historyMessage.content

                /// Clean tool call markers from assistant messages
                if role == "assistant" {
                    cleanContent = cleanToolCallMarkers(from: cleanContent)
                }

                /// Strip <userContext>...</userContext> from OLD user messages (not the latest one)
                /// This prevents sending the same 9800-char block 13+ times
                /// CRITICAL: Never strip from PINNED messages - they contain critical context
                /// (e.g., first message in conversation with copilot-instructions)
                if role == "user" && index != lastUserMessageIndex && !historyMessage.isPinned {
                    let originalLength = cleanContent.count
                    cleanContent = stripUserContextBlock(from: cleanContent)
                    let stripped = originalLength - cleanContent.count
                    if stripped > 0 {
                        strippedContextChars += stripped
                        logger.debug("CONTEXT_DEDUP: Stripped \(stripped) chars from user message \(index)")
                    }
                } else if role == "user" && historyMessage.isPinned && index != lastUserMessageIndex {
                    logger.debug("CONTEXT_DEDUP: Preserved <userContext> on pinned message \(index)")
                }

                messages.append(OpenAIChatMessage(role: role, content: cleanContent))
                logger.debug("DEBUG_DUPLICATION: Message \(index): role=\(role), content=\(cleanContent.safePrefix(50))")
            }

            if strippedContextChars > 0 {
                logger.info("CONTEXT_DEDUP: Total stripped \(strippedContextChars) chars of duplicated [User Context] blocks from \(messagesToSend.count) messages")
            }

            messages.append(contentsOf: messagesToAppend)
        }

        /// Only add new message if it's NOT already in conversation history The message might already be in conversation.messages if ChatWidget synced it, or if runAutonomousWorkflow() added it at line 193.
        logger.debug("DEBUG_DUPLICATION: Before adding new message - iteration=\(iteration), message='\(message)', messages.count=\(messages.count)")

        let newMessageNotInHistory = messagesToSend.isEmpty ||
                                     !messagesToSend.last!.isFromUser ||
                                     messagesToSend.last!.content != message

        /// VS CODE COPILOT PATTERN: Inject reminders RIGHT BEFORE the user message
        /// This positions them with maximum salience - the agent sees them immediately before responding

        /// Mini prompt reminder - user's enabled mini prompts (instructions)
        if let miniPromptReminder = miniPromptReminderContent {
            messages.append(createSystemReminder(content: miniPromptReminder, model: model))
            logger.debug("callLLM: Injected mini prompt reminder RIGHT BEFORE user message")
        }

        /// Todo reminder - task progress tracking
        if let todoReminder = todoReminderContent {
            messages.append(createSystemReminder(content: todoReminder, model: model))
            logger.debug("callLLM: Injected todo reminder RIGHT BEFORE user message (VS Code pattern, \(activeTodoCount) active todos)")
        }

        if message != "Please continue" && iteration == 0 && newMessageNotInHistory {
            messages.append(OpenAIChatMessage(role: "user", content: message))
            logger.debug("DEBUG_DUPLICATION: Added new user message (not in history), total now \(messages.count)")
        } else {
            logger.debug("DEBUG_DUPLICATION: Skipped adding new message - already in conversation history or continuation (iteration=\(iteration))")
        }

        logger.debug("callLLM: Request has \(messages.count) messages (\(messagesToSend.count) conversation + \(internalMessages.count) internal)")
        logger.debug("callLLM: User sees \(conversation.messages.count) messages, LLM context uses \(messagesToSend.count) messages")

        /// CRITICAL: Get model's actual context limit BEFORE YaRN processing
        /// This ensures YaRN compresses to the correct target for this specific model
        let modelContextLimit = await tokenCounter.getContextSize(modelName: model)
        logger.debug("YARN: Model '\(model)' has context limit of \(modelContextLimit) tokens")

        /// Process ALL messages with YARN before sending to LLM This includes conversation messages, system prompts, AND tool execution results Tool results can be massive (web scraping, document imports) and MUST be compressed.
        logger.debug("YARN: Processing ALL \(messages.count) messages (conversation + tool results) before LLM call")

        /// Calculate fingerprint BEFORE YaRN processing to detect compression
        let originalFingerprint = messageFingerprint(messages)

        var yarnCompressed = false
        do {
            messages = try await processAllMessagesWithYARN(messages, conversationId: conversationId, modelContextLimit: modelContextLimit)

            /// Calculate fingerprint AFTER YaRN processing
            let compressedFingerprint = messageFingerprint(messages)
            yarnCompressed = (originalFingerprint != compressedFingerprint)

            logger.debug("YARN: Processed messages ready for LLM (\(messages.count) messages after YARN)")
            logger.debug("YARN: Compression \(yarnCompressed ? "ACTIVE" : "NOT NEEDED") - fingerprints \(yarnCompressed ? "differ" : "match")")
        } catch {
            logger.warning("YARN: Processing failed, using original messages: \(error)")
            /// Continue with original messages if YARN fails.
        }

        /// Conditional statefulMarker based on YaRN compression + premium model status
        /// Get model billing info to determine if model is premium
        let modelIsPremium: Bool
        if let billingInfo = endpointManager.getGitHubCopilotModelBillingInfo(modelId: model) {
            modelIsPremium = billingInfo.isPremium
            logger.debug("BILLING: Model '\(model)' premium=\(modelIsPremium), multiplier=\(billingInfo.multiplier)x")
        } else {
            modelIsPremium = false
            logger.debug("BILLING: Model '\(model)' billing info unavailable, treating as free model")
        }

        /// Determine whether to use statefulMarker for billing continuity
        /// Use currentMarker (may be cleared if trimming occurred) instead of statefulMarker
        let checkpointMarker: String?
        if yarnCompressed && modelIsPremium {
            /// YaRN compressed context AND model charges premium rates
            /// Skip statefulMarker to avoid billing mismatch (compressed context != original context)
            checkpointMarker = nil
            logger.warning("BILLING: Skipping statefulMarker - YaRN compression active on premium model (prevents billing mismatch)")

            /// Notify user about potential premium billing due to compression
            /// Only notify for internal calls (not external API calls which have no UI)
            if !isExternalAPICall {
                let billingInfo = endpointManager.getGitHubCopilotModelBillingInfo(modelId: model)
                let multiplierText = billingInfo?.multiplier.map { "\($0)x" } ?? "premium"

                let warningMessage = """
                WARNING: Context Compression Notice

                Your conversation context has grown large. SAM automatically compressed the context to prevent errors.

                Because you're using a premium model (\(model) - \(multiplierText) billing multiplier), this request may incur premium API charges.

                This is normal for large conversations with many document imports or tool results. The compression ensures reliable operation.
                """

                /// Add warning as assistant message in conversation
                /// Use non-blocking approach - don't wait for user, just inform
                Task { @MainActor in
                    conversation.messageBus?.addAssistantMessage(
                        id: UUID(),
                        content: warningMessage,
                        timestamp: Date()
                    )
                    /// MessageBus handles persistence automatically
                }

                logger.info("BILLING: Added compression warning to conversation for user visibility")
            }
        } else {
            /// No compression OR free model - preserve statefulMarker for billing continuity
            /// CRITICAL: Use currentMarker (may be nil if trimming cleared it) instead of statefulMarker
            checkpointMarker = currentMarker ?? conversation.lastGitHubCopilotResponseId
            if let marker = checkpointMarker {
                logger.debug("BILLING: Using statefulMarker for billing continuity: \(marker.prefix(20))...")
            } else {
                logger.debug("BILLING: No statefulMarker available (may have been cleared by payload trimming)")
            }
        }

        /// Inject isExternalAPICall flag into samConfig for tool filtering External API calls should never have user_collaboration tool (no UI to interact with) SECURITY: Pass enableTerminalAccess from conversation settings to filter terminal_operations.
        let enhancedSamConfig: SAMConfig?
        if let samConfig = samConfig {
            enhancedSamConfig = SAMConfig(
                sharedMemoryEnabled: samConfig.sharedMemoryEnabled,
                mcpToolsEnabled: samConfig.mcpToolsEnabled,
                memoryCollectionId: samConfig.memoryCollectionId,
                conversationTitle: samConfig.conversationTitle,
                maxIterations: samConfig.maxIterations,
                enableReasoning: samConfig.enableReasoning,
                workingDirectory: samConfig.workingDirectory,
                systemPromptId: samConfig.systemPromptId,
                isExternalAPICall: isExternalAPICall,
                enableTerminalAccess: conversation.settings.enableTerminalAccess,
                enableWorkflowMode: samConfig.enableWorkflowMode,
                enableDynamicIterations: samConfig.enableDynamicIterations
            )
        } else if isExternalAPICall {
            /// No samConfig provided but we're external API call - create one with just the flag.
            enhancedSamConfig = SAMConfig(isExternalAPICall: true, enableTerminalAccess: false)
        } else {
            /// No samConfig, internal call - still need to pass terminal setting.
            enhancedSamConfig = SAMConfig(enableTerminalAccess: conversation.settings.enableTerminalAccess)
        }

        /// Build OpenAI request WITHOUT tools (we'll inject them next) Use conversation's maxTokens setting (user-configured, defaults to 8192).
        /// CRITICAL: Ensure maxTokens is at least 4096 to prevent truncated responses
        let effectiveMaxTokens = max(conversation.settings.maxTokens ?? 8192, 4096)
        let baseRequest = OpenAIChatRequest(
            model: model,
            messages: messages,
            temperature: 0.7,
            maxTokens: effectiveMaxTokens,
            stream: false,
            samConfig: enhancedSamConfig,
            sessionId: conversationId.uuidString,
            statefulMarker: checkpointMarker,
            iterationNumber: iteration
        )

        /// Inject MCP tools using SharedConversationService This ensures tools are properly formatted in OpenAI format.
        logger.debug("callLLM: Injecting MCP tools via SharedConversationService")
        let requestWithTools = await conversationService.injectMCPToolsIntoRequest(baseRequest)

        /// CRITICAL: For Claude models, batch consecutive tool results into single user messages
        /// Claude Messages API requires ALL tool results from one iteration in ONE user message
        /// This fixes the tool result batching issue that caused workflow loops
        var messagesToProcess = requestWithTools.messages
        if modelLower.contains("claude") {
            messagesToProcess = batchToolResultsForClaude(messagesToProcess)
            logger.debug("callLLM: Applied Claude tool result batching")
        }

        /// CRITICAL: Ensure message alternation for Claude API compatibility
        /// Claude requires strict user/assistant alternation with no empty messages
        /// Apply this AFTER all message construction is complete but BEFORE sending to API
        let fixedMessages = ensureMessageAlternation(messagesToProcess)
        let finalRequest = OpenAIChatRequest(
            model: requestWithTools.model,
            messages: fixedMessages,
            temperature: requestWithTools.temperature,
            maxTokens: requestWithTools.maxTokens,
            stream: requestWithTools.stream,
            tools: requestWithTools.tools,
            samConfig: requestWithTools.samConfig,
            sessionId: requestWithTools.sessionId,
            statefulMarker: requestWithTools.statefulMarker,
            iterationNumber: requestWithTools.iterationNumber
        )
        logger.debug("callLLM: Applied message alternation validation for Claude compatibility")

        /// Validate request size before sending Most timeouts occur because agent sends too much data to API.
        let (estimatedTokens, isSafe, contextLimit) = await validateRequestSize(
            messages: finalRequest.messages,
            model: model,
            tools: finalRequest.tools
        )

        if !isSafe {
            logger.warning("API_REQUEST_SIZE: Request exceeds safe threshold (\(estimatedTokens) tokens / \(contextLimit) limit)")
            logger.warning("API_REQUEST_SIZE: Forcing aggressive YaRN compression to 70% target to prevent 400 errors")

            /// Force aggressive compression when request too large
            /// This prevents 400 Bad Request errors that cause infinite workflow loops
            let targetTokens = Int(Double(contextLimit) * 0.70) // Target 70% instead of 85%

            if let processor = yarnProcessor {
                logger.debug("YARN_FORCED: Applying emergency compression from \(estimatedTokens) to target \(targetTokens) tokens")

                /// Convert OpenAIChatMessage to Message format for YaRN processing
                let conversationMessages = messages.map { chatMsg -> Message in
                    Message(
                        id: UUID(),
                        content: chatMsg.content ?? "",
                        isFromUser: chatMsg.role == "user",
                        timestamp: Date(),
                        performanceMetrics: nil,
                        githubCopilotResponseId: nil,
                        isPinned: chatMsg.role == "system",
                        importance: chatMsg.role == "system" ? 1.0 : (chatMsg.role == "user" ? 0.9 : 0.7)
                    )
                }

                do {
                    /// Force aggressive compression with explicit target
                    let processedContext = try await processor.processConversationContext(
                        messages: conversationMessages,
                        conversationId: conversationId,
                        targetTokenCount: targetTokens
                    )

                    /// Convert back to OpenAIChatMessage
                    messages = processedContext.messages.map { message -> OpenAIChatMessage in
                        let role = message.isFromUser ? "user" : (message.isPinned ? "system" : "assistant")
                        return OpenAIChatMessage(role: role, content: message.content)
                    }

                    logger.debug("YARN_FORCED: Successfully compressed to \(processedContext.tokenCount) tokens (target was \(targetTokens))")

                    /// Update yarnCompressed flag since we just compressed again
                    yarnCompressed = true
                    
                    /// Track compression telemetry
                    await conversationManager.incrementCompressionEvent(for: conversationId)

                    /// Rebuild request with compressed messages
                    /// Need to create new baseRequest with compressed messages
                    let compressedBaseRequest = OpenAIChatRequest(
                        model: model,
                        messages: messages,
                        temperature: 0.7,
                        maxTokens: conversation.settings.maxTokens ?? 8192,
                        stream: false,
                        samConfig: enhancedSamConfig,
                        sessionId: conversationId.uuidString,
                        statefulMarker: checkpointMarker,
                        iterationNumber: iteration
                    )

                    /// Re-inject tools with compressed messages
                    let compressedRequestWithTools = await conversationService.injectMCPToolsIntoRequest(compressedBaseRequest)

                    /// CRITICAL: For Claude models, batch consecutive tool results into single user messages
                    var compressedMessagesToProcess = compressedRequestWithTools.messages
                    if modelLower.contains("claude") {
                        compressedMessagesToProcess = batchToolResultsForClaude(compressedMessagesToProcess)
                        logger.debug("callLLM: Applied Claude tool result batching to compressed messages")
                    }

                    /// CRITICAL: Ensure message alternation for Claude API compatibility
                    let fixedCompressedMessages = ensureMessageAlternation(compressedMessagesToProcess)
                    let finalCompressedRequest = OpenAIChatRequest(
                        model: compressedRequestWithTools.model,
                        messages: fixedCompressedMessages,
                        temperature: compressedRequestWithTools.temperature,
                        maxTokens: compressedRequestWithTools.maxTokens,
                        stream: compressedRequestWithTools.stream,
                        tools: compressedRequestWithTools.tools,
                        samConfig: compressedRequestWithTools.samConfig,
                        sessionId: compressedRequestWithTools.sessionId,
                        statefulMarker: compressedRequestWithTools.statefulMarker,
                        iterationNumber: compressedRequestWithTools.iterationNumber
                    )
                    logger.debug("callLLM: Applied message alternation validation to compressed request")

                    /// Proceed with compressed request
                    logger.debug("callLLM: Calling EndpointManager.processChatCompletion() with compressed request and retry policy")

                    let retryPolicy = RetryPolicy.default
                    let response = try await retryPolicy.execute(
                        operation: { [self] in
                            try await self.endpointManager.processChatCompletion(finalCompressedRequest)
                        },
                        onRetry: { [self] attempt, delay, error in
                            self.logger.warning("API_RETRY: Non-streaming attempt \(attempt)/\(retryPolicy.maxRetries) after \(delay)s delay - \(errorDescription(for: error))")
                        }
                    )

                    /// Continue with response processing (code below will handle it)
                    guard let firstChoice = response.choices.first else {
                        logger.error("callLLM: No choices in LLM response")
                        return LLMResponse(
                            content: "ERROR: No response choices from LLM",
                            finishReason: "error",
                            toolCalls: nil,
                            statefulMarker: nil
                        )
                    }

                    let choiceWithTools = response.choices.first(where: { $0.message.toolCalls != nil && !$0.message.toolCalls!.isEmpty })
                    let contentChoice = response.choices.first(where: { $0.message.content != nil && !$0.message.content!.isEmpty }) ?? firstChoice

                    var finishReason: String
                    if let toolChoice = choiceWithTools {
                        finishReason = toolChoice.finishReason
                    } else {
                        if firstChoice.finishReason == "tool_calls" && firstChoice.message.toolCalls?.isEmpty != false {
                            logger.warning("BUG_FIX: GitHub Copilot returned finish_reason='tool_calls' with NO tool_calls array - overriding to 'stop'")
                            finishReason = "stop"
                        } else {
                            finishReason = firstChoice.finishReason
                        }
                    }
                    let content = contentChoice.message.content ?? ""

                    logger.debug("callLLM: Response has \(response.choices.count) choices, finishReason=\(finishReason), choiceWithTools=\(choiceWithTools != nil)")

                    var toolCalls: [ToolCall]?
                    if let choice = choiceWithTools, let openAIToolCalls = choice.message.toolCalls {
                        logger.debug("callLLM: Parsing \(openAIToolCalls.count) tool calls")
                        toolCalls = []

                        for toolCall in openAIToolCalls {
                            let argumentsData = toolCall.function.arguments.data(using: String.Encoding.utf8) ?? Data()
                            if let arguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] {
                                toolCalls?.append(ToolCall(
                                    id: toolCall.id,
                                    name: toolCall.function.name,
                                    arguments: arguments
                                ))
                                logger.debug("callLLM: Parsed tool call '\(toolCall.function.name)' (id: \(toolCall.id))")
                            } else {
                                logger.error("callLLM: Failed to parse arguments JSON for tool '\(toolCall.function.name)'")
                            }
                        }
                    }

                    /// Extract statefulMarker from response
                    let responseMarker = response.statefulMarker
                    if let marker = responseMarker {
                        logger.debug("callLLM: Received statefulMarker for future billing continuity: \(marker.prefix(20))...")
                    }

                    return LLMResponse(
                        content: content,
                        finishReason: finishReason,
                        toolCalls: toolCalls,
                        statefulMarker: responseMarker
                    )

                } catch {
                    logger.error("YARN_FORCED: Emergency compression failed: \(error)")
                    logger.warning("YARN_FORCED: Proceeding with original request - may result in 400 error")
                    /// Fall through to normal request handling below
                }
            } else {
                logger.error("YARN_FORCED: No processor available - cannot compress oversized request")
                logger.warning("YARN_FORCED: Proceeding anyway - high risk of 400 error")
            }
        }

        logger.debug("callLLM: Calling EndpointManager.processChatCompletion() with retry policy")

        /// Wrap API call with retry policy for transient network errors Prevents conversation loss on timeout/network issues (exponential backoff: 2s/4s/6s).
        let retryPolicy = RetryPolicy.default
        let response = try await retryPolicy.execute(
            operation: { [self] in
                try await self.endpointManager.processChatCompletion(finalRequest)
            },
            onRetry: { [self] attempt, delay, error in
                self.logger.warning("API_RETRY: Non-streaming attempt \(attempt)/\(retryPolicy.maxRetries) after \(delay)s delay - \(errorDescription(for: error))")

                /// Log retry for debugging - do NOT modify conversation.messages (causes UI issues) Retry notifications in non-streaming mode are logged only Streaming mode sends retry notifications via stream chunks (better UX).
            }
        )

        guard let firstChoice = response.choices.first else {
            logger.error("callLLM: No choices in LLM response")
            /// Return empty response instead of throwing - allows workflow to continue.
            return LLMResponse(
                content: "ERROR: No response choices from LLM",
                finishReason: "error",
                toolCalls: nil,
                statefulMarker: nil
            )
        }

        /// GitHub Copilot may return multiple choices Choice 0: Thinking/explanation message with no tool calls Choice 1: Actual tool call with tool_calls array We need to find the choice with tool calls, not just use the first one.
        let choiceWithTools = response.choices.first(where: { $0.message.toolCalls != nil && !$0.message.toolCalls!.isEmpty })
        let contentChoice = response.choices.first(where: { $0.message.content != nil && !$0.message.content!.isEmpty }) ?? firstChoice

        /// If no choice has tool_calls, use firstChoice's finish_reason (NOT choiceWithTools) GitHub Copilot sometimes returns finish_reason="tool_calls" with NO actual tool_calls array This caused workflow to break thinking tools are pending when there are none.
        var finishReason: String
        var contentFilterResults: ContentFilterResults?

        if let toolChoice = choiceWithTools {
            /// Found a choice with actual tool_calls → use its finish_reason.
            finishReason = toolChoice.finishReason
            contentFilterResults = toolChoice.contentFilterResults
        } else {
            /// No choice has tool_calls → MUST use stop/length (NOT tool_calls from firstChoice!) CRITICAL: If firstChoice says "tool_calls" but has no toolCalls array, override to "stop".
            if firstChoice.finishReason == "tool_calls" && firstChoice.message.toolCalls?.isEmpty != false {
                logger.warning("BUG_FIX: GitHub Copilot returned finish_reason='tool_calls' with NO tool_calls array - overriding to 'stop'")
                finishReason = "stop"
            } else {
                finishReason = firstChoice.finishReason
            }
            contentFilterResults = firstChoice.contentFilterResults
        }
        let content = contentChoice.message.content ?? ""

        /// CONTENT FILTER DETECTION: Check if response was blocked and provide clear error message
        if finishReason == "content_filter" {
            let filterType = contentFilterResults?.getTriggeredFilters() ?? "content policy"
            logger.error("️ CONTENT_FILTER_BLOCKED: Response blocked by \(filterType) filter")

            let errorMessage = """
            WARNING: **Content Filter Blocked Response**

            The AI provider's content filter blocked this response due to: **\(filterType)** policy violation.

            **Why this happens:**
            - GitHub Copilot has strict content filtering for violence, hate speech, sexual content, and self-harm
            - Legitimate news content (crime reports, political events) may trigger these filters
            - This is a provider limitation, not a SAM issue

            **Solutions:**
            1. **Switch provider**: Use OpenAI or Claude models (less restrictive filtering)
            2. **Modify request**: Ask for different topics or sections (avoid crime/violence if possible)
            3. **Try again**: Sometimes rephrasing the request helps

            **To switch provider:**
            - Settings → API Providers → Select OpenAI or Claude
            - Or use model picker to choose a non-GitHub model

            *If you need assistance with crime/violence news content, OpenAI and Claude providers work better for this use case.*
            """

            return LLMResponse(
                content: errorMessage,
                finishReason: "content_filter",
                toolCalls: nil,
                statefulMarker: response.statefulMarker
            )
        }

        logger.debug("callLLM: Response has \(response.choices.count) choices, finishReason=\(finishReason), choiceWithTools=\(choiceWithTools != nil)")

        /// Parse tool calls if present (from the choice that actually has them).
        var toolCalls: [ToolCall]?
        if let choice = choiceWithTools, let openAIToolCalls = choice.message.toolCalls {
            logger.debug("callLLM: Parsing \(openAIToolCalls.count) tool calls")
            toolCalls = []

            for toolCall in openAIToolCalls {
                /// Parse arguments JSON string to dictionary.
                let argumentsData = toolCall.function.arguments.data(using: String.Encoding.utf8) ?? Data()
                if let arguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] {
                    toolCalls?.append(ToolCall(
                        id: toolCall.id,
                        name: toolCall.function.name,
                        arguments: arguments
                    ))
                    logger.debug("callLLM: Parsed tool call '\(toolCall.function.name)' (id: \(toolCall.id))")
                } else {
                    logger.error("callLLM: Failed to parse arguments JSON for tool '\(toolCall.function.name)'")
                }
            }
        }

        logger.debug("callLLM: LLM response - finishReason=\(finishReason), content length=\(content.count), toolCalls=\(toolCalls?.count ?? 0)")

        /// MLX Tool Call Parser - Extract tool calls from JSON code blocks MLX models don't have native tool calling support, they output JSON blocks or [TOOL_CALLS] format We need to parse these and create ToolCall objects.
        var finalContent = content
        var finalToolCalls = toolCalls

        if finalToolCalls == nil || finalToolCalls!.isEmpty {
            /// No native tool calls found - check for MLX-style formats.
            let (mlxToolCalls, cleanedContent) = extractMLXToolCalls(from: content)

            if !mlxToolCalls.isEmpty {
                logger.debug("callLLM: Extracted \(mlxToolCalls.count) MLX tool calls from response")
                finalToolCalls = mlxToolCalls
                finalContent = cleanedContent

                /// Override finish_reason to tool_calls so autonomous loop continues.
                if finishReason != "tool_calls" {
                    logger.debug("callLLM: Overriding finish_reason to 'tool_calls' for MLX model")
                    finishReason = "tool_calls"
                }
            } else {
                logger.debug("callLLM: No MLX tool calls found in response")
            }
        } else {
            logger.debug("callLLM: Using native tool calls from provider (\(finalToolCalls!.count) calls)")
        }

        /// CRITICAL: Strip system-reminder tags before returning/saving
        /// Claude may echo back <system-reminder> content - must filter it out
        finalContent = stripSystemReminders(from: finalContent)

        /// Extract statefulMarker from response for GitHub Copilot session continuity This is used as previous_response_id in subsequent requests to prevent quota increments.
        let statefulMarker = response.statefulMarker
        if let marker = statefulMarker {
            logger.debug("callLLM: Extracted statefulMarker from response: \(marker.prefix(20))...")
        }

        return LLMResponse(
            content: finalContent,
            finishReason: finishReason,
            toolCalls: finalToolCalls,
            statefulMarker: statefulMarker
        )
    }

    /// Calls the LLM via EndpointManager with streaming support Yields chunks to continuation in real-time for better UX.
    @MainActor
    private func callLLMStreaming(
        conversationId: UUID,
        message: String,
        model: String,
        internalMessages: [OpenAIChatMessage],
        iteration: Int,
        continuation: AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error>.Continuation,
        requestId: String,
        created: Int,
        samConfig: SAMConfig? = nil,
        statefulMarker: String? = nil,
        statefulMarkerMessageCount: Int? = nil,
        sentInternalMessagesCount: Int = 0,
        retrievedMessageIds: inout Set<UUID>
    ) async throws -> LLMResponse {
        logger.debug("ERROR:ERROR:ERROR: CALL_LLM_STREAMING_ENTRY_POINT_REACHED ERROR:ERROR:ERROR: - model: \(model), conversationId: \(conversationId)")
        logger.debug("callLLMStreaming: Building OpenAI streaming request for model '\(model)'")

        /// LAZY FETCH: Check if this is first GitHub Copilot request, fetch model capabilities if needed.
        await lazyFetchModelCapabilitiesIfNeeded(for: model)

        /// Get conversation for user messages only (not tool results).
        guard let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) else {
            logger.error("callLLMStreaming: Conversation not found: \(conversationId.uuidString)")
            return LLMResponse(
                content: "ERROR: Conversation not found",
                finishReason: "error",
                toolCalls: nil,
                statefulMarker: nil
            )
        }

        /// CONTEXT MANAGEMENT: Use YARN exclusively CRITICAL Context pruning was causing premium billing charges because it calls GitHub API to generate summaries.
        logger.debug("CONTEXT_MANAGEMENT: Using YARN for context compression (no API calls, no premium charges)")

        /// Build messages array: system prompt + conversation messages + internal tool messages.
        var messages: [OpenAIChatMessage] = []

        /// Add user-configured system prompt (includes guard rails) FIRST This was the architectural gap - API requests never included SystemPromptManager prompts.
        let defaultPromptId = await MainActor.run {
            SystemPromptManager.shared.selectedConfigurationId
        }
        let promptId = conversation.settings.selectedSystemPromptId ?? defaultPromptId

        logger.debug("DEBUG_ORCH_CONV: callLLMStreaming using conversation \(conversation.id), selectedSystemPromptId: \(conversation.settings.selectedSystemPromptId?.uuidString ?? "nil"), promptId: \(promptId?.uuidString ?? "nil")")

        let toolsEnabled = samConfig?.mcpToolsEnabled ?? true
        let workflowModeEnabled = conversation.settings.enableWorkflowMode
        let dynamicIterationsEnabled = conversation.settings.enableDynamicIterations
        var userSystemPrompt = await MainActor.run {
            SystemPromptManager.shared.generateSystemPrompt(
                for: promptId,
                toolsEnabled: toolsEnabled,
                workflowModeEnabled: workflowModeEnabled,
                dynamicIterationsEnabled: dynamicIterationsEnabled,
                model: model
            )
        }

        /// Merge personality if selected
        if let personalityId = conversation.settings.selectedPersonalityId {
            let personalityManager = PersonalityManager()
            if let personality = personalityManager.getPersonality(id: personalityId),
               personality.id != Personality.assistant.id {  // Skip if Assistant (default)
                let personalityInstructions = personality.generatePromptAdditions()
                userSystemPrompt += "\n\n" + personalityInstructions
                logger.info("Merged personality '\(personality.name)' into system prompt (\(personalityInstructions.count) chars)")
            }
        }

        /// Inject conversation ID and working directory for memory operations and file operations.
        var systemPromptAdditions = """
        \(userSystemPrompt)

        CONVERSATION_ID: \(conversationId.uuidString)
        """

        /// Add working directory context when tools are enabled
        if toolsEnabled {
            let effectiveWorkingDir = conversationManager.getEffectiveWorkingDirectory(for: conversation)
            systemPromptAdditions += """


            # WORKING DIRECTORY CONTEXT

            Your current working directory is: `\(effectiveWorkingDir)`

            All file operations and terminal commands will execute relative to this directory by default.
            You do not need to run 'pwd' or ask about the starting directory - this IS your working directory.
            """
        }

        let systemPromptWithId = systemPromptAdditions

        logger.debug("callLLMStreaming: Generated system prompt from ID: \(promptId?.uuidString ?? "default"), length: \(systemPromptWithId.count) chars, toolsEnabled: \(toolsEnabled)")
        logger.debug("callLLMStreaming: Guard rails present: \(systemPromptWithId.contains("TOOL SCHEMA CONFIDENTIALITY"))")

        if !userSystemPrompt.isEmpty {
            messages.append(OpenAIChatMessage(role: "system", content: systemPromptWithId))
            logger.debug("callLLMStreaming: Added user-configured system prompt to messages (with conversation ID)")
        }

        /// CLAUDE USERCONTEXT INJECTION
        /// Per Claude Messages API best practices: Extract important context from ALL pinned messages
        /// and inject as system message on EVERY request (context doesn't persist in conversation history)
        /// Reference: claude-messages.txt - "Do not rely on Turn 1 staying in history forever"
        let modelLower = model.lowercased()
        if modelLower.contains("claude") {
            /// Extract userContext from ALL pinned messages
            let pinnedMessages = conversation.messages.filter { $0.isPinned }
            var extractedContexts: [String] = []
            
            for pinnedMessage in pinnedMessages {
                let content = pinnedMessage.content
                if let userContextStart = content.range(of: "\n\n<userContext>\n"),
                   let userContextEnd = content.range(of: "\n</userContext>", range: userContextStart.upperBound..<content.endIndex) {
                    /// Extract userContext content (without tags)
                    let userContextContent = String(content[userContextStart.upperBound..<userContextEnd.lowerBound])
                    extractedContexts.append(userContextContent)
                }
            }
            
            /// If we found any userContext blocks in pinned messages, inject them
            if !extractedContexts.isEmpty {
                let claudeContextMessage = """
                ## User Context (Persistent)
                
                This context was provided in pinned messages and applies to all turns of this conversation:
                
                \(extractedContexts.joined(separator: "\n\n---\n\n"))
                """
                
                messages.append(OpenAIChatMessage(role: "system", content: claudeContextMessage))
                logger.info("CLAUDE_CONTEXT: Injected userContext from \(extractedContexts.count) pinned message(s) as system content (\(claudeContextMessage.count) chars)")
            }
        }

        /// AUTOMATIC CONTEXT RETRIEVAL Inject pinned messages + semantic search results BEFORE conversation messages This ensures critical context (initial request, key decisions) is always available CRITICAL FIX: Use message ID tracking to prevent Phase 3 duplication across iterations - Phase 1 (pinned) always runs - core context - Phase 2 (semantic search) always runs - relevant memories - Phase 3 (high-importance) tracks retrieved IDs - prevents duplication while preserving context.
        if let retrievedContext = await retrieveRelevantContext(
            conversation: conversation,
            currentUserMessage: message,
            iteration: iteration,
            caller: "callLLMStreaming_line3534",
            retrievedMessageIds: &retrievedMessageIds
        ) {
            messages.append(OpenAIChatMessage(role: "system", content: retrievedContext))
            logger.debug("callLLMStreaming: Added automatic context retrieval (\(retrievedContext.count) chars) for iteration \(iteration)")
        }

        /// DOCUMENT IMPORT REMINDER INJECTION Tell agent what documents are already imported so they search memory instead of re-importing
        if DocumentImportReminderInjector.shared.shouldInjectReminder(conversationId: conversation.id) {
            if let docReminder = DocumentImportReminderInjector.shared.formatDocumentReminder(conversationId: conversation.id) {
                messages.append(createSystemReminder(content: docReminder, model: model))
                logger.debug("callLLMStreaming: Injected document import reminder (\(DocumentImportReminderInjector.shared.getImportedCount(for: conversation.id)) docs)")
            }
        }

        /// Filter out UI-only progress/status messages before sending to API These messages are only for UI display and should not be sent to LLM WHY FILTER: - Progress messages like "→ Continuing work" or "SUCCESS: User Collaboration: ..." are UI-only - They don't represent actual conversation content - Including them adds unnecessary noise to LLM context WHAT TO FILTER: - Messages starting with "→" (continuation status) - Messages starting with "SUCCESS: User Collaboration:" (collaboration prompts) - "Extended execution limit" status messages WHAT TO KEEP: - User messages (always kept) - Tool result messages (isToolMessage=true) - even if they start with "SUCCESS:" - Assistant messages with actual LLM responses.
        var conversationMessages: [Message] = Array(conversation.messages).filter { msg in
            /// Always keep user messages.
            if msg.isFromUser {
                return true
            }

            /// CRITICAL: Always keep tool messages - they contain tool execution results
            /// These are needed for the agent to understand what work was done
            if msg.isToolMessage {
                return true
            }

            /// For assistant messages, check if it's a UI-only progress message.
            let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)

            /// Filter out progress/status messages (UI-only, not real LLM responses).
            /// Be specific - only filter known UI-only patterns, not all "SUCCESS:" messages
            let uiOnlyPatterns = [
                "→",
                "SUCCESS: User Collaboration:",
                "Extended execution limit"
            ]

            for pattern in uiOnlyPatterns {
                if content.hasPrefix(pattern) {
                    logger.debug("STREAMING_FILTER: Excluding UI progress message from API: \(String(content.prefix(50)))...")
                    return false
                }
            }

            /// Keep assistant messages (real LLM responses).
            return true
        }

        /// Handle tool results properly We still send tool results from internalMessages to provide LLM with tool execution context.
        let hasToolResults = !internalMessages.isEmpty
        let checkpointSlicedAllMessages = false

        let internalMessagesToSend = internalMessages[...]
        logger.debug("INTERNAL_MESSAGES_STREAMING: Sending all \(internalMessages.count) internal messages (tool calls + results)")

        /// Delta-only slicing ONLY when statefulMarker exists AND we have tool results
        /// Previously, slicing happened whenever statefulMarker existed, even for subsequent user messages
        /// This caused conversationMessages to be empty when user sent a follow-up message, removing all context!
        /// /// CORRECT BEHAVIOR:
        /// 1. statefulMarker + hasToolResults = delta-only mode (workflow iteration) - skip conversation history
        /// 2. statefulMarker + NO tool results = subsequent user message - send FULL conversation history
        /// 3. NO statefulMarker = first message or fresh start - send FULL conversation history
        if let marker = statefulMarker, hasToolResults {
            /// Delta-only mode: This is a workflow iteration with tool results
            /// Server has full history up to marker, only need to send tool execution delta
            /// PREFERRED: Use message count from when marker was captured (no timing dependencies)
            if let markerMessageCount = statefulMarkerMessageCount {
                /// Slice to only include messages AFTER the marker count
                /// Example: If marker was captured at count=3, send messages from index 3 onwards
                let sliceIndex = markerMessageCount
                conversationMessages = Array(conversationMessages.suffix(from: min(sliceIndex, conversationMessages.count)))
                logger.debug("STATEFUL_MARKER_SLICING: Using message count \(markerMessageCount), sending \(conversationMessages.count) messages after marker (delta-only mode with tool results)")
            }
            /// FALLBACK: Search for marker in messages (timing-dependent, may fail if message not persisted yet)
            else if let markerIndex = conversationMessages.lastIndex(where: { $0.githubCopilotResponseId == marker }) {
                /// Slice to only include messages AFTER the marker (marker itself is already on server)
                conversationMessages = Array(conversationMessages.suffix(from: markerIndex + 1))
                logger.debug("STATEFUL_MARKER_SLICING: Found marker at index \(markerIndex), sending ONLY \(conversationMessages.count) messages after marker (delta-only mode, fallback method)")
            } else {
                logger.warning("STATEFUL_MARKER_WARNING: Marker \(marker.prefix(20))... not found in conversation AND no message count available, sending full history (\(conversationMessages.count) messages)")
            }
        } else if statefulMarker != nil && !hasToolResults {
            /// Subsequent user message scenario: statefulMarker exists but no tool results yet
            /// Do NOT slice conversation history - user needs full context for their new message!
            logger.debug("SUBSEQUENT_USER_MESSAGE: StatefulMarker exists but no tool results - sending FULL conversation history (\(conversationMessages.count) messages) for user context")
        } else {
            logger.debug("INFO: No statefulMarker, sending all \(conversationMessages.count) conversation messages")
        }

        /// When statefulMarker exists, send ONLY internalMessages (delta-only mode)
        /// This prevents duplicate assistant messages that cause Claude 400 errors
        /// ROOT CAUSE: Assistant responses are in BOTH conversation.messages AND internalMessages
        /// GitHub Copilot approach: With statefulMarker, only send NEW messages (delta)
        /// Our approach: internalMessages IS the delta (tool calls + results from previous iteration)
        /// Do NOT inject "Please continue" into messages array
        /// GitHub Copilot API: "Please continue" is query param only, NOT a synthetic message
        var currentMarker = statefulMarker  /// Make mutable copy
        if let marker = currentMarker, hasToolResults {
            /// Delta-only mode: Server has full history up to marker, only send new tool execution context
            /// The stateful marker tells the API to continue from the previous response
            /// We send ONLY the tool results (delta), not the full conversation history
            messages.append(contentsOf: internalMessagesToSend)
            logger.debug("STATEFUL_MARKER_DELTA_MODE: Sending \(internalMessagesToSend.count) internal messages (delta-only mode, no synthetic user message)")

            /// CRITICAL: Enforce 16KB payload limit (vscode-copilot-chat pattern)
            /// Even with cached large tool results, accumulated deltas can exceed limit
            /// If trimming occurs, clear marker (it may reference removed message)
            if enforcePayloadSizeLimit(&messages, maxBytes: 16000) {
                currentMarker = nil
                logger.warning("PAYLOAD_SIZE: Cleared statefulMarker after trimming (marker may reference removed message)")
            }
        } else if hasToolResults && checkpointSlicedAllMessages {
            /// BILLING FIX: Checkpoint found AND we have tool results Send ONLY tool results, don't duplicate conversation history.
            logger.debug("BILLING_FIX: Checkpoint slicing produced 0 conversation messages + tool results present")
            logger.debug("BILLING_FIX: Sending ONLY \(internalMessagesToSend.count) tool results (no conversation duplication) - this prevents premium charge")
            messages.append(contentsOf: internalMessagesToSend)
        } else {
            /// Normal flow: Add conversation messages + tool results (First request, or checkpoint not found, or no tool results).
            /// CRITICAL FIX: Strip <userContext>...</userContext> blocks from OLD user messages
            /// These blocks are injected into every user message and stored permanently,
            /// causing context explosion (e.g., 13 messages × 9800 chars = 127,400 chars duplicated)
            /// Keep context ONLY on the LATEST user message
            let lastUserMessageIndex = conversationMessages.lastIndex(where: { $0.isFromUser })
            var strippedContextChars = 0

            for (index, historyMessage) in conversationMessages.enumerated() {
                var cleanContent = historyMessage.content

                /// DIAGNOSTIC: Track isToolMessage flag at conversion
                let hasPreview = cleanContent.contains("[TOOL_RESULT_PREVIEW]") || cleanContent.contains("[TOOL_RESULT_STORED]")
                if hasPreview {
                    let contentPrefix = cleanContent.prefix(60).replacingOccurrences(of: "\n", with: " ")
                    logger.debug("CONVERT_TOOL_MSG: isToolMessage=\(historyMessage.isToolMessage), type=\(historyMessage.type), contentPrefix=[\(contentPrefix)]")
                }

                // Handle tool messages with proper role and toolCallId
                if historyMessage.isToolMessage {
                    // Tool messages need role="tool" and toolCallId for proper API formatting
                    let toolCallId = historyMessage.toolCallId ?? UUID().uuidString
                    messages.append(OpenAIChatMessage(
                        role: "tool",
                        content: cleanContent,
                        toolCallId: toolCallId
                    ))
                    logger.debug("CONTEXT_BUILD: Added tool message with id=\(toolCallId.prefix(8))...")
                    continue
                }

                let role = historyMessage.isFromUser ? "user" : "assistant"

                /// Clean tool call markers from assistant messages
                if role == "assistant" {
                    cleanContent = cleanToolCallMarkers(from: cleanContent)
                }

                /// Strip <userContext>...</userContext> from OLD user messages (not the latest one)
                /// This prevents sending the same 9800-char block 13+ times
                /// CRITICAL: Never strip from PINNED messages - they contain critical context
                /// (e.g., first message in conversation with copilot-instructions)
                if role == "user" && index != lastUserMessageIndex && !historyMessage.isPinned {
                    let originalLength = cleanContent.count
                    cleanContent = stripUserContextBlock(from: cleanContent)
                    let stripped = originalLength - cleanContent.count
                    if stripped > 0 {
                        strippedContextChars += stripped
                        logger.debug("CONTEXT_DEDUP: Stripped \(stripped) chars from user message \(index)")
                    }
                } else if role == "user" && historyMessage.isPinned && index != lastUserMessageIndex {
                    logger.debug("CONTEXT_DEDUP: Preserved <userContext> on pinned message \(index)")
                }

                messages.append(OpenAIChatMessage(role: role, content: cleanContent))
            }

            if strippedContextChars > 0 {
                logger.info("CONTEXT_DEDUP: Total stripped \(strippedContextChars) chars of duplicated [User Context] blocks from \(conversationMessages.count) messages")
            }

            /// Add tool results if present.
            if hasToolResults {
                messages.append(contentsOf: internalMessagesToSend)
                logger.debug("BILLING_DEBUG: Added \(conversationMessages.count) conversation messages + \(internalMessagesToSend.count) tool messages")
            } else {
                logger.debug("BILLING_DEBUG: Added \(conversationMessages.count) conversation messages (no tool results)")
            }
        }

        /// VS CODE COPILOT PATTERN: Inject reminders at the END of messages (high salience)
        /// This is critical for multi-step workflows - agent needs to see reminders right before responding
        let activeTodoCount = TodoManager.shared.getProgressStatistics(for: conversation.id.uuidString).totalTodos
        let responseCount = conversation.messages.count

        /// Mini prompt reminder - user's enabled mini prompts (instructions)
        if MiniPromptReminderInjector.shared.shouldInjectReminder(
            conversationId: conversation.id,
            enabledMiniPromptIds: conversation.enabledMiniPromptIds,
            currentResponseCount: responseCount
        ) {
            if let miniPromptReminder = MiniPromptReminderInjector.shared.formatMiniPromptReminder(
                conversationId: conversation.id,
                enabledMiniPromptIds: conversation.enabledMiniPromptIds
            ) {
                messages.append(createSystemReminder(content: miniPromptReminder, model: model))
                logger.debug("callLLMStreaming: Injected mini prompt reminder at END of messages")
            }
        }

        /// Todo reminder - task progress tracking
        if TodoReminderInjector.shared.shouldInjectReminder(
            conversationId: conversation.id,
            currentResponseCount: responseCount,
            activeTodoCount: activeTodoCount
        ) {
            if let todoReminder = TodoReminderInjector.shared.formatTodoReminder(
                conversationId: conversation.id,
                todoManager: TodoManager.shared
            ) {
                messages.append(createSystemReminder(content: todoReminder, model: model))
                logger.debug("callLLMStreaming: Injected todo reminder at END of messages (VS Code pattern, \(activeTodoCount) active todos)")
            }
        }

        /// Memory reminder - prevent duplicate memory stores
        /// CRITICAL: Inject at END of messages (high salience) so agent sees what was already stored
        if MemoryReminderInjector.shared.shouldInjectReminder(conversationId: conversation.id) {
            if let memoryReminder = MemoryReminderInjector.shared.formatMemoryReminder(conversationId: conversation.id) {
                messages.append(createSystemReminder(content: memoryReminder, model: model))
                logger.debug("callLLMStreaming: Injected memory reminder at END of messages (\(MemoryReminderInjector.shared.getStoredCount(for: conversation.id)) memories)")
            }
        }

        /// Status signal reminder - prompt agent to emit continue/complete signals
        /// CRITICAL: Inject at END of messages (high salience) when workflow mode is enabled
        if StatusSignalReminderInjector.shared.shouldInjectReminder(isWorkflowMode: conversation.settings.enableWorkflowMode) {
            let statusReminder = StatusSignalReminderInjector.shared.formatStatusSignalReminder()
            messages.append(createSystemReminder(content: statusReminder, model: model))
            logger.debug("callLLMStreaming: Injected status signal reminder at END of messages (workflow mode enabled)")
        }

        logger.debug("callLLMStreaming: Built complete message array with \(messages.count) messages (before alternation fix)")

        /// CRITICAL: For Claude models, batch consecutive tool results into single user messages
        /// Claude Messages API requires ALL tool results from one iteration in ONE user message
        /// This fixes the tool result batching issue that caused workflow loops
        if modelLower.contains("claude") {
            messages = batchToolResultsForClaude(messages)
            logger.debug("callLLMStreaming: Applied Claude tool result batching")
        }

        /// CRITICAL: Fix message alternation BEFORE YARN compression
        /// Claude requires strict user/assistant alternation with no empty messages
        /// This MUST happen before YARN because YARN compresses individual messages
        /// If we merge AFTER YARN, we concatenate compressed content and blow up token count!
        messages = ensureMessageAlternation(messages)
        logger.debug("callLLMStreaming: Applied message alternation fix - \(messages.count) messages after merging")

        /// CRITICAL: Get model's actual context limit BEFORE YaRN processing
        /// This ensures YaRN compresses to the correct target for this specific model
        let modelContextLimit = await tokenCounter.getContextSize(modelName: model)
        logger.debug("YARN: Model '\(model)' has context limit of \(modelContextLimit) tokens")

        /// Process ALL messages with YARN before sending to LLM This includes conversation messages, system prompts, AND tool execution results Tool results can be massive (web scraping, document imports) and MUST be compressed.
        logger.debug("YARN: Processing ALL \(messages.count) messages (conversation + tool results) before LLM call")
        do {
            messages = try await processAllMessagesWithYARN(messages, conversationId: conversationId, modelContextLimit: modelContextLimit)
            logger.debug("YARN: Processed messages ready for LLM (\(messages.count) messages after YARN)")
        } catch {
            logger.warning("YARN: Processing failed, using original messages: \(error)")
            /// Continue with original messages if YARN fails.
        }

        logger.debug("callLLMStreaming: Request has \(messages.count) messages (after YARN)")

        /// Log statefulMarker presence for debugging.
        if let marker = statefulMarker {
            logger.debug("callLLMStreaming: Including statefulMarker from previous iteration: \(marker.prefix(20))...")
        }

        /// Inject isExternalAPICall flag into samConfig for tool filtering External API calls should never have user_collaboration tool (no UI to interact with) SECURITY: Pass enableTerminalAccess from conversation settings to filter terminal_operations.
        let enhancedSamConfig: SAMConfig?
        if let samConfig = samConfig {
            enhancedSamConfig = SAMConfig(
                sharedMemoryEnabled: samConfig.sharedMemoryEnabled,
                mcpToolsEnabled: samConfig.mcpToolsEnabled,
                memoryCollectionId: samConfig.memoryCollectionId,
                conversationTitle: samConfig.conversationTitle,
                maxIterations: samConfig.maxIterations,
                enableReasoning: samConfig.enableReasoning,
                workingDirectory: samConfig.workingDirectory,
                systemPromptId: samConfig.systemPromptId,
                isExternalAPICall: isExternalAPICall,
                enableTerminalAccess: conversation.settings.enableTerminalAccess,
                enableWorkflowMode: samConfig.enableWorkflowMode,
                enableDynamicIterations: samConfig.enableDynamicIterations
            )
        } else if isExternalAPICall {
            /// No samConfig provided but we're external API call - create one with just the flag.
            enhancedSamConfig = SAMConfig(isExternalAPICall: true, enableTerminalAccess: false)
        } else {
            /// No samConfig, internal call - still need to pass terminal setting.
            enhancedSamConfig = SAMConfig(enableTerminalAccess: conversation.settings.enableTerminalAccess)
        }

        /// Build OpenAI request with statefulMarker for GitHub Copilot session continuity Use conversation's maxTokens setting (user-configured, defaults to 8192).
        /// CRITICAL: Ensure maxTokens is at least 4096 to prevent truncated responses
        let effectiveMaxTokensStreaming = max(conversation.settings.maxTokens ?? 8192, 4096)
        let baseRequest = OpenAIChatRequest(
            model: model,
            messages: messages,
            temperature: 0.7,
            maxTokens: effectiveMaxTokensStreaming,
            stream: true,
            samConfig: enhancedSamConfig,
            sessionId: conversationId.uuidString,
            statefulMarker: currentMarker,
            iterationNumber: iteration
        )

        /// Inject MCP tools.
        logger.debug("callLLMStreaming: Injecting MCP tools")
        let finalRequest = await conversationService.injectMCPToolsIntoRequest(baseRequest)

        /// Validate request size before sending Most timeouts occur because agent sends too much data to API.
        let (estimatedTokens, isSafe, contextLimit) = await validateRequestSize(
            messages: finalRequest.messages,
            model: model,
            tools: finalRequest.tools
        )

        if !isSafe {
            logger.warning("API_REQUEST_SIZE: Streaming request exceeds safe threshold (\(estimatedTokens) tokens / \(contextLimit) limit)")
            logger.warning("API_REQUEST_SIZE: High risk of timeout. Consider additional YARN compression in future iterations.")
            /// We proceed anyway (retry will handle timeout), but log warning for improvement.
        }

        logger.debug("callLLMStreaming: Calling EndpointManager.processStreamingChatCompletion() with retry policy")

        /// Wrap streaming call with retry policy Must retry BEFORE yielding any chunks to continuation.
        let retryPolicy = RetryPolicy.default

        let streamingResponse = try await retryPolicy.execute(
            operation: { [self] in
                try await self.endpointManager.processStreamingChatCompletion(finalRequest)
            },
            onRetry: { [self] attempt, delay, error in
                self.logger.warning("STREAMING_RETRY: Attempt \(attempt)/\(retryPolicy.maxRetries) after \(delay)s delay - \(errorDescription(for: error))")

                /// Send retry notification via streaming continuation (will appear in real-time).
                let retryChunk = ServerOpenAIChatStreamChunk(
                    id: requestId,
                    object: "chat.completion.chunk",
                    created: created,
                    model: model,
                    choices: [
                        OpenAIChatStreamChoice(
                            index: 0,
                            delta: OpenAIChatDelta(
                                role: nil,
                                content: "\n\nNetwork timeout - retrying (attempt \(attempt)/\(retryPolicy.maxRetries))...\n\n",
                                toolCalls: nil,
                                statefulMarker: nil
                            ),
                            finishReason: nil
                        )
                    ]
                )
                continuation.yield(retryChunk)
            }
        )

        /// Accumulate response while yielding chunks.
        var accumulatedContent = ""
        var finishReason: String?
        var statefulMarker: String?
        var contentFilterResults: ContentFilterResults?

        /// CLAUDE FIX: Use ModelConfigurationManager to determine delta mode
        /// Claude models send FULL message content in each chunk (cumulative deltas)
        /// GPT models send ONLY new tokens in each chunk (incremental deltas)
        let isCumulativeDeltaModel = ModelConfigurationManager.shared.isCumulativeDeltaModel(model)

        /// Extract normalized model name for logging
        let normalizedModel = model.contains("/") ? model.components(separatedBy: "/").last ?? model : model

        logger.debug("STREAMING_MODE_DETECTION", metadata: [
            "model": .string(model),
            "normalizedModel": .string(normalizedModel),
            "isCumulative": .stringConvertible(isCumulativeDeltaModel),
            "configFound": .stringConvertible(ModelConfigurationManager.shared.getConfiguration(for: model) != nil)
        ])

        if isCumulativeDeltaModel {
            logger.debug("STREAMING_REPLACE: Using cumulative delta mode (Claude) - will REPLACE content each chunk")
        } else {
            logger.debug("STREAMING_APPEND: Using incremental delta mode (GPT) - will ACCUMULATE content each chunk")
        }

        /// CRITICAL: Delay assistant message creation until first content chunk
        /// Do NOT create message until we have actual content (not just tool calls)
        /// This prevents empty assistant messages when LLM only returns tool calls
        var assistantMessageId: UUID?

        /// Track tool messages by execution ID to create separate cards for each tool call
        var toolMessagesByExecutionId: [String: UUID] = [:]

        /// Track accumulated content separately for each message
        var accumulatedContentByMessageId: [UUID: String] = [:]

        /// Use StreamingToolCalls for index-based accumulation.
        let streamingToolCalls = StreamingToolCalls()

        /// Track chunk count for debugging
        var chunkCount = 0

        for try await chunk in streamingResponse {
            /// CRITICAL: Check for cancellation on each chunk to enable immediate stop
            /// This allows the stop button to immediately halt streaming from remote APIs
            if isCancellationRequested {
                logger.info("STREAMING_CANCELLED: Cancellation flag set, stopping stream immediately")
                continuation.finish()
                return LLMResponse(
                    content: accumulatedContent,
                    finishReason: "cancelled",
                    toolCalls: nil,
                    statefulMarker: statefulMarker
                )
            }
            try Task.checkCancellation()

            /// CRITICAL: Determine which message this chunk belongs to
            /// - Tool chunks (isToolMessage=true) → create/update TOOL message
            /// - Regular chunks (isToolMessage=false) → update ASSISTANT message
            let targetMessageId: UUID

            if chunk.isToolMessage == true, let executionId = chunk.toolExecutionId {
                /// Tool chunk: create tool message if this is first chunk for this execution
                if let existingToolMessageId = toolMessagesByExecutionId[executionId] {
                    /// Reuse existing tool message for this execution
                    targetMessageId = existingToolMessageId
                } else {
                    /// Create new tool message for this execution
                    /// Convert String toolStatus to ToolStatus enum
                    let toolStatus: ToolStatus
                    if let statusString = chunk.toolStatus {
                        toolStatus = ToolStatus(rawValue: statusString) ?? .running
                    } else {
                        toolStatus = .running
                    }

                    let toolMessageId = conversation.messageBus?.addToolMessage(
                        id: UUID(),
                        name: chunk.toolName ?? "unknown",
                        status: toolStatus,
                        details: "",  /// Will be updated as chunks arrive
                        toolDisplayData: chunk.toolDisplayData,
                        toolCallId: executionId
                    ) ?? UUID()

                    toolMessagesByExecutionId[executionId] = toolMessageId
                    targetMessageId = toolMessageId

                    logger.debug("MESSAGEBUS_CREATE_TOOL: Created tool message id=\(toolMessageId.uuidString.prefix(8)) for execution=\(executionId.prefix(8)) tool=\(chunk.toolName ?? "unknown")")
                }
            } else {
                /// Regular LLM content chunk: create assistant message on first content chunk
                if assistantMessageId == nil {
                    /// First content chunk - create assistant message now
                    let newMessageId = UUID()
                    conversation.messageBus?.addAssistantMessage(
                        id: newMessageId,
                        content: "",  /// Will update with content immediately after
                        timestamp: Date(),
                        isStreaming: true
                    )
                    assistantMessageId = newMessageId
                    accumulatedContentByMessageId[newMessageId] = ""
                    logger.debug("MESSAGEBUS_CREATE: Created assistant message id=\(newMessageId.uuidString.prefix(8)) on first content chunk")
                }
                targetMessageId = assistantMessageId!
            }

            /// CRITICAL: Add messageId to chunk before yielding
            /// ChatWidget needs messageId to track which message is being updated
            /// API chunks don't include messageId - we add it here
            let chunkWithMessageId = ServerOpenAIChatStreamChunk(
                id: chunk.id,
                object: chunk.object,
                created: chunk.created,
                model: chunk.model,
                choices: chunk.choices,
                isToolMessage: chunk.isToolMessage,
                toolName: chunk.toolName,
                toolIcon: chunk.toolIcon,
                toolStatus: chunk.toolStatus,
                toolDisplayData: chunk.toolDisplayData,
                toolDetails: chunk.toolDetails,
                parentToolName: chunk.parentToolName,
                toolExecutionId: chunk.toolExecutionId,
                toolMetadata: chunk.toolMetadata,
                messageId: targetMessageId  /// Use tool message ID or assistant message ID
            )

            /// Yield chunk with appropriate messageId to continuation for real-time UI update.
            continuation.yield(chunkWithMessageId)

            /// DEBUG: Log chunk structure
            if let delta = chunk.choices.first?.delta {
                logger.debug("CHUNK_DEBUG: HAS delta, content=\(delta.content ?? "nil")")
            } else {
                logger.debug("CHUNK_DEBUG: NO delta, choices=\(chunk.choices.count)")
            }

            /// Accumulate content.
            if let delta = chunk.choices.first?.delta {
                if let content = delta.content {
                    chunkCount += 1

                    /// Get current accumulated content for this message
                    let currentAccumulated = accumulatedContentByMessageId[targetMessageId] ?? ""
                    let prevLength = currentAccumulated.count

                    /// DEBUG: Check if targetMessageId is stable
                    logger.debug("ACCUMULATE_DEBUG: msgId=\(targetMessageId.uuidString.prefix(8)) prevAcc=\(prevLength) newChunk=\(content.count)")

                    /// CRITICAL FIX: Claude sends cumulative deltas (full message so far), GPT sends incremental
                    let newAccumulated: String
                    let contentToSendToUI: String

                    if isCumulativeDeltaModel {
                        /// CUMULATIVE MODE (Claude): Buffer and send only NEW content
                        /// Claude sends full message so far, we need to extract just the delta

                        /// CRITICAL FIX: Unescape JSON sequences that Claude API returns
                        /// Claude returns content with escaped slashes (\/) and quotes (\")
                        var unescapedContent = content
                        unescapedContent = unescapedContent.replacingOccurrences(of: "\\/", with: "/")
                        unescapedContent = unescapedContent.replacingOccurrences(of: "\\\"", with: "\"")

                        /// Store the full accumulated content
                        newAccumulated = unescapedContent

                        /// Calculate delta: extract ONLY the new content since last chunk
                        /// This makes Claude behave like GPT - UI only sees incremental updates
                        if newAccumulated.count > currentAccumulated.count {
                            let deltaStartIndex = currentAccumulated.count
                            contentToSendToUI = String(newAccumulated[newAccumulated.index(newAccumulated.startIndex, offsetBy: deltaStartIndex)...])
                        } else {
                            /// No new content (rare, but possible)
                            contentToSendToUI = ""
                        }

                        if chunkCount <= 3 || chunkCount % 10 == 0 {
                            let msgIdStr = String(targetMessageId.uuidString.prefix(8))
                            let deltaPreview = String(contentToSendToUI.prefix(50))
                            let hasEscapedSlash = content.contains("\\/")
                            let hasEscapedQuote = content.contains("\\\"")
                            logger.debug("STREAMING_CHUNK_BUFFER: num=\(chunkCount) mode=cumulative msgId=\(msgIdStr) fullLen=\(newAccumulated.count) prevLen=\(prevLength) deltaLen=\(contentToSendToUI.count) hasSlash=\(hasEscapedSlash) hasQuote=\(hasEscapedQuote) delta='\(deltaPreview)'")
                        }
                    } else {
                        /// INCREMENTAL MODE (GPT): Content is already a delta, just accumulate
                        newAccumulated = currentAccumulated + content
                        contentToSendToUI = content  // Send the chunk as-is

                        if chunkCount <= 3 || chunkCount % 10 == 0 {
                            let msgIdStr = String(targetMessageId.uuidString.prefix(8))
                            let previewStr = String(content.prefix(50))
                            let suffixStr = String(newAccumulated.suffix(50))
                            logger.debug("STREAMING_CHUNK_APPEND: num=\(chunkCount) mode=incremental msgId=\(msgIdStr) chunkLen=\(content.count) prevLen=\(prevLength) accLen=\(newAccumulated.count) preview=\(previewStr) suffix=\(suffixStr)")
                        }
                    }

                    /// Store updated accumulated content for this message
                    accumulatedContentByMessageId[targetMessageId] = newAccumulated

                    /// DEBUG: Always log accumulation to verify it's working
                    let msgIdStr = String(targetMessageId.uuidString.prefix(8))
                    logger.debug("ACCUMULATE: num=\(chunkCount) msgId=\(msgIdStr) chunkLen=\(content.count) accLen=\(newAccumulated.count)")

                    /// CRITICAL: Strip system-reminder tags DURING streaming (not just at end)
                    /// Apply to FULL accumulated content, then send full cleaned version to UI
                    let cleanedAccumulated = stripSystemReminders(from: newAccumulated)

                    /// CRITICAL: Update MessageBus with FULL cleaned accumulated content
                    /// MessageBus throttles updates internally (30 FPS) to prevent UI churn
                    /// We send the full content here, but for cumulative models we've already
                    /// calculated the delta above for logging purposes
                    conversation.messageBus?.updateStreamingMessage(
                        id: targetMessageId,
                        content: cleanedAccumulated
                    )
                }

                /// Accumulate tool calls using index-based tracking GitHub Copilot sends tool calls incrementally across chunks.
                if let toolCalls = delta.toolCalls {
                    logger.debug("callLLMStreaming: Received \(toolCalls.count) tool call delta(s) in chunk")
                    streamingToolCalls.update(toolCallsArray: toolCalls)
                }

                /// Capture statefulMarker for GitHub Copilot session continuity Prevents multiple premium billing charges during tool calling iterations.
                if let marker = delta.statefulMarker {
                    statefulMarker = marker
                    logger.debug("callLLMStreaming: Captured statefulMarker for session continuity: \(marker.prefix(20))...")
                }
            }

            /// Check for finish reason and content filter.
            if let choice = chunk.choices.first {
                if let reason = choice.finishReason {
                    finishReason = reason
                }
                if let filterResults = choice.contentFilterResults {
                    contentFilterResults = filterResults
                    logger.warning("WARNING: CONTENT_FILTER_DETECTED: Response was blocked by content filter")
                }
            }
        }

        /// CONTENT FILTER DETECTION: Check if response was blocked and provide clear error message
        if finishReason == "content_filter" {
            let filterType = contentFilterResults?.getTriggeredFilters() ?? "content policy"
            logger.error("️ CONTENT_FILTER_BLOCKED: Response blocked by \(filterType) filter")

            let errorMessage = """
            WARNING: **Content Filter Blocked Response**

            The AI provider's content filter blocked this response due to: **\(filterType)** policy violation.

            **Why this happens:**
            - GitHub Copilot has strict content filtering for violence, hate speech, sexual content, and self-harm
            - Legitimate news content (crime reports, political events) may trigger these filters
            - This is a provider limitation, not a SAM issue

            **Solutions:**
            1. **Switch provider**: Use OpenAI or Claude models (less restrictive filtering)
            2. **Modify request**: Ask for different topics or sections (avoid crime/violence if possible)
            3. **Try again**: Sometimes rephrasing the request helps

            **To switch provider:**
            - Settings → API Providers → Select OpenAI or Claude
            - Or use model picker to choose a non-GitHub model

            *If you need assistance with crime/violence news content, OpenAI and Claude providers work better for this use case.*
            """

            return LLMResponse(
                content: errorMessage,
                finishReason: "content_filter",
                toolCalls: nil,
                statefulMarker: statefulMarker
            )
        }

        /// Log streaming completion summary
        logger.debug("STREAMING_COMPLETE", metadata: [
            "model": .string(model),
            "isCumulative": .stringConvertible(isCumulativeDeltaModel),
            "totalChunks": .stringConvertible(chunkCount),
            "finalContentLength": .stringConvertible(accumulatedContent.count),
            "finishReason": .string(finishReason ?? "none"),
            "hadToolCalls": .stringConvertible(streamingToolCalls.hasToolCalls())
        ])

        /// Parse accumulated tool calls AFTER streaming completes.
        var parsedToolCalls: [ToolCall]?
        if streamingToolCalls.hasToolCalls() {
            let completedToolCalls = streamingToolCalls.getCompletedToolCalls()
            logger.debug("callLLMStreaming: Accumulated \(completedToolCalls.count) complete tool calls")

            parsedToolCalls = []

            for toolCall in completedToolCalls {
                let argumentsData = toolCall.function.arguments.data(using: .utf8) ?? Data()
                if let arguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] {
                    parsedToolCalls?.append(ToolCall(
                        id: toolCall.id,
                        name: toolCall.function.name,
                        arguments: arguments
                    ))
                    logger.debug("callLLMStreaming: Parsed tool call '\(toolCall.function.name)' with \(arguments.count) arguments")
                } else {
                    logger.warning("callLLMStreaming: Failed to parse arguments for tool '\(toolCall.function.name)': \(toolCall.function.arguments)")
                }
            }
        } else if finishReason == "tool_calls" {
            logger.warning("callLLMStreaming: finish_reason=tool_calls but no accumulated tool calls found")
        }

        /// MLX Tool Call Parser - Extract tool calls from JSON code blocks MLX models don't have native tool calling support, they output JSON blocks like: ```json {"name": "manage_todo_list", "arguments": {...}} ``` We need to parse these blocks and create ToolCall objects.

        /// Get final content from assistant message (not tool messages)
        /// If no assistant message was created (only tool calls), content is empty
        var finalContent = ""
        if let msgId = assistantMessageId {
            finalContent = accumulatedContentByMessageId[msgId] ?? ""
        }
        var finalToolCalls = parsedToolCalls

        /// CRITICAL: Complete streaming for all tool messages
        /// Tool messages were created during streaming, now mark them as complete
        for (executionId, toolMessageId) in toolMessagesByExecutionId {
            conversation.messageBus?.completeStreamingMessage(id: toolMessageId)
            logger.debug("TOOL_MESSAGE_COMPLETE: executionId=\(executionId.prefix(8)) messageId=\(toolMessageId.uuidString.prefix(8))")
        }

        if finalToolCalls == nil || finalToolCalls!.isEmpty {
            /// No native tool calls found - check for MLX-style JSON blocks.
            let (mlxToolCalls, cleanedContent) = extractMLXToolCalls(from: finalContent)

            if !mlxToolCalls.isEmpty {
                logger.debug("callLLMStreaming: Extracted \(mlxToolCalls.count) MLX tool calls from JSON blocks")
                finalToolCalls = mlxToolCalls
                finalContent = cleanedContent

                /// Override finish_reason to tool_calls so autonomous loop continues.
                if finishReason != "tool_calls" {
                    logger.debug("callLLMStreaming: Overriding finish_reason to 'tool_calls' for MLX model")
                    finishReason = "tool_calls"
                }
            } else {
                logger.debug("callLLMStreaming: No MLX tool calls found in JSON blocks")
            }
        } else {
            logger.debug("callLLMStreaming: Using native tool calls from provider (\(finalToolCalls!.count) calls)")
        }

        /// CRITICAL: Strip system-reminder tags before returning/saving
        /// Claude may echo back <system-reminder> content - must filter it out
        finalContent = stripSystemReminders(from: finalContent)

        logger.debug("callLLMStreaming: Streaming complete - finishReason=\(finishReason ?? "nil"), content length=\(finalContent.count), toolCalls=\(finalToolCalls?.count ?? 0), statefulMarker=\(statefulMarker != nil ? "present" : "nil")")

        /// CRITICAL: Complete streaming message in MessageBus with final content
        /// This marks the message as no longer streaming and ensures persistence
        /// Content was already updated via updateStreamingMessage() calls during chunking
        /// If no assistant message was created (only tool calls), skip completion
        if let msgId = assistantMessageId {
            /// CRITICAL: Add toolCalls metadata to message BEFORE completing
            /// This fixes Gemini (and other providers) tool call message format
            /// Without this, tool calls appear as plain text instead of proper metadata
            if let toolCalls = finalToolCalls, !toolCalls.isEmpty {
                /// Convert ToolCall to SimpleToolCall for message storage
                let simpleToolCalls = toolCalls.map { toolCall -> SimpleToolCall in
                    /// Serialize arguments dict back to JSON string for SimpleToolCall
                    let argsData = try? JSONSerialization.data(withJSONObject: toolCall.arguments)
                    let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    
                    return SimpleToolCall(
                        id: toolCall.id,
                        type: "function",
                        function: SimpleFunctionCall(
                            name: toolCall.name,
                            arguments: argsString
                        )
                    )
                }
                
                /// Update message with toolCalls metadata
                conversation.messageBus?.updateMessage(
                    id: msgId,
                    toolCalls: simpleToolCalls
                )
                
                logger.debug("MESSAGEBUS_TOOLCALLS: Added \(simpleToolCalls.count) tool calls to message id=\(msgId.uuidString.prefix(8))")
            }
            
            conversation.messageBus?.completeStreamingMessage(
                id: msgId
            )
            logger.debug("MESSAGEBUS_COMPLETE: Completed streaming for message id=\(msgId.uuidString.prefix(8)) with final content length=\(finalContent.count)")
        } else {
            logger.info("MESSAGEBUS_COMPLETE: No assistant message created (only tool calls executed)")
        }

        return LLMResponse(
            content: finalContent,
            finishReason: finishReason ?? "stop",
            toolCalls: finalToolCalls,
            statefulMarker: statefulMarker
        )
    }

    /// Parses todo list from manage_todo_list tool result Extracts structured todo items for autonomous execution.
    private func parseTodoList(from toolResult: String) -> [TodoItem] {
        logger.debug("parseTodoList: Attempting to parse todo list from tool result")

        var todos: [TodoItem] = []

        /// The tool returns a formatted string, but we need to call manage_todo_list with operation=read to get the actual structured data.

        let lines = toolResult.components(separatedBy: "\n")
        var currentId: Int?
        var currentTitle: String?
        var currentDescription: String?
        var currentStatus: String = "not-started"

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            /// Detect status sections.
            if trimmedLine.contains("NOT STARTED:") {
                currentStatus = "not-started"
                continue
            } else if trimmedLine.contains("IN PROGRESS:") {
                currentStatus = "in-progress"
                continue
            } else if trimmedLine.contains("COMPLETED:") {
                currentStatus = "completed"
                continue
            }

            /// Parse todo items (format: " 1.
            if let regex = try? NSRegularExpression(pattern: #"^\s*(\d+)\.\s+(.+)$"#, options: []),
               let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) {

                /// Save previous todo if exists.
                if let id = currentId, let title = currentTitle {
                    todos.append(TodoItem(
                        id: id,
                        title: title,
                        description: currentDescription ?? "",
                        status: currentStatus
                    ))
                }

                /// Extract new todo.
                if let idRange = Range(match.range(at: 1), in: line),
                   let titleRange = Range(match.range(at: 2), in: line) {
                    currentId = Int(line[idRange])
                    currentTitle = String(line[titleRange])
                    currentDescription = nil
                }
            }
            /// Parse description lines (format: " → Description").
            else if trimmedLine.hasPrefix("→") {
                let desc = trimmedLine.dropFirst(1).trimmingCharacters(in: .whitespaces)
                currentDescription = (currentDescription ?? "") + desc
            }
        }

        /// Save last todo.
        if let id = currentId, let title = currentTitle {
            todos.append(TodoItem(
                id: id,
                title: title,
                description: currentDescription ?? "",
                status: currentStatus
            ))
        }

        logger.debug("parseTodoList: Parsed \(todos.count) todo items")
        return todos
    }

    // MARK: - Properties

    /// Filters internal markers and debugging output from LLM responses Removes JSON status signals, legacy markers [WORKFLOW_COMPLETE]/[CONTINUE], and INTENT EXTRACTION output before saving to conversation.
    private func filterInternalMarkers(from text: String) -> String {
        var cleaned = text

        /// Filter 0: Remove JSON status signals (NEW FORMAT - highest priority) Pattern: {"status": "continue"} or {"status": "complete"} on own line or embedded.
        if let jsonStatusRegex = try? NSRegularExpression(
            pattern: #"\{\s*"status"\s*:\s*"(continue|complete)"\s*\}"#,
            options: [.caseInsensitive]
        ) {
            let nsString = cleaned as NSString
            let range = NSRange(location: 0, length: nsString.length)
            cleaned = jsonStatusRegex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        /// Filter 1: Remove legacy bracketed completion markers (BACKWARD COMPATIBILITY).
        let bracketedMarkers = [
            "[WORKFLOW_COMPLETE]",
            "[CONTINUE]"
        ]
        for marker in bracketedMarkers {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "")
        }

        /// Also remove uppercase non-bracketed variants (defensive).
        let bareMarkers = ["WORKFLOW_COMPLETE"]
        for marker in bareMarkers {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "", options: .caseInsensitive, range: nil)
        }

        /// Filter 2: Remove INTENT EXTRACTION output (multiline JSON blocks) Pattern: "INTENT EXTRACTION:\n{...}" - remove entire section.
        if let regex = try? NSRegularExpression(
            pattern: "INTENT EXTRACTION:\\s*\\n\\{[^}]*\\}",
            options: [.dotMatchesLineSeparators]
        ) {
            let nsString = cleaned as NSString
            let range = NSRange(location: 0, length: nsString.length)
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        /// We intentionally DO NOT trim here to preserve internal spacing and newlines.
        return cleaned
    }

    /// Filters internal markers but preserves surrounding whitespace/newlines.
    private func filterInternalMarkersNoTrim(from text: String) -> String {
        /// Prepare JSON-only-line regex (matches a line that is just the JSON status).
        let jsonLinePattern = try? NSRegularExpression(
            pattern: "^\\s*\\{\\s*\"status\"\\s*:\\s*\"(continue|complete)\"\\s*\\}\\s*$",
            options: [.caseInsensitive]
        )

        var outputLines: [String] = []
        var skipIntentBlock = false

        /// Iterate lines preserving empty lines and other whitespace.
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            /// If currently skipping an INTENT EXTRACTION block, look for closing brace.
            if skipIntentBlock {
                if line.contains("}") {
                    skipIntentBlock = false
                }
                continue
            }

            /// Detect start of INTENT EXTRACTION block and skip until closing brace.
            if line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("INTENT EXTRACTION:") {
                skipIntentBlock = true
                continue
            }

            /// Match JSON-only lines like {"status": "continue"}.
            if let regex = jsonLinePattern {
                let nsLine = line as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    /// Skip this exact JSON marker line but preserve surrounding newlines.
                    continue
                }
            }

            /// Legacy bracketed markers on their own lines.
            let trimmedUpper = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if trimmedUpper == "[WORKFLOW_COMPLETE]" || trimmedUpper == "[CONTINUE]" || trimmedUpper == "WORKFLOW_COMPLETE" {
                continue
            }

            /// Keep the line as-is.
            outputLines.append(line)
        }

        /// Reconstruct preserving newline separators.
        return outputLines.joined(separator: "\n")
    }

    /// Executes tool calls and returns results Execute tool calls with streaming progress (for streaming workflow) CRITICAL: Respects tool metadata for blocking/serial execution.
    private func executeToolCallsStreaming(
        _ toolCalls: [ToolCall],
        iteration: Int,
        continuation: AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error>.Continuation,
        requestId: String,
        created: Int,
        model: String,
        conversationId: UUID?
    ) async throws -> [ToolExecution] {
        logger.error("TOOL_EXEC_INPUT: count=\(toolCalls.count) ids=\(toolCalls.map { $0.id }.joined(separator: ",")) names=\(toolCalls.map { $0.name }.joined(separator: ","))")
        logger.info("executeToolCalls: Executing \(toolCalls.count) tools with metadata-driven execution control")

        /// Separate tools by execution requirements - Blocking tools: MUST complete before workflow continues (user_collaboration, foreground terminal) - Serial tools: Execute one-at-a-time but don't block workflow - Parallel tools: Can execute concurrently.

        var blockingToolCalls: [ToolCall] = []
        var serialToolCalls: [ToolCall] = []
        var parallelToolCalls: [ToolCall] = []

        /// Classify each tool based on metadata.
        for toolCall in toolCalls {
            if let tool = conversationManager.mcpManager.getToolByName(toolCall.name) {
                /// Check tool metadata.
                let requiresBlocking = tool.requiresBlocking
                let requiresSerial = tool.requiresSerial

                /// Special case: terminal_operations.run_command (foreground).
                let isTerminalForeground = isTerminalForegroundCommand(toolCall)

                if requiresBlocking || isTerminalForeground {
                    blockingToolCalls.append(toolCall)
                    logger.info("TOOL_CLASSIFICATION: \(toolCall.name) → BLOCKING (requiresBlocking=\(requiresBlocking), terminalForeground=\(isTerminalForeground))")
                } else if requiresSerial {
                    serialToolCalls.append(toolCall)
                    logger.info("TOOL_CLASSIFICATION: \(toolCall.name) → SERIAL")
                } else {
                    parallelToolCalls.append(toolCall)
                    logger.debug("TOOL_CLASSIFICATION: \(toolCall.name) → PARALLEL")
                }
            } else {
                /// Tool not found - treat as parallel (will fail safely).
                parallelToolCalls.append(toolCall)
                logger.warning("TOOL_CLASSIFICATION: \(toolCall.name) → PARALLEL (tool not found in registry)")
            }
        }

        var allExecutions: [ToolExecution] = []

        logger.error("TOOL_CLASSIFICATION_RESULT: blocking=\(blockingToolCalls.count) serial=\(serialToolCalls.count) parallel=\(parallelToolCalls.count)")

        /// Execute BLOCKING tools FIRST (serially, await each) These tools MUST complete before anything else runs Example: user_collaboration (wait for user), foreground ssh command.
        if !blockingToolCalls.isEmpty {
            logger.info("BLOCKING_PHASE_START: Executing \(blockingToolCalls.count) blocking tools serially")

            for (index, toolCall) in blockingToolCalls.enumerated() {
                logger.info("BLOCKING_TOOL_EXECUTE: [\(index + 1)/\(blockingToolCalls.count)] \(toolCall.name) - workflow BLOCKED until complete")

                let execution = try await executeSingleToolWithStreaming(
                    toolCall,
                    iteration: iteration,
                    continuation: continuation,
                    requestId: requestId,
                    created: created,
                    model: model,
                    conversationId: conversationId
                )

                allExecutions.append(execution)
                logger.info("BLOCKING_TOOL_COMPLETE: \(toolCall.name) - workflow can now continue")
            }

            logger.info("BLOCKING_PHASE_COMPLETE: All blocking tools finished, workflow continues")
        }

        /// Execute SERIAL tools (one-at-a-time, but workflow continues).
        if !serialToolCalls.isEmpty {
            logger.info("SERIAL_PHASE_START: Executing \(serialToolCalls.count) serial tools")

            for toolCall in serialToolCalls {
                let execution = try await executeSingleToolWithStreaming(
                    toolCall,
                    iteration: iteration,
                    continuation: continuation,
                    requestId: requestId,
                    created: created,
                    model: model,
                    conversationId: conversationId
                )
                allExecutions.append(execution)
            }

            logger.info("SERIAL_PHASE_COMPLETE: All serial tools finished")
        }

        /// Execute PARALLEL tools (concurrently for performance).
        if !parallelToolCalls.isEmpty {
            logger.debug("PARALLEL_PHASE_START: Executing \(parallelToolCalls.count) parallel tools concurrently")

            let parallelExecutions = try await executeParallelToolsWithStreaming(
                parallelToolCalls,
                iteration: iteration,
                continuation: continuation,
                requestId: requestId,
                created: created,
                model: model,
                conversationId: conversationId
            )

            allExecutions.append(contentsOf: parallelExecutions)
            logger.debug("PARALLEL_PHASE_COMPLETE: All parallel tools finished")
        }

        logger.info("TOOL_EXECUTION_COMPLETE: All \(toolCalls.count) tools finished (blocking:\(blockingToolCalls.count), serial:\(serialToolCalls.count), parallel:\(parallelToolCalls.count))")
        return allExecutions
    }

    /// Check if a terminal_operations tool call is a foreground command (blocks execution) Check if a terminal_operations tool call is a foreground command (blocks execution) Foreground terminal commands (run_command with isBackground=false): - Execute SERIALLY (one at a time, no parallelization) - BLOCK workflow until command completes - Examples: ssh sessions, interactive commands, vim editing Background terminal commands (isBackground=true) run in parallel and don't block.
    private func isTerminalForegroundCommand(_ toolCall: ToolCall) -> Bool {
        guard toolCall.name == "terminal_operations" else { return false }

        guard let operation = toolCall.arguments["operation"] as? String else { return false }

        /// run_command with isBackground=false (or not set) is foreground → blocks AND serial.
        if operation == "run_command" {
            let isBackground = toolCall.arguments["isBackground"] as? Bool ?? false
            let isForeground = !isBackground

            if isForeground {
                logger.info("TERMINAL_FOREGROUND_DETECTED: run_command with isBackground=\(isBackground) will execute SERIALLY and BLOCK workflow")
            }

            return isForeground
        }

        return false
    }

    /// Execute a single tool with streaming progress (used for blocking/serial execution).
    private func executeSingleToolWithStreaming(
        _ toolCall: ToolCall,
        iteration: Int,
        continuation: AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error>.Continuation,
        requestId: String,
        created: Int,
        model: String,
        conversationId: UUID?
    ) async throws -> ToolExecution {
        let toolPerfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("AgentOrchestrator.executeSingleToolWithStreaming",
                                            duration: CFAbsoluteTimeGetCurrent() - toolPerfStart)
        }

        logger.error("SINGLE_TOOL_START: name=\(toolCall.name) id=\(toolCall.id)")
        let startTime = Date()

        /// CRITICAL: Create tool message in MessageBus BEFORE yielding chunks
        /// This ensures ChatWidget can track the message via messageId in chunks
        /// Prevents duplicate message creation and enables instant tool card rendering
        let toolMessageId = UUID()
        if let conversationId = conversationId,
           let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {

            guard conversation.messageBus != nil else {
                logger.error("TOOL_EXEC_ERROR: MessageBus is nil for conversation id=\(conversation.id.uuidString.prefix(8))")
                throw NSError(domain: "AgentOrchestrator", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "MessageBus not initialized"])
            }

            let registry = ToolDisplayInfoRegistry.shared
            let toolDetails = registry.getToolDetails(for: toolCall.name, arguments: toolCall.arguments)

            conversation.messageBus?.addToolMessage(
                id: toolMessageId,
                name: toolCall.name,
                status: .running,
                details: "",  /// Will be updated after execution completes
                detailsArray: toolDetails,
                icon: getToolIcon(toolCall.name),
                toolCallId: toolCall.id
            )

            logger.debug("MESSAGEBUS_CREATE_TOOL: Created tool message id=\(toolMessageId.uuidString.prefix(8)) for tool=\(toolCall.name) executionId=\(toolCall.id.prefix(8))")
        } else {
            logger.warning("TOOL_EXEC_WARNING: Conversation not found for id=\(conversationId?.uuidString.prefix(8) ?? "nil"), tool message not created in MessageBus")
        }

        /// Show tool starting.
        let toolDetail = extractToolActionDetail(toolCall)
        let actionDescription = toolDetail.isEmpty ? getUserFriendlyActionDescription(toolCall.name, toolDetail) : toolDetail

        if !actionDescription.isEmpty {
            let progressMessage = "SUCCESS: \(actionDescription)..."

            let registry = ToolDisplayInfoRegistry.shared
            let toolDetails = registry.getToolDetails(for: toolCall.name, arguments: toolCall.arguments)
            let toolIcon: String? = getToolIcon(toolCall.name)

            let progressChunk = ServerOpenAIChatStreamChunk(
                id: requestId,
                object: "chat.completion.chunk",
                created: created,
                model: model,
                choices: [OpenAIChatStreamChoice(
                    index: 0,
                    delta: OpenAIChatDelta(content: progressMessage + "\n"),
                    finishReason: nil
                )],
                isToolMessage: true,
                toolName: toolCall.name,
                toolIcon: toolIcon,
                toolStatus: "running",
                toolDetails: toolDetails,
                toolExecutionId: toolCall.id,
                messageId: toolMessageId  /// Pass messageId to chunk for ChatWidget correlation
            )

            logger.debug("TOOL_CHUNK_YIELD: toolName=\(toolCall.name), status=running")
            logger.debug("TOOL_PROGRESS_MESSAGE_YIELDED: tool=\(toolCall.name) content=\(progressMessage.prefix(50)) isToolMessage=true")

            if toolCall.name.lowercased() != "think" {
                continuation.yield(progressChunk)
            }
        }

        /// EXECUTE SYNCHRONOUSLY - THIS BLOCKS UNTIL COMPLETE.
        logger.debug("TOOL_EXECUTION_START: \(toolCall.name) - awaiting completion")

        if let result = await self.conversationManager.executeMCPTool(
            name: toolCall.name,
            parameters: toolCall.arguments,
            toolCallId: toolCall.id,
            conversationId: conversationId,
            isExternalAPICall: self.isExternalAPICall,
            terminalManager: self.terminalManager,
                        iterationController: self
        ) {
            let duration = Date().timeIntervalSince(startTime)
            logger.info("TOOL_EXECUTION_COMPLETE: \(toolCall.name) after \(String(format: "%.2f", duration))s")

            /// Update tool status in MessageBus after execution completes
            if let conversationId = conversationId,
               let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                conversation.messageBus?.updateToolStatus(
                    id: toolMessageId,
                    status: result.success ? .success : .error,
                    duration: duration,
                    details: result.output.content
                )
                logger.debug("MESSAGEBUS_UPDATE_TOOL: Updated tool message id=\(toolMessageId.uuidString.prefix(8)) status=\(result.success ? "success" : "error")")
            }

            /// Emit completion chunk with result metadata for UI display
            let completionChunk = ServerOpenAIChatStreamChunk(
                id: requestId,
                object: "chat.completion.chunk",
                created: created,
                model: model,
                choices: [OpenAIChatStreamChoice(
                    index: 0,
                    delta: OpenAIChatDelta(content: ""),
                    finishReason: nil
                )],
                isToolMessage: true,
                toolName: toolCall.name,
                toolIcon: self.getToolIcon(toolCall.name),
                toolStatus: result.success ? "success" : "error",
                toolDetails: nil,
                parentToolName: nil,
                toolExecutionId: toolCall.id,
                toolMetadata: result.metadata.additionalContext,
                messageId: toolMessageId  /// Include messageId for completion chunk
            )
            continuation.yield(completionChunk)

            /// Process progress events.
            for event in result.progressEvents {
                if event.eventType == .toolStarted, let message = event.message {
                    let progressChunk = ServerOpenAIChatStreamChunk(
                        id: requestId,
                        object: "chat.completion.chunk",
                        created: created,
                        model: model,
                        choices: [OpenAIChatStreamChoice(
                            index: 0,
                            delta: OpenAIChatDelta(content: message + "\n"),
                            finishReason: nil
                        )],
                        isToolMessage: true,
                        toolName: event.toolName,
                        toolIcon: self.getToolIcon(event.toolName),
                        toolStatus: event.status ?? "running",
                        toolDisplayData: event.display as? ToolDisplayData,
                        toolDetails: event.details,
                        parentToolName: event.parentToolName,
                        toolExecutionId: toolCall.id,
                        messageId: toolMessageId  /// Include messageId for sub-tool chunks
                    )
                    continuation.yield(progressChunk)
                }

                /// Stream .userMessage progressEvents (MODERN: ToolDisplayData only)
                if event.eventType == .userMessage {
                    guard let displayData = event.display as? ToolDisplayData,
                          let summary = displayData.summary, !summary.isEmpty else {
                        logger.warning("PROGRESS_EVENT_SKIP: userMessage missing ToolDisplayData.summary")
                        continue
                    }

                    let messageContent = "Thinking: \(summary)"
                    logger.info("PROGRESS_EVENT_STREAM: eventType=userMessage toolName=\(event.toolName) content.prefix=\(messageContent.prefix(50))")

                    /// CRITICAL: Create message in MessageBus BEFORE yielding chunk
                    /// This ensures MessageBus is the single source of truth for message creation
                    let messageId = UUID()
                    if let conversationId = conversationId,
                       let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                        conversation.messageBus?.addThinkingMessage(
                            id: messageId,
                            reasoningContent: summary,
                            showReasoning: true
                        )
                        logger.debug("MESSAGEBUS_CREATE: Created thinking message id=\(messageId.uuidString.prefix(8)) in MessageBus")
                    } else {
                        logger.warning("MESSAGEBUS_CREATE: Could not find conversation for id=\(conversationId?.uuidString.prefix(8) ?? "nil")")
                    }

                    let userMessageChunk = ServerOpenAIChatStreamChunk(
                        id: requestId,
                        object: "chat.completion.chunk",
                        created: created,
                        model: model,
                        choices: [OpenAIChatStreamChoice(
                            index: 0,
                            delta: OpenAIChatDelta(
                                role: "assistant",
                                content: messageContent + "\n"
                            ),
                            finishReason: nil
                        )],
                        isToolMessage: true,
                        toolName: event.toolName,
                        toolIcon: displayData.icon ?? self.getToolIcon(event.toolName),
                        toolStatus: event.status ?? "success",
                        toolDisplayData: displayData,
                        toolDetails: event.details,
                        parentToolName: event.parentToolName,
                        toolExecutionId: toolCall.id,
                        messageId: messageId  /// Pass messageId to chunk for UI correlation
                    )
                    logger.debug("PROGRESS_EVENT_CHUNK: chunk.toolName=\(userMessageChunk.toolName ?? "nil") chunk.isToolMessage=\(userMessageChunk.isToolMessage ?? false) messageId=\(messageId.uuidString.prefix(8))")
                    continuation.yield(userMessageChunk)
                    await Task.yield()
                }
            }

            return ToolExecution(
                toolCallId: toolCall.id,
                toolName: toolCall.name,
                arguments: toolCall.arguments,
                result: result.output.content,
                success: result.success,
                timestamp: startTime,
                iteration: iteration
            )
        } else {
            logger.error("TOOL_EXECUTION_FAILED: Tool '\(toolCall.name)' returned nil")

            return ToolExecution(
                toolCallId: toolCall.id,
                toolName: toolCall.name,
                arguments: toolCall.arguments,
                result: "Error: Tool execution failed",
                success: false,
                timestamp: startTime,
                iteration: iteration
            )
        }
    }

    /// Execute multiple tools in parallel (existing parallel execution logic).
    private func executeParallelToolsWithStreaming(
        _ toolCalls: [ToolCall],
        iteration: Int,
        continuation: AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error>.Continuation,
        requestId: String,
        created: Int,
        model: String,
        conversationId: UUID?
    ) async throws -> [ToolExecution] {
        logger.error("PARALLEL_TOOLS_START: count=\(toolCalls.count) ids=\(toolCalls.map { $0.id }.joined(separator: ","))")

        /// CRITICAL: Create tool messages in MessageBus for parallel execution BEFORE yielding chunks
        /// This ensures ChatWidget can track each tool via messageId
        /// Use executionId → toolMessageId mapping for tracking multiple tools
        var toolMessagesByExecutionId: [String: UUID] = [:]

        if let conversationId = conversationId,
           let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {

            for toolCall in toolCalls {
                let toolMessageId = UUID()

                let registry = ToolDisplayInfoRegistry.shared
                let toolDetails = registry.getToolDetails(for: toolCall.name, arguments: toolCall.arguments)

                conversation.messageBus?.addToolMessage(
                    id: toolMessageId,
                    name: toolCall.name,
                    status: .running,
                    details: "",  /// Will be updated after execution
                    detailsArray: toolDetails,
                    icon: getToolIcon(toolCall.name),
                    toolCallId: toolCall.id
                )

                toolMessagesByExecutionId[toolCall.id] = toolMessageId
                logger.debug("MESSAGEBUS_CREATE_TOOL: Created tool message id=\(toolMessageId.uuidString.prefix(8)) for parallel tool=\(toolCall.name) executionId=\(toolCall.id.prefix(8))")
            }
        } else {
            logger.warning("PARALLEL_TOOLS_WARNING: Conversation not found for id=\(conversationId?.uuidString.prefix(8) ?? "nil"), tool messages not created in MessageBus")
        }

        /// Show all tools starting.
        for toolCall in toolCalls {
            let toolDetail = extractToolActionDetail(toolCall)
            let actionDescription = toolDetail.isEmpty ? getUserFriendlyActionDescription(toolCall.name, toolDetail) : toolDetail

            if !actionDescription.isEmpty {
                let progressMessage = "SUCCESS: \(actionDescription)..."

                let registry = ToolDisplayInfoRegistry.shared
                let toolDetails = registry.getToolDetails(for: toolCall.name, arguments: toolCall.arguments)
                let toolIcon: String? = getToolIcon(toolCall.name)

                /// Get messageId for this tool execution
                let toolMessageId = toolMessagesByExecutionId[toolCall.id]

                let progressChunk = ServerOpenAIChatStreamChunk(
                    id: requestId,
                    object: "chat.completion.chunk",
                    created: created,
                    model: model,
                    choices: [OpenAIChatStreamChoice(
                        index: 0,
                        delta: OpenAIChatDelta(content: progressMessage + "\n"),
                        finishReason: nil
                    )],
                    isToolMessage: true,
                    toolName: toolCall.name,
                    toolIcon: toolIcon,
                    toolStatus: "running",
                    toolDetails: toolDetails,
                    toolExecutionId: toolCall.id,
                    messageId: toolMessageId  /// Include messageId for parallel tool tracking
                )

                let ts = Date().timeIntervalSince1970
                let microseconds = Int(ts * 1_000_000)
                logger.error("TS:\(microseconds) CHUNK_YIELD: toolName=\(toolCall.name), actionDesc=\(actionDescription), isToolMessage=true, toolId=\(toolCall.id)")

                if toolCall.name.lowercased() != "think" {
                    continuation.yield(progressChunk)

                    /// Signal that a tool card is pending for this execution
                    await MainActor.run {
                        self.toolCardsPending.insert(toolCall.id)
                        let tsPending = Date().timeIntervalSince1970
                        let microPending = Int(tsPending * 1_000_000)
                        self.logger.error("TS:\(microPending) PENDING: Added execution ID: \(toolCall.id)")
                    }
                }
            }
        }

        /// Give the async stream time to deliver chunks to UI before waiting
        /// Brief sleep ensures chunks reach the for-await loop in ChatWidget
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        /// CRITICAL: Force MainActor to process pending UI updates BEFORE waiting
        /// This ensures SwiftUI has a chance to render tool cards
        /// Without this, SwiftUI won't render until we're done with the task
        await MainActor.run { }  // Empty closure forces context switch
        await Task.yield()  // Yield to allow SwiftUI rendering
        await MainActor.run { }  // Second yield for safety
        await Task.yield()

        /// Wait for UI to acknowledge all tool cards are ready
        /// This ensures cards appear before execution starts
        /// Timeout after 3s to prevent deadlock (UI async stream can take 3s to process chunks)
        let allToolIds = Set(toolCalls.filter { $0.name.lowercased() != "think" }.map { $0.id })
        if !allToolIds.isEmpty {
            logger.debug("TOOL_CARD_WAIT: Waiting for \(allToolIds.count) tool cards to be acknowledged")
            let startTime = Date()
            let timeout: TimeInterval = 3.0 // 3 seconds

            while await MainActor.run(body: { !allToolIds.isSubset(of: self.toolCardsReady) }) {
                /// Check timeout
                if Date().timeIntervalSince(startTime) > timeout {
                    let acknowledged = await MainActor.run { self.toolCardsReady }
                    logger.warning("TOOL_CARD_TIMEOUT: UI didn't acknowledge cards within 3s (acknowledged: \(acknowledged.count)/\(allToolIds.count)), proceeding anyway")
                    break
                }

                /// CRITICAL: Yield to MainActor frequently to allow SwiftUI rendering
                /// This gives SwiftUI opportunities to process the render queue
                await MainActor.run { }  /// Force context switch to MainActor
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                await Task.yield()  /// Yield to allow rendering
            }

        /// Clear pending/ready sets for next batch
        await MainActor.run {
            self.toolCardsPending.removeAll()
            self.toolCardsReady.removeAll()
        }

        let tsReady = Date().timeIntervalSince1970
        let microReady = Int(tsReady * 1_000_000)
        logger.error("TS:\(microReady) READY: UI acknowledged \(allToolIds.count) tool cards, proceeding with execution")

        /// CRITICAL: Give SwiftUI time to actually RENDER the cards after messages array is updated
        /// ACK happens when message is added to array, but rendering is async
        /// 200ms ensures cards are visible before execution starts
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        logger.debug("TOOL_CARDS_RENDERED: Waited 200ms for SwiftUI rendering, starting execution now")
    }

        /// Capture conversationId and toolMessagesByExecutionId for use in task group
        let conversationIdForTools = conversationId
        let toolMessagesForTasks = toolMessagesByExecutionId  /// Capture as constant for Sendable safety
        nonisolated(unsafe) let capturedTerminalManager = self.terminalManager  /// Capture nonisolated(unsafe) property before async

        /// Now execute all tools in parallel using withTaskGroup (ORIGINAL LOGIC).
        return await withTaskGroup(of: (Int, ToolExecution).self) { group in
            var executions: [ToolExecution] = []

            for (index, toolCall) in toolCalls.enumerated() {
                let toolCallId = toolCall.id  /// Capture id before async task to avoid actor isolation issues
                let toolCallName = toolCall.name  /// Capture name as well
                let toolCallArguments = SendableArguments(value: toolCall.arguments)  /// Wrap in Sendable container
                let toolCallsCount = toolCalls.count  /// Capture count for logging

                group.addTask { @Sendable in
                    let tsExecute = Date().timeIntervalSince1970
                    let microExecute = Int(tsExecute * 1_000_000)
                    await MainActor.run {
                        self.logger.error("TS:\(microExecute) EXECUTE: index=\(index) name=\(toolCallName) id=\(toolCallId)")
                    }
                    let startTime = Date()
                    await MainActor.run {
                        self.logger.debug("executeToolCalls: Executing tool \(index + 1)/\(toolCallsCount) '\(toolCallName)' (id: \(toolCallId))")
                    }

                    /// Execute via ConversationManager.executeMCPTool() CRITICAL: Pass toolCall.id so tools can use LLM's tool call ID instead of generating their own CRITICAL: Pass terminalManager so terminal_operations uses visible UI terminal.
                    /// CRITICAL (Task 19): Pass conversationId from session to prevent data leakage
                    if let result = await self.conversationManager.executeMCPTool(
                        name: toolCallName,
                        parameters: toolCallArguments.value,
                        toolCallId: toolCallId,
                        conversationId: conversationIdForTools,
                        isExternalAPICall: self.isExternalAPICall,
                        terminalManager: capturedTerminalManager,
                        iterationController: self
                    ) {
                        let duration = Date().timeIntervalSince(startTime)

                        /// Update tool status in MessageBus after execution completes
                        if let conversationId = conversationIdForTools,
                           let toolMessageId = toolMessagesForTasks[toolCallId] {
                            let conversation = await MainActor.run {
                                self.conversationManager.conversations.first(where: { $0.id == conversationId })
                            }
                            if let conversation = conversation {
                                await MainActor.run {
                                    conversation.messageBus?.updateToolStatus(
                                        id: toolMessageId,
                                        status: result.success ? .success : .error,
                                        duration: duration,
                                        details: result.output.content
                                    )
                                    self.logger.debug("MESSAGEBUS_UPDATE_TOOL: Updated parallel tool message id=\(toolMessageId.uuidString.prefix(8)) status=\(result.success ? "success" : "error")")
                                }
                            }
                        }

                        /// Log progress events count.
                        await MainActor.run {
                            self.logger.debug("TOOL_RESULT_DEBUG: tool=\(toolCallName), progressEvents=\(result.progressEvents.count), success=\(result.success)")
                        }

                        /// Process progress events from tool execution Yield chunks for each sub-tool execution with parent context.
                        for event in result.progressEvents {
                            await MainActor.run {
                                self.logger.debug("PROGRESS_EVENT: \(event.eventType) - tool: \(event.toolName), parent: \(event.parentToolName ?? "none")")
                            }

                            /// Yield progress chunk for sub-tool execution.
                            if event.eventType == .toolStarted, let message = event.message {
                                let toolMessageId = toolMessagesForTasks[toolCallId]
                                let progressChunk = ServerOpenAIChatStreamChunk(
                                    id: requestId,
                                    object: "chat.completion.chunk",
                                    created: created,
                                    model: model,
                                    choices: [OpenAIChatStreamChoice(
                                        index: 0,
                                        delta: OpenAIChatDelta(content: message + "\n"),
                                        finishReason: nil
                                    )],
                                    isToolMessage: true,
                                    toolName: event.toolName,
                                    toolIcon: self.getToolIcon(event.toolName),
                                    toolStatus: event.status ?? "running",
                                    toolDetails: event.details,
                                    parentToolName: event.parentToolName,
                                    toolExecutionId: toolCallId,
                                    messageId: toolMessageId  /// Include messageId for sub-tool tracking
                                )
                                continuation.yield(progressChunk)
                            }

                            /// Handle user-facing messages (MODERN: ToolDisplayData only)
                            if event.eventType == .userMessage {
                                guard let displayData = event.display as? ToolDisplayData,
                                      let summary = displayData.summary, !summary.isEmpty else {
                                    await MainActor.run {
                                        self.logger.warning("PROGRESS_EVENT_SKIP_PARALLEL: userMessage missing ToolDisplayData.summary")
                                    }
                                    continue
                                }

                                let messageContent = "Thinking: \(summary)"

                                await MainActor.run {
                                    self.logger.info("USER_MESSAGE_CHUNK_EMIT: tool=\(event.toolName), contentLength=\(messageContent.count), first50=\"\(String(messageContent.prefix(50)))\"")
                                }

                                let userMessageChunk = ServerOpenAIChatStreamChunk(
                                    id: requestId,
                                    object: "chat.completion.chunk",
                                    created: created,
                                    model: model,
                                    choices: [OpenAIChatStreamChoice(
                                        index: 0,
                                        delta: OpenAIChatDelta(
                                            role: "assistant",
                                            content: messageContent + "\n"
                                        ),
                                        finishReason: nil
                                    )],
                                    isToolMessage: true,
                                    toolName: event.toolName,
                                    toolIcon: displayData.icon ?? self.getToolIcon(event.toolName),
                                    toolStatus: event.status ?? "success",
                                    toolDisplayData: displayData,
                                    toolDetails: event.details,
                                    parentToolName: event.parentToolName,
                                    toolExecutionId: toolCallId
                                )
                                continuation.yield(userMessageChunk)

                                await MainActor.run {
                                    self.logger.info("USER_MESSAGE_CHUNK_YIELDED: Successfully emitted userMessage chunk to client")
                                }

                                /// Force immediate flush for first message visibility Without this, userMessage chunks can be buffered until next yield.
                                await Task.yield()
                            }
                        }

                        /// Log what the tool result content is.
                        await MainActor.run {
                            self.logger.debug("DEBUG_TOOL_RESULT: Tool '\(toolCallName)' result type: \(type(of: result.output.content)), isEmpty: \(result.output.content.isEmpty), count: \(result.output.content.count)")
                            self.logger.debug("DEBUG_TOOL_RESULT: Tool '\(toolCallName)' result value: '\(result.output.content)'")
                            self.logger.debug("executeToolCalls: Tool '\(toolCallName)' succeeded in \(String(format: "%.2f", duration))s, emitted \(result.progressEvents.count) progress events")
                        }

                        let execution = ToolExecution(
                            toolCallId: toolCallId,
                            toolName: toolCallName,
                            arguments: toolCallArguments.value,
                            result: result.output.content,
                            success: result.success,
                            timestamp: startTime,
                            iteration: iteration
                        )

                        return (index, execution)
                    } else {
                        /// Tool not found or execution failed.
                        await MainActor.run {
                            self.logger.error("executeToolCalls: Tool '\(toolCallName)' returned nil (not found or failed)")
                        }

                        /// Create execution with error result.
                        let execution = ToolExecution(
                            toolCallId: toolCallId,
                            toolName: toolCallName,
                            arguments: toolCallArguments.value,
                            result: "ERROR: Tool '\(toolCallName)' not found or execution failed",
                            success: false,
                            timestamp: Date(),
                            iteration: iteration
                        )
                        return (index, execution)
                    }
                }
            }

            /// Collect results in original order.
            var indexedExecutions: [(Int, ToolExecution)] = []
            for await result in group {
                indexedExecutions.append(result)
            }

            /// Sort by original index to preserve tool call order.
            indexedExecutions.sort { $0.0 < $1.0 }
            executions = indexedExecutions.map { $0.1 }

            logger.debug("executeToolCalls: Completed \(executions.count)/\(toolCalls.count) tool executions in PARALLEL")

            /// Tool results are NOT sent as visible chunks They go into conversation history for the LLM but don't create UI messages The tool progress messages ("SUCCESS: Researching...") already show in tool cards Sending raw JSON results would clutter the UI with machine-readable data.

            return executions
        }
    }

    /// Execute tool calls without streaming (for non-streaming workflow).
    private func executeToolCalls(
        _ toolCalls: [ToolCall],
        iteration: Int,
        conversationId: UUID?
    ) async throws -> [ToolExecution] {
        logger.debug("executeToolCalls: Executing \(toolCalls.count) tools in PARALLEL")

        /// Capture conversationId for use in task group
        let conversationIdForTools = conversationId
        nonisolated(unsafe) let capturedTerminalManager = self.terminalManager  /// Capture nonisolated(unsafe) property before async

        /// PERFORMANCE FIX: Execute tools in PARALLEL instead of sequentially Sequential execution was causing 5x+ slowdown when multiple tools were called With parallel execution, all tools run simultaneously.
        return await withTaskGroup(of: (Int, ToolExecution).self) { group in
            var executions: [ToolExecution] = []

            for (index, toolCall) in toolCalls.enumerated() {
                let toolCallId = toolCall.id  /// Capture before async task
                let toolCallName = toolCall.name
                let toolCallArguments = SendableArguments(value: toolCall.arguments)  /// Wrap in Sendable container

                group.addTask { @Sendable in
                    let startTime = Date()

                    /// TOOL_EXECUTION_START - Track individual tool execution start.
                    await MainActor.run {
                        self.logger.debug("TOOL_EXECUTION_START", metadata: [
                            "iteration": .stringConvertible(iteration),
                            "toolName": .string(toolCallName),
                            "toolCallId": .string(toolCallId)
                        ])

                        self.logger.debug("executeToolCalls: Executing tool '\\(toolCallName)' (id: \\(toolCallId))")
                    }

                    /// Execute via ConversationManager.executeMCPTool() CRITICAL: Pass toolCall.id so tools can use LLM's tool call ID instead of generating their own CRITICAL: Pass terminalManager so terminal_operations uses visible UI terminal.
                    /// CRITICAL (Task 19): Pass session.conversationId to prevent data leakage
                    if let result = await self.conversationManager.executeMCPTool(
                        name: toolCallName,
                        parameters: toolCallArguments.value,
                        toolCallId: toolCallId,
                        conversationId: conversationIdForTools,
                        isExternalAPICall: self.isExternalAPICall,
                        terminalManager: capturedTerminalManager,
                        iterationController: self
                    ) {
                        let duration = Date().timeIntervalSince(startTime)
                        let execution = ToolExecution(
                            toolCallId: toolCallId,
                            toolName: toolCallName,
                            arguments: toolCallArguments.value,
                            result: result.output.content,
                            timestamp: startTime,
                            iteration: iteration
                        )

                        /// TOOL_EXECUTION_COMPLETE - Track individual tool execution completion.
                        await MainActor.run {
                            self.logger.debug("TOOL_EXECUTION_COMPLETE", metadata: [
                                "iteration": .stringConvertible(iteration),
                                "toolName": .string(toolCallName),
                                "success": .stringConvertible(true),
                                "executionTime": .string(String(format: "%.2fms", duration * 1000)),
                                "resultLength": .stringConvertible(result.output.content.count)
                            ])

                            self.logger.debug("executeToolCalls: Tool '\(toolCallName)' succeeded in \(String(format: "%.2f", duration))s")

                            /// Update StateManager: Remove tool from active tools
                            if let conversationId = conversationIdForTools {
                                self.conversationManager.stateManager.updateState(conversationId: conversationId) { state in
                                    state.activeTools.remove(toolCallName)
                                    /// If no more active tools, set status to idle
                                    if state.activeTools.isEmpty {
                                        state.status = .idle
                                    } else if case .processing = state.status {
                                        /// Update to next active tool
                                        state.status = .processing(toolName: state.activeTools.first)
                                    }
                                }
                                self.logger.debug("StateManager: Removed \(toolCallName) from activeTools for conversation \(conversationId.uuidString.prefix(8))")
                            }
                        }

                        return (index, execution)
                    } else {
                        /// Tool not found or execution failed.
                        let duration = Date().timeIntervalSince(startTime)

                        /// TOOL_EXECUTION_COMPLETE - Track tool execution failure.
                        await MainActor.run {
                            self.logger.error("TOOL_EXECUTION_COMPLETE", metadata: [
                                "iteration": .stringConvertible(iteration),
                                "toolName": .string(toolCallName),
                                "success": .stringConvertible(false),
                                "executionTime": .string(String(format: "%.2fms", duration * 1000)),
                                "error": .string("Tool not found or execution failed")
                            ])

                            self.logger.error("executeToolCalls: Tool '\(toolCallName)' returned nil (not found or failed)")

                            /// Update StateManager: Remove tool from active tools even on failure
                            if let conversationId = conversationIdForTools {
                                self.conversationManager.stateManager.updateState(conversationId: conversationId) { state in
                                    state.activeTools.remove(toolCallName)
                                    /// If no more active tools, set status to idle
                                    if state.activeTools.isEmpty {
                                        state.status = .idle
                                    } else if case .processing = state.status {
                                        /// Update to next active tool
                                        state.status = .processing(toolName: state.activeTools.first)
                                    }
                                }
                                self.logger.debug("StateManager: Removed \(toolCallName) from activeTools (failed) for conversation \(conversationId.uuidString.prefix(8))")
                            }
                        }

                        /// Create execution with error result.
                        let execution = ToolExecution(
                            toolCallId: toolCallId,
                            toolName: toolCallName,
                            arguments: toolCallArguments.value,
                            result: "ERROR: Tool '\(toolCallName)' not found or execution failed",
                            timestamp: startTime,
                            iteration: iteration
                        )
                        return (index, execution)
                    }
                }
            }

            /// Collect results in original order.
            var indexedExecutions: [(Int, ToolExecution)] = []
            for await result in group {
                indexedExecutions.append(result)
            }

            /// Sort by original index to preserve tool call order.
            indexedExecutions.sort { $0.0 < $1.0 }
            executions = indexedExecutions.map { $0.1 }

            logger.debug("executeToolCalls: Completed \(executions.count)/\(toolCalls.count) tool executions in PARALLEL")

            return executions
        }
    }

    /// Format tool execution progress message with details about what each tool is doing.
    private func formatToolExecutionProgress(_ toolCalls: [ToolCall]) -> String {
        if toolCalls.count == 1 {
            let tool = toolCalls[0]
            let detail = extractToolActionDetail(tool)
            /// If detail is empty, use user-friendly tool name.
            let actionDescription = detail.isEmpty ? getUserFriendlyActionDescription(tool.name, detail) : detail
            return "SUCCESS: \(actionDescription)"
        } else {
            /// Multiple tools - batch identical actions to avoid repetition Group by action description.
            var actionCounts: [String: Int] = [:]
            var actionOrder: [String] = []

            for tool in toolCalls {
                let detail = extractToolActionDetail(tool)
                let actionDescription = detail.isEmpty ? getUserFriendlyActionDescription(tool.name, detail) : detail

                /// Track first occurrence order.
                if actionCounts[actionDescription] == nil {
                    actionOrder.append(actionDescription)
                }
                actionCounts[actionDescription, default: 0] += 1
            }

            /// Format with counts for repeated actions.
            let formattedActions = actionOrder.map { action in
                let count = actionCounts[action]!
                return count > 1 ? "\(action) (\(count)x)" : action
            }.joined(separator: ", ")

            return "SUCCESS: \(formattedActions)"
        }
    }

    /// Convert technical tool names to user-friendly action descriptions.
    private func getUserFriendlyActionDescription(_ toolName: String, _ detail: String) -> String {
        /// If detail already contains a descriptive action, don't add tool name.
        if !detail.isEmpty {
            /// Detail already contains the action description (e.g., "creating todo list") Just return empty string so we use only the detail.
            return ""
        }

        /// Map tool names to user-friendly actions Note: Consolidated tools (memory_operations, web_operations, etc.) are handled by ToolDisplayInfoRegistry.
        switch toolName {
        case "think":
            return "Thinking"

        case "user_collaboration":
            /// Don't show generic message - specific collaboration message is emitted separately.
            return ""

        default:
            /// For unknown tools, format the name nicely.
            return toolName.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Get SF Symbol icon for tool (used by progress event processing) Generate user-friendly message for tool execution Returns nil if no user message should be shown.
    nonisolated private func generateUserMessageForTool(_ toolName: String, arguments: [String: Any]) -> String? {
        /// Extract common parameters.
        let query = arguments["query"] as? String
        let url = arguments["url"] as? String
        let filePath = arguments["filePath"] as? String
        let path = arguments["path"] as? String
        let command = arguments["command"] as? String
        let operation = arguments["operation"] as? String

        /// Generate message based on tool and operation.
        switch toolName.lowercased() {
        case "terminal_operations", "terminal", "run_in_terminal":
            if let cmd = command {
                let isBackground = arguments["isBackground"] as? Bool ?? false
                return isBackground ? "Starting background process: `\(cmd)`" : "Running command in terminal: `\(cmd)`"
            }
            return "Running terminal command"

        case "web_operations":
            guard let op = operation else { return "Performing web operation" }
            switch op {
            case "research":
                return query.map { "Researching the web for: \($0)" } ?? "Researching the web"
            case "retrieve":
                return query.map { "Retrieving stored research for: \($0)" } ?? "Retrieving research"
            case "web_search":
                return query.map { "Searching the web for: \($0)" } ?? "Searching the web"
            case "serpapi":
                let engine = arguments["engine"] as? String ?? "search engine"
                return query.map { "Searching \(engine) for: \($0)" } ?? "Performing search"
            case "scrape":
                return url.map { "Scraping content from: \($0)" } ?? "Scraping webpage"
            case "fetch":
                return url.map { "Fetching content from: \($0)" } ?? "Fetching webpage"
            default:
                return nil
            }

        case "document_operations":
            guard let op = operation else { return "Performing document operation" }
            switch op {
            case "document_import":
                if let p = path {
                    let filename = (p as NSString).lastPathComponent
                    return "Importing document: \(filename)"
                }
                return "Importing document"
            case "document_create":
                let format = arguments["format"] as? String ?? "document"
                if let filename = arguments["filename"] as? String {
                    return "Creating \(format.uppercased()) document: \(filename)"
                }
                return "Creating new \(format.uppercased()) document"
            case "get_doc_info":
                return "Getting document information"
            default:
                return nil
            }

        case "file_operations":
            guard let op = operation else { return "Performing file operation" }
            switch op {
            case "read_file":
                if let fp = filePath {
                    let filename = (fp as NSString).lastPathComponent
                    return "Reading file: \(filename)"
                }
                return "Reading file"
            case "create_file":
                if let fp = filePath {
                    let filename = (fp as NSString).lastPathComponent
                    return "Creating file: \(filename)"
                }
                return "Creating new file"
            case "replace_string", "multi_replace_string":
                if let fp = filePath {
                    let filename = (fp as NSString).lastPathComponent
                    return "Editing file: \(filename)"
                }
                return "Editing file"
            case "rename_file":
                if let oldPath = arguments["oldPath"] as? String,
                   let newPath = arguments["newPath"] as? String {
                    let oldName = (oldPath as NSString).lastPathComponent
                    let newName = (newPath as NSString).lastPathComponent
                    return "Renaming: \(oldName) → \(newName)"
                }
                return "Renaming file"
            case "delete_file":
                if let fp = filePath {
                    let filename = (fp as NSString).lastPathComponent
                    return "Deleting file: \(filename)"
                }
                return "Deleting file"
            case "list_dir":
                if let p = path {
                    let dirName = (p as NSString).lastPathComponent
                    return "Listing directory: \(dirName)"
                }
                return "Listing directory"
            case "file_search":
                return query.map { "Searching for files: \($0)" } ?? "Searching for files"
            case "grep_search":
                return query.map { "Searching code for: \($0)" } ?? "Searching code"
            case "semantic_search":
                return query.map { "Semantic search: \($0)" } ?? "Performing semantic search"
            default:
                return nil
            }

        case "memory_operations":
            guard let op = operation else { return "Performing memory operation" }
            switch op {
            case "search_memory":
                return query.map { "Searching memory for: \($0)" } ?? "Searching memory"
            case "store_memory":
                if let content = arguments["content"] as? String {
                    let preview = content.prefix(50)
                    return "Storing in memory: \(preview)..."
                }
                return "Storing in memory"
            default:
                return nil
            }

        case "build_and_version_control":
            guard let op = operation else { return "Performing build operation" }
            switch op {
            case "create_and_run_task":
                if let task = arguments["task"] as? [String: Any],
                   let label = task["label"] as? String {
                    return "Running build task: \(label)"
                }
                return "Running build task"
            case "run_task":
                if let label = arguments["label"] as? String {
                    return "Running task: \(label)"
                }
                return "Running task"
            case "git_commit":
                if let message = arguments["message"] as? String {
                    let preview = message.prefix(50)
                    return "Committing changes: \(preview)"
                }
                return "Committing changes to git"
            case "get_changed_files":
                return "Checking git status"
            case "get_task_output":
                return "Getting task output"
            default:
                return nil
            }

        case "run_subagent":
            if let task = arguments["task"] as? String {
                return "Starting subagent: \(task)"
            }
            return "Running subagent"

        default:
            /// No user message for other tools.
            return nil
        }
    }

    nonisolated private func getToolIcon(_ toolName: String) -> String {
        switch toolName.lowercased() {
        // Image & Visual
        case "image_generation":
            return "photo.on.rectangle.angled"
        case "document_create", "document_create_mcp", "document_create_tool", "create_document":
            return "doc.badge.plus"
        case "document_import", "document_import_mcp":
            return "doc.badge.arrow.up"
        case "document_operations", "document_operations_mcp", "import_document", "search_documents":
            return "doc.text"

        // Web & Research
        case "web_research", "web_research_mcp", "web_search", "researching", "research_query":
            return "globe.badge.chevron.backward"
        case "web_operations", "web_operations_mcp":
            return "network"
        case "fetch", "fetch_webpage":
            return "arrow.down.doc"
        case "scrape", "web_scraping":
            return "doc.text.magnifyingglass"

        // File Operations
        case "read_file", "file_read", "file_operations":
            return "doc.plaintext"
        case "create_file", "file_write", "write_file":
            return "doc.badge.plus"
        case "delete_file", "file_delete":
            return "trash"
        case "rename_file":
            return "pencil.and.list.clipboard"
        case "list_dir", "list", "create_directory", "create_dir":
            return "folder"
        case "get_changed_files", "build_and_version_control", "git_commit":
            return "arrow.triangle.2.circlepath"

        // Code Operations
        case "replace_string_in_file", "multi_replace_string_in_file", "edit_file":
            return "arrow.left.arrow.right"
        case "insert_edit":
            return "text.insert"
        case "apply_patch":
            return "bandage"
        case "grep_search", "file_search":
            return "magnifyingglass.circle"
        case "semantic_search":
            return "brain"
        case "list_code_usages":
            return "list.bullet.indent"

        // Memory & Data
        case "vectorrag_add_document":
            return "doc.badge.arrow.up"
        case "vectorrag_query", "memory", "memory_operations", "search_memory":
            return "doc.text.magnifyingglass"
        case "vectorrag_list_documents":
            return "list.bullet.rectangle"
        case "vectorrag_delete_document":
            return "trash.circle"

        // Tasks & Management
        case "create_and_run_task", "run_task":
            return "play.circle"
        case "manage_todo_list", "manage_todos", "todo_operations":
            return "list.clipboard"
        case "think", "thinking":
            return "brain.head.profile"

        // User Interaction
        case "user_collaboration", "collaborate":
            return "person.2.badge.gearshape"

        // Terminal & Execution
        case "run_in_terminal", "terminal", "terminal_operations", "execute_command", "run_command":
            return "terminal"
        case "get_terminal_output":
            return "terminal.fill"
        case "terminal_last_command":
            return "clock.arrow.2.circlepath"
        case "terminal_selection":
            return "selection.pin.in.out"

        // Testing
        case "run_tests", "runtests":
            return "checkmark.seal"
        case "test_failure":
            return "xmark.seal"

        // MCP Server & Advanced
        case "run_subagent":
            return "person.crop.circle.badge.plus"
        case "mcp_server_operations", "list_mcp_servers", "start_mcp_server":
            return "server.rack"
        case "ui_operations", "open_simple_browser":
            return "safari"
        case "run_sam_command":
            return "command"

        // Default fallback
        default:
            return "wrench.and.screwdriver"
        }
    }

    /// Extract action detail from tool call arguments Extract action detail from tool call arguments Returns a human-readable description of what the tool is doing.
    private func extractToolActionDetail(_ toolCall: ToolCall) -> String {
        /// PROTOCOL-BASED: Check if tool has registered display info provider.
        let registry = ToolDisplayInfoRegistry.shared
        if let displayInfo = registry.getDisplayInfo(for: toolCall.name, arguments: toolCall.arguments) {
            return displayInfo
        }

        /// SMART FALLBACK: Extract details from common argument patterns.
        let args = toolCall.arguments

        /// Check for query/search arguments.
        if let query = args["query"] as? String {
            return query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Check for file-related arguments.
        if let filePath = args["filePath"] as? String {
            let filename = (filePath as NSString).lastPathComponent
            return filename
        }

        if let filename = args["filename"] as? String {
            if let format = args["format"] as? String {
                return "\(format.uppercased()): \(filename)"
            }
            return filename
        }

        if let path = args["path"] as? String {
            let filename = (path as NSString).lastPathComponent
            return filename
        }

        if let output_path = args["output_path"] as? String {
            let filename = (output_path as NSString).lastPathComponent
            return filename
        }

        /// Check for URL arguments.
        if let url = args["url"] as? String {
            if let host = URL(string: url)?.host {
                return host
            }
            return url
        }

        if let urls = args["urls"] as? [String], !urls.isEmpty {
            if urls.count == 1, let url = urls.first {
                if let host = URL(string: url)?.host {
                    return host
                }
                return url
            }
            let hosts = urls.prefix(2).compactMap { URL(string: $0)?.host }
            if !hosts.isEmpty {
                let hostsText = hosts.joined(separator: ", ")
                return urls.count > 2 ? "\(hostsText), +\(urls.count - 2) more" : hostsText
            }
        }

        /// Check for command arguments.
        if let command = args["command"] as? String {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 60 ? String(trimmed.prefix(57)) + "..." : trimmed
        }

        /// Check for content arguments.
        if let content = args["content"] as? String {
            if let format = args["format"] as? String {
                let preview = content.prefix(40).trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(format.uppercased()): \(preview)..."
            }
            let preview = content.prefix(50).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.count > 50 ? preview + "..." : preview
        }

        /// Check for operation-specific patterns.
        if let operation = args["operation"] as? String {
            /// Format operation name nicely.
            let formatted = operation
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return formatted
        }

        /// No useful details found.
        return ""
    }

    /// Adds tool execution results to conversation history.
    @MainActor
    private func addToolResultsToConversation(
        conversationId: UUID,
        toolResults: [ToolExecution]
    ) async throws {
        logger.debug("addToolResultsToConversation: Formatting \(toolResults.count) tool results")

        /// Format tool results as a summary message In future: Should use OpenAI's role="tool" format with tool_call_id For now: Format as clear user message summarizing tool results.
        var summary = "Tool execution results:\n\n"

        for (index, execution) in toolResults.enumerated() {
            summary += "\(index + 1). Tool: \(execution.toolName)\n"
            summary += "   Result: \(execution.result)\n\n"
        }

        logger.debug("addToolResultsToConversation: Formatted summary (\(summary.count) chars)")

        /// Add to conversation via ConversationManager Find conversation by ID in conversations array.
        if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
            conversation.messageBus?.addAssistantMessage(
                id: UUID(),
                content: summary,
                timestamp: Date()
            )
            /// MessageBus handles persistence automatically
            logger.debug("addToolResultsToConversation: Successfully added tool results to conversation")
        } else {
            logger.error("addToolResultsToConversation: ERROR - Conversation \(conversationId.uuidString) not found")
            /// Don't throw - continue workflow even if we couldn't persist.
        }
    }

    /// Detect if agent is mid-workflow (needs continuation) or completing simple task CONTEXT-AWARE DETECTION: - Checks if agent used multi-step planning tools (think) - Analyzes message content for continuation signals - Detects if agent explicitly stated work is complete - Parameters: - response: The agent's response message - internalMessages: Conversation history - toolsExecuted: Whether tools were executed in this workflow - Returns: true if agent appears to be mid-workflow, false if completing simple task.
    private func detectMidWorkflowState(
        response: String,
        internalMessages: [OpenAIChatMessage],
        toolsExecuted: Bool
    ) -> Bool {
        let lowercasedResponse = response.lowercased()

        /// HEURISTIC 1: Check if agent used think tool (indicates multi-step planning).
        let usedThinkTool = internalMessages.contains { message in
            let content = message.content ?? ""
            return content.lowercased().contains("SUCCESS: thinking:") ||
                content.lowercased().contains("tool: think")
        }

        /// HEURISTIC 2: Check for continuation signals in response.
        let continuationSignals = [
            "next i will", "then i will", "i will now",
            "step 1", "step 2", "first,", "second,",
            "now that i", "after", "once",
            "moving forward", "next step"
        ]
        let hasContinuationSignal = continuationSignals.contains { signal in
            lowercasedResponse.contains(signal)
        }

        /// HEURISTIC 3: Check if agent explicitly said work is complete.
        let completionSignals = [
            "work complete", "task complete", "finished",
            "completed", "done", "all set",
            "successfully created", "successfully completed"
        ]
        let hasCompletionSignal = completionSignals.contains { signal in
            lowercasedResponse.contains(signal)
        }

        /// HEURISTIC 4: Check user's request for multi-step indicators.
        let userRequest = (internalMessages.first { $0.role == "user" }?.content ?? "").lowercased()
        let multiStepKeywords = [
            " and ", " then ", "first", "after that",
            "research", "analyze", "create", "generate"
        ]
        let isMultiStepRequest = multiStepKeywords.filter { keyword in
            userRequest.contains(keyword)
        }.count >= 2

        /// DECISION LOGIC: - If agent used think tool → probably mid-workflow - If has continuation signals and no completion signals → mid-workflow - If multi-step request and tools executed but no completion → mid-workflow - If has completion signals → NOT mid-workflow.

        if hasCompletionSignal {
            return false
        }

        if usedThinkTool {
            return true
        }

        if hasContinuationSignal {
            return true
        }

        if isMultiStepRequest && toolsExecuted {
            return true
        }

        return false
    }

    // MARK: - YARN Context Management

    /// Calculate hash of message array content for compression detection
    private func messageFingerprint(_ messages: [OpenAIChatMessage]) -> String {
        let combined = messages.map { msg in
            "\(msg.role):\(msg.content ?? "")"
        }.joined(separator: "|")

        var hasher = Hasher()
        hasher.combine(combined)
        return String(hasher.finalize())
    }

    /// Process ALL messages (conversation + tool results) with YARN for intelligent context management This prevents HTTP 400 payload size errors from GitHub Copilot and other providers **CRITICAL**: This must be called on the COMPLETE message array (conversation + system + tools) BEFORE sending to LLM.
    /// - Parameters:
    ///   - allMessages: Complete message array (conversation + system + tools)
    ///   - conversationId: The conversation UUID
    ///   - modelContextLimit: The model's actual context limit (from TokenCounter)
    private func processAllMessagesWithYARN(
        _ allMessages: [OpenAIChatMessage],
        conversationId: UUID,
        modelContextLimit: Int? = nil
    ) async throws -> [OpenAIChatMessage] {

        /// Initialize YARN processor if needed (lazy initialization).
        if yarnProcessor == nil || !yarnProcessor!.isInitialized {
            logger.debug("YARN: Initializing YaRNContextProcessor with mega 128M token profile")
            try await yarnProcessor?.initialize()
        }

        guard let processor = yarnProcessor else {
            logger.warning("YARN: Processor not available - returning original messages")
            return allMessages
        }

        /// CRITICAL FIX: Use model's actual context limit, not universal 524K
        /// This prevents 400 errors when using smaller models like GPT-4 (8K)
        let effectiveTarget: Int
        if let limit = modelContextLimit {
            /// Target 70% of model's context to leave room for response
            effectiveTarget = Int(Double(limit) * 0.70)
            logger.debug("YARN: Using model-specific target: \(effectiveTarget) tokens (70% of \(limit) limit)")
        } else {
            /// Fallback to YaRN's default (for local models or when limit unknown)
            effectiveTarget = Int(Double(processor.contextWindowSize) * 0.70)
            logger.debug("YARN: Using default target: \(effectiveTarget) tokens (70% of \(processor.contextWindowSize))")
        }

        /// Convert OpenAIChatMessage to Message format for YARN processing.
        let conversationMessages = allMessages.map { chatMsg -> Message in
            Message(
                id: UUID(),
                content: chatMsg.content ?? "",
                isFromUser: chatMsg.role == "user",
                timestamp: Date(),
                performanceMetrics: nil,
                githubCopilotResponseId: nil,
                isPinned: chatMsg.role == "system",
                importance: chatMsg.role == "system" ? 1.0 : (chatMsg.role == "user" ? 0.9 : 0.7)
            )
        }

        /// Process complete message context with YARN using model-specific target.
        let processedContext = try await processor.processConversationContext(
            messages: conversationMessages,
            conversationId: conversationId,
            targetTokenCount: effectiveTarget
        )

        /// Convert back to OpenAIChatMessage format.
        let processedMessages = processedContext.messages.map { message -> OpenAIChatMessage in
            let role = message.isFromUser ? "user" : (message.isPinned ? "system" : "assistant")
            return OpenAIChatMessage(role: role, content: message.content)
        }

        /// Log compression statistics.
        let stats = processor.getContextStatistics()
        let originalTokens = stats.compressionRatio > 0 ? Int(Double(processedContext.tokenCount) / stats.compressionRatio) : processedContext.tokenCount
        logger.debug("YARN: Processed \(allMessages.count) → \(processedMessages.count) messages", metadata: [
            "original_tokens": "\(originalTokens)",
            "compressed_tokens": "\(processedContext.tokenCount)",
            "compression_ratio": "\(String(format: "%.2f", stats.compressionRatio))",
            "compression_active": "\(stats.isCompressionActive)",
            "method": "\(processedContext.processingMethod)"
        ])
        
        /// Track compression telemetry if compression was applied
        if processedContext.compressionApplied {
            await conversationManager.incrementCompressionEvent(for: conversationId)
        }

        return processedMessages
    }

    /// Validate API request size before sending CRITICAL: Most timeouts occur because agent sends more data than API can handle This pre-flight check estimates request size and triggers compression if oversized Returns (estimatedTokens, isSafe, contextLimit).
    private func validateRequestSize(
        messages: [OpenAIChatMessage],
        model: String,
        tools: [OpenAITool]? = nil
    ) async -> (estimatedTokens: Int, isSafe: Bool, contextLimit: Int) {
        /// Get model's known context limit.
        let contextLimit = await tokenCounter.getContextSize(modelName: model)

        /// Estimate total tokens in request.
        var totalTokens = 0
        for message in messages {
            let content = message.content ?? ""
            totalTokens += await tokenCounter.estimateTokensRemote(text: content)
        }

        /// Include tool schema/token cost in estimation (tools can be large).
        if let tools = tools, !tools.isEmpty {
            let toolTokens = await tokenCounter.calculateToolTokens(tools: tools, model: nil, isLocal: false)
            totalTokens += toolTokens
            logger.debug("REQUEST_SIZE_VALIDATION: Added tool token estimate: \(toolTokens) tokens for \(tools.count) tools")
        }

        /// SAFETY THRESHOLD: 85% of context limit Why 85%?.
        let safetyThreshold = Int(Float(contextLimit) * 0.85)
        let isSafe = totalTokens <= safetyThreshold

        if !isSafe {
            logger.warning("REQUEST_SIZE_VALIDATION: Request too large - \(totalTokens) tokens exceeds 85% threshold (\(safetyThreshold)/\(contextLimit))")
            logger.warning("REQUEST_SIZE_VALIDATION: This will likely cause timeout. Recommend triggering additional YARN compression.")
        } else {
            logger.debug("REQUEST_SIZE_VALIDATION: Request size OK - \(totalTokens) tokens / \(contextLimit) limit (\(Int(Float(totalTokens)/Float(contextLimit)*100))%)")
        }

        return (totalTokens, isSafe, contextLimit)
    }

    /// Calculate total payload size in bytes for a message array
    /// Used to enforce API payload limits (typically 16KB for GitHub Copilot)
    private func calculatePayloadSize(_ messages: [OpenAIChatMessage]) -> Int {
        var totalBytes = 0
        for message in messages {
            if let content = message.content {
                totalBytes += content.utf8.count
            }
            if let toolCalls = message.toolCalls {
                for toolCall in toolCalls {
                    let args = toolCall.function.arguments  // Not optional
                    totalBytes += args.utf8.count
                    totalBytes += toolCall.function.name.utf8.count
                }
            }
        }
        return totalBytes
    }

    /// Enforce payload size limit by removing oldest messages
    /// Based on vscode-copilot-chat pattern to stay under API limits
    /// Returns true if trimming occurred, false otherwise
    private func enforcePayloadSizeLimit(_ messages: inout [OpenAIChatMessage], maxBytes: Int = 16000) -> Bool {
        let initialSize = calculatePayloadSize(messages)

        if initialSize <= maxBytes {
            self.logger.debug("PAYLOAD_SIZE: \(initialSize) bytes (under \(maxBytes) limit)")
            return false  /// No trimming needed
        }

        self.logger.warning("PAYLOAD_SIZE: \(initialSize) bytes exceeds limit (\(maxBytes)), trimming oldest messages")

        var currentSize = initialSize
        var removedCount = 0

        /// Remove oldest messages until we're under the limit
        /// Keep at least the last 2 messages (latest user + tool results)
        while currentSize > maxBytes && messages.count > 2 {
            let removed = messages.removeFirst()
            removedCount += 1

            if let content = removed.content {
                currentSize -= content.utf8.count
            }
            if let toolCalls = removed.toolCalls {
                for toolCall in toolCalls {
                    let args = toolCall.function.arguments  // Not optional
                    currentSize -= args.utf8.count
                    currentSize -= toolCall.function.name.utf8.count
                }
            }
        }

        self.logger.info("PAYLOAD_SIZE: Removed \(removedCount) oldest messages, reduced from \(initialSize) to \(currentSize) bytes")
        return true  /// Trimming occurred
    }
}

// MARK: - Timeout Error Enhancement

/// Enhance timeout errors with helpful guidance for agents GitHub API timeouts often occur when agents send too much data (large tool responses, verbose context).
private func enhanceTimeoutError(_ error: Error) -> Error {
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
private func stripUserContextBlock(from content: String) -> String {
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
private func cleanToolCallMarkers(from content: String) -> String {
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

// MARK: - Supporting Types

/// Response from LLM call.
private struct LLMResponse {
    let content: String
    let finishReason: String
    let toolCalls: [ToolCall]?
    let statefulMarker: String?
}

/// Tool call information from LLM response.
private struct ToolCall: @unchecked Sendable {
    let id: String
    let name: String
    let arguments: [String: Any]
}

/// Sendable wrapper for tool arguments dictionary
/// @unchecked Sendable is safe here because:
/// 1. Dictionary only contains JSON-serializable types (String, Int, Bool, Array, Dictionary)
/// 2. These types are all value types or immutable references
/// 3. Dictionary is captured as immutable `let` binding before crossing actor boundaries
private struct SendableArguments: @unchecked Sendable {
    let value: [String: Any]
}

/// Todo item structure for autonomous execution.
private struct TodoItem {
    let id: Int
    let title: String
    let description: String
    let status: String
}
