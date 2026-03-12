// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// RecallHistoryTool.swift
/// SAM MCP Tool for Recalling Archived Conversation History
///
/// PURPOSE:
/// When YaRN compression archives older context to fit model limits,
/// this tool allows agents to recall that context when needed.
///
/// USAGE:
/// Agent calls recall_history with a query to find relevant archived context.
/// Tool returns matching chunks with summaries and content previews.

import Foundation
import Logging

// MARK: - Archive Types (defined here to avoid circular dependency)
// These mirror the types in ContextArchiveManager

/// A chunk of archived context for recall
public struct RecallChunk: Sendable {
    public let id: UUID
    public let conversationId: UUID
    public let timeRange: String
    public let summary: String
    public let keyTopics: [String]
    public let messageCount: Int
    public let tokenCount: Int
    public let messages: [RecallMessage]

    public init(id: UUID, conversationId: UUID, timeRange: String, summary: String, keyTopics: [String], messageCount: Int, tokenCount: Int, messages: [RecallMessage]) {
        self.id = id
        self.conversationId = conversationId
        self.timeRange = timeRange
        self.summary = summary
        self.keyTopics = keyTopics
        self.messageCount = messageCount
        self.tokenCount = tokenCount
        self.messages = messages
    }

    public struct RecallMessage: Sendable {
        public let content: String
        public let isFromUser: Bool
        public let timestamp: Date

        public init(content: String, isFromUser: Bool, timestamp: Date) {
            self.content = content
            self.isFromUser = isFromUser
            self.timestamp = timestamp
        }
    }
}

/// Memory map for available archives
public struct RecallMemoryMap: Sendable {
    public let conversationId: UUID
    public let totalChunks: Int
    public let totalTokensArchived: Int
    public let chunkSummaries: [(id: UUID, timeRange: String, summary: String, topics: [String])]

    public init(conversationId: UUID, totalChunks: Int, totalTokensArchived: Int, chunkSummaries: [(id: UUID, timeRange: String, summary: String, topics: [String])]) {
        self.conversationId = conversationId
        self.totalChunks = totalChunks
        self.totalTokensArchived = totalTokensArchived
        self.chunkSummaries = chunkSummaries
    }
}

/// Protocol for archive manager to enable dependency injection without circular imports
public protocol ContextArchiveProvider {
    func recallHistory(query: String, conversationId: UUID, limit: Int) async throws -> [RecallChunk]
    func recallHistoryByTime(conversationId: UUID, timeHint: String, limit: Int) async throws -> [RecallChunk]
    func getMemoryMap(conversationId: UUID) async throws -> RecallMemoryMap

    // MARK: - Topic-Wide Search (for Shared Topics)

    /// Recall history across ALL conversations in a shared topic
    func recallTopicHistory(query: String, topicId: UUID, limit: Int) async throws -> [RecallChunk]

    /// Get memory map for an entire topic (all conversations)
    func getTopicMemoryMap(topicId: UUID) async throws -> RecallMemoryMap

    /// Get list of conversation IDs that belong to a topic
    func getConversationsInTopic(topicId: UUID) async throws -> [UUID]
}

/// MCP Tool for recalling archived conversation history
public class RecallHistoryTool: MCPTool, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.tools.recall_history")

    // MARK: - MCPTool Protocol

    public var name: String { "recall_history" }

    public var description: String {
        """
        Recall archived conversation history from earlier conversations.

        Use this tool when:
        - You need context from earlier in a long conversation
        - The user references something discussed previously
        - You see "[Memory Status]" indicating archived context exists
        - You need to remember decisions or information from earlier
        - You want to see what other agents discussed in a shared topic

        When working in a shared topic, you can search across ALL agent conversations:
        - Set topic_id to search history from all agents in the topic
        - Omit topic_id to search only your current conversation

        The tool returns relevant context chunks with summaries and content.
        Each chunk includes a time range, summary, and key topics.
        """
    }

    public var parameters: [String: MCPToolParameter] {
        [
            "query": MCPToolParameter(
                type: .string,
                description: "Search term or topic to find relevant history. Be specific.",
                required: true
            ),
            "topic_id": MCPToolParameter(
                type: .string,
                description: "Optional: UUID of shared topic to search across ALL conversations in the topic. If omitted, searches only current conversation.",
                required: false
            ),
            "time_hint": MCPToolParameter(
                type: .string,
                description: "Optional: 'recent' for latest archived, 'early' for oldest, or leave empty for relevance-based search",
                required: false
            ),
            "limit": MCPToolParameter(
                type: .integer,
                description: "Number of chunks to retrieve (1-10, default: 3)",
                required: false
            )
        ]
    }

    public init() {}

    public func initialize() async throws {
        logger.debug("RecallHistoryTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard let query = parameters["query"] as? String, !query.isEmpty else {
            throw MCPToolError.invalidParameters("'query' parameter is required and must be non-empty")
        }

        if let limit = parameters["limit"] as? Int, limit < 1 || limit > 10 {
            throw MCPToolError.invalidParameters("'limit' must be between 1 and 10")
        }

        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {

        logger.debug("recall_history invoked", metadata: [
            "conversation": "\(context.conversationId?.uuidString.prefix(8) ?? "none")"
        ])

        // Parse arguments
        guard let query = parameters["query"] as? String, !query.isEmpty else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Error: 'query' parameter is required. Provide a search term to find relevant history."),
                toolName: name
            )
        }

        let topicIdString = parameters["topic_id"] as? String
        let topicId = topicIdString.flatMap { UUID(uuidString: $0) }
        let timeHint = parameters["time_hint"] as? String
        let limit = min(max((parameters["limit"] as? Int) ?? 3, 1), 10)

        // Get conversation ID (required for single-conversation search)
        let conversationId = context.conversationId

        // Validate we have either conversationId or topicId
        if conversationId == nil && topicId == nil {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Error: No conversation or topic context available. Provide topic_id or ensure you're in an active conversation."),
                toolName: name
            )
        }

        // Get archive provider
        guard let provider = RecallHistoryTool.sharedArchiveProvider else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Error: Archive provider not available. Long-term memory may not be enabled."),
                toolName: name
            )
        }

        do {
            // Determine search scope: topic-wide or single conversation
            if let topicId = topicId {
                // TOPIC-WIDE SEARCH: Search across ALL conversations in the shared topic
                logger.info("recall_history: Topic-wide search for '\(query.prefix(30))' in topic \(topicId.uuidString.prefix(8))")

                let chunks = try await provider.recallTopicHistory(
                    query: query,
                    topicId: topicId,
                    limit: limit
                )

                let memoryMap = try await provider.getTopicMemoryMap(topicId: topicId)
                let conversationCount = try await provider.getConversationsInTopic(topicId: topicId).count

                if chunks.isEmpty {
                    return MCPToolResult(
                        success: true,
                        output: MCPOutput(content: formatNoResultsForTopic(query: query, memoryMap: memoryMap, conversationCount: conversationCount)),
                        toolName: name
                    )
                }

                let formattedResult = formatTopicResults(
                    chunks: chunks,
                    query: query,
                    memoryMap: memoryMap,
                    conversationCount: conversationCount
                )

                logger.info("recall_history returned \(chunks.count) chunks across topic for query '\(query.prefix(30))'")

                return MCPToolResult(
                    success: true,
                    output: MCPOutput(content: formattedResult),
                    toolName: name
                )

            } else {
                // SINGLE CONVERSATION SEARCH: Original behavior
                guard let conversationId = conversationId else {
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(content: "Error: No conversation context available. recall_history requires an active conversation or topic_id."),
                        toolName: name
                    )
                }

                // Recall based on time hint or query
                let chunks: [RecallChunk]
                if let hint = timeHint, ["recent", "early"].contains(hint.lowercased()) {
                    chunks = try await provider.recallHistoryByTime(
                        conversationId: conversationId,
                        timeHint: hint,
                        limit: limit
                    )
                } else {
                    chunks = try await provider.recallHistory(
                        query: query,
                        conversationId: conversationId,
                        limit: limit
                    )
                }

                // Get memory map for additional context
                let memoryMap = try await provider.getMemoryMap(conversationId: conversationId)

                if chunks.isEmpty {
                    return MCPToolResult(
                        success: true,
                        output: MCPOutput(content: formatNoResults(query: query, memoryMap: memoryMap)),
                        toolName: name
                    )
                }

                // Format results
                let formattedResult = formatResults(chunks: chunks, query: query, memoryMap: memoryMap)

                logger.info("recall_history returned \(chunks.count) chunks for query '\(query.prefix(30))'")

                return MCPToolResult(
                    success: true,
                    output: MCPOutput(content: formattedResult),
                    toolName: name
                )
            }

        } catch {
            logger.error("recall_history failed: \(error)")
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Error recalling history: \(error.localizedDescription)"),
                toolName: name
            )
        }
    }

    // MARK: - Shared Archive Provider

    /// Shared archive provider instance (set by application startup)
    public nonisolated(unsafe) static var sharedArchiveProvider: ContextArchiveProvider?

    // MARK: - Formatting

    private func formatResults(chunks: [RecallChunk], query: String, memoryMap: RecallMemoryMap) -> String {
        var output = """
        # Recalled History for: "\(query)"

        Found \(chunks.count) relevant archive chunk\(chunks.count == 1 ? "" : "s").

        """

        for (index, chunk) in chunks.enumerated() {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"

            output += """

            ---
            ## Chunk \(index + 1): \(chunk.timeRange)

            **Summary:** \(chunk.summary)

            **Key Topics:** \(chunk.keyTopics.joined(separator: ", "))

            **Messages (\(chunk.messageCount)):**

            """

            // Include message previews (limited to keep response reasonable)
            for message in chunk.messages.prefix(5) {
                let role = message.isFromUser ? "User" : "Assistant"
                let preview = String(message.content.prefix(500))
                let truncated = message.content.count > 500 ? "..." : ""
                output += """

                [\(role) - \(timeFormatter.string(from: message.timestamp))]
                \(preview)\(truncated)

                """
            }

            if chunk.messageCount > 5 {
                output += "\n... and \(chunk.messageCount - 5) more messages in this chunk.\n"
            }
        }

        // Add memory map summary
        if memoryMap.totalChunks > chunks.count {
            let allTopics = Set(memoryMap.chunkSummaries.flatMap { $0.topics }).prefix(15)
            output += """

            ---
            ## Additional Archived Context

            There are \(memoryMap.totalChunks - chunks.count) more archived chunks available.
            Total archived tokens: \(memoryMap.totalTokensArchived)

            Other topics in archive: \(allTopics.joined(separator: ", "))

            Use recall_history again with a different query to access more context.
            """
        }

        return output
    }

    private func formatNoResults(query: String, memoryMap: RecallMemoryMap) -> String {
        if memoryMap.totalChunks == 0 {
            return """
            No archived history found for: "\(query)"

            This conversation has no archived context yet. Context is archived when:
            - The conversation exceeds the model's context limit
            - YaRN compression removes older messages to make room

            The conversation history is still fresh and available in your current context.
            """
        }

        let allTopics = Set(memoryMap.chunkSummaries.flatMap { $0.topics }).prefix(15)

        return """
        No matches found for: "\(query)"

        However, there are \(memoryMap.totalChunks) archived chunks available.
        Total archived tokens: \(memoryMap.totalTokensArchived)

        Available topics in archive:
        \(allTopics.joined(separator: ", "))

        Try a different search term related to these topics, or use time_hint: "recent" or "early".
        """
    }

    // MARK: - Topic-Wide Formatting

    private func formatTopicResults(chunks: [RecallChunk], query: String, memoryMap: RecallMemoryMap, conversationCount: Int) -> String {
        var output = """
        # Recalled History for: "\(query)"
        ## Searching across \(conversationCount) agent conversation\(conversationCount == 1 ? "" : "s") in shared topic

        Found \(chunks.count) relevant archive chunk\(chunks.count == 1 ? "" : "s") from multiple agents.

        """

        // Group chunks by conversation to show which agent contributed
        let groupedByConversation = Dictionary(grouping: chunks) { $0.conversationId }

        for (conversationId, conversationChunks) in groupedByConversation {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"

            output += """

            ═══════════════════════════════════════════════════════════════
            ## Agent Conversation: \(conversationId.uuidString.prefix(8))...
            ═══════════════════════════════════════════════════════════════

            """

            for (index, chunk) in conversationChunks.enumerated() {
                output += """

                ---
                ### Chunk \(index + 1): \(chunk.timeRange)

                **Summary:** \(chunk.summary)

                **Key Topics:** \(chunk.keyTopics.joined(separator: ", "))

                **Messages (\(chunk.messageCount)):**

                """

                // Include message previews (limited to keep response reasonable)
                for message in chunk.messages.prefix(5) {
                    let role = message.isFromUser ? "User" : "Assistant"
                    let preview = String(message.content.prefix(500))
                    let truncated = message.content.count > 500 ? "..." : ""
                    output += """

                    [\(role) - \(timeFormatter.string(from: message.timestamp))]
                    \(preview)\(truncated)

                    """
                }

                if chunk.messageCount > 5 {
                    output += "\n... and \(chunk.messageCount - 5) more messages in this chunk.\n"
                }
            }
        }

        // Add memory map summary
        if memoryMap.totalChunks > chunks.count {
            let allTopics = Set(memoryMap.chunkSummaries.flatMap { $0.topics }).prefix(15)
            output += """

            ═══════════════════════════════════════════════════════════════
            ## Additional Archived Context in Topic
            ═══════════════════════════════════════════════════════════════

            There are \(memoryMap.totalChunks - chunks.count) more archived chunks across all agents.
            Total archived tokens: \(memoryMap.totalTokensArchived)

            Other topics in archive: \(allTopics.joined(separator: ", "))

            Use recall_history again with a different query to access more context from any agent.
            """
        }

        return output
    }

    private func formatNoResultsForTopic(query: String, memoryMap: RecallMemoryMap, conversationCount: Int) -> String {
        if memoryMap.totalChunks == 0 {
            return """
            No archived history found for: "\(query)"

            Searched across \(conversationCount) agent conversation\(conversationCount == 1 ? "" : "s") in the shared topic.

            No agents have archived context yet. Context is archived when:
            - A conversation exceeds the model's context limit
            - YaRN compression removes older messages to make room

            All agent conversations are still fresh and within their context limits.
            """
        }

        let allTopics = Set(memoryMap.chunkSummaries.flatMap { $0.topics }).prefix(15)

        return """
        No matches found for: "\(query)"

        Searched across \(conversationCount) agent conversation\(conversationCount == 1 ? "" : "s").

        However, there are \(memoryMap.totalChunks) archived chunks available from various agents.
        Total archived tokens: \(memoryMap.totalTokensArchived)

        Available topics in topic archive:
        \(allTopics.joined(separator: ", "))

        Try a different search term related to these topics.
        """
    }
}

// MARK: - Tool Error

public enum MCPToolError: Error, LocalizedError {
    case invalidParameters(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidParameters(let message):
            return "Invalid parameters: \(message)"
        case .executionFailed(let message):
            return "Execution failed: \(message)"
        }
    }
}
