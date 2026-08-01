// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConversationEngine
import MCPFramework
import ConfigurationSystem
import SecurityFramework

/// Shared request preparation for callLLM and callLLMStreaming.
///
/// Phase 5 of the context management refactor extracted the request-prep
/// pipeline that was duplicated between the non-streaming and streaming paths.
/// Both paths built the same system prompt, dynamic context, Claude pinned-message
/// userContext, automatic context retrieval, reminders, custom instructions, and
/// KV-cache dynamic context. Same logic, copy-pasted. When one path diverged from
/// the other (e.g. the tool_calls persistence bug fixed in 0201306), it diverged
/// silently and only one path picked up the fix.
///
/// All extractors below are stateless and operate on the messages array in-place
/// (with return value for callers that want the side-effects captured). Every
/// helper accepts the conversation + model + samConfig so future fixes apply to
/// both paths automatically.

extension AgentOrchestrator {

    // MARK: - System prompt

    /// Build the static system prompt and the dynamic per-turn context block.
    ///
    /// The static system prompt is byte-identical across turns (for KV cache
    /// stability): user-configured prompt + personality, sanitized for invisible
    /// character injection vectors.
    ///
    /// The dynamic context is NOT byte-identical (changes per turn: working dir,
    /// session title, LTM entries). It is meant to be appended to the last user
    /// message inside `<userContext>...</userContext>` tags so the system message
    /// prefix stays static.
    func buildSystemPromptAndDynamicContext(
        conversation: ConversationModel,
        conversationId: UUID,
        model: String,
        samConfig: SAMConfig?,
        loggerPrefix: String
    ) async -> (systemPrompt: String, dynamicContext: String) {
        let defaultPromptId = await MainActor.run {
            SystemPromptManager.shared.selectedConfigurationId
        }
        let promptId = conversation.settings.selectedSystemPromptId ?? defaultPromptId
        logger.debug("\(loggerPrefix): promptId=\(promptId?.uuidString ?? "nil"), toolsEnabled=\(samConfig?.mcpToolsEnabled ?? true)")

        let toolsEnabled = samConfig?.mcpToolsEnabled ?? true
        var userSystemPrompt = await MainActor.run {
            SystemPromptManager.shared.generateSystemPrompt(
                for: promptId,
                toolsEnabled: toolsEnabled,
                model: model
            )
        }

        // Personality merge - inject right after Core Identity, not at the end.
        // The personality establishes SAM's helpful, approachable character.
        // Putting it at the end buries it under thousands of words of agent protocol.
        if let personalityId = conversation.settings.selectedPersonalityId {
            let personalityManager = PersonalityManager()
            if let personality = personalityManager.getPersonality(id: personalityId) {
                let personalityInstructions = personality.generatePromptAdditions()
                if !personalityInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Find the end of the Core Identity section and insert personality after it.
                    // Core Identity ends at the "## Tool Usage" heading or equivalent.
                    if let range = userSystemPrompt.range(of: "\n## ") {
                        let insertionPoint = range.lowerBound
                        userSystemPrompt.insert(
                            contentsOf: "\n\n" + personalityInstructions + "\n",
                            at: insertionPoint
                        )
                    } else {
                        // Fallback: append if no section marker found
                        userSystemPrompt += "\n\n" + personalityInstructions
                    }
                    logger.info("\(loggerPrefix): Injected personality '\(personality.name)' after Core Identity (\(personalityInstructions.count) chars)")
                }
            }
        }

        // SECURITY: Strip invisible Unicode used for prompt injection vectors.
        userSystemPrompt = SecurityPipeline.sanitizeInputNonNil(userSystemPrompt)

        var dynamicContext = "CONVERSATION_ID: \(conversationId.uuidString)"

        if toolsEnabled {
            // memory_operations only exposed to conversations in a shared topic.
            let isSharedTopic = conversation.settings.useSharedData
                && conversation.settings.sharedTopicId != nil
                && conversation.settings.sharedTopicName != nil
            let tools = conversationManager.mcpManager.getAvailableTools()
                .filter { $0.name != "memory_operations" || isSharedTopic }
            if !tools.isEmpty {
                var listing = "\n\nAvailable Tools:"
                for tool in tools {
                    let desc = tool.description.components(separatedBy: "\n").first ?? tool.description
                    listing += "\n- \(tool.name): \(desc)"
                }
                listing += "\n\nUse tools when the task requires action. Respond naturally for conversation."
                dynamicContext += listing
            }
        }

        if toolsEnabled {
            let effectiveWorkingDir = conversationManager.getEffectiveWorkingDirectory(for: conversation)
            dynamicContext += """


            # WORKING DIRECTORY CONTEXT

            Your current working directory is: `\(effectiveWorkingDir)`

            All file operations will execute relative to this directory by default.
            You do not need to run 'pwd' or ask about the starting directory - this IS your working directory.
            """
        }

        if conversation.settings.useSharedData,
           let topicId = conversation.settings.sharedTopicId,
           let topicName = conversation.settings.sharedTopicName {
            dynamicContext += """


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
            logger.debug("\(loggerPrefix): Injected shared topic context for '\(topicName)'")
        }

        // LTM is gated to shared-topic conversations only.
        let hasSharedTopic = conversation.settings.useSharedData
            && conversation.settings.sharedTopicId != nil
            && conversation.settings.sharedTopicName != nil
        if hasSharedTopic,
           let sharedTopicId = conversation.settings.sharedTopicId,
           let sharedTopicName = conversation.settings.sharedTopicName {
            let ltmPath = LongTermMemory.resolveFilePath(
                conversationId: conversationId,
                sharedTopicId: sharedTopicId,
                sharedTopicName: sharedTopicName,
                useSharedData: conversation.settings.useSharedData
            )
            let ltm = LongTermMemory.load(from: ltmPath)
            if ltm.totalEntries > 0 {
                let ltmBlock = ltm.formatForSystemPrompt()
                if !ltmBlock.isEmpty {
                    dynamicContext += "\n\n" + ltmBlock
                    logger.info("\(loggerPrefix): Injected shared-topic LTM (\(ltm.totalEntries) entries)")
                }
            }
        }

        // Session naming - only present on first turn.
        if conversation.title.hasPrefix("New Conversation") {
            dynamicContext += """


            ## Session Title [MANDATORY]

            This conversation has no title. You MUST include this marker as the LAST line of your FIRST response:

            <!--session:{"title":"Your 3-6 Word Title"}-->

            Requirements:
            - 3-6 words, title case, specific to the topic
            - LAST line of response, on its own line
            - First response ONLY, never repeat
            - Example: <!--session:{"title":"Fix Authentication Token Bug"}-->
            """
            logger.debug("\(loggerPrefix): Injected session naming instruction")
        }

        return (userSystemPrompt, dynamicContext)
    }

    // MARK: - Claude pinned-message userContext

    /// Claude models lose pinned-message context between turns (they don't carry
    /// over conversation history the way OpenAI does via statefulMarker). Per the
    /// Claude Messages API guidance, re-extract `<userContext>` blocks from ALL
    /// pinned messages on every request and inject them as a system message.
    func appendClaudePinnedUserContext(
        to messages: inout [OpenAIChatMessage],
        conversation: ConversationModel,
        model: String,
        loggerPrefix: String
    ) {
        guard model.lowercased().contains("claude") else { return }

        var extractedContexts: [String] = []
        for pinnedMessage in conversation.messages where pinnedMessage.isPinned {
            let content = pinnedMessage.content
            if let userContextStart = content.range(of: "\n\n<userContext>\n"),
               let userContextEnd = content.range(of: "\n</userContext>", range: userContextStart.upperBound..<content.endIndex) {
                let userContextContent = String(content[userContextStart.upperBound..<userContextEnd.lowerBound])
                extractedContexts.append(userContextContent)
            }
        }

        guard !extractedContexts.isEmpty else { return }

        let claudeContextMessage = """
        ## User Context (Persistent)

        This context was provided in pinned messages and applies to all turns of this conversation:

        \(extractedContexts.joined(separator: "\n\n---\n\n"))
        """

        messages.append(OpenAIChatMessage(role: "system", content: claudeContextMessage))
        logger.info("CLAUDE_CONTEXT: Injected userContext from \(extractedContexts.count) pinned message(s) (\(claudeContextMessage.count) chars)")
    }

    // MARK: - Automatic context retrieval

    /// Run the semantic-search based context retrieval (pinned + relevant memories)
    /// and append the result as a system message. The retrievedMessageIds inout
    /// parameter is updated to prevent the same message from being re-injected on
    /// subsequent iterations.
    func appendContextRetrieval(
        to messages: inout [OpenAIChatMessage],
        conversation: ConversationModel,
        currentUserMessage: String,
        iteration: Int,
        retrievedMessageIds: inout Set<UUID>,
        caller: String,
        loggerPrefix: String
    ) async {
        if let retrievedContext = await retrieveRelevantContext(
            conversation: conversation,
            currentUserMessage: currentUserMessage,
            iteration: iteration,
            caller: caller,
            retrievedMessageIds: &retrievedMessageIds
        ) {
            messages.append(OpenAIChatMessage(role: "system", content: retrievedContext))
            logger.debug("\(loggerPrefix): Added automatic context retrieval (\(retrievedContext.count) chars)")
        }
    }

    // MARK: - Reminders

    /// Inject document-import and memory reminders as system messages (VS Code
    /// Copilot pattern: high salience reminders visible to the model).
    ///
    /// Todo reminders are handled separately by the caller because the streaming
    /// path injects them at the END of messages (different position) while the
    /// non-streaming path injects them BEFORE the user message.
    func appendImportAndMemoryReminders(
        to messages: inout [OpenAIChatMessage],
        conversation: ConversationModel,
        model: String,
        loggerPrefix: String
    ) {
        if DocumentImportReminderInjector.shared.shouldInjectReminder(conversationId: conversation.id) {
            if let docReminder = DocumentImportReminderInjector.shared.formatDocumentReminder(conversationId: conversation.id) {
                messages.append(createSystemReminder(content: docReminder, model: model))
                logger.debug("\(loggerPrefix): Injected document import reminder (\(DocumentImportReminderInjector.shared.getImportedCount(for: conversation.id)) docs)")
            }
        }

        if MemoryReminderInjector.shared.shouldInjectReminder(conversationId: conversation.id) {
            if let memoryReminder = MemoryReminderInjector.shared.formatMemoryReminder(conversationId: conversation.id) {
                messages.append(createSystemReminder(content: memoryReminder, model: model))
                logger.debug("\(loggerPrefix): Injected memory reminder (\(MemoryReminderInjector.shared.getStoredCount(for: conversation.id)) memories)")
            }
        }
    }

    // MARK: - Custom instructions + dynamic context

    /// One-time persist custom instructions to conversation history (so the model
    /// retains context for its decisions even after the instruction is disabled)
    /// and inject them into the last user message for immediate salience.
    func injectCustomInstructions(
        into messages: inout [OpenAIChatMessage],
        conversation: ConversationModel
    ) {
        guard !conversation.enabledCustomInstructionIds.isEmpty else { return }
        let customInstructionText = CustomInstructionManager.shared.getInjectedText(
            for: conversation.id,
            enabledIds: conversation.enabledCustomInstructionIds
        )
        guard !customInstructionText.isEmpty else { return }

        // One-time persist (hidden from UI via isSystemGenerated).
        let alreadyPersisted = conversation.messages.contains { msg in
            msg.isFromUser && msg.content.contains(customInstructionText.prefix(100))
        }
        if !alreadyPersisted {
            let persistContent = "<userContext>\n\(customInstructionText)\n</userContext>"
            conversation.messageBus?.addUserMessage(
                content: persistContent,
                isPinned: true,
                isSystemGenerated: true
            )
            logger.info("callLLM: Persisted custom instruction content as hidden message (\(customInstructionText.count) chars)")
        }

        // Ephemeral injection into last user message.
        if let lastUserIndex = messages.lastIndex(where: { $0.role == "user" }) {
            let existingContent = messages[lastUserIndex].content ?? ""
            if !existingContent.contains(customInstructionText.prefix(100)) {
                let injectedContent = existingContent + "\n\n<userContext>\n\(customInstructionText)\n</userContext>"
                messages[lastUserIndex] = OpenAIChatMessage(role: "user", content: injectedContent)
                logger.info("callLLM: Ephemeral custom instruction injection into last user message (\(customInstructionText.count) chars)")
            }
        }
    }

    /// KV cache optimization: inject per-turn dynamic context into the last user
    /// message inside `<userContext>` tags. Keeps the system prompt byte-identical
    /// across turns (enabling cache reuse) while still giving the model access
    /// to changing context like working directory and LTM entries.
    func injectDynamicContextIntoLastUserMessage(
        into messages: inout [OpenAIChatMessage],
        dynamicContext: String,
        loggerPrefix: String
    ) {
        guard !dynamicContext.isEmpty else { return }
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == "user" }) else {
            logger.warning("\(loggerPrefix): No user message found for dynamic context injection")
            return
        }
        let existingContent = messages[lastUserIndex].content ?? ""
        let injectedContent = existingContent + "\n\n<userContext>\n\(dynamicContext)\n</userContext>"
        messages[lastUserIndex] = OpenAIChatMessage(role: "user", content: injectedContent)
        logger.debug("\(loggerPrefix): Injected dynamic context (\(dynamicContext.count) chars) into last user message for KV cache stability")
    }

    // MARK: - Context validation + archiving

    /// Run MessageValidator's budget walk + thread_summary compression and archive
    /// dropped messages for later recall. Returns the validated/truncated messages.
    func validateAndArchiveContext(
        messages: [OpenAIChatMessage],
        conversationId: UUID,
        model: String,
        loggerPrefix: String
    ) async -> [OpenAIChatMessage] {
        let modelContextLimit = await tokenCounter.getContextSize(modelName: model)
        let truncationResult = MessageValidator.validateAndTruncateWithDropped(
            messages: messages,
            maxPromptTokens: modelContextLimit
        )

        if truncationResult.wasTrimmed {
            logger.info("\(loggerPrefix): MessageValidator trimmed \(messages.count) -> \(truncationResult.messages.count) messages (\(truncationResult.droppedMessages.count) dropped)")

            if !truncationResult.droppedMessages.isEmpty {
                Task { [conversationManager, logger] in
                    do {
                        let droppedAsEnhanced = truncationResult.droppedMessages.compactMap { msg -> EnhancedMessage? in
                            guard let content = msg.content, !content.isEmpty else { return nil }
                            return EnhancedMessage(
                                content: content,
                                isFromUser: msg.role == "user"
                            )
                        }
                        if !droppedAsEnhanced.isEmpty {
                            _ = try await conversationManager.contextArchiveManager.archiveMessages(
                                droppedAsEnhanced,
                                conversationId: conversationId,
                                reason: .conversationTrimmed
                            )
                            logger.debug("\(loggerPrefix): Archived \(droppedAsEnhanced.count) dropped messages for recall")
                        }
                    } catch {
                        logger.warning("\(loggerPrefix): Failed to archive dropped messages: \(error)")
                    }
                }
            }
        } else {
            logger.debug("\(loggerPrefix): Messages within budget, no trimming needed")
        }

        return truncationResult.messages
    }

    // MARK: - Request building

    /// Build the SAMConfig with isExternalAPICall flag, and the base
    /// OpenAIChatRequest (without tools - those get injected next).
    /// User-configured sampling parameters (temperature, topP) are wired through;
    /// repetition penalty is per-provider.
    func buildBaseRequest(
        messages: [OpenAIChatMessage],
        conversation: ConversationModel,
        conversationId: UUID,
        model: String,
        iteration: Int,
        samConfig: SAMConfig?,
        statefulMarker: String?,
        streaming: Bool
    ) -> OpenAIChatRequest {
        let effectiveMaxTokens = max(conversation.settings.maxTokens ?? 8192, 4096)
        let samplingTemperature = conversation.settings.temperature
        let samplingTopP = conversation.settings.topP
        let samplingRepetitionPenalty: Double? = nil

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
                thinking: samConfig.thinking
            )
        } else if isExternalAPICall {
            enhancedSamConfig = SAMConfig(isExternalAPICall: true)
        } else {
            enhancedSamConfig = nil
        }

        return OpenAIChatRequest(
            model: model,
            messages: messages,
            temperature: samplingTemperature,
            topP: samplingTopP,
            repetitionPenalty: samplingRepetitionPenalty,
            maxTokens: effectiveMaxTokens,
            stream: streaming,
            samConfig: enhancedSamConfig,
            sessionId: conversationId.uuidString,
            statefulMarker: statefulMarker,
            iterationNumber: iteration
        )
    }

    /// Inject MCP tools into the base request via SharedConversationService, then
    /// apply message alternation (Claude requires strict user/assistant alternation
    /// with no empty messages) and validate tool message pairs as a safety net.
    func finalizeRequestWithToolsAndAlternation(
        baseRequest: OpenAIChatRequest,
        loggerPrefix: String
    ) async -> OpenAIChatRequest {
        let requestWithTools = await conversationService.injectMCPToolsIntoRequest(baseRequest)

        var messages = ensureMessageAlternation(requestWithTools.messages)
        messages = MessageValidator.validateToolMessagePairs(messages)
        logger.debug("\(loggerPrefix): Applied alternation + tool pair validation (\(messages.count) messages)")

        return OpenAIChatRequest(
            model: requestWithTools.model,
            messages: messages,
            temperature: requestWithTools.temperature,
            topP: requestWithTools.topP,
            repetitionPenalty: requestWithTools.repetitionPenalty,
            maxTokens: requestWithTools.maxTokens,
            stream: requestWithTools.stream,
            tools: requestWithTools.tools,
            samConfig: requestWithTools.samConfig,
            sessionId: requestWithTools.sessionId,
            statefulMarker: requestWithTools.statefulMarker,
            iterationNumber: requestWithTools.iterationNumber
        )
    }
}