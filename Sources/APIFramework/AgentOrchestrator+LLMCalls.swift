// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConversationEngine
import MCPFramework
import ConfigurationSystem

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
        var userSystemPrompt = await MainActor.run {
            SystemPromptManager.shared.generateSystemPrompt(
                for: promptId,
                toolsEnabled: toolsEnabled,
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

        /// Inject conversation ID for memory operations.
        var systemPromptAdditions = """
        \(userSystemPrompt)

        CONVERSATION_ID: \(conversationId.uuidString)
        """

        /// Inject dynamic tool listing when tools are enabled
        if toolsEnabled {
            let tools = conversationManager.mcpManager.getAvailableTools()
            if !tools.isEmpty {
                var listing = "Available Tools:"
                for tool in tools {
                    let desc = tool.description.components(separatedBy: "\n").first ?? tool.description
                    listing += "\n- \(tool.name): \(desc)"
                }
                listing += "\n\nUse tools when the task requires action. Respond naturally for conversation."
                systemPromptAdditions += "\n\n" + listing
            }
        }

        /// Add working directory context when tools are enabled
        if toolsEnabled {
            let effectiveWorkingDir = conversationManager.getEffectiveWorkingDirectory(for: conversation)
            systemPromptAdditions += """


            # WORKING DIRECTORY CONTEXT

            Your current working directory is: `\(effectiveWorkingDir)`

            All file operations will execute relative to this directory by default.
            You do not need to run 'pwd' or ask about the starting directory - this IS your working directory.
            """
        }

        /// SHARED TOPIC CONTEXT INJECTION
        /// When a conversation is attached to a shared topic, inject topic awareness
        /// so the agent knows about the shared context and can use recall_history with topic_id
        if conversation.settings.useSharedData,
           let topicId = conversation.settings.sharedTopicId,
           let topicName = conversation.settings.sharedTopicName {
            systemPromptAdditions += """


            # SHARED TOPIC CONTEXT

            You are working within the shared topic: "\(topicName)"
            Topic ID: \(topicId.uuidString)

            **IMPORTANT: You already have access to data from this topic.** Context from other conversations
            in the "\(topicName)" topic is automatically retrieved and injected into your context on every request.
            Look for the "SHARED TOPIC CONVERSATION HISTORY" and "HIGH IMPORTANCE MESSAGES" sections in your
            system context - these contain real data from the topic that you should use to answer questions.

            This conversation shares memory and working files with other conversations in this topic.
            When answering questions, ALWAYS check the injected topic context first before claiming you
            don't have information. The data is already in your context.

            If you need MORE context beyond what was auto-injected, use the `recall_history` tool with:
            - topic_id: "\(topicId.uuidString)" to search across ALL conversations in this topic
            - Or omit topic_id to search only this conversation's archived history
            """
            logger.debug("callLLM: Injected shared topic context for topic '\(topicName)' (\(topicId.uuidString.prefix(8)))")
        }

        /// LTM INJECTION: Load and inject Long-Term Memory entries into system prompt
        /// This gives the agent access to learned discoveries, solutions, and patterns
        /// across sessions, scoped to the conversation or shared topic.
        do {
            let useSharedData = conversation.settings.useSharedData
            let sharedTopicId = conversation.settings.sharedTopicId
            let sharedTopicName = conversation.settings.sharedTopicName

            let ltmPath = LongTermMemory.resolveFilePath(
                conversationId: conversationId,
                sharedTopicId: sharedTopicId,
                sharedTopicName: sharedTopicName,
                useSharedData: useSharedData
            )

            let ltm = LongTermMemory.load(from: ltmPath)
            if ltm.totalEntries > 0 {
                let ltmBlock = ltm.formatForSystemPrompt()
                if !ltmBlock.isEmpty {
                    systemPromptAdditions += "\n\n" + ltmBlock
                    logger.info("callLLM: Injected LTM (\(ltm.totalEntries) entries) into system prompt")
                }
            }
        }

        /// Session naming: inject instruction for unnamed conversations so AI provides a title
        if conversation.title.hasPrefix("New Conversation") {
            systemPromptAdditions += """


            ## Session Title [MANDATORY]

            This conversation has no title. You MUST include this marker as the LAST line of your FIRST response:

            <!--session:{"title":"Your 3-6 Word Title"}-->

            Requirements:
            - 3-6 words, title case, specific to the topic
            - LAST line of response, on its own line
            - First response ONLY, never repeat
            - Example: <!--session:{"title":"Fix Authentication Token Bug"}-->
            """
            logger.debug("callLLM: Injected session naming instruction for unnamed conversation")
        }

        let systemPromptWithId = systemPromptAdditions

        logger.debug("callLLM: Generated system prompt from ID: \(promptId?.uuidString ?? "default"), length: \(systemPromptWithId.count) chars, toolsEnabled: \(toolsEnabled)")
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

        /// Add conversation messages (user requests + LLM responses only, no tool results) CRITICAL: Use contextMessages if available (after pruning), otherwise use full messages This allows context pruning to work transparently - UI shows full history, LLM gets pruned context.
        /// Filter out tool messages - they're stored by MessageBus during execution but the
        /// properly-structured versions (with correct assistant+tool_calls -> tool result ordering)
        /// are in internalMessages. Including them here creates ordering violations.
        var messagesToSend = (conversation.contextMessages ?? conversation.messages).filter { !$0.isToolMessage }

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

        /// Mini prompt reminder - user's enabled mini prompts (instructions)
        if let miniPromptReminder = miniPromptReminderContent {
            messages.append(createSystemReminder(content: miniPromptReminder, model: model))
            /// Record successful injection to prevent repeating
            MiniPromptReminderInjector.shared.recordInjection(
                conversationId: conversation.id,
                enabledMiniPromptIds: conversation.enabledMiniPromptIds
            )
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

        /// Get model's actual context limit for MessageValidator budget calculation
        let modelContextLimit = await tokenCounter.getContextSize(modelName: model)
        logger.debug("CONTEXT: Model '\(model)' has context limit of \(modelContextLimit) tokens")

        /// CONTEXT MANAGEMENT: Use MessageValidator (CLIO-style) for budget-based context trimming.
        /// Preserves tool_call/tool_result pairs, compresses dropped context into thread_summary,
        /// always keeps system prompt + most recent user message.
        let originalMessageCount = messages.count
        let truncationResult = MessageValidator.validateAndTruncateWithDropped(
            messages: messages,
            maxPromptTokens: modelContextLimit
        )
        messages = truncationResult.messages
        var yarnCompressed = truncationResult.wasTrimmed
        if yarnCompressed {
            logger.info("CONTEXT: MessageValidator trimmed \(originalMessageCount) -> \(messages.count) messages (\(truncationResult.droppedMessages.count) dropped)")

            // Archive dropped messages for later recall
            if !truncationResult.droppedMessages.isEmpty {
                Task {
                    do {
                        let droppedAsEnhanced = truncationResult.droppedMessages.compactMap { msg -> EnhancedMessage? in
                            guard let content = msg.content, !content.isEmpty else { return nil }
                            return EnhancedMessage(
                                content: content,
                                isFromUser: msg.role == "user"
                            )
                        }
                        if !droppedAsEnhanced.isEmpty {
                            _ = try await self.conversationManager.contextArchiveManager.archiveMessages(
                                droppedAsEnhanced,
                                conversationId: conversationId,
                                reason: .conversationTrimmed
                            )
                            self.logger.debug("CONTEXT: Archived \(droppedAsEnhanced.count) dropped messages for recall")
                        }
                    } catch {
                        self.logger.warning("CONTEXT: Failed to archive dropped messages: \(error)")
                    }
                }
            }
        } else {
            logger.debug("CONTEXT: Messages within budget, no trimming needed")
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

        /// Inject isExternalAPICall flag into samConfig for tool filtering. External API calls should never have user_collaboration tool (no UI to interact with).
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
                isExternalAPICall: isExternalAPICall
            )
        } else if isExternalAPICall {
            /// No samConfig provided but we're external API call - create one with just the flag.
            enhancedSamConfig = SAMConfig(isExternalAPICall: true)
        } else {
            enhancedSamConfig = nil
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
                    
                    /// CRITICAL: Re-validate size after compression to prevent 400 errors
                    /// GitHub Copilot and other providers enforce hard token limits (e.g., 64K for GitHub Copilot)
                    /// If compression didn't bring us under limit, force aggressive message trimming
                    var finalMessages = fixedCompressedMessages
                    let (postCompressionTokens, postCompressionSafe, _) = await validateRequestSize(
                        messages: finalMessages,
                        model: model,
                        tools: compressedRequestWithTools.tools
                    )
                    
                    if !postCompressionSafe {
                        logger.warning("POST_COMPRESSION_CHECK: Still exceeds limit (\(postCompressionTokens) tokens), forcing message trimming to prevent 400 error")
                        
                        /// Force trim to 70% of context limit by removing oldest messages
                        let targetTokens = Int(Double(contextLimit) * 0.70)
                        var currentTokens = postCompressionTokens
                        var trimCount = 0
                        
                        while currentTokens > targetTokens && finalMessages.count > 2 {
                            /// Remove oldest message (keep system prompt at index 0 if present)
                            let startIndex = finalMessages[0].role == "system" ? 1 : 0
                            if finalMessages.count > startIndex {
                                let removed = finalMessages.remove(at: startIndex)
                                let removedTokens = await tokenCounter.estimateTokensRemote(text: removed.content ?? "")
                                currentTokens -= removedTokens
                                trimCount += 1
                            } else {
                                break
                            }
                        }
                        
                        logger.warning("POST_COMPRESSION_TRIM: Removed \(trimCount) oldest messages, \(postCompressionTokens) → \(currentTokens) tokens")
                    }
                    
                    let finalCompressedRequest = OpenAIChatRequest(
                        model: compressedRequestWithTools.model,
                        messages: finalMessages,
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

        /// MLX Tool Call Parser - Extract tool calls from JSON code blocks MLX models don't have native tool calling support, they output JSON blocks or [TOOL_CALLS] format We need to parse these and create ToolCall objects.
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
            statefulMarker: statefulMarker
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
        var userSystemPrompt = await MainActor.run {
            SystemPromptManager.shared.generateSystemPrompt(
                for: promptId,
                toolsEnabled: toolsEnabled,
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

        /// Inject conversation ID for memory operations.
        var systemPromptAdditions = """
        \(userSystemPrompt)

        CONVERSATION_ID: \(conversationId.uuidString)
        """

        /// Inject dynamic tool listing when tools are enabled
        if toolsEnabled {
            let tools = conversationManager.mcpManager.getAvailableTools()
            if !tools.isEmpty {
                var listing = "Available Tools:"
                for tool in tools {
                    let desc = tool.description.components(separatedBy: "\n").first ?? tool.description
                    listing += "\n- \(tool.name): \(desc)"
                }
                listing += "\n\nUse tools when the task requires action. Respond naturally for conversation."
                systemPromptAdditions += "\n\n" + listing
            }
        }

        /// Add working directory context when tools are enabled
        if toolsEnabled {
            let effectiveWorkingDir = conversationManager.getEffectiveWorkingDirectory(for: conversation)
            systemPromptAdditions += """


            # WORKING DIRECTORY CONTEXT

            Your current working directory is: `\(effectiveWorkingDir)`

            All file operations will execute relative to this directory by default.
            You do not need to run 'pwd' or ask about the starting directory - this IS your working directory.
            """
        }

        /// SHARED TOPIC CONTEXT INJECTION
        /// When a conversation is attached to a shared topic, inject topic awareness
        /// so the agent knows about the shared context and can use recall_history with topic_id
        if conversation.settings.useSharedData,
           let topicId = conversation.settings.sharedTopicId,
           let topicName = conversation.settings.sharedTopicName {
            systemPromptAdditions += """


            # SHARED TOPIC CONTEXT

            You are working within the shared topic: "\(topicName)"
            Topic ID: \(topicId.uuidString)

            **IMPORTANT: You already have access to data from this topic.** Context from other conversations
            in the "\(topicName)" topic is automatically retrieved and injected into your context on every request.
            Look for the "SHARED TOPIC CONVERSATION HISTORY" and "HIGH IMPORTANCE MESSAGES" sections in your
            system context - these contain real data from the topic that you should use to answer questions.

            This conversation shares memory and working files with other conversations in this topic.
            When answering questions, ALWAYS check the injected topic context first before claiming you
            don't have information. The data is already in your context.

            If you need MORE context beyond what was auto-injected, use the `recall_history` tool with:
            - topic_id: "\(topicId.uuidString)" to search across ALL conversations in this topic
            - Or omit topic_id to search only this conversation's archived history
            """
            logger.debug("callLLMStreaming: Injected shared topic context for topic '\(topicName)' (\(topicId.uuidString.prefix(8)))")
        }

        /// LTM INJECTION: Load and inject Long-Term Memory entries into system prompt
        do {
            let useSharedData = conversation.settings.useSharedData
            let sharedTopicId = conversation.settings.sharedTopicId
            let sharedTopicName = conversation.settings.sharedTopicName

            let ltmPath = LongTermMemory.resolveFilePath(
                conversationId: conversationId,
                sharedTopicId: sharedTopicId,
                sharedTopicName: sharedTopicName,
                useSharedData: useSharedData
            )

            let ltm = LongTermMemory.load(from: ltmPath)
            if ltm.totalEntries > 0 {
                let ltmBlock = ltm.formatForSystemPrompt()
                if !ltmBlock.isEmpty {
                    systemPromptAdditions += "\n\n" + ltmBlock
                    logger.info("callLLMStreaming: Injected LTM (\(ltm.totalEntries) entries) into system prompt")
                }
            }
        }

        /// Session naming: inject instruction for unnamed conversations so AI provides a title
        if conversation.title.hasPrefix("New Conversation") {
            systemPromptAdditions += """


            ## Session Title [MANDATORY]

            This conversation has no title. You MUST include this marker as the LAST line of your FIRST response:

            <!--session:{"title":"Your 3-6 Word Title"}-->

            Requirements:
            - 3-6 words, title case, specific to the topic
            - LAST line of response, on its own line
            - First response ONLY, never repeat
            - Example: <!--session:{"title":"Fix Authentication Token Bug"}-->
            """
            logger.debug("callLLMStreaming: Injected session naming instruction for unnamed conversation")
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

            /// Skip tool messages from conversation history - these are stored by MessageBus
            /// during tool execution but the properly-structured versions (with correct
            /// assistant+tool_calls -> tool result ordering) are in internalMessages.
            /// Including them here creates duplicates and ordering violations that cause
            /// API errors ("messages with role 'tool' must follow 'tool_calls'").
            if msg.isToolMessage {
                return false
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
                /// Record successful injection to prevent repeating
                MiniPromptReminderInjector.shared.recordInjection(
                    conversationId: conversation.id,
                    enabledMiniPromptIds: conversation.enabledMiniPromptIds
                )
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

        logger.debug("callLLMStreaming: Built complete message array with \(messages.count) messages (before alternation fix)")

        /// CRITICAL: For Claude models via DIRECT Anthropic provider, batch consecutive tool results
        /// Claude Messages API requires ALL tool results from one iteration in ONE user message
        /// This fixes the tool result batching issue that caused workflow loops
        /// 
        /// IMPORTANT: Do NOT batch for GitHub Copilot + Claude!
        /// GitHub Copilot's API handles Claude conversion internally and expects OpenAI format
        /// Batching causes the marker to be buried in alternation merging
        let isDirectAnthropicProvider = model.lowercased().hasPrefix("anthropic/")
        let isClaudeModel = modelLower.contains("claude")
        
        if isClaudeModel && isDirectAnthropicProvider {
            messages = batchToolResultsForClaude(messages)
            logger.debug("callLLMStreaming: Applied Claude tool result batching for direct Anthropic provider")
        } else if isClaudeModel {
            logger.debug("callLLMStreaming: Skipping Claude batching (not direct Anthropic provider - proxy will handle conversion)")
        }

        /// CRITICAL: Fix message alternation BEFORE YARN compression
        /// Claude requires strict user/assistant alternation with no empty messages
        /// This MUST happen before YARN because YARN compresses individual messages
        /// If we merge AFTER YARN, we concatenate compressed content and blow up token count!
        messages = ensureMessageAlternation(messages)
        logger.debug("callLLMStreaming: Applied message alternation fix - \(messages.count) messages after merging")

        /// Get model context limit for MessageValidator budget calculation
        let modelContextLimit = await tokenCounter.getContextSize(modelName: model)
        logger.debug("CONTEXT: Model has context limit of \(modelContextLimit) tokens")

        /// CONTEXT MANAGEMENT: Use MessageValidator (CLIO-style) for budget-based context trimming.
        let originalMessageCount = messages.count
        let truncationResult = MessageValidator.validateAndTruncateWithDropped(
            messages: messages,
            maxPromptTokens: modelContextLimit
        )
        messages = truncationResult.messages
        if truncationResult.wasTrimmed {
            logger.info("CONTEXT: MessageValidator trimmed \(originalMessageCount) -> \(messages.count) messages (\(truncationResult.droppedMessages.count) dropped)")

            // Archive dropped messages for later recall
            if !truncationResult.droppedMessages.isEmpty {
                Task {
                    do {
                        let droppedAsEnhanced = truncationResult.droppedMessages.compactMap { msg -> EnhancedMessage? in
                            guard let content = msg.content, !content.isEmpty else { return nil }
                            return EnhancedMessage(
                                content: content,
                                isFromUser: msg.role == "user"
                            )
                        }
                        if !droppedAsEnhanced.isEmpty {
                            _ = try await self.conversationManager.contextArchiveManager.archiveMessages(
                                droppedAsEnhanced,
                                conversationId: conversationId,
                                reason: .conversationTrimmed
                            )
                            self.logger.debug("CONTEXT: Archived \(droppedAsEnhanced.count) dropped messages for recall")
                        }
                    } catch {
                        self.logger.warning("CONTEXT: Failed to archive dropped messages: \(error)")
                    }
                }
            }
        }

        logger.debug("callLLMStreaming: Request has \(messages.count) messages (after YARN)")

        /// Log statefulMarker presence for debugging.
        if let marker = statefulMarker {
            logger.debug("callLLMStreaming: Including statefulMarker from previous iteration: \(marker.prefix(20))...")
        }

        /// Inject isExternalAPICall flag into samConfig for tool filtering. External API calls should never have user_collaboration tool (no UI to interact with).
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
                isExternalAPICall: isExternalAPICall
            )
        } else if isExternalAPICall {
            /// No samConfig provided but we're external API call - create one with just the flag.
            enhancedSamConfig = SAMConfig(isExternalAPICall: true)
        } else {
            enhancedSamConfig = nil
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

        /// Track tool messages by execution ID to create separate cards for each tool call
        var toolMessagesByExecutionId: [String: UUID] = [:]

        /// Track accumulated content separately for each message
        var accumulatedContentByMessageId: [UUID: String] = [:]

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
}
