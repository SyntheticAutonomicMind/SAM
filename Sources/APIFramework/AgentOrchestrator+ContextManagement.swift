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
        /// Phase 3 (high-importance filter) was removed in the CLIO sync. It duplicated
        /// context already preserved by MessageValidator's thread_summary compression,
        /// added per-iteration scan cost, and could mislead the model by re-presenting
        /// messages from history. MessageValidator now owns the "preserve important
        /// context across long sessions" responsibility.

        /// Combine all context parts if any exist.
        if contextParts.isEmpty {
            logger.debug("AUTO_RETRIEVAL: No additional context retrieved (no pinned messages, no relevant memories)")
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

    // pruneConversationHistory and shouldPruneContextBeforeLLMCall removed during
    // CLIO sync. Their responsibilities are now handled by MessageValidator:
    // - proactive trim before every LLM call (not a 70% threshold check)
    // - structured thread_summary compression (no LLM call required)
    // - atomic unit grouping so tool_calls/results never split
    // - last user message always re-injected


    /// Calculate hash of message array content for compression detection
    // messageFingerprint and processAllMessagesWithYARN removed during CLIO sync.
    // Context management is owned by MessageValidator (atomic unit grouping,
    // budget walk, thread_summary compression). Providers trust messages as-is.

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
