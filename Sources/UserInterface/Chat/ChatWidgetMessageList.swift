// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConversationEngine
import ConfigurationSystem
import APIFramework
import Logging

extension ChatWidget {
    // MARK: - Message List
    
    var messageList: some View {
        ScrollViewReader { proxy in
            /// Outer wrapper is intentionally minimal - the inner ScrollView
            /// has many modifiers and extracting it into scrollableContent
            /// keeps each closure small enough for the Swift type-checker.
            messageListScrollView(proxy: proxy)
        }
    }

    /// The inner ScrollView with all its modifiers. Extracted from
    /// messageList to keep Swift's type-checker within its timeout budget
    /// (CI Xcode 26.2 was failing with "unable to type-check this expression
    /// in reasonable time" because the chained modifier graph was too deep).
    /// Further split into 3 builder functions because Xcode 26.2 still
    /// timed out on the 15-modifier chain in a single @ViewBuilder.
    @ViewBuilder
    func messageListScrollView(proxy: ScrollViewProxy) -> some View {
        applyNotificationModifiers(
            applyScrollTrackingModifiers(
                baseScrollContent(),
                proxy: proxy
            ),
            proxy: proxy
        )
    }

    @ViewBuilder
    func baseScrollContent() -> some View {
        ScrollView {
            if let activeConv = activeConversation {
                messagesVStack(for: activeConv)
            }
        }
    }

    @ViewBuilder
    func applyScrollTrackingModifiers<Content: View>(_ content: Content, proxy: ScrollViewProxy) -> some View {
        content
            .scrollPosition(id: $bottomVisibleItemId, anchor: .bottom)
            .background(Color.clear)
            .onChange(of: bottomVisibleItemId) { _, newId in
                updateFollowingOutput(scrollItemId: newId)
            }
            .onChange(of: messages) { _, newMessages in
                cachedToolHierarchy = buildToolHierarchy(messages: newMessages)

                guard scrollLockEnabled, isFollowingOutput,
                      let lastMessage = newMessages.last else { return }

                /// Single scroll point: if following output, scroll to bottom.
                /// Replaces 4 separate onChange handlers + 150ms sleep hack.
                /// No throttling delay — the MessageBus delta sync already
                /// throttles to 33ms, so we just follow.
                proxy.scrollTo("scroll-bottom-anchor", anchor: .bottom)
            }
            .onAppear {
                scrollProxy = proxy
                isFollowingOutput = true
            }
            .overlay(alignment: .bottom) {
                if scrollLockEnabled && !isFollowingOutput {
                    jumpToLatestPill(proxy: proxy)
                }
            }
    }

    @ViewBuilder
    func applyNotificationModifiers<Content: View>(_ content: Content, proxy: ScrollViewProxy) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .scrollToTop)) { _ in
            if let firstMessage = messages.first {
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(firstMessage.id.uuidString, anchor: .top)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollToBottom)) { _ in
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo("scroll-bottom-anchor", anchor: .bottom)
            }
            isFollowingOutput = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .pageUp)) { _ in
            pageScroll(proxy: proxy, direction: .up)
            isFollowingOutput = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .pageDown)) { _ in
            pageScroll(proxy: proxy, direction: .down)
        }
    }

    /// Update isFollowingOutput based on the item currently visible at the
    /// bottom anchor. nil means the binding hasn't been populated yet
    /// (e.g. on first appear before layout settles); keep the existing
    /// state in that case so we don't flicker the pill.
    func updateFollowingOutput(scrollItemId: String?) {
        guard let scrollItemId = scrollItemId else { return }
        let atBottom = (scrollItemId == "scroll-bottom-anchor")
        if atBottom != isFollowingOutput {
            isFollowingOutput = atBottom
        }
    }

    /// "Jump to latest" pill shown when the user has scrolled away from the
    /// bottom. Clicking it scrolls to the bottom anchor and re-enables
    /// follow-output so auto-scroll resumes for new content.
    @ViewBuilder
    func jumpToLatestPill(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("scroll-bottom-anchor", anchor: .bottom)
            }
            /// Set immediately rather than waiting for the .scrollPosition
            /// binding to update, so subsequent streaming updates are
            /// auto-scrolled without waiting for the layout pass.
            isFollowingOutput = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.caption2.weight(.semibold))
                Text("Latest")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .primary.opacity(0.15), radius: 3, x: 0, y: 1)
            )
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .help("Jump to latest message")
    }

    /// Private enum for scroll direction tracking
    enum PageDirection {
        case up, down
    }

    func pageScroll(proxy: ScrollViewProxy, direction: PageDirection) {
        /// Estimate approximately 5-7 messages per page
        let pageSize = 6

        guard !messages.isEmpty else { return }

        /// Find current visible message index (approximation based on lastScrolledToId)
        var currentIndex: Int
        if let lastId = lastScrolledToId,
           let idx = messages.firstIndex(where: { $0.id == lastId }) {
            currentIndex = idx
        } else {
            /// Default to middle of conversation if no scroll tracked
            currentIndex = messages.count / 2
        }

        /// Calculate target index
        let targetIndex: Int
        switch direction {
        case .up:
            targetIndex = max(0, currentIndex - pageSize)
        case .down:
            targetIndex = min(messages.count - 1, currentIndex + pageSize)
        }

        /// Scroll to target message
        let targetMessage = messages[targetIndex]
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(targetMessage.id.uuidString, anchor: direction == .up ? .top : .bottom)
        }
        lastScrolledToId = targetMessage.id
    }

    func messagesVStack(for conversation: ConversationModel) -> some View {
        /// PERFORMANCE: Use LazyVStack to allow SwiftUI to destroy off-screen views
        /// Previous VStack kept ALL messages in memory causing massive slowdowns with many tool calls
        /// LazyVStack + stable scroll anchor prevents scroll jumping while enabling view recycling
        LazyVStack(spacing: 12) {
                    /// PERFORMANCE FIX: Use cached tool hierarchy instead of rebuilding on every render
                    /// buildToolHierarchy() is now called only when messages change, not on every view update
                    let toolHierarchy = cachedToolHierarchy

                    /// Filter out system-generated messages (e.g., auto-continue prompts)
                    /// These messages are kept in conversation history for context but hidden from UI
                    let visibleMessages = messages.filter { !$0.isSystemGenerated }

                    ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                        /// PERFORMANCE: Removed debug logging that fired on EVERY render pass
                        /// Original: logger.debug("[CHAT_RENDER_LOOP]...") - caused 4tps drop with many messages

                        /// FIX (Issue #4): Show subtasks WHILE running Only skip child messages if parent is COMPLETE (not running) This prevents subtasks from disappearing while executing.
                        let shouldSkipAsChild: Bool = {
                            guard message.isToolMessage, let parentName = message.parentToolName else {
                                return false
                            }

                            /// Find parent message.
                            if let parent = messages.first(where: { $0.toolName == parentName && $0.isToolMessage }) {
                                /// Only hide if parent is complete (success or error).
                                return parent.toolStatus == .success || parent.toolStatus == .error
                            }

                            /// No parent found, show the child.
                            return false
                        }()

                        if shouldSkipAsChild {
                            EmptyView()
                        } else {
                            /// Filter raw tool call JSON (assistant messages that are pure JSON tool invocations).
                            /// IMPORTANT: Don't filter tool result messages - they should render as tool cards
                            let isToolCallJSON = !message.isToolMessage && isToolCallJSONMessage(message)

                            /// Filter empty messages (often incomplete streaming artifacts).
                            /// Thinking messages should NOT be filtered if they have reasoningContent
                            /// Even if content is empty, reasoningContent may contain the actual thinking data
                            /// Image messages should NOT be filtered if they have contentParts
                            /// Even if content is empty, contentParts may contain the actual image data
                            /// CRITICAL: Tool execution messages should NEVER be filtered, even when empty
                            /// Tool cards are created with empty content and filled in when tool completes
                            ///
                            /// effectiveContent strips <think>/</think> tag remnants so messages whose
                            /// only content is the closing tag from a thinking block (common when the
                            /// model emits `</thinking>` as the first content chunk before tool calls)
                            /// are treated as empty rather than rendering an "empty" bubble with the
                            /// literal tag visible.
                                                        let isEmpty = message.content.isEmpty &&
                                          message.type != .toolExecution &&  /// ALWAYS show tool cards, even when empty
                                          (message.type != .thinking || (message.reasoningContent == nil || message.reasoningContent!.isEmpty)) &&
                                          (message.contentParts == nil || message.contentParts!.isEmpty)

                            /// Filter placeholder thinking messages (just "SUCCESS: Thinking..." with no actual content).
                            let isPlaceholderThinking = message.type == .thinking &&
                                message.content == "SUCCESS: Thinking..." &&
                                (message.reasoningContent == nil || message.reasoningContent?.isEmpty == true)

                            /// PERFORMANCE: Removed verbose filter logging that fired on every render
                            let willRender = !isToolCallJSON && !isEmpty && !isPlaceholderThinking

                            /// Only filter raw tool call JSON, empty messages, and placeholder thinking.
                            if willRender {
                                /// SCROLL BOUNCE FIX: Use STABLE IDs for ALL message types
                                /// Previously tool messages used content.hashValue which forced
                                /// view recreation on every content update → layout shift → bounce
                                /// 
                                /// SwiftUI handles content diffing internally - we just need stable IDs
                                /// This prevents forced view recreation that causes scroll jumping
                                let viewID: String = message.id.uuidString

                                /// SEPARATOR: Thin divider before each rendered message (except first).
                                /// Fixed in LazyVStack layout — does not move with content during streaming.
                                if index > 0 {
                                    MessageSeparator()
                                }

                                /// LAZYVSTACK FIX: Wrap in container with minimum height
                                /// LazyVStack needs non-zero layout dimensions to properly render
                                /// Without this, messages may appear empty until scrolled
                                Group {
                                    /// PERFORMANCE: Removed render-path diagnostic logging
                                    /// Original logging fired on EVERY view render causing major slowdowns

                                    /// Check message.type BEFORE isToolMessage to prevent thinking cards being rendered as tool cards
                                    /// Thinking messages have isToolMessage=true but must render via MessageView → ThinkingCard
                                    if message.type == .thinking {
                                        MessageView(
                                            message: message,
                                            enableAnimations: enableAnimations,
                                            conversation: conversation,
                                            messageToExport: $messageToExport
                                        )
                                    } else if message.isToolMessage {
                                        ToolMessageWithChildren(
                                            message: message,
                                            children: toolHierarchy[message.id] ?? [],
                                            enableAnimations: enableAnimations,
                                            conversation: conversation,
                                            messageToExport: $messageToExport
                                        )
                                            .onAppear {
                                                /// CRITICAL: Acknowledge tool card RENDERING (not just message creation)
                                                /// This signals to orchestrator that card is VISIBLE, not just added to array
                                                /// Note: Removed verbose timestamp logging for performance
                                                if let toolCallId = message.toolCallId {
                                                    currentOrchestrator?.toolCardsReady.insert(toolCallId)
                                                }
                                            }
                                    } else {
                                        /// PERFORMANCE: Use cached cleaned message to avoid regex on every render
                                        MessageView(
                                            message: message,
                                            enableAnimations: enableAnimations,
                                            conversation: conversation,
                                            messageToExport: $messageToExport
                                        )
                                    }
                                }
                                /// No .fixedSize — LazyVStack handles intrinsic heights naturally.
                                .id(viewID)
                            } else {
                                /// PERFORMANCE: Removed filter logging (fired on every render)
                                EmptyView()
                            }
                        }
                    }

                    /// SCROLL ANCHOR: Invisible view at the bottom of the message list.
                    /// Used for "scroll to bottom" commands.
                    Color.clear
                        .frame(height: 1)
                        .id("scroll-bottom-anchor")
                }
                .padding(.horizontal)  /// Only horizontal padding, no bottom padding
                .padding(.top)
    }

    // MARK: - Message Type Detection

    /// Check if message is a tool call JSON message (raw JSON emitted by
    /// the model instead of an actual text response).
    ///
    /// Uses JSONDecoder to attempt parsing the trimmed content as a known
    /// tool-call or status shape. This eliminates false positives that the
    /// previous `contains`-based heuristic produced on legitimate markdown
    /// responses that happened to start with `{` and end with `}`.
    func isToolCallJSONMessage(_ message: EnhancedMessage) -> Bool {
        guard !message.isFromUser else { return false }

        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)

        /// Check for tool result chunk marker (from read_tool_result).
        if trimmed.contains("[TOOL_RESULT_CHUNK]") || trimmed.contains("[TOOL_RESULT_STORED]") {
            return true
        }

        /// Only attempt JSON decode if the message looks like JSON.
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return false }

        let decoder = JSONDecoder()

        /// Tool call shape: {"name": "...", "arguments": {...}}
        struct ToolCallJSON: Decodable {
            let name: String
            let arguments: [String: String]
        }
        if (try? decoder.decode(ToolCallJSON.self, from: Data(trimmed.utf8))) != nil {
            return true
        }

        /// Status/workflow control JSON: {"status": "..."}
        struct StatusJSON: Decodable {
            let status: String
        }
        if (try? decoder.decode(StatusJSON.self, from: Data(trimmed.utf8))) != nil {
            return true
        }

        /// Structured data shapes (news research, web search results, etc.)
        struct StructuredDataJSON: Decodable {
            let type: String?
            let query: String?
            let result_count: Int?
            let article_count: Int?
            let conducted_at: String?
        }
        if (try? decoder.decode(StructuredDataJSON.self, from: Data(trimmed.utf8))) != nil {
            return true
        }

        return false
    }

}
