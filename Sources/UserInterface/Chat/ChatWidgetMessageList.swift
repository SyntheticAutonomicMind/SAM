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
            ScrollView {
                if let activeConv = activeConversation {
                    messagesVStack(for: activeConv)
                        .id(activeConv.id)  /// Force recreation only when conversation changes
                }
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            .onChange(of: messages.count) { _, _ in
                /// New message added or removed - scroll if auto-scroll is active
                guard scrollLockEnabled, let lastMessage = messages.last else { return }
                performThrottledScroll(proxy: proxy, to: lastMessage)
            }
            .onChange(of: messages.last?.content.count) { _, _ in
                /// Streaming content update - only scroll during active streaming
                guard scrollLockEnabled,
                      let lastMessage = messages.last,
                      lastMessage.isStreaming else { return }
                performThrottledScroll(proxy: proxy, to: lastMessage)
            }
            .onChange(of: messages.last?.type) { _, newType in
                /// Tool card or thinking type change - scroll to make visible
                guard scrollLockEnabled,
                      let lastMessage = messages.last,
                      newType == .toolExecution || newType == .thinking else { return }
                performThrottledScroll(proxy: proxy, to: lastMessage)
            }
            .onChange(of: messages.last?.isStreaming) { oldValue, newValue in
                /// Streaming completion scroll: when streaming ends, layout recomputes
                /// (ProgressView removed, metrics added, content re-parsed).
                /// Scroll to bottom anchor after layout settles to keep content visible.
                if oldValue == true && newValue == false {
                    guard scrollLockEnabled else { return }
                    Task { @MainActor in
                        /// 150ms allows layout to settle after streaming->complete transition
                        try? await Task.sleep(for: .milliseconds(150))
                        proxy.scrollTo("scroll-bottom-anchor", anchor: .bottom)
                    }
                }
            }
            .onChange(of: messages) { _, newMessages in
                /// Cache tool hierarchy and prune stale message cache
                cachedToolHierarchy = buildToolHierarchy(messages: newMessages)
                let currentMessageIds = Set(newMessages.map { $0.id })
                cachedCleanedMessages = cachedCleanedMessages.filter { currentMessageIds.contains($0.key) }
            }
            .onAppear {
                scrollProxy = proxy
            }
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
            }
            .onReceive(NotificationCenter.default.publisher(for: .pageUp)) { _ in
                pageScroll(proxy: proxy, direction: .up)
            }
            .onReceive(NotificationCenter.default.publisher(for: .pageDown)) { _ in
                pageScroll(proxy: proxy, direction: .down)
            }
        }
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

    func performThrottledScroll(proxy: ScrollViewProxy, to message: EnhancedMessage) {
        let now = Date()
        let timeSinceLastScroll = now.timeIntervalSince(lastScrollTime)

        /// Content is growing if the message is streaming, or is a tool/thinking card
        let isGrowingContent = message.isStreaming ||
            message.type == .toolExecution ||
            message.type == .thinking

        if timeSinceLastScroll >= 0.1 {
            /// Enough time passed - scroll immediately
            lastScrollTime = now
            lastScrolledToId = message.id

            if isGrowingContent {
                /// Growing content: scroll to the last message's bottom edge.
                /// This keeps the newest content visible as it streams in without
                /// overshooting past the content into empty space.
                proxy.scrollTo(message.id.uuidString, anchor: .bottom)
            } else {
                /// Static content: scroll to the top of the message so user
                /// can read from the beginning (handles large messages well).
                proxy.scrollTo(message.id.uuidString, anchor: .top)
            }
        } else {
            /// Too soon - debounce
            pendingScrollTask?.cancel()
            pendingScrollTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let currentLast = messages.last else { return }
                    lastScrollTime = Date()
                    lastScrolledToId = currentLast.id

                    let growing = currentLast.isStreaming ||
                        currentLast.type == .toolExecution ||
                        currentLast.type == .thinking

                    if growing {
                        proxy.scrollTo(currentLast.id.uuidString, anchor: .bottom)
                    } else {
                        proxy.scrollTo(currentLast.id.uuidString, anchor: .top)
                    }
                }
            }
        }
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

                    ForEach(visibleMessages) { message in
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
                            let isEmpty = message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                          message.type != .toolExecution &&  /// ALWAYS show tool cards, even when empty
                                          (message.type != .thinking || (message.reasoningContent == nil || message.reasoningContent!.isEmpty)) &&
                                          (message.contentParts == nil || message.contentParts!.isEmpty)

                            /// Filter placeholder thinking messages (just "SUCCESS: Thinking..." with no actual content).
                            let isPlaceholderThinking = message.type == .thinking &&
                                message.content.trimmingCharacters(in: .whitespacesAndNewlines) == "SUCCESS: Thinking..." &&
                                (message.reasoningContent == nil || message.reasoningContent!.isEmpty)

                            /// Handle messages with thinking content - extract response when reasoning disabled.
                            let displayMessage = getDisplayMessage(message, enableReasoning: enableReasoning)

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
                                            message: getCachedCleanedMessage(displayMessage),
                                            enableAnimations: enableAnimations,
                                            conversation: conversation,
                                            messageToExport: $messageToExport
                                        )
                                    } else if message.isToolMessage {
                                        ToolMessageWithChildren(
                                            message: getCachedCleanedMessage(displayMessage),
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
                                            message: getCachedCleanedMessage(displayMessage),
                                            enableAnimations: enableAnimations,
                                            conversation: conversation,
                                            messageToExport: $messageToExport
                                        )
                                    }
                                }
                                /// LAZYVSTACK RENDER FIX: Force intrinsic content height for all messages.
                                /// Without .fixedSize, LazyVStack may defer rendering and show empty placeholders.
                                /// Previously toggled based on isStreaming, but the transition from
                                /// streaming -> non-streaming caused massive layout recomputation
                                /// that cleared the visible window (scroll position lost during relayout).
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minHeight: 24)
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
                .id("messages-\(enableAnimations)")
                .padding(.horizontal)  /// Only horizontal padding, no bottom padding
                .padding(.top)
    }

}
