// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConversationEngine
import MCPFramework
import ConfigurationSystem

// MARK: - Context Management

extension AgentOrchestrator {

    /// Automatically retrieve relevant context before LLM calls Combines pinned messages + semantic memory search for comprehensive context This ensures agents never lose critical information like initial requests or key decisions.
    @MainActor
    func retrieveRelevantContext(
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
        /// CRITICAL FIX: Use effectiveScopeId for shared topic support
        /// When a conversation has a shared topic, search the TOPIC's memory pool
        /// (not the conversation's empty per-conversation database).
        /// This ensures new conversations attached to a shared topic can access
        /// all previously stored memories from other conversations in that topic.
        let memoryScopeId = conversationManager.getEffectiveScopeId(for: conversation)
        let isSharedScope = memoryScopeId != conversation.id
        if isSharedScope {
            logger.debug("AUTO_RETRIEVAL: Using shared topic scope \(memoryScopeId) (topic: \(conversation.settings.sharedTopicName ?? "unknown"))")
        }

        do {
            let memories = try await conversationManager.memoryManager.retrieveRelevantMemories(
                for: currentUserMessage,
                conversationId: memoryScopeId,
                limit: 5,
                similarityThreshold: 0.3
            )

            if !memories.isEmpty {
                let scopeLabel = isSharedScope ? "shared topic" : "conversation"
                logger.debug("AUTO_RETRIEVAL: Retrieved \(memories.count) relevant memories via semantic search (\(scopeLabel) scope)")

                var memoryContext = "\n=== RELEVANT PRIOR CONTEXT (Semantic Search) ===\n"
                for (index, memory) in memories.enumerated() {
                    memoryContext += "\n[Memory \(index + 1) - Similarity: \(String(format: "%.2f", memory.similarity)), Importance: \(String(format: "%.2f", memory.importance))]:\n\(memory.content)\n"
                }
                contextParts.append(memoryContext)
            } else {
                logger.debug("AUTO_RETRIEVAL: No relevant memories found via semantic search (scope: \(memoryScopeId))")
            }
        } catch {
            logger.warning("AUTO_RETRIEVAL: Memory retrieval failed: \(error), continuing without memory context")
        }

        /// PHASE 2b: Shared Topic Archive Retrieval
        /// When a conversation is in a shared topic, automatically retrieve relevant archived
        /// context from other conversations in the topic. This gives the agent awareness of
        /// prior discussions, decisions, and context from the shared topic's history.
        if isSharedScope,
           let topicId = conversation.settings.sharedTopicId,
           let archiveProvider = RecallHistoryTool.sharedArchiveProvider {
            do {
                let topicChunks = try await archiveProvider.recallTopicHistory(
                    query: currentUserMessage,
                    topicId: topicId,
                    limit: 3
                )

                if !topicChunks.isEmpty {
                    logger.debug("AUTO_RETRIEVAL: Retrieved \(topicChunks.count) relevant topic archive chunks from shared topic \(topicId.uuidString.prefix(8))")

                    var topicContext = "\n=== SHARED TOPIC HISTORY (From Other Conversations) ===\n"
                    topicContext += "The following context was found in other conversations within the shared topic:\n"
                    for (index, chunk) in topicChunks.enumerated() {
                        topicContext += "\n[Topic Archive \(index + 1) - \(chunk.timeRange), \(chunk.messageCount) messages]:\n"
                        topicContext += "Summary: \(chunk.summary)\n"
                        if !chunk.keyTopics.isEmpty {
                            topicContext += "Topics: \(chunk.keyTopics.joined(separator: ", "))\n"
                        }
                        // Include a preview of the most relevant messages
                        let previewMessages = chunk.messages.prefix(3)
                        for msg in previewMessages {
                            let role = msg.isFromUser ? "USER" : "ASSISTANT"
                            let preview = String(msg.content.prefix(500))
                            topicContext += "  [\(role)]: \(preview)\n"
                        }
                    }
                    contextParts.append(topicContext)
                } else {
                    logger.debug("AUTO_RETRIEVAL: No relevant topic archive chunks found for shared topic \(topicId.uuidString.prefix(8))")
                }
            } catch {
                logger.warning("AUTO_RETRIEVAL: Topic archive retrieval failed: \(error), continuing without topic context")
            }
        }

        /// PHASE 2c: Direct Conversation Message Search for Shared Topics
        /// When memories and archives are empty (common: messages aren't auto-indexed into memory DBs),
        /// search the actual conversation messages of OTHER conversations in the shared topic.
        /// This is the primary data source since conversation content lives in ConversationModel.messages,
        /// not in the per-conversation memory.db (which is only populated by explicit memory_operations
        /// tool calls or document imports).
        if isSharedScope,
           let topicId = conversation.settings.sharedTopicId {

            /// Find all OTHER conversations in this topic (exclude current conversation)
            let topicConversations = conversationManager.conversations.filter {
                $0.settings.sharedTopicId == topicId && $0.id != conversation.id
            }

            if !topicConversations.isEmpty {
                /// Extract keywords from the user's message for relevance scoring
                let queryWords = Set(currentUserMessage.lowercased()
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { $0.count > 3 }  // Skip short words
                )

                /// Score and collect relevant messages from topic conversations
                var scoredMessages: [(message: ConfigurationSystem.EnhancedMessage, score: Double, conversationTitle: String)] = []

                for topicConversation in topicConversations {
                    let messages = topicConversation.messages.filter {
                        !$0.isToolMessage && !$0.isSystemGenerated && !$0.content.isEmpty
                    }

                    for msg in messages {
                        let contentLower = msg.content.lowercased()
                        var score = 0.0

                        /// Keyword match scoring
                        for word in queryWords {
                            if contentLower.contains(word) {
                                score += 1.0
                            }
                        }

                        /// Boost pinned and high-importance messages
                        if msg.isPinned { score += 2.0 }
                        score += msg.importance * 0.5

                        /// Include if any relevance detected, or if pinned/high-importance
                        if score > 0 {
                            scoredMessages.append((msg, score, topicConversation.title))
                        }
                    }
                }

                /// Sort by score and take top results
                scoredMessages.sort { $0.score > $1.score }
                let topMessages = scoredMessages.prefix(8)

                if !topMessages.isEmpty {
                    logger.debug("AUTO_RETRIEVAL: Found \(topMessages.count) relevant messages from \(topicConversations.count) other topic conversation(s)")

                    var topicMsgContext = "\n=== SHARED TOPIC CONVERSATION HISTORY ===\n"
                    topicMsgContext += "The following messages were found in other conversations within the \"\(conversation.settings.sharedTopicName ?? "shared")\" topic:\n"

                    for (index, item) in topMessages.enumerated() {
                        let role = item.message.isFromUser ? "USER" : "ASSISTANT"
                        /// Cap message preview to 800 chars to avoid overwhelming context
                        let preview = String(item.message.content.prefix(800))
                        topicMsgContext += "\n[Topic Message \(index + 1) from \"\(item.conversationTitle)\" - \(role), Relevance: \(String(format: "%.1f", item.score))]:\n\(preview)\n"
                    }
                    contextParts.append(topicMsgContext)
                } else {
                    logger.debug("AUTO_RETRIEVAL: No keyword-relevant messages found in \(topicConversations.count) other topic conversation(s)")
                }
            }
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
    func pruneConversationHistory(
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
    func shouldPruneContextBeforeLLMCall(
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
        let systemPrompt = await MainActor.run {
            SystemPromptManager.shared.generateSystemPrompt(
                for: promptId
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



    /// Calculate hash of message array content for compression detection
    func messageFingerprint(_ messages: [OpenAIChatMessage]) -> String {
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
    func processAllMessagesWithYARN(
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
    func validateRequestSize(
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
    func calculatePayloadSize(_ messages: [OpenAIChatMessage]) -> Int {
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
    func enforcePayloadSizeLimit(_ messages: inout [OpenAIChatMessage], maxBytes: Int = 16000) -> Bool {
        let initialSize = calculatePayloadSize(messages)

        if initialSize <= maxBytes {
            self.logger.debug("PAYLOAD_SIZE: \(initialSize) bytes (under \(maxBytes) limit)")
            return false  /// No trimming needed
        }

        self.logger.warning("PAYLOAD_SIZE: \(initialSize) bytes exceeds limit (\(maxBytes)), trimming oldest message pairs")

        var currentSize = initialSize
        var removedCount = 0

        /// CRITICAL FIX: Remove oldest message PAIRS to avoid orphaning tool results
        /// Tool messages must stay paired with their corresponding assistant+toolcalls message
        /// Otherwise the LLM sees tool results without context → loops
        while currentSize > maxBytes && messages.count > 2 {
            /// Check if first message is assistant with tool calls
            if messages[0].role == "assistant" && (messages[0].toolCalls?.isEmpty == false) {
                /// Find the matching tool result(s) after this assistant message
                var pairEnd = 1
                while pairEnd < messages.count && messages[pairEnd].role == "tool" {
                    pairEnd += 1
                }
                
                /// Remove the entire pair (assistant+toolcalls + all tool results)
                let pairSize = (0..<pairEnd).reduce(0) { size, idx in
                    var msgSize = messages[idx].content?.utf8.count ?? 0
                    if let toolCalls = messages[idx].toolCalls {
                        for toolCall in toolCalls {
                            msgSize += toolCall.function.arguments.utf8.count
                            msgSize += toolCall.function.name.utf8.count
                        }
                    }
                    return size + msgSize
                }
                
                /// Remove all messages in the pair
                for _ in 0..<pairEnd {
                    let removed = messages.removeFirst()
                    removedCount += 1
                    logger.debug("PAYLOAD_SIZE: Removed message (role=\(removed.role), part of pair)")
                }
                
                currentSize -= pairSize
            } else {
                /// Not a tool call pair, just remove the single message
                let removed = messages.removeFirst()
                removedCount += 1

                if let content = removed.content {
                    currentSize -= content.utf8.count
                }
                if let toolCalls = removed.toolCalls {
                    for toolCall in toolCalls {
                        let args = toolCall.function.arguments
                        currentSize -= args.utf8.count
                        currentSize -= toolCall.function.name.utf8.count
                    }
                }
            }
        }

        self.logger.info("PAYLOAD_SIZE: Removed \(removedCount) oldest messages (kept pairs together), reduced from \(initialSize) to \(currentSize) bytes")
        return true  /// Trimming occurred
    }
}
