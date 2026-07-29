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
    func safePrefix(_ maxLength: Int) -> String {
        guard !isEmpty else { return "" }
        guard maxLength > 0 else { return "" }
        let scalars = self.unicodeScalars
        guard scalars.count > maxLength else { return self }
        let endIndex = scalars.index(scalars.startIndex, offsetBy: maxLength)
        return String(scalars[..<endIndex])
    }
}

// MARK: - LLM API Calls

extension AgentOrchestrator {

    /// Calls the LLM via EndpointManager (bypasses SAM 1.0 feedback loop).
    @MainActor
    func callLLM(
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

        /// CONTEXT MANAGEMENT: Context trimming is owned by MessageValidator (run later in this
        /// function). MessageValidator performs a budget walk with atomic unit grouping and
        /// compresses dropped context into a thread_summary - no LLM calls, no API charges.
        logger.debug("CONTEXT_MANAGEMENT: MessageValidator handles context trimming (budget walk + thread_summary compression)")

        /// Build messages array: system prompt + conversation messages + internal tool messages.
        var messages: [OpenAIChatMessage] = []

        /// Add user-configured system prompt (includes guard rails) FIRST This was the architectural gap - API requests never included SystemPromptManager prompts.
        /// System prompt + dynamic context (shared with callLLMStreaming via
        /// buildSystemPromptAndDynamicContext).
        let (systemPromptContent, dynamicContext) = await buildSystemPromptAndDynamicContext(
            conversation: conversation,
            conversationId: conversationId,
            model: model,
            samConfig: samConfig,
            loggerPrefix: "callLLM"
        )

        logger.debug("callLLM: System prompt length=\(systemPromptContent.count) chars, dynamic context=\(dynamicContext.count) chars")


        /// CLAUDE USERCONTEXT INJECTION (Claude-specific pinned-message context).
        appendClaudePinnedUserContext(
            to: &messages,
            conversation: conversation,
            model: model,
            loggerPrefix: "callLLM"
        )

        /// AUTOMATIC CONTEXT RETRIEVAL (pinned + semantic search).
        await appendContextRetrieval(
            to: &messages,
            conversation: conversation,
            currentUserMessage: message,
            iteration: iteration,
            retrievedMessageIds: &retrievedMessageIds,
            caller: "callLLM",
            loggerPrefix: "callLLM"
        )

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

        /// Document import + memory reminders (shared with streaming path).
        appendImportAndMemoryReminders(
            to: &messages,
            conversation: conversation,
            model: model,
            loggerPrefix: "callLLM"
        )

        /// Add conversation messages (user requests + LLM responses only, no tool results).
        /// Filter out tool messages and assistant messages with tool_calls (when internalMessages exist).
        /// Tool messages and assistant+tool_calls messages are stored by MessageBus during execution
        /// but the properly-structured versions (with correct assistant+tool_calls -> tool result ordering)
        /// are in internalMessages. Including them here creates ordering violations.
        let hasInternalMsgs = !internalMessages.isEmpty
        var messagesToSend = conversation.messages.filter { msg in
            if msg.isToolMessage { return false }
            if !msg.isFromUser && hasInternalMsgs {
                let hasToolCalls = msg.toolCalls != nil && !(msg.toolCalls?.isEmpty ?? true)
                if hasToolCalls { return false }
            }
            return true
        }

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
                let apiMessage = convertEnhancedToAPIMessage(historyMessage)
                messages.append(apiMessage)
                logger.debug("DELTA_MESSAGE: Message \(index): role=\(apiMessage.role), content=\(apiMessage.content?.safePrefix(50) ?? "(nil)")")
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
                var apiMessage = convertEnhancedToAPIMessage(historyMessage)

                /// Strip <userContext>...</userContext> from OLD user messages (not the latest one)
                /// This prevents sending the same 9800-char block 13+ times
                /// CRITICAL: Never strip from PINNED messages - they contain critical context
                /// (e.g., first message in conversation with copilot-instructions)
                if apiMessage.role == "user" && index != lastUserMessageIndex && !historyMessage.isPinned {
                    if let content = apiMessage.content {
                        let originalLength = content.count
                        let cleanContent = stripUserContextBlock(from: content)
                        let stripped = originalLength - cleanContent.count
                        if stripped > 0 {
                            strippedContextChars += stripped
                            apiMessage = OpenAIChatMessage(role: apiMessage.role, content: cleanContent)
                            logger.debug("CONTEXT_DEDUP: Stripped \(stripped) chars from user message \(index)")
                        }
                    }
                } else if apiMessage.role == "user" && historyMessage.isPinned && index != lastUserMessageIndex {
                    logger.debug("CONTEXT_DEDUP: Preserved <userContext> on pinned message \(index)")
                }

                messages.append(apiMessage)
                logger.debug("DEBUG_DUPLICATION: Message \(index): role=\(apiMessage.role), toolCalls=\(apiMessage.toolCalls?.count ?? 0), content=\(apiMessage.content?.safePrefix(50) ?? "(nil)")")
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

        /// CUSTOM INSTRUCTION INJECTION: Append custom instruction content to the last user message
        /// in the API payload. This is NOT persisted to conversation history - it only exists
        /// in the messages array sent to the API. Models pay more attention to content in user
        /// messages than system prompts, so this gets custom instructions acted on rather than ignored.
        ///
        /// ONE-TIME PERSIST: When custom instructions are enabled mid-conversation, we also add a
        /// hidden system-generated user message to conversation history so the model retains
        /// context about WHY it made certain decisions even after the instruction is disabled.
        if !conversation.enabledCustomInstructionIds.isEmpty {
            let customInstructionText = CustomInstructionManager.shared.getInjectedText(
                for: conversation.id,
                enabledIds: conversation.enabledCustomInstructionIds
            )
            if !customInstructionText.isEmpty {
                /// Check if custom instruction content is already persisted in conversation history
                let alreadyPersisted = conversation.messages.contains { msg in
                    msg.isFromUser && msg.content.contains(customInstructionText.prefix(100))
                }

                /// One-time persist: Add hidden message if not already in history.
                /// This ensures the model retains context for its decisions even after
                /// the custom instruction is disabled. Hidden from UI via isSystemGenerated.
                if !alreadyPersisted {
                    let persistContent = "<userContext>\n\(customInstructionText)\n</userContext>"
                    conversation.messageBus?.addUserMessage(
                        content: persistContent,
                        isPinned: true,
                        isSystemGenerated: true
                    )
                    logger.info("callLLM: Persisted custom instruction content as hidden message for conversation continuity (\(customInstructionText.count) chars)")
                }

                /// Ephemeral injection into last user message for immediate salience
                if let lastUserIndex = messages.lastIndex(where: { $0.role == "user" }) {
                    let existingContent = messages[lastUserIndex].content ?? ""
                    if !existingContent.contains(customInstructionText.prefix(100)) {
                        let injectedContent = existingContent + "\n\n<userContext>\n\(customInstructionText)\n</userContext>"
                        messages[lastUserIndex] = OpenAIChatMessage(role: "user", content: injectedContent)
                        logger.info("callLLM: Ephemeral custom instruction injection into last user message (\(customInstructionText.count) chars)")
                    } else {
                        logger.debug("callLLM: Custom instruction already present in last user message")
                    }
                }
            }
        }

        /// KV CACHE OPTIMIZATION: Inject dynamic context into last user message.
        /// This keeps the system prompt byte-identical across turns, enabling full KV cache reuse.
        /// Dynamic context includes: conversation ID, tool listing, working directory, shared topic,
        /// LTM entries, and session naming instruction.
        if !dynamicContext.isEmpty {
            if let lastUserIndex = messages.lastIndex(where: { $0.role == "user" }) {
                let existingContent = messages[lastUserIndex].content ?? ""
                let injectedContent = existingContent + "\n\n<userContext>\n\(dynamicContext)\n</userContext>"
                messages[lastUserIndex] = OpenAIChatMessage(role: "user", content: injectedContent)
                logger.debug("callLLM: Injected dynamic context (\(dynamicContext.count) chars) into last user message for KV cache stability")
            } else {
                logger.warning("callLLM: No user message found for dynamic context injection")
            }
        }

        /// CONTEXT MANAGEMENT: MessageValidator performs budget walk with atomic unit
        /// grouping and compresses dropped context into a thread_summary. Shared helper
        /// ensures both call paths apply the same logic.
        messages = await validateAndArchiveContext(
            messages: messages,
            conversationId: conversationId,
            model: model,
            loggerPrefix: "callLLM"
        )

        /// Determine statefulMarker for session continuity (may have been cleared
        /// by MessageValidator if trimming occurred).
        let checkpointMarker: String? = currentMarker ?? conversation.lastGitHubCopilotResponseId
        if let marker = checkpointMarker {
            logger.debug("Using statefulMarker for session continuity: \(marker.prefix(20))...")
        } else {
            logger.debug("No statefulMarker available (may have been cleared by payload trimming)")
        }

        /// Build base request (without tools) + inject MCP tools + apply alternation
        /// and tool pair validation. Shared helper ensures both call paths apply the
        /// same logic for SAMConfig, sampling params, tool injection, and alternation.
        let baseRequest = buildBaseRequest(
            messages: messages,
            conversation: conversation,
            conversationId: conversationId,
            model: model,
            iteration: iteration,
            samConfig: samConfig,
            statefulMarker: checkpointMarker,
            streaming: false
        )
        let finalRequest = await finalizeRequestWithToolsAndAlternation(
            baseRequest: baseRequest,
            loggerPrefix: "callLLM"
        )

        /// Context management is owned entirely by MessageValidator (run earlier in this function).
        /// Any request that still exceeds the safe threshold here means either:
        /// - The model's reported context size is wrong (use a more conservative model config)
        /// - A provider-specific hard limit is smaller than the model's nominal context
        /// - A bug in MessageValidator's budget walk
        /// In all three cases the right fix is upstream - this code path intentionally does NOT
        /// cascade into YaRN/force-trim because that masked the real issue and produced
        /// requests with corrupt tool_call/tool_result pairing.
        let (estimatedTokens, isSafe, contextLimit) = await validateRequestSize(
            messages: finalRequest.messages,
            model: model,
            tools: finalRequest.tools
        )
        if !isSafe {
            logger.warning("API_REQUEST_SIZE: Request exceeds safe threshold (\(estimatedTokens) tokens / \(contextLimit) limit) - MessageValidator output will be sent as-is")
        }


        /// DIAGNOSTIC: Log full message array to understand what LLM actually sees
        logger.debug("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logger.debug("DIAGNOSTIC_MESSAGES: Full message array being sent to LLM (\(finalRequest.messages.count) messages)")
        for (index, msg) in finalRequest.messages.enumerated() {
            let contentPreview = msg.content?.prefix(150) ?? "nil"
            let toolCallsInfo = msg.toolCalls.map { "toolCalls=\($0.count)" } ?? "no-tools"
            let toolCallId = msg.toolCallId ?? "no-id"
            logger.debug("  [\(index)] role=\(msg.role) \(toolCallsInfo) toolCallId=\(toolCallId) content=\(contentPreview)...")
        }
        logger.debug("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

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
                let argumentsString = toolCall.function.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                var arguments: [String: Any] = [:]
                
                // Handle empty arguments (some tools take no params)
                if !argumentsString.isEmpty && argumentsString != "{}" {
                    let argumentsData = argumentsString.data(using: String.Encoding.utf8) ?? Data()
                    if let parsedArgs = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] {
                        arguments = parsedArgs
                    } else {
                        logger.warning("callLLM: Failed to parse arguments JSON for tool '\(toolCall.function.name)': \(argumentsString)")
                        // Still create the tool call with empty arguments - don't skip it!
                    }
                }
                
                toolCalls?.append(ToolCall(
                    id: toolCall.id,
                    name: toolCall.function.name,
                    arguments: arguments
                ))
                logger.debug("callLLM: Parsed tool call '\(toolCall.function.name)' (id: \(toolCall.id))")
            }
        }

        logger.debug("callLLM: LLM response - finishReason=\(finishReason), content length=\(content.count), toolCalls=\(toolCalls?.count ?? 0)")

        /// MLX Tool Call Parser - Extract tool calls from <tool_call> XML tags or JSON code blocks.
        /// Local models don't have native tool calling support - they emit text-only responses
        /// in the formats instructed by AppleMLXAdapter's system prompt.
        var finalContent = content
        var finalToolCalls = toolCalls

        if finalToolCalls?.isEmpty != false {
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
        } else if let calls = finalToolCalls {
            logger.debug("callLLM: Using native tool calls from provider (\(calls.count) calls)")
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
            statefulMarker: statefulMarker,
            rawContent: content.contains("<think>") ? content : nil
        )
    }

    /// Calls the LLM via EndpointManager with streaming support Yields chunks to continuation in real-time for better UX.
    @MainActor
    func callLLMStreaming(
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

        /// CONTEXT MANAGEMENT: Context trimming is owned by MessageValidator (run later in this
        /// function). MessageValidator performs a budget walk with atomic unit grouping and
        /// compresses dropped context into a thread_summary - no LLM calls, no API charges.
        logger.debug("CONTEXT_MANAGEMENT: MessageValidator handles context trimming (budget walk + thread_summary compression)")

        /// Build messages array: system prompt + conversation messages + internal tool messages.
        var messages: [OpenAIChatMessage] = []

        /// System prompt + dynamic context (shared with callLLM via
        /// buildSystemPromptAndDynamicContext).
        let (systemPromptContent, dynamicContext) = await buildSystemPromptAndDynamicContext(
            conversation: conversation,
            conversationId: conversationId,
            model: model,
            samConfig: samConfig,
            loggerPrefix: "callLLMStreaming"
        )

        logger.debug("callLLMStreaming: System prompt length=\(systemPromptContent.count) chars, dynamic context=\(dynamicContext.count) chars")

        if !systemPromptContent.isEmpty {
            messages.append(OpenAIChatMessage(role: "system", content: systemPromptContent))
            logger.debug("callLLMStreaming: Added user-configured system prompt to messages (static prefix)")
        }

        /// CLAUDE USERCONTEXT INJECTION (Claude-specific pinned-message context).
        appendClaudePinnedUserContext(
            to: &messages,
            conversation: conversation,
            model: model,
            loggerPrefix: "callLLMStreaming"
        )

        /// AUTOMATIC CONTEXT RETRIEVAL (pinned + semantic search).
        await appendContextRetrieval(
            to: &messages,
            conversation: conversation,
            currentUserMessage: message,
            iteration: iteration,
            retrievedMessageIds: &retrievedMessageIds,
            caller: "callLLMStreaming",
            loggerPrefix: "callLLMStreaming"
        )

        /// Document import + memory reminders (shared with non-streaming path).
        appendImportAndMemoryReminders(
            to: &messages,
            conversation: conversation,
            model: model,
            loggerPrefix: "callLLMStreaming"
        )

        /// Filter out UI-only progress/status messages before sending to API These messages are only for UI display and should not be sent to LLM WHY FILTER: - Progress messages like "→ Continuing work" or "SUCCESS: User Collaboration: ..." are UI-only - They don't represent actual conversation content - Including them adds unnecessary noise to LLM context WHAT TO FILTER: - Messages starting with "→" (continuation status) - Messages starting with "SUCCESS: User Collaboration:" (collaboration prompts) - "Extended execution limit" status messages WHAT TO KEEP: - User messages (always kept) - Tool result messages (isToolMessage=true) - even if they start with "SUCCESS:" - Assistant messages with actual LLM responses.
        var conversationMessages: [Message] = Array(conversation.messages).filter { msg in
            /// Always keep user messages.
            if msg.isFromUser {
                return true
            }

            /// Skip tool messages from conversation history - these are stored by MessageBus
            /// during tool execution but the properly-structured versions (with correct
            /// assistant+tool_calls -> tool result ordering) are in internalMessages.
            /// Including them here creates duplicates and ordering violations that cause
            /// API errors ("messages with role 'tool' must follow 'tool_calls'").
            if msg.isToolMessage {
                return false
            }

            /// Skip assistant messages that have tool_calls when internalMessages exist.
            /// These are stored by MessageBus during streaming tool-call workflow iterations.
            /// The properly-structured versions are already in internalMessages with correct
            /// assistant(tool_calls) -> tool(result) ordering. Including duplicates from
            /// conversation history creates malformed message sequences.
            if !msg.isFromUser && !internalMessages.isEmpty {
                let hasToolCalls = msg.toolCalls != nil && !(msg.toolCalls?.isEmpty ?? true)
                if hasToolCalls {
                    return false
                }
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
        var useDeltaMode = false  /// Track whether we should use delta-only mode
        
        if let marker = statefulMarker, hasToolResults {
            /// Delta-only mode: This is a workflow iteration with tool results
            /// Server has full history up to marker, only need to send tool execution delta
            /// PREFERRED: Use message count from when marker was captured (no timing dependencies)
            if let markerMessageCount = statefulMarkerMessageCount {
                /// Slice to only include messages AFTER the marker count
                /// Example: If marker was captured at count=3, send messages from index 3 onwards
                let sliceIndex = markerMessageCount
                conversationMessages = Array(conversationMessages.suffix(from: min(sliceIndex, conversationMessages.count)))
                useDeltaMode = true  /// Successfully sliced, use delta mode
                logger.debug("STATEFUL_MARKER_SLICING: Using message count \(markerMessageCount), sending \(conversationMessages.count) messages after marker (delta-only mode with tool results)")
            }
            /// FALLBACK: Search for marker in messages (timing-dependent, may fail if message not persisted yet)
            else if let markerIndex = conversationMessages.lastIndex(where: { $0.githubCopilotResponseId == marker }) {
                /// Slice to only include messages AFTER the marker (marker itself is already on server)
                conversationMessages = Array(conversationMessages.suffix(from: markerIndex + 1))
                useDeltaMode = true  /// Successfully found marker, use delta mode
                logger.debug("STATEFUL_MARKER_SLICING: Found marker at index \(markerIndex), sending ONLY \(conversationMessages.count) messages after marker (delta-only mode, fallback method)")
            } else {
                /// CRITICAL: Marker not found - cannot use delta mode safely!
                /// Send FULL conversation history to prevent context loss
                useDeltaMode = false  /// Force full history mode
                logger.warning("STATEFUL_MARKER_WARNING: Marker \(marker.prefix(20))... not found in conversation AND no message count available, FORCING FULL HISTORY MODE (safety fallback)")
            }
        } else if statefulMarker != nil && !hasToolResults {
            /// Subsequent user message scenario: statefulMarker exists but no tool results yet
            /// Do NOT slice conversation history - user needs full context for their new message!
            useDeltaMode = false  /// Full history needed for user message
            logger.debug("SUBSEQUENT_USER_MESSAGE: StatefulMarker exists but no tool results - sending FULL conversation history (\(conversationMessages.count) messages) for user context")
        } else {
            useDeltaMode = false  /// No marker, send full history
            logger.debug("INFO: No statefulMarker, sending all \(conversationMessages.count) conversation messages")
        }

        /// When delta mode is enabled, send ONLY internalMessages (delta-only mode)
        /// When delta mode is disabled, send conversationMessages + internalMessages (full history)
        /// This prevents duplicate assistant messages that cause Claude 400 errors
        /// ROOT CAUSE: Assistant responses are in BOTH conversation.messages AND internalMessages
        /// GitHub Copilot approach: With statefulMarker, only send NEW messages (delta)
        /// Our approach: internalMessages IS the delta (tool calls + results from previous iteration)
        /// Do NOT inject "Please continue" into messages array
        /// GitHub Copilot API: "Please continue" is query param only, NOT a synthetic message
        var currentMarker = statefulMarker  /// Make mutable copy
        if useDeltaMode && hasToolResults {
            /// Delta-only mode: Server has full history up to marker, only send new tool execution context
            /// The stateful marker tells the API to continue from the previous response
            /// We send ONLY the tool results (delta), not the full conversation history
            messages.append(contentsOf: internalMessagesToSend)
            logger.debug("STATEFUL_MARKER_DELTA_MODE: Sending \(internalMessagesToSend.count) internal messages (delta-only mode, no synthetic user message)")

            /// CRITICAL FIX: Only enforce payload limit for Claude (Claude-specific limitation)
            /// GitHub Copilot and other models don't have this restriction
            /// This was causing tool results to be trimmed away → infinite loop bug
            let modelLower = model.lowercased()
            if modelLower.contains("claude") {
                /// CRITICAL: Enforce 64KB payload limit for Claude (increased from 32KB to match GitHub Copilot limit)
                /// Even with cached large tool results, accumulated deltas can exceed limit
                /// If trimming occurs, clear marker (it may reference removed message)
                if enforcePayloadSizeLimit(&messages, maxBytes: 64000) {
                    currentMarker = nil
                    logger.warning("PAYLOAD_SIZE: Cleared statefulMarker after trimming (marker may reference removed message)")
                }
            } else {
                logger.debug("PAYLOAD_SIZE: Skipping payload limit for non-Claude model (\(model))")
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
                // Use unified converter that preserves tool calls and tool result structure
                var apiMessage = convertEnhancedToAPIMessage(historyMessage)

                /// Strip <userContext>...</userContext> from OLD user messages (not the latest one)
                /// This prevents sending the same 9800-char block 13+ times
                /// CRITICAL: Never strip from PINNED messages - they contain critical context
                /// (e.g., first message in conversation with copilot-instructions)
                if apiMessage.role == "user" && index != lastUserMessageIndex && !historyMessage.isPinned {
                    if let content = apiMessage.content {
                        let originalLength = content.count
                        let cleanContent = stripUserContextBlock(from: content)
                        let stripped = originalLength - cleanContent.count
                        if stripped > 0 {
                            strippedContextChars += stripped
                            apiMessage = OpenAIChatMessage(role: apiMessage.role, content: cleanContent)
                            logger.debug("CONTEXT_DEDUP: Stripped \(stripped) chars from user message \(index)")
                        }
                    }
                } else if apiMessage.role == "user" && historyMessage.isPinned && index != lastUserMessageIndex {
                    logger.debug("CONTEXT_DEDUP: Preserved <userContext> on pinned message \(index)")
                }

                messages.append(apiMessage)
                logger.debug("CONTEXT_BUILD: Message \(index): role=\(apiMessage.role), toolCalls=\(apiMessage.toolCalls?.count ?? 0), content=\(apiMessage.content?.safePrefix(50) ?? "(nil)")")
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

        logger.debug("callLLMStreaming: Built complete message array with \(messages.count) messages (before alternation fix)")

        /// Claude models via GitHub Copilot/OpenRouter don't need tool result batching -
        /// those proxies handle Claude conversion internally and expect OpenAI format.

        /// Apply alternation fix before validation so the budget walk sees the
        /// pre-merge message structure (alternation can grow the message count
        /// by collapsing two user messages into one - safer to budget first).
        messages = ensureMessageAlternation(messages)
        logger.debug("callLLMStreaming: Applied message alternation fix - \(messages.count) messages after merging")

        /// Safety net: validate tool message pairs after alternation merging.
        /// The alternation function can create orphaned tool results if it merges
        /// assistant messages incorrectly. This catches any issues before the API call.
        messages = MessageValidator.validateToolMessagePairs(messages)
        logger.debug("callLLMStreaming: Validated tool message pairs - \(messages.count) messages after validation")

        /// CUSTOM INSTRUCTION INJECTION + ONE-TIME PERSIST
        /// See callLLM for full rationale - models act on user-message content, ignore system prompt tail.
        if !conversation.enabledCustomInstructionIds.isEmpty {
            let customInstructionText = CustomInstructionManager.shared.getInjectedText(
                for: conversation.id,
                enabledIds: conversation.enabledCustomInstructionIds
            )
            if !customInstructionText.isEmpty {
                /// Check if custom instruction content is already persisted in conversation history
                let alreadyPersisted = conversation.messages.contains { msg in
                    msg.isFromUser && msg.content.contains(customInstructionText.prefix(100))
                }

                /// One-time persist: Add hidden message if not already in history
                if !alreadyPersisted {
                    let persistContent = "<userContext>\n\(customInstructionText)\n</userContext>"
                    conversation.messageBus?.addUserMessage(
                        content: persistContent,
                        isPinned: true,
                        isSystemGenerated: true
                    )
                    logger.info("callLLMStreaming: Persisted custom instruction content as hidden message (\(customInstructionText.count) chars)")
                }

                /// Ephemeral injection into last user message for immediate salience
                if let lastUserIndex = messages.lastIndex(where: { $0.role == "user" }) {
                    let existingContent = messages[lastUserIndex].content ?? ""
                    if !existingContent.contains(customInstructionText.prefix(100)) {
                        let injectedContent = existingContent + "\n\n<userContext>\n\(customInstructionText)\n</userContext>"
                        messages[lastUserIndex] = OpenAIChatMessage(role: "user", content: injectedContent)
                        logger.info("callLLMStreaming: Ephemeral custom instruction injection into last user message (\(customInstructionText.count) chars)")
                    } else {
                        logger.debug("callLLMStreaming: Custom instruction already present in last user message")
                    }
                }
            }
        }

        /// KV CACHE OPTIMIZATION: Inject dynamic context into last user message.
        /// This keeps the system prompt byte-identical across turns, enabling full KV cache reuse.
        /// Dynamic context includes: conversation ID, tool listing, working directory, shared topic,
        /// LTM entries, and session naming instruction.
        if !dynamicContext.isEmpty {
            if let lastUserIndex = messages.lastIndex(where: { $0.role == "user" }) {
                let existingContent = messages[lastUserIndex].content ?? ""
                let injectedContent = existingContent + "\n\n<userContext>\n\(dynamicContext)\n</userContext>"
                messages[lastUserIndex] = OpenAIChatMessage(role: "user", content: injectedContent)
                logger.debug("callLLMStreaming: Injected dynamic context (\(dynamicContext.count) chars) into last user message for KV cache stability")
            } else {
                logger.warning("callLLMStreaming: No user message found for dynamic context injection")
            }
        }

        /// Get model context limit for MessageValidator budget calculation
        let modelContextLimit = await tokenCounter.getContextSize(modelName: model)
        /// CONTEXT MANAGEMENT: MessageValidator performs budget walk with atomic unit
        /// grouping and compresses dropped context into a thread_summary. Shared helper
        /// ensures both call paths apply the same logic.
        messages = await validateAndArchiveContext(
            messages: messages,
            conversationId: conversationId,
            model: model,
            loggerPrefix: "callLLMStreaming"
        )

        logger.debug("callLLMStreaming: Request has \(messages.count) messages (after MessageValidator)")

        /// Log statefulMarker presence for debugging.
        if let marker = statefulMarker {
            logger.debug("callLLMStreaming: Including statefulMarker from previous iteration: \(marker.prefix(20))...")
        }

        /// Build base request (without tools) + inject MCP tools + apply alternation
        /// and tool pair validation. Shared helper ensures both call paths apply the
        /// same logic for SAMConfig, sampling params, tool injection, and alternation.
        let baseRequest = buildBaseRequest(
            messages: messages,
            conversation: conversation,
            conversationId: conversationId,
            model: model,
            iteration: iteration,
            samConfig: samConfig,
            statefulMarker: currentMarker,
            streaming: true
        )
        let finalRequest = await finalizeRequestWithToolsAndAlternation(
            baseRequest: baseRequest,
            loggerPrefix: "callLLMStreaming"
        )

        /// Context management is owned entirely by MessageValidator (run earlier in this function).
        /// Any request that still exceeds the safe threshold here means either:
        /// - The model's reported context size is wrong (use a more conservative model config)
        /// - A provider-specific hard limit is smaller than the model's nominal context
        /// - A bug in MessageValidator's budget walk
        /// In all three cases the right fix is upstream - this code path intentionally does NOT
        /// cascade into YaRN/force-trim because that masked the real issue and produced
        /// requests with corrupt tool_call/tool_result pairing.
        let (estimatedTokens, isSafe, contextLimit) = await validateRequestSize(
            messages: finalRequest.messages,
            model: model,
            tools: finalRequest.tools
        )
        if !isSafe {
            logger.warning("API_REQUEST_SIZE: Request exceeds safe threshold (\(estimatedTokens) tokens / \(contextLimit) limit) - MessageValidator output will be sent as-is")
        }
        /// DIAGNOSTIC: Log full message array to understand what LLM actually sees
        logger.debug("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logger.debug("DIAGNOSTIC_MESSAGES_STREAMING: Full message array being sent to LLM (\(finalRequest.messages.count) messages)")
        for (index, msg) in finalRequest.messages.enumerated() {
            let contentPreview = msg.content?.prefix(150) ?? "nil"
            let toolCallsInfo = msg.toolCalls.map { "toolCalls=\($0.count)" } ?? "no-tools"
            let toolCallId = msg.toolCallId ?? "no-id"
            logger.debug("  [\(index)] role=\(msg.role) \(toolCallsInfo) toolCallId=\(toolCallId) content=\(contentPreview)...")
        }
        logger.debug("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        logger.debug("callLLMStreaming: Calling EndpointManager.processStreamingChatCompletion() with retry policy")

        /// Create streaming response with auth-recovery retry
        /// Auth errors (401) manifest INSIDE the stream during iteration, not during creation.
        /// The provider detects 401, refreshes the token, then throws authRecoverable.
        /// We catch that during iteration and create a fresh stream with the new token.
        var streamingResponse = try await endpointManager.processStreamingChatCompletion(finalRequest)

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

        /// Track thinking message for provider-level thinking (e.g., MiniMax <think> tags)
        var thinkingMessageId: UUID?

        /// Track tool messages by execution ID to create separate cards for each tool call
        var toolMessagesByExecutionId: [String: UUID] = [:]

        /// Track accumulated content separately for each message
        var accumulatedContentByMessageId: [UUID: String] = [:]

        /// Track accumulated thinking text for providers that strip <think> tags during streaming.
        /// Used to reconstruct rawContent (with <think> tags) for API round-trips.
        var accumulatedThinkingText = ""

        /// Use StreamingToolCalls for index-based accumulation.
        let streamingToolCalls = StreamingToolCalls()

        /// Track chunk count for debugging
        var chunkCount = 0
        var authRetryAttempts = 0
        let maxAuthRetries = 2

        /// Auth recovery retry loop: if the stream throws authRecoverable (401 token refresh),
        /// create a new stream and restart. This only fires before any content chunks are yielded.
        authRetryLoop: while true {
        do {
        for try await chunk in streamingResponse {
            /// CRITICAL: Check for cancellation on each chunk to enable immediate stop
            /// This allows the stop button to immediately halt streaming from remote APIs
            if isCancellationRequested {
                logger.info("STREAMING_CANCELLED: Cancellation flag set, stopping stream immediately")
                continuation.finish()
                cleanupPartialStreamingMessages(
                    conversationId: conversationId,
                    assistantMessageId: assistantMessageId,
                    toolMessagesByExecutionId: toolMessagesByExecutionId
                )
                return LLMResponse(
                    content: accumulatedContent,
                    finishReason: "cancelled",
                    toolCalls: nil,
                    statefulMarker: statefulMarker
                )
            }
            do {
                try Task.checkCancellation()
            } catch {
                logger.info("STREAMING_CANCELLED: Task cancelled, stopping stream immediately")
                continuation.finish()
                cleanupPartialStreamingMessages(
                    conversationId: conversationId,
                    assistantMessageId: assistantMessageId,
                    toolMessagesByExecutionId: toolMessagesByExecutionId
                )
                throw CancellationError()
            }

            /// CRITICAL: Determine which message this chunk belongs to
            /// - Tool chunks (isToolMessage=true) → create/update TOOL message
            /// - Regular chunks (isToolMessage=false) → update ASSISTANT message
            let targetMessageId: UUID

            if chunk.isToolMessage == true, chunk.toolName == "thinking" {
                /// Thinking chunk from provider (e.g., MiniMax <think> tags).
                /// Create a proper .thinking message via addThinkingMessage().
                let thinkingText = chunk.toolDetails?.joined(separator: "\n") ?? ""
                if !thinkingText.isEmpty {
                    /// Accumulate thinking text for rawContent reconstruction.
                    accumulatedThinkingText += thinkingText

                    let enableReasoning = conversation.settings.enableReasoning
                    let thinkMsgId = conversation.messageBus?.addThinkingMessage(
                        id: UUID(),
                        reasoningContent: thinkingText,
                        showReasoning: enableReasoning
                    ) ?? UUID()
                    thinkingMessageId = thinkMsgId
                    targetMessageId = thinkMsgId
                    logger.debug("THINKING_MESSAGE_CREATE: id=\(thinkMsgId.uuidString.prefix(8)) len=\(thinkingText.count) reasoning=\(enableReasoning)")
                } else {
                    /// Empty thinking chunk - skip.
                    continue
                }
            } else if chunk.isToolMessage == true, let executionId = chunk.toolExecutionId {
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
                    var cleanedAccumulated = stripSystemReminders(from: newAccumulated)

                    /// Extract session naming marker during streaming (before stripping)
                    /// The marker builds up across chunks - extract title once complete
                    if cleanedAccumulated.contains("<!--session:") && cleanedAccumulated.contains("-->") {
                        extractAndApplySessionName(from: cleanedAccumulated, conversationId: conversationId)

                        /// Strip session naming markers so they don't flash in UI
                        cleanedAccumulated = cleanedAccumulated.replacingOccurrences(
                            of: #"\s*<!--session:\{[^}]*\}-->\s*"#,
                            with: "",
                            options: .regularExpression
                        )
                    }

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

                /// Capture statefulMarker for GitHub Copilot session continuity. Ensures tool calling iterations share the same conversation session, reducing token cost.
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
        /// Stream completed successfully - exit retry loop
        logger.debug("AUTH_RETRY_DEBUG: Stream completed normally, breaking retry loop")
        break authRetryLoop
        } catch let error as ProviderError where error.isAuthRecoverable && authRetryAttempts < maxAuthRetries && chunkCount == 0 {
            /// Token was refreshed after 401 - retry with a fresh stream
            authRetryAttempts += 1
            logger.info("AUTH_RETRY: Stream threw authRecoverable before any chunks, retrying (\(authRetryAttempts)/\(maxAuthRetries))")
            streamingResponse = try await endpointManager.processStreamingChatCompletion(finalRequest)
            continue authRetryLoop
        } catch {
            logger.error("AUTH_RETRY_DEBUG: Stream threw non-recoverable error: \(error), type=\(type(of: error))")
            /// Stream errors also leak partial state - the assistant message was
            /// created mid-stream and any tool messages too. Clean up before
            /// propagating the error.
            cleanupPartialStreamingMessages(
                conversationId: conversationId,
                assistantMessageId: assistantMessageId,
                toolMessagesByExecutionId: toolMessagesByExecutionId
            )
            throw error
        }
        } // end authRetryLoop

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
                let argumentsString = toolCall.function.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                var arguments: [String: Any] = [:]
                
                // Handle empty arguments (some tools like list_system_prompts take no params)
                // An empty string or "{}" should result in an empty dictionary
                if !argumentsString.isEmpty && argumentsString != "{}" {
                    let argumentsData = argumentsString.data(using: .utf8) ?? Data()
                    if let parsedArgs = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] {
                        arguments = parsedArgs
                    } else {
                        logger.warning("callLLMStreaming: Failed to parse arguments for tool '\(toolCall.function.name)': \(argumentsString)")
                        // Still create the tool call with empty arguments - don't skip it!
                    }
                }
                
                parsedToolCalls?.append(ToolCall(
                    id: toolCall.id,
                    name: toolCall.function.name,
                    arguments: arguments
                ))
                logger.debug("callLLMStreaming: Parsed tool call '\(toolCall.function.name)' with \(arguments.count) arguments")
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

        /// Strip residual <think>...</think> tags from final content.
        /// Some providers (MiniMax) include thinking in <think> tags that may
        /// not be fully intercepted by the streaming parser. Clean up any remnants.
        if finalContent.contains("<think>") || finalContent.contains("</think>") {
            /// Remove complete <think>...</think> blocks.
            while let startRange = finalContent.range(of: "<think>"),
                  let endRange = finalContent.range(of: "</think>", range: startRange.upperBound..<finalContent.endIndex) {
                finalContent.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            }
            /// Remove any orphaned tags.
            finalContent = finalContent.replacingOccurrences(of: "<think>", with: "")
            finalContent = finalContent.replacingOccurrences(of: "</think>", with: "")
            finalContent = finalContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// CRITICAL: Complete streaming for all tool messages
        /// Tool messages were created during streaming, now mark them as complete
        for (executionId, toolMessageId) in toolMessagesByExecutionId {
            conversation.messageBus?.completeStreamingMessage(id: toolMessageId)
            logger.debug("TOOL_MESSAGE_COMPLETE: executionId=\(executionId.prefix(8)) messageId=\(toolMessageId.uuidString.prefix(8))")
        }

        if finalToolCalls?.isEmpty != false {
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
        } else if let calls = finalToolCalls {
            logger.debug("callLLMStreaming: Using native tool calls from provider (\(calls.count) calls)")
        }

        /// CRITICAL: Strip system-reminder tags before returning/saving
        /// Claude may echo back <system-reminder> content - must filter it out
        finalContent = stripSystemReminders(from: finalContent)

        logger.debug("callLLMStreaming: Streaming complete - finishReason=\(finishReason ?? "nil"), content length=\(finalContent.count), toolCalls=\(finalToolCalls?.count ?? 0), statefulMarker=\(statefulMarker != nil ? "present" : "nil")")

        /// CRITICAL: Complete streaming message in MessageBus with final content
        /// This marks the message as no longer streaming and ensures persistence
        /// Content was already updated via updateStreamingMessage() calls during chunking
        if let msgId = assistantMessageId {
            /// CRITICAL: Add toolCalls metadata to message BEFORE completing
            /// This fixes Gemini (and other providers) tool call message format
            /// Without this, tool calls appear as plain text instead of proper metadata
            if let toolCalls = finalToolCalls, !toolCalls.isEmpty {
                /// Convert ToolCall to SimpleToolCall for message storage
                let simpleToolCalls = AgentOrchestrator.makeSimpleToolCalls(toolCalls)
                
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
        } else if let toolCalls = finalToolCalls, !toolCalls.isEmpty {
            /// No assistant message was created during streaming (response had only tool_calls,
            /// no content chunks ever arrived). Create one now with just the tool_calls so the
            /// tool result messages have a parent assistant message in conversation.messages.
            /// Otherwise tool results become orphans on conversation reload.
            let simpleToolCalls = AgentOrchestrator.makeSimpleToolCalls(toolCalls)
            conversation.messageBus?.addAssistantMessage(
                content: "",
                timestamp: Date(),
                toolCalls: simpleToolCalls
            )
            logger.info("MESSAGEBUS_TOOLCALLS_ONLY: Created assistant message with only tool_calls (no content) for \(simpleToolCalls.count) tool calls")
        } else {
            logger.info("MESSAGEBUS_COMPLETE: No assistant message created (only tool calls executed)")
        }

        return LLMResponse(
            content: finalContent,
            finishReason: finishReason ?? "stop",
            toolCalls: finalToolCalls,
            statefulMarker: statefulMarker,
            rawContent: !accumulatedThinkingText.isEmpty
                ? "<think>\(accumulatedThinkingText)</think>\n\(finalContent)"
                : nil
        )
    }

    /// Clean up partially-streamed messages when the stream is cancelled or errors
    /// mid-flight. Without this, the assistant message (and any tool messages
    /// created during streaming) stay in the messageBus with `isStreaming=true`
    /// forever, which:
    /// 1. Shows a stuck "streaming..." indicator in the UI
    /// 2. Persists to disk on next save as a streaming message
    /// 3. Causes MessageValidator to flag it as orphaned (assistant has no
    ///    corresponding response from the LLM API)
    ///
    /// Called from the cancellation and error paths in callLLMStreaming.
    func cleanupPartialStreamingMessages(
        conversationId: UUID,
        assistantMessageId: UUID?,
        toolMessagesByExecutionId: [String: UUID]
    ) {
        guard let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) else {
            return
        }

        if let assistantId = assistantMessageId {
            conversation.messageBus?.completeStreamingMessage(id: assistantId)
            logger.info("STREAMING_CLEANUP: Completed partial assistant message \(assistantId.uuidString.prefix(8))")
        }

        for (_, toolMessageId) in toolMessagesByExecutionId {
            conversation.messageBus?.completeStreamingMessage(id: toolMessageId)
            logger.info("STREAMING_CLEANUP: Completed partial tool message \(toolMessageId.uuidString.prefix(8))")
        }
    }
}
