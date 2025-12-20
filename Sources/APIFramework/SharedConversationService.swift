// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConversationEngine
import MCPFramework
import Logging
@MainActor
public class SharedConversationService: ObservableObject {
    private let logger = Logging.Logger(label: "com.sam.sharedservice")

    private let conversationManager: ConversationManager
    private var endpointManager: EndpointManager?
    private let toolRegistry: UniversalToolRegistry

    public init(conversationManager: ConversationManager) {
        self.conversationManager = conversationManager
        self.toolRegistry = UniversalToolRegistry(conversationManager: conversationManager)
        logger.debug("SharedConversationService initialized")
    }

    /// Inject EndpointManager after initialization to resolve circular dependencies.
    public func injectEndpointManager(_ endpointManager: EndpointManager) {
        logger.debug("SHARED_SERVICE: Injecting EndpointManager")
        self.endpointManager = endpointManager
        logger.debug("SHARED_SERVICE: EndpointManager injection completed")
    }

    /// Process non-streaming chat completion with unified conversation flow This ensures both streaming and non-streaming API requests use identical tool injection.
    public func processNonStreamingConversation(
        request: OpenAIChatRequest,
        sessionId: String? = nil
    ) async throws -> ServerOpenAIChatResponse {

        guard let endpointManager = self.endpointManager else {
            logger.error("SHARED_SERVICE: ERROR - EndpointManager not injected!")
            throw SharedConversationError.endpointManagerNotInjected
        }

        logger.debug("SHARED_SERVICE: Processing non-streaming conversation")
        logger.debug("SHARED_SERVICE: Request model: \(request.model)")
        logger.debug("SHARED_SERVICE: Message count: \(request.messages.count)")
        if let sessionId = sessionId {
            logger.debug("SHARED_SERVICE: Session ID: \(sessionId)")
        }

        /// Inject MCP tools into request for both UI and API consistency This ensures memory_search and other MCP tools are available in non-streaming API requests.
        let enhancedRequest = await injectMCPToolsIntoRequest(request)

        /// Use EndpointManager for unified conversation processing.
        let initialResponse = try await endpointManager.processChatCompletion(enhancedRequest)

        /// SAM 1.0 FEEDBACK LOOP: Implement the decoupled conversation/tool processing pattern This matches SAM 1.0's approach: decouple conversation from tools, process tools, continue LLM.
        let finalResponse = try await processSAM1FeedbackLoop(initialResponse, originalRequest: enhancedRequest, sessionId: sessionId)

        logger.debug("SHARED_SERVICE: Successfully completed non-streaming conversation")

        return finalResponse
    }

    /// Execute tools and append results to response content (simplified approach) This validates tool execution works before implementing full LLM continuation.
    private func executeToolsAndAppendResults(
        _ response: ServerOpenAIChatResponse,
        sessionId: String?
    ) async throws -> ServerOpenAIChatResponse {

        guard let firstChoice = response.choices.first else {
            logger.warning("SHARED_SERVICE: No response choices found")
            return response
        }

        /// Check if LLM returned tool calls.
        guard let toolCalls = firstChoice.message.toolCalls, !toolCalls.isEmpty else {
            /// No tool calls, return response as-is.
            logger.debug("SHARED_SERVICE: No tool calls detected, returning original response")
            return response
        }

        logger.debug("SHARED_SERVICE: SIMPLIFIED TOOL EXECUTION - Processing \(toolCalls.count) tool calls")

        /// Execute all tool calls and collect results.
        var toolResults: [String] = []

        for toolCall in toolCalls {
            logger.debug("SHARED_SERVICE: Executing tool: \(toolCall.function.name)")
            logger.debug("SHARED_SERVICE: Tool arguments string (length \(toolCall.function.arguments.count)): \(toolCall.function.arguments)")

            do {
                /// Strip trailing quote if present (MLX models add extra quote).
                var cleanedArguments = toolCall.function.arguments
                logger.debug("DEBUG_ARGS: Raw: [\(cleanedArguments)]")
                logger.debug("DEBUG_ARGS: HasPrefix{: \(cleanedArguments.hasPrefix("{")), HasSuffix\": \(cleanedArguments.hasSuffix("\""))")

                if cleanedArguments.hasSuffix("\"") && cleanedArguments.hasPrefix("{") {
                    cleanedArguments = String(cleanedArguments.dropLast())
                    logger.debug("DEBUG_ARGS: SUCCESS - Stripped trailing quote")
                }

                /// Parse tool arguments with cleaned string.
                let argumentsData = cleanedArguments.data(using: .utf8) ?? Data()
                let arguments = try JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] ?? [:]

                /// Execute MCP tool through ConversationManager.
                let isExternal = (sessionId != nil)
                if let result = await conversationManager.executeMCPTool(name: toolCall.function.name, parameters: arguments, isExternalAPICall: isExternal) {
                    let resultText = "Tool '\(toolCall.function.name)' executed successfully:\n\(result.output.content)"
                    toolResults.append(resultText)
                    logger.debug("SHARED_SERVICE: Tool '\(toolCall.function.name)' executed successfully")
                } else {
                    let errorText = "Tool '\(toolCall.function.name)' execution failed: Tool not found or execution error"
                    toolResults.append(errorText)
                    logger.error("SHARED_SERVICE: Tool '\(toolCall.function.name)' execution failed")
                }
            } catch {
                let errorText = "Tool '\(toolCall.function.name)' execution error: \(error.localizedDescription)"
                toolResults.append(errorText)
                logger.error("SHARED_SERVICE: Tool '\(toolCall.function.name)' execution error: \(error)")
            }
        }

        /// Append tool results to original response content.
        let toolResultsContent = toolResults.joined(separator: "\n\n")
        let originalContent = firstChoice.message.content ?? "I used the following tools:"
        let enhancedContent = originalContent + "\n\n**Tool Execution Results:**\n\n" + toolResultsContent

        /// Create enhanced response with tool results appended.
        let enhancedChoice = OpenAIChatChoice(
            index: firstChoice.index,
            message: OpenAIChatMessage(
                role: firstChoice.message.role,
                content: enhancedContent
            ),
            finishReason: firstChoice.finishReason
        )

        let enhancedResponse = ServerOpenAIChatResponse(
            id: response.id,
            object: response.object,
            created: response.created,
            model: response.model,
            choices: [enhancedChoice],
            usage: response.usage
        )

        logger.debug("SHARED_SERVICE: Tool execution completed, results appended to response")
        return enhancedResponse
    }

    /// Process tool calls and continue LLM conversation - TRUE Sequential Thinking Implementation This implements the User → LLM → Tool → LLM → User flow for proper sequential thinking.
    private func processToolCallsAndContinue(
        _ response: ServerOpenAIChatResponse,
        originalRequest: OpenAIChatRequest,
        sessionId: String?
    ) async throws -> ServerOpenAIChatResponse {

        guard let firstChoice = response.choices.first else {
            logger.warning("SHARED_SERVICE: No response choices found")
            return response
        }

        /// Check if LLM returned tool calls.
        guard let toolCalls = firstChoice.message.toolCalls, !toolCalls.isEmpty else {
            /// No tool calls, return response as-is.
            logger.debug("SHARED_SERVICE: No tool calls detected, returning original response")
            return response
        }

        logger.debug("SHARED_SERVICE: TRUE SEQUENTIAL THINKING - LLM requested \(toolCalls.count) tool calls")

        /// Execute all tool calls.
        var toolMessages: [OpenAIChatMessage] = []

        /// Add the assistant's tool call message (CRITICAL: must include toolCalls for GitHub Copilot).
        logger.debug("SHARED_SERVICE: Original assistant message - content: '\(firstChoice.message.content ?? "nil")', toolCalls count: \(toolCalls.count)")
        for (index, toolCall) in toolCalls.enumerated() {
            logger.debug("SHARED_SERVICE: ToolCall \(index + 1): id=\(toolCall.id), name=\(toolCall.function.name)")
        }

        let assistantMessage = OpenAIChatMessage(
            role: "assistant",
            content: firstChoice.message.content,
            toolCalls: toolCalls
        )
        toolMessages.append(assistantMessage)

        /// Execute each tool call and create tool result messages.
        for toolCall in toolCalls {
            logger.debug("SHARED_SERVICE: Executing tool: \(toolCall.function.name)")
            logger.debug("SHARED_SERVICE: Tool arguments string (length \(toolCall.function.arguments.count)): \(toolCall.function.arguments)")

            do {
                /// Strip trailing quote if present (MLX models add extra quote).
                var cleanedArguments = toolCall.function.arguments
                logger.debug("DEBUG: Raw arguments before cleaning: [\(cleanedArguments)]")
                logger.debug("DEBUG: Starts with {: \(cleanedArguments.hasPrefix("{")), Ends with \": \(cleanedArguments.hasSuffix("\""))")

                if cleanedArguments.hasSuffix("\"") && cleanedArguments.hasPrefix("{") {
                    cleanedArguments = String(cleanedArguments.dropLast())
                    logger.debug("DEBUG: SUCCESS - Stripped trailing quote from arguments")
                }

                /// Parse tool arguments with cleaned string.
                let argumentsData = cleanedArguments.data(using: .utf8) ?? Data()
                let arguments = try JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] ?? [:]

                /// Execute MCP tool through ConversationManager.
                let isExternal = (originalRequest.samConfig?.isExternalAPICall == true) || (sessionId != nil)
                if let result = await conversationManager.executeMCPTool(name: toolCall.function.name, parameters: arguments, isExternalAPICall: isExternal) {
                    let toolResultMessage = OpenAIChatMessage(
                        role: "tool",
                        content: "Tool '\(toolCall.function.name)' executed successfully:\n\(result.output.content)",
                        toolCallId: toolCall.id
                    )
                    toolMessages.append(toolResultMessage)
                    logger.debug("SHARED_SERVICE: Tool '\(toolCall.function.name)' executed successfully")
                } else {
                    let errorMessage = OpenAIChatMessage(
                        role: "tool",
                        content: "Tool '\(toolCall.function.name)' execution failed: Tool not found or execution error",
                        toolCallId: toolCall.id
                    )
                    toolMessages.append(errorMessage)
                    logger.error("SHARED_SERVICE: Tool '\(toolCall.function.name)' execution failed")
                }
            } catch {
                let errorMessage = OpenAIChatMessage(
                    role: "tool",
                    content: "Tool '\(toolCall.function.name)' execution error: \(error.localizedDescription)",
                    toolCallId: toolCall.id
                )
                toolMessages.append(errorMessage)
                logger.error("SHARED_SERVICE: Tool '\(toolCall.function.name)' execution error: \(error)")
            }
        }

        /// Continue conversation with LLM using tool results Create new request with original conversation + tool calls + tool results.
        let continuationMessages = originalRequest.messages + toolMessages
        let continuationRequest = OpenAIChatRequest(
            model: originalRequest.model,
            messages: continuationMessages,
            temperature: originalRequest.temperature,
            maxTokens: originalRequest.maxTokens,
            stream: originalRequest.stream,
            tools: originalRequest.tools,
            samConfig: originalRequest.samConfig,
            contextId: originalRequest.contextId,
            enableMemory: originalRequest.enableMemory,
            sessionId: originalRequest.sessionId,
            conversationId: originalRequest.conversationId
        )

        logger.debug("SHARED_SERVICE: Continuing conversation with LLM using \(toolMessages.count) tool result messages")

        /// Send continuation request to LLM.
        guard let endpointManager = self.endpointManager else {
            throw SharedConversationError.endpointManagerNotInjected
        }
        let continuationResponse = try await endpointManager.processChatCompletion(continuationRequest)

        /// Recursively handle any additional tool calls (in case LLM wants to call more tools).
        return try await processToolCallsAndContinue(continuationResponse, originalRequest: continuationRequest, sessionId: sessionId)
    }

    /// Process tool calls in streaming response - TRUE sequential thinking implementation BREAKTHROUGH IMPLEMENTATION - VS CODE COPILOT CHAT PATTERN: This method implements the critical pattern for GitHub Copilot streaming with tool calls.
    private func processStreamingToolCalls(
        _ originalStream: AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error>,
        originalRequest: OpenAIChatRequest,
        sessionId: String?
    ) -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {

        return AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> { continuation in
            Task {
                do {
                    /// Accumulate all chunks and reconstruct complete response.
                    var accumulatedContent = ""
                    var accumulatedToolCalls: [OpenAIToolCall] = []
                    var streamChunks: [ServerOpenAIChatStreamChunk] = []
                    var lastModel = ""
                    var responseId = ""
                    var finishReason = "stop"

                    logger.debug("SHARED_SERVICE: Starting true sequential thinking - accumulating stream")

                    /// Collect all chunks from the original stream.
                    for try await chunk in originalStream {
                        streamChunks.append(chunk)

                        /// Forward the chunk to the user immediately for real-time response.
                        continuation.yield(chunk)

                        /// Accumulate data to reconstruct complete response.
                        if let choice = chunk.choices.first {
                            if let content = choice.delta.content {
                                accumulatedContent += content
                            }
                            if let toolCalls = choice.delta.toolCalls {
                                accumulatedToolCalls.append(contentsOf: toolCalls)
                                logger.debug("SHARED_SERVICE: FOUND TOOL CALLS in chunk: \(toolCalls.count)")
                            }

                            /// Capture finish_reason from streaming chunks.
                            if let chunkFinishReason = choice.finishReason {
                                finishReason = chunkFinishReason
                                logger.debug("SHARED_SERVICE: Detected finish_reason: \(finishReason)")
                            }
                        }

                        /// Track metadata for response reconstruction.
                        lastModel = chunk.model
                        responseId = chunk.id
                    }

                    logger.debug("SHARED_SERVICE: Stream complete, accumulated \(accumulatedContent.count) characters")
                    logger.debug("SHARED_SERVICE: Final finish_reason: \(finishReason)")

                    /// Handle tool calls based on finish_reason (VS Code Copilot Chat pattern).
                    if finishReason == "tool_calls" {
                        logger.debug("SHARED_SERVICE: Stream indicated tool_calls, making non-streaming request to get tool call details")

                        /// INSIGHT: GitHub Copilot streaming API limitation workaround
                        ///
                        /// What happens in streaming:
                        /// - GitHub sends finish_reason="tool_calls" as indication
                        /// - But NO actual tool call data (names, arguments) in stream chunks
                        /// - UI sees "tools needed" but can't execute anything
                        ///
                        /// The workaround:
                        /// - Detect finish_reason="tool_calls" from stream
                        /// - Make separate non-streaming request with same context
                        /// - Non-streaming response includes full tool call data
                        /// - Execute tools with actual data
                        ///
                        /// Why this works:
                        /// - User already saw streaming response (good UX)
                        /// - Background non-streaming request gets tool details (reliable execution)
                        /// - Tools execute with proper data
                        /// - Next streaming response includes tool results
                        ///
                        /// This pattern matches GitHub Copilot streaming API behavior.

                        guard let endpointManager = self.endpointManager else {
                            throw SharedConversationError.endpointManagerNotInjected
                        }

                        /// Create identical non-streaming request to get tool calls NOTE: This is internal processing only - user still gets streaming response.
                        let nonStreamingRequest = OpenAIChatRequest(
                            model: originalRequest.model,
                            messages: originalRequest.messages,
                            temperature: originalRequest.temperature,
                            maxTokens: originalRequest.maxTokens,
                            stream: false,
                            tools: originalRequest.tools,
                            samConfig: originalRequest.samConfig,
                            contextId: originalRequest.contextId,
                            enableMemory: originalRequest.enableMemory,
                            sessionId: originalRequest.sessionId,
                            conversationId: originalRequest.conversationId
                        )

                        logger.debug("SHARED_SERVICE: Making non-streaming request to get tool call details")
                        let toolCallResponse = try await endpointManager.processChatCompletion(nonStreamingRequest)

                        /// STREAMING TOOL EXECUTION: Use streaming-aware tool execution for conversational feedback.
                        logger.debug("SHARED_SERVICE: Using streaming tool execution with conversational feedback")
                        try await executeToolsAndContinueConversation(
                            response: toolCallResponse,
                            originalRequest: nonStreamingRequest,
                            sessionId: sessionId,
                            continuation: continuation
                        )

                        continuation.finish()
                        return
                    }

                    /// No tool calls - reconstruct complete response for regular completion.
                    logger.debug("SHARED_SERVICE: Reconstructed response - Content: \(accumulatedContent.count) chars, Tool calls: \(accumulatedToolCalls.count)")

                    let completeResponse = ServerOpenAIChatResponse(
                        id: responseId,
                        object: "chat.completion",
                        created: Int(Date().timeIntervalSince1970),
                        model: lastModel,
                        choices: [
                            OpenAIChatChoice(
                                index: 0,
                                message: OpenAIChatMessage(
                                    role: "assistant",
                                    content: accumulatedContent.isEmpty ? nil : accumulatedContent,
                                    toolCalls: accumulatedToolCalls.isEmpty ? nil : accumulatedToolCalls
                                ),
                                finishReason: finishReason
                            )
                        ],
                        usage: ServerOpenAIUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
                    )

                    /// Check for tool calls using same logic as non-streaming mode.
                    if shouldProcessToolCalls(completeResponse) {
                        logger.error("SHARED_SERVICE: Tool calls detected, executing tools and continuing with LLM")

                        /// Execute tools and continue conversation with LLM.
                        try await executeToolsAndContinueConversation(
                            response: completeResponse,
                            originalRequest: originalRequest,
                            sessionId: sessionId,
                            continuation: continuation
                        )
                    }

                    continuation.finish()
                } catch {
                    logger.error("SHARED_SERVICE: Sequential thinking error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Check if response contains tool calls that need processing (matches SAMAPIServer logic).
    private func shouldProcessToolCalls(_ response: ServerOpenAIChatResponse) -> Bool {
        guard let firstChoice = response.choices.first,
              let toolCalls = firstChoice.message.toolCalls,
              !toolCalls.isEmpty else {
            logger.debug("SHARED_SERVICE: No tool calls found in response")
            return false
        }

        logger.debug("SHARED_SERVICE: Found \(toolCalls.count) tool calls in response")
        return true
    }

    /// Execute tools and continue conversation with LLM (TRUE sequential thinking).
    private func executeToolsAndContinueConversation(
        response: ServerOpenAIChatResponse,
        originalRequest: OpenAIChatRequest,
        sessionId: String?,
        continuation: AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error>.Continuation
    ) async throws {

        guard let firstChoice = response.choices.first,
              let toolCalls = firstChoice.message.toolCalls else {
            return
        }

        logger.debug("SHARED_SERVICE: Executing \(toolCalls.count) tools for true sequential thinking")

        /// Execute each tool call WITH REAL-TIME PROGRESS FEEDBACK.
        var toolResults: [String] = []
        let created = Int(Date().timeIntervalSince1970)
        let requestId = "sam-tool-progress-\(UUID().uuidString)"

        for (index, toolCall) in toolCalls.enumerated() {
            /// Yield progress message IMMEDIATELY as each tool starts This ensures users see tool execution in REAL-TIME during streaming.
            let progressContent = "SUCCESS: SAM Command: \(toolCall.function.name)\n"
            let progressChunk = ServerOpenAIChatStreamChunk(
                id: requestId,
                object: "chat.completion.chunk",
                created: created,
                model: response.model,
                choices: [OpenAIChatStreamChoice(
                    index: 0,
                    delta: OpenAIChatDelta(content: progressContent),
                    finishReason: nil
                )]
            )
            continuation.yield(progressChunk)
            logger.debug("SHARED_SERVICE: Yielded progress for tool \(index + 1)/\(toolCalls.count): \(toolCall.function.name)")

            do {
                /// Parse tool arguments.
                let argumentsData = toolCall.function.arguments.data(using: .utf8) ?? Data()
                let arguments = try JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] ?? [:]

                /// Execute MCP tool through ConversationManager.
                let isExternal = (originalRequest.samConfig?.isExternalAPICall == true) || (sessionId != nil)
                if let result = await conversationManager.executeMCPTool(name: toolCall.function.name, parameters: arguments, isExternalAPICall: isExternal) {
                    let resultText = "Tool '\(toolCall.function.name)' executed successfully:\n\(result.output.content)"
                    toolResults.append(resultText)
                    logger.debug("SHARED_SERVICE: Tool '\(toolCall.function.name)' executed successfully")
                } else {
                    let errorText = "Tool '\(toolCall.function.name)' execution failed: Tool not found or execution error"
                    toolResults.append(errorText)
                    logger.error("SHARED_SERVICE: Tool '\(toolCall.function.name)' execution failed")
                }
            } catch {
                let errorText = "Tool '\(toolCall.function.name)' execution error: \(error.localizedDescription)"
                toolResults.append(errorText)
                logger.error("SHARED_SERVICE: Tool '\(toolCall.function.name)' execution error: \(error)")
            }
        }

        /// Use SAM 1.0 feedback loop for continuation (same as non-streaming).
        logger.debug("SHARED_SERVICE: Using SAM 1.0 feedback loop for tool result processing and LLM continuation")

        /// Create a non-streaming response object from the tool calls for feedback loop processing.
        let toolCallResponse = ServerOpenAIChatResponse(
            id: "sam-tool-response-\(UUID().uuidString)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: "sam-streaming-processor",
            choices: [
                OpenAIChatChoice(
                    index: 0,
                    message: OpenAIChatMessage(
                        role: "assistant",
                        content: nil,
                        toolCalls: toolCalls
                    ),
                    finishReason: "tool_calls"
                )
            ],
            usage: ServerOpenAIUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        )

        /// Create continuation request based on original request but non-streaming for feedback loop.
        let continuationRequest = OpenAIChatRequest(
            model: originalRequest.model,
            messages: originalRequest.messages,
            temperature: originalRequest.temperature,
            maxTokens: originalRequest.maxTokens,
            stream: false,
            tools: originalRequest.tools,
            samConfig: originalRequest.samConfig,
            contextId: originalRequest.contextId,
            enableMemory: originalRequest.enableMemory,
            sessionId: originalRequest.sessionId,
            conversationId: originalRequest.conversationId
        )

        /// Use the complete SAM 1.0 feedback loop to process tools and get LLM continuation.
        do {
            let finalResponse = try await processSAM1FeedbackLoop(toolCallResponse, originalRequest: continuationRequest, sessionId: sessionId)

            /// Convert the final response back to streaming chunks.
            let streamChunks = convertResponseToStreamChunks(finalResponse)
            for chunk in streamChunks {
                continuation.yield(chunk)
            }
        } catch {
            logger.error("SHARED_SERVICE: SAM 1.0 feedback loop failed in streaming mode: \(error)")
            /// Create error response and convert to chunks.
            let errorResponse = ServerOpenAIChatResponse(
                id: "sam-error-\(UUID().uuidString)",
                object: "chat.completion",
                created: Int(Date().timeIntervalSince1970),
                model: "sam-streaming-processor",
                choices: [
                    OpenAIChatChoice(
                        index: 0,
                        message: OpenAIChatMessage(
                            role: "assistant",
                            content: "Error processing tools: \(error.localizedDescription)",
                            toolCalls: nil
                        ),
                        finishReason: "stop"
                    )
                ],
                usage: ServerOpenAIUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
            )
            let errorChunks = convertResponseToStreamChunks(errorResponse)
            for chunk in errorChunks {
                continuation.yield(chunk)
            }
        }
    }

    /// Inject available MCP tools into the request for both UI and API consistency MCP Tool Injection System - CRITICAL BRIDGE BETWEEN SAM AND EXTERNAL LLM PROVIDERS ARCHITECTURE PURPOSE: This method bridges SAM's internal MCP (Model Context Protocol) tool ecosystem with external LLM providers like GitHub Copilot.
    public func injectMCPToolsIntoRequest(_ request: OpenAIChatRequest) async -> OpenAIChatRequest {
        logger.debug("SHARED_SERVICE: Starting MCP tool injection")

        /// Get available MCP tools from ConversationManager.
        let availableTools = conversationManager.getAvailableMCPTools()

        logger.debug("SHARED_SERVICE: Found \(availableTools.count) available MCP tools")

        /// Filter out user_collaboration tool for external API calls User collaboration requires interactive UI (SSE events, user input) which external APIs cannot provide This includes: - Any request with isExternalAPICall=true (set by caller) - Autonomous Worker mode (system prompt UUID 00000000-0000-0000-0000-000000000002) SECURITY: Filter out terminal_operations if enableTerminalAccess=false Terminal operations disabled by default for security For internal SAM usage (UI-based conversations), user_collaboration works normally.
        let shouldFilterUserCollaboration = request.samConfig?.isExternalAPICall == true || {
            if let systemPromptId = request.samConfig?.systemPromptId {
                let autonomousWorkerUUID = "00000000-0000-0000-0000-000000000002"
                return systemPromptId == "autonomous_editor" || systemPromptId == "autonomous_worker" || systemPromptId == autonomousWorkerUUID
            }
            return false
        }()

        let shouldFilterTerminalOperations = request.samConfig?.enableTerminalAccess != true

        /// Filter out run_subagent when workflow mode is disabled
        /// Issue #3: run_subagent available even when workflow toggle is OFF
        let shouldFilterSubagent = request.samConfig?.enableWorkflowMode != true

        /// Filter out increase_max_iterations when dynamic iterations disabled
        /// The "Extend" toggle controls whether agent can request more iterations
        let shouldFilterDynamicIterations = request.samConfig?.enableDynamicIterations != true

        logger.debug("SHARED_SERVICE: Tool filtering decision", metadata: [
            "enableWorkflowMode": .string(String(describing: request.samConfig?.enableWorkflowMode)),
            "shouldFilterSubagent": .stringConvertible(shouldFilterSubagent),
            "enableDynamicIterations": .string(String(describing: request.samConfig?.enableDynamicIterations)),
            "shouldFilterDynamicIterations": .stringConvertible(shouldFilterDynamicIterations),
            "conversationId": .string(request.conversationId ?? "none")
        ])

        var filteredTools = availableTools

        if shouldFilterUserCollaboration {
            logger.debug("SHARED_SERVICE: Filtering user_collaboration (isExternalAPICall=\(request.samConfig?.isExternalAPICall == true), autonomous mode)")
            filteredTools = filteredTools.filter { $0.name != "user_collaboration" }
        }

        if shouldFilterTerminalOperations {
            logger.debug("SHARED_SERVICE: Filtering terminal_operations (enableTerminalAccess=false, security default)")
            filteredTools = filteredTools.filter { $0.name != "terminal_operations" }
        }

        if shouldFilterSubagent {
            logger.debug("SHARED_SERVICE: Filtering run_subagent (enableWorkflowMode=false)")
            filteredTools = filteredTools.filter { $0.name != "run_subagent" }
        }

        if shouldFilterDynamicIterations {
            logger.debug("SHARED_SERVICE: Filtering increase_max_iterations (enableDynamicIterations=false)")
            filteredTools = filteredTools.filter { $0.name != "increase_max_iterations" }
        }

        if shouldFilterUserCollaboration || shouldFilterTerminalOperations || shouldFilterSubagent || shouldFilterDynamicIterations {
            logger.debug("SHARED_SERVICE: Filtered \(availableTools.count) → \(filteredTools.count) tools")
        }

        /// ALWAYS INJECT ALL TOOLS - Dynamic injection causes performance issues Models need full tool context to function properly Previous experiment with dynamic injection showed: - Llama-2-7B: Completely broken (garbage output) - Qwen models: Worked but slower - GPT-4: Worked but added latency Conclusion: Always send all tools for consistent, fast behavior.

        logger.info("TOOL_INJECTION: Injecting \(filteredTools.count) tools for model \(request.model)")

        for tool in filteredTools {
            logger.debug("SHARED_SERVICE: Available tool: \(tool.name)")
        }

        /// If no tools available or tools already defined in request, return as-is.
        if filteredTools.isEmpty || request.tools != nil {
            logger.debug("SHARED_SERVICE: No tool injection needed (available: \(filteredTools.count), existing: \(request.tools?.count ?? 0))")
            return request
        }

        /// Check if MCP tools are explicitly disabled via samConfig This allows pre-loading and other special requests to opt-out of tool injection.
        logger.debug("SHARED_SERVICE: Checking samConfig.mcpToolsEnabled: \(request.samConfig?.mcpToolsEnabled?.description ?? "nil")")
        if let mcpToolsEnabled = request.samConfig?.mcpToolsEnabled, !mcpToolsEnabled {
            logger.debug("SHARED_SERVICE: MCP tools explicitly disabled via samConfig (mcpToolsEnabled=false)")
            return request
        }

        /// Convert MCP tools to OpenAI tool definitions.
        let openAITools = filteredTools.map { mcpTool in
            /// Convert MCP parameter definitions to OpenAI format.
            let properties = mcpTool.parameters.reduce(into: [String: [String: Any]]()) { result, param in
                let (paramName, paramDef) = param

                /// Dynamic description injection for run_subagent model parameter.
                var description = paramDef.description
                if mcpTool.name == "run_subagent" && paramName == "model" {
                    /// Inject current model into description.
                    description = """
                    Model to use for subagent. Uses \(request.model) unless otherwise specified.
                    """
                }

                var paramSpec: [String: Any] = [
                    "type": paramDef.type.description,
                    "description": description
                ]

                if let enumValues = paramDef.enumValues {
                    paramSpec["enum"] = enumValues
                }

                /// Handle array types with arrayElementType (GitHub Copilot requires "items" property).
                if case .array = paramDef.type, let arrayElementType = paramDef.arrayElementType {
                    paramSpec["items"] = convertMCPParameterTypeToOpenAI(arrayElementType)
                }

                result[paramName] = paramSpec
            }

            let requiredParams = mcpTool.parameters.compactMap { param in
                param.value.required ? param.key : nil
            }

            let openAIParameters: [String: Any] = [
                "type": "object",
                "properties": properties,
                "required": requiredParams
            ]

            return OpenAITool(
                type: "function",
                function: OpenAIFunction(
                    name: mcpTool.name,
                    description: mcpTool.description,
                    parameters: openAIParameters
                )
            )
        }

        logger.debug("SHARED_SERVICE: Injecting \(openAITools.count) MCP tools into request for model: \(request.model)")

        /// Debug: Log tool injection details.
        for (index, tool) in openAITools.enumerated() {
            logger.debug("SHARED_SERVICE: Injecting tool \(index + 1): \(tool.function.name)")
        }

        /// Create enhanced request with MCP tools.
        let enhancedRequest = OpenAIChatRequest(
            model: request.model,
            messages: request.messages,
            temperature: request.temperature,
            maxTokens: request.maxTokens,
            stream: request.stream,
            tools: openAITools,
            samConfig: request.samConfig,
            contextId: request.contextId,
            enableMemory: request.enableMemory,
            sessionId: request.sessionId,
            conversationId: request.conversationId,
            statefulMarker: request.statefulMarker,
            iterationNumber: request.iterationNumber
        )

        /// Debug: Log final request details.
        logger.debug("SHARED_SERVICE: Enhanced request created - Model: \(enhancedRequest.model), Tools: \(enhancedRequest.tools?.count ?? 0), Stream: \(String(describing: enhancedRequest.stream))")
        if let lastMessage = enhancedRequest.messages.last,
           let content = lastMessage.content {
            logger.debug("SHARED_SERVICE: Last message content: \(String(content.prefix(100)))")
        }

        return enhancedRequest
    }

    /// Convert MCPParameterType to OpenAI JSON schema format This handles the conversion of complex MCP types (arrays, objects) to proper OpenAI tool definitions.
    private func convertMCPParameterTypeToOpenAI(_ paramType: MCPParameterType) -> [String: Any] {
        switch paramType {
        case .string:
            return ["type": "string"]

        case .integer:
            return ["type": "integer"]

        case .boolean:
            return ["type": "boolean"]

        case .array:
            return ["type": "array"]

        case .object(let properties):
            /// Convert object properties to OpenAI format.
            let openAIProperties = properties.reduce(into: [String: [String: Any]]()) { result, property in
                let (propName, propDef) = property
                var propSpec: [String: Any] = [
                    "type": propDef.type.description,
                    "description": propDef.description
                ]

                if let enumValues = propDef.enumValues {
                    propSpec["enum"] = enumValues
                }

                /// Handle nested arrays/objects recursively.
                if case .array = propDef.type, let arrayElementType = propDef.arrayElementType {
                    propSpec["items"] = convertMCPParameterTypeToOpenAI(arrayElementType)
                }

                result[propName] = propSpec
            }

            /// Get required properties for this object.
            let requiredProps = properties.compactMap { prop in
                prop.value.required ? prop.key : nil
            }

            var objectSchema: [String: Any] = [
                "type": "object",
                "properties": openAIProperties
            ]

            if !requiredProps.isEmpty {
                objectSchema["required"] = requiredProps
            }

            return objectSchema
        }
    }

    /// SAM 1.0 Feedback Loop Implementation - CORE SEQUENTIAL THINKING ARCHITECTURE CRITICAL: This method implements the exact SAM 1.0 pattern discovered through user guidance.
    private func processSAM1FeedbackLoop(
        _ response: ServerOpenAIChatResponse,
        originalRequest: OpenAIChatRequest,
        sessionId: String?
    ) async throws -> ServerOpenAIChatResponse {

        guard let firstChoice = response.choices.first else {
            logger.warning("SHARED_SERVICE: No response choices found")
            return response
        }

        /// Check if LLM returned tool calls.
        guard let toolCalls = firstChoice.message.toolCalls, !toolCalls.isEmpty else {
            /// No tool calls - return conversation response as-is.
            logger.debug("SHARED_SERVICE: No tool calls detected, returning conversation response")
            return response
        }

        logger.debug("SHARED_SERVICE: SAM 1.0 FEEDBACK LOOP - LLM returned conversation + \(toolCalls.count) tool requests")

        /// DECOUPLE - Return conversation response immediately to user The user sees the conversational response right away.
        var conversationResponse = response
        if let conversationContent = firstChoice.message.content, !conversationContent.isEmpty {
            logger.debug("SHARED_SERVICE: Decoupled conversational response sent to user: '\(conversationContent.prefix(50))...'")
        } else {
            /// If no conversational content, provide a user-friendly message (VS Code Copilot Chat pattern).
            let enhancedChoice = OpenAIChatChoice(
                index: firstChoice.index,
                message: OpenAIChatMessage(
                    role: firstChoice.message.role,
                    content: "I'll help you with that.",
                    toolCalls: toolCalls
                ),
                finishReason: firstChoice.finishReason
            )
            conversationResponse = ServerOpenAIChatResponse(
                id: response.id,
                object: response.object,
                created: response.created,
                model: response.model,
                choices: [enhancedChoice],
                usage: response.usage
            )
            logger.debug("SHARED_SERVICE: Enhanced conversational response with user-friendly message")
        }

        /// Process tools sequentially in background.
        logger.debug("SHARED_SERVICE: Processing \(toolCalls.count) tools sequentially")
        var toolMessages: [OpenAIChatMessage] = []

        /// Add the assistant's tool call message first.
        let assistantMessage = OpenAIChatMessage(
            role: "assistant",
            content: firstChoice.message.content,
            toolCalls: toolCalls
        )
        toolMessages.append(assistantMessage)

        /// Execute each tool sequentially.
        for toolCall in toolCalls {
            logger.debug("SHARED_SERVICE: Executing tool: \(toolCall.function.name)")

            do {
                /// Strip trailing quote if present (MLX models add extra quote).
                var cleanedArguments = toolCall.function.arguments
                logger.debug("DEBUG_LOOP: Raw arguments: [\(cleanedArguments)]")

                if cleanedArguments.hasSuffix("\"") && cleanedArguments.hasPrefix("{") {
                    cleanedArguments = String(cleanedArguments.dropLast())
                    logger.debug("DEBUG_LOOP: SUCCESS - Stripped trailing quote")
                }

                let argumentsData = cleanedArguments.data(using: .utf8) ?? Data()
                let arguments = try JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] ?? [:]

                let isExternal = (originalRequest.samConfig?.isExternalAPICall == true) || (sessionId != nil)
                if let result = await conversationManager.executeMCPTool(name: toolCall.function.name, parameters: arguments, isExternalAPICall: isExternal) {
                    let toolResultMessage = OpenAIChatMessage(
                        role: "tool",
                        content: result.output.content,
                        toolCallId: toolCall.id
                    )
                    toolMessages.append(toolResultMessage)
                    logger.debug("SHARED_SERVICE: Tool '\(toolCall.function.name)' completed successfully")
                } else {
                    let errorMessage = OpenAIChatMessage(
                        role: "tool",
                        content: "Tool execution failed",
                        toolCallId: toolCall.id
                    )
                    toolMessages.append(errorMessage)
                    logger.error("SHARED_SERVICE: Tool '\(toolCall.function.name)' failed")
                }
            } catch {
                let errorMessage = OpenAIChatMessage(
                    role: "tool",
                    content: "Tool error: \(error.localizedDescription)",
                    toolCallId: toolCall.id
                )
                toolMessages.append(errorMessage)
                logger.error("SHARED_SERVICE: Tool '\(toolCall.function.name)' error: \(error)")
            }
        }

        /// Send tool results back to LLM for continuation.
        let continuationMessages = originalRequest.messages + toolMessages
        let continuationRequest = OpenAIChatRequest(
            model: originalRequest.model,
            messages: continuationMessages,
            temperature: originalRequest.temperature,
            maxTokens: originalRequest.maxTokens,
            stream: originalRequest.stream,
            tools: originalRequest.tools,
            samConfig: originalRequest.samConfig,
            contextId: originalRequest.contextId,
            enableMemory: originalRequest.enableMemory,
            sessionId: originalRequest.sessionId,
            conversationId: originalRequest.conversationId
        )

        logger.debug("SHARED_SERVICE: Sending tool results back to LLM for continuation")

        guard let endpointManager = self.endpointManager else {
            throw SharedConversationError.endpointManagerNotInjected
        }

        let continuationResponse = try await endpointManager.processChatCompletion(continuationRequest)

        /// Check if LLM wants to continue with more tools (recursive).
        if let continuationChoice = continuationResponse.choices.first,
           let continuationToolCalls = continuationChoice.message.toolCalls,
           !continuationToolCalls.isEmpty {
            logger.debug("SHARED_SERVICE: LLM requested \(continuationToolCalls.count) more tools, continuing feedback loop")
            return try await processSAM1FeedbackLoop(continuationResponse, originalRequest: continuationRequest, sessionId: sessionId)
        }

        /// Combine conversational response with final LLM continuation.
        logger.debug("SHARED_SERVICE: LLM completed, combining responses")

        /// If the continuation has meaningful content, append it to the conversation response.
        if let finalChoice = continuationResponse.choices.first,
           let finalContent = finalChoice.message.content, !finalContent.isEmpty {

            /// Combine the original conversational response with the final response.
            let originalContent = conversationResponse.choices.first?.message.content ?? ""
            let combinedContent = originalContent + "\n\n" + finalContent

            let combinedChoice = OpenAIChatChoice(
                index: firstChoice.index,
                message: OpenAIChatMessage(
                    role: firstChoice.message.role,
                    content: combinedContent
                ),
                finishReason: finalChoice.finishReason
            )

            let combinedResponse = ServerOpenAIChatResponse(
                id: response.id,
                object: response.object,
                created: response.created,
                model: response.model,
                choices: [combinedChoice],
                usage: continuationResponse.usage
            )

            logger.debug("SHARED_SERVICE: SAM 1.0 feedback loop completed with combined response")
            return combinedResponse
        }

        /// If no meaningful continuation, return the original conversational response.
        logger.debug("SHARED_SERVICE: SAM 1.0 feedback loop completed, returning conversational response")
        return conversationResponse
    }

    /// Convert a complete response to streaming chunks for output consistency.
    private func convertResponseToStreamChunks(_ response: ServerOpenAIChatResponse) -> [ServerOpenAIChatStreamChunk] {
        var chunks: [ServerOpenAIChatStreamChunk] = []

        guard let choice = response.choices.first else {
            return chunks
        }

        /// Initial role chunk.
        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [
                OpenAIChatStreamChoice(
                    index: 0,
                    delta: OpenAIChatDelta(role: "assistant", content: nil),
                    finishReason: nil
                )
            ]
        ))

        /// Content chunks (if any).
        if let content = choice.message.content {
            chunks.append(ServerOpenAIChatStreamChunk(
                id: response.id,
                object: "chat.completion.chunk",
                created: response.created,
                model: response.model,
                choices: [
                    OpenAIChatStreamChoice(
                        index: 0,
                        delta: OpenAIChatDelta(role: nil, content: content),
                        finishReason: nil
                    )
                ]
            ))
        }

        /// Final chunk with finish reason.
        chunks.append(ServerOpenAIChatStreamChunk(
            id: response.id,
            object: "chat.completion.chunk",
            created: response.created,
            model: response.model,
            choices: [
                OpenAIChatStreamChoice(
                    index: 0,
                    delta: OpenAIChatDelta(role: nil, content: nil),
                    finishReason: choice.finishReason
                )
            ]
        ))

        return chunks
    }

    // MARK: - Helper Methods

    /// Get model context size for dynamic tool injection decisions Returns: Context window size in tokens.
    private func getModelContextSize(_ model: String) -> Int {
        /// Known model context sizes.
        let knownContextSizes: [String: Int] = [
            /// Llama-2 models (4k context).
            "llama-2-7b": 4096,
            "llama-2-13b": 4096,
            "llama-2-70b": 4096,

            /// Mistral models.
            "mistral-7b": 8192,
            "mixtral-8x7b": 32768,

            /// Qwen models.
            "qwen2.5-7b": 32768,
            "qwen2.5-coder": 32768,

            /// Default assumption for unknown models.
            "default": 8192
        ]

        /// Normalize model name for matching.
        let modelLower = model.lowercased()

        /// Check for exact matches or partial matches.
        for (pattern, contextSize) in knownContextSizes {
            if modelLower.contains(pattern) {
                logger.debug("MODEL_CONTEXT: \(model) matched pattern '\(pattern)' → \(contextSize) tokens")
                return contextSize
            }
        }

        /// Default to 8k for unknown models (safe assumption).
        logger.debug("MODEL_CONTEXT: Unknown model \(model), defaulting to 8192 tokens")
        return knownContextSizes["default"]!
    }

    /// Parse conversation history for tool requests from think tool Looks for "TOOL_REQUEST:" markers in assistant messages Returns: Array of requested tool names.
    private func parseToolRequestsFromHistory(_ messages: [OpenAIChatMessage]) -> [String] {
        var requestedTools = Set<String>()

        /// Parse messages in reverse (most recent first) for efficiency.
        for message in messages.reversed() {
            /// Only check assistant messages (where think tool results appear).
            guard message.role == "assistant" || message.role == "tool" else {
                continue
            }

            guard let content = message.content else {
                continue
            }

            /// Look for TOOL_REQUEST marker from ThinkTool.
            if content.contains("TOOL_REQUEST:") {
                /// Extract tool names after the marker.
                if let range = content.range(of: "TOOL_REQUEST:") {
                    let toolsString = String(content[range.upperBound...])
                    /// Parse comma-separated tool names.
                    let tools = toolsString
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }

                    requestedTools.formUnion(tools)
                    logger.debug("TOOL_REQUEST_FOUND: \(tools.joined(separator: ", "))")
                }
            }
        }

        return Array(requestedTools)
    }
}

public enum SharedConversationError: Error {
    case endpointManagerNotInjected

    public var localizedDescription: String {
        switch self {
        case .endpointManagerNotInjected:
            return "EndpointManager must be injected before processing conversations"
        }
    }
}
