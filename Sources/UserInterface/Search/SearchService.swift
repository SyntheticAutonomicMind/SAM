// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConversationEngine

/// Global search result representing a message found across conversations.
struct GlobalSearchResult: Identifiable {
    let id = UUID()
    let conversationId: UUID
    let conversationName: String
    let messageId: UUID
    let messageContent: String
    let messageRole: String
    let timestamp: Date

    /// Create excerpt from message content with context around search query.
    func excerpt(for query: String, maxLength: Int = 150) -> String {
        let lowercasedContent = messageContent.lowercased()
        let lowercasedQuery = query.lowercased()

        /// Find first occurrence of query.
        guard let range = lowercasedContent.range(of: lowercasedQuery) else {
            /// Query not found (shouldn't happen), return truncated content.
            return String(messageContent.prefix(maxLength))
        }

        /// Calculate context window around query.
        let queryStart = lowercasedContent.distance(from: lowercasedContent.startIndex, to: range.lowerBound)
        let contextBefore = max(0, queryStart - (maxLength / 2))
        let contextAfter = min(messageContent.count, queryStart + query.count + (maxLength / 2))

        /// Extract excerpt with context.
        let startIndex = messageContent.index(messageContent.startIndex, offsetBy: contextBefore)
        let endIndex = messageContent.index(messageContent.startIndex, offsetBy: min(contextAfter, messageContent.count))
        var excerpt = String(messageContent[startIndex..<endIndex])

        /// Add ellipsis if truncated.
        if contextBefore > 0 {
            excerpt = "..." + excerpt
        }
        if contextAfter < messageContent.count {
            excerpt = excerpt + "..."
        }

        return excerpt
    }

    /// Get highlighted excerpt with query terms highlighted.
    func highlightedExcerpt(for query: String) -> AttributedString {
        let excerptText = excerpt(for: query)
        var attributed = AttributedString(excerptText)

        /// Find and highlight all occurrences of query (case-insensitive).
        let lowercasedExcerpt = excerptText.lowercased()
        let lowercasedQuery = query.lowercased()

        var searchStart = lowercasedExcerpt.startIndex
        while let range = lowercasedExcerpt[searchStart...].range(of: lowercasedQuery) {
            /// Convert String.Index to AttributedString.Index.
            let startDistance = lowercasedExcerpt.distance(from: lowercasedExcerpt.startIndex, to: range.lowerBound)
            let endDistance = lowercasedExcerpt.distance(from: lowercasedExcerpt.startIndex, to: range.upperBound)

            let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: startDistance)
            let attrEnd = attributed.index(attributed.startIndex, offsetByCharacters: endDistance)
            attributed[attrStart..<attrEnd].backgroundColor = .yellow.opacity(0.3)
            attributed[attrStart..<attrEnd].foregroundColor = .primary

            searchStart = range.upperBound
        }

        return attributed
    }
}

/// Service for searching messages across all conversations.
@MainActor
class SearchService: ObservableObject {
    @Published var results: [GlobalSearchResult] = []
    @Published var isSearching = false

    private let conversationManager: ConversationManager

    init(conversationManager: ConversationManager) {
        self.conversationManager = conversationManager
    }

    /// Search all conversations for messages containing the query - Parameter query: Search query string - Returns: Array of search results sorted by relevance and recency.
    func search(query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        let lowercasedQuery = query.lowercased()
        var foundResults: [GlobalSearchResult] = []

        /// Search through all conversations.
        for conversation in conversationManager.conversations {
            /// Search through all messages in conversation.
            for message in conversation.messages {
                /// Check if message content contains query (case-insensitive).
                if message.content.lowercased().contains(lowercasedQuery) {
                    let result = GlobalSearchResult(
                        conversationId: conversation.id,
                        conversationName: conversation.title,
                        messageId: message.id,
                        messageContent: message.content,
                        messageRole: message.isFromUser ? "user" : "assistant",
                        timestamp: message.timestamp
                    )
                    foundResults.append(result)
                }
            }
        }

        /// Sort results: most recent first, then by relevance (exact matches first).
        results = foundResults.sorted { result1, result2 in
            let exactMatch1 = result1.messageContent.lowercased() == lowercasedQuery
            let exactMatch2 = result2.messageContent.lowercased() == lowercasedQuery

            if exactMatch1 != exactMatch2 {
                return exactMatch1
            }

            /// Otherwise sort by timestamp (most recent first).
            return result1.timestamp > result2.timestamp
        }
    }

    /// Clear search results.
    func clearResults() {
        results = []
    }
}
