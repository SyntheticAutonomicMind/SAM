// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConversationEngine
import Logging

private let logger = Logger(label: "com.sam.search")

/// Global search overlay for searching across all conversations Keyboard shortcuts: Cmd+F to open, Escape to close.
struct GlobalSearchView: View {
    @EnvironmentObject private var conversationManager: ConversationManager
    @State private var searchResults: [GlobalSearchResult] = []
    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var isTextFieldFocused: Bool

    @Binding var isPresented: Bool
    let onResultSelected: (UUID, UUID) -> Void

    var body: some View {
        ZStack {
            /// Background dimming.
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            /// Search panel.
            VStack(spacing: 0) {
                /// Search field.
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)

                    TextField("Search all conversations...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            if let firstResult = searchResults.first {
                                handleResultSelection(firstResult)
                            }
                        }
                        .onChange(of: searchQuery) { _, newQuery in
                            performDebouncedSearch(query: newQuery)
                        }

                    if !searchQuery.isEmpty {
                        Button(action: {
                            searchQuery = ""
                            searchResults = []
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .background(.regularMaterial)

                Divider()

                /// Results list.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isSearching {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Searching...")
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                        } else if searchQuery.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "magnifyingglass")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary)
                                Text("Search across all conversations")
                                    .font(.headline)
                                Text("Type to search messages, code, and content")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(40)
                        } else if searchResults.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary)
                                Text("No results found")
                                    .font(.headline)
                                Text("Try different keywords")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(40)
                        } else {
                            ForEach(searchResults) { result in
                                SearchResultRow(
                                    result: result,
                                    searchQuery: searchQuery,
                                    onSelected: {
                                        handleResultSelection(result)
                                    }
                                )
                            }
                        }
                    }
                }
                .frame(maxHeight: 400)
                .background(.regularMaterial)
            }
            .frame(width: 600)
            .background(.regularMaterial)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
            .padding(40)
        }
        .onAppear {
            /// Auto-focus search field when overlay appears.
            isTextFieldFocused = true
        }
        .onExitCommand {
            /// Close search overlay when Escape key is pressed.
            isPresented = false
        }
    }

    private func performDebouncedSearch(query: String) {
        /// Cancel previous search task.
        debounceTask?.cancel()

        /// Create new debounced search task.
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)

            if !Task.isCancelled {
                await performSearch(query: query)
            }
        }
    }

    @MainActor
    private func performSearch(query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
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
        searchResults = foundResults.sorted { result1, result2 in
            let exactMatch1 = result1.messageContent.lowercased() == lowercasedQuery
            let exactMatch2 = result2.messageContent.lowercased() == lowercasedQuery

            if exactMatch1 != exactMatch2 {
                return exactMatch1
            }

            /// Otherwise sort by timestamp (most recent first).
            return result1.timestamp > result2.timestamp
        }
    }

    private func handleResultSelection(_ result: GlobalSearchResult) {
        onResultSelected(result.conversationId, result.messageId)
        isPresented = false
    }
}

/// Individual search result row.
struct SearchResultRow: View {
    let result: GlobalSearchResult
    let searchQuery: String
    let onSelected: () -> Void

    var body: some View {
        Button(action: onSelected) {
            HStack(alignment: .top, spacing: 12) {
                /// Role icon.
                Image(systemName: roleIcon)
                    .foregroundColor(roleColor)
                    .font(.body)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    /// Conversation name and timestamp.
                    HStack {
                        Text(result.conversationName)
                            .font(.headline)
                            .foregroundColor(.primary)

                        Spacer()

                        Text(result.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    /// Message role.
                    Text(result.messageRole.capitalized)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    /// Message excerpt with highlighting.
                    Text(result.highlightedExcerpt(for: searchQuery))
                        .font(.body)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.02))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { _ in
            /// Hover effect handled by SwiftUI.
        }

        Divider()
            .padding(.leading, 48)
    }

    private var roleIcon: String {
        switch result.messageRole.lowercased() {
        case "user":
            return "person.fill"

        case "assistant":
            return "sparkles"

        case "system":
            return "gear"

        default:
            return "message.fill"
        }
    }

    private var roleColor: Color {
        switch result.messageRole.lowercased() {
        case "user":
            return .blue

        case "assistant":
            return .purple

        case "system":
            return .orange

        default:
            return .gray
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var isPresented = true

        var body: some View {
            GlobalSearchView(isPresented: $isPresented) { conversationId, messageId in
                logger.debug("Selected: \(conversationId) - \(messageId)")
            }
        }
    }

    return PreviewWrapper()
}
