// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Combine
import ConfigurationSystem
import Logging

/// Single source of truth for conversation messages
/// Eliminates bidirectional sync by providing centralized message management with debounced persistence
@MainActor
public class ConversationMessageBus: ObservableObject {
    // MARK: - Published State

    /// Single source of truth - UI binds to this
    @Published public private(set) var messages: [EnhancedMessage] = []

    // MARK: - Private State

    /// Fast lookup cache (messageId → array index)
    private var messageCache: [UUID: Int] = [:]

    /// Non-blocking persistence queue
    private let persistenceQueue = DispatchQueue(
        label: "com.sam.messageBus.persistence",
        qos: .utility
    )

    /// Debounce timer for batched saves (prevent excessive disk I/O)
    private var saveTimer: Timer?
    private let saveDebounceDuration: TimeInterval = 0.5

    /// Throttle mechanism for sync to conversation (prevents excessive UI updates during streaming)
    private var lastSyncTime: Date?
    private let syncThrottleInterval: TimeInterval = 0.001 // 1ms = max 1000 updates/second (minimal throttling for max performance)

    /// Delta sync throttle (separate from full sync for independent control)
    private var lastDeltaSyncTime: Date?
    private let deltaSyncThrottleInterval: TimeInterval = 0.033 // 33ms = ~30 FPS (balanced performance/responsiveness)

    /// References for persistence
    private weak var conversation: ConversationModel?
    private weak var conversationManager: ConversationManager?

    /// Logger
    private let logger = Logger(label: "com.sam.MessageBus")

    // MARK: - Initialization

    public init(
        conversation: ConversationModel,
        conversationManager: ConversationManager
    ) {
        self.conversation = conversation
        self.conversationManager = conversationManager

        /// Load initial messages from conversation
        loadInitialMessages()
    }

    // MARK: - Public API (ONLY way to modify messages)

    /// Add user message
    @discardableResult
    public func addUserMessage(content: String, timestamp: Date = Date(), isPinned: Bool? = nil, isSystemGenerated: Bool = false) -> UUID {
        let messageId = UUID()

        /// AUTO-PIN LOGIC: Pin first 10 user messages for guaranteed context retrieval
        /// CRITICAL: Message #1 MUST ALWAYS be pinned (sets conversation context)
        /// First 10 messages ensure agents retain initial setup and constraints
        /// Can be overridden with explicit isPinned parameter
        let currentUserMessageCount = messages.filter { $0.isFromUser }.count
        let isFirstMessage = currentUserMessageCount == 0
        let isEarlyMessage = currentUserMessageCount < 10
        let shouldPinMessage = isPinned ?? (isFirstMessage || isEarlyMessage)

        /// Calculate importance score
        let importance = calculateMessageImportance(text: content, isUser: true)

        let message = EnhancedMessage(
            id: messageId,
            content: content,
            isFromUser: true,
            timestamp: timestamp,
            processingTime: nil,
            isPinned: shouldPinMessage,
            importance: importance,
            isSystemGenerated: isSystemGenerated
        )

        appendMessage(message)
        scheduleSave()

        logger.debug("USER_MESSAGE: id=\(messageId.uuidString.prefix(8)), pinned=\(shouldPinMessage), importance=\(String(format: "%.2f", importance)), systemGenerated=\(isSystemGenerated)")
        return messageId
    }

    /// Add assistant message
    @discardableResult
    public func addAssistantMessage(
        content: String,
        contentParts: [MessageContentPart]? = nil,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        isPinned: Bool = false
    ) -> UUID {
        let messageId = UUID()

        /// Calculate importance score for assistant message
        let importance = calculateMessageImportance(text: content, isUser: false)

        let message = EnhancedMessage(
            id: messageId,
            content: content,
            contentParts: contentParts,
            isFromUser: false,
            timestamp: timestamp,
            processingTime: nil,
            isStreaming: isStreaming,
            isPinned: isPinned,
            importance: importance
        )

        appendMessage(message)
        scheduleSave()

        logger.debug("ASSISTANT_MESSAGE: id=\(messageId.uuidString.prefix(8)), streaming=\(isStreaming), hasParts=\(contentParts != nil), pinned=\(isPinned), importance=\(String(format: "%.2f", importance))")
        return messageId
    }

    /// Add assistant message with specific ID (for streaming compatibility)
    @discardableResult
    public func addAssistantMessage(
        id: UUID,
        content: String,
        contentParts: [MessageContentPart]? = nil,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        isPinned: Bool = false
    ) -> UUID {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("MessageBus.addAssistantMessage",
                                            duration: CFAbsoluteTimeGetCurrent() - perfStart)
        }

        logger.debug("🟢 ADD_ASST: id=\(id.uuidString.prefix(8)), streaming=\(isStreaming), hasParts=\(contentParts != nil), pinned=\(isPinned)")

        /// Calculate importance score for assistant message
        let importance = calculateMessageImportance(text: content, isUser: false)

        let message = EnhancedMessage(
            id: id,
            content: content,
            contentParts: contentParts,
            isFromUser: false,
            timestamp: timestamp,
            processingTime: nil,
            isStreaming: isStreaming,
            isPinned: isPinned,
            importance: importance
        )

        appendMessage(message)
        logger.debug("🟢 ADD_ASST: Appended, cache[\(id.uuidString.prefix(8))]=\(messageCache[id] ?? -1), importance=\(String(format: "%.2f", importance))")
        scheduleSave()

        logger.debug("ASSISTANT_MESSAGE: id=\(id.uuidString.prefix(8)), streaming=\(isStreaming), hasParts=\(contentParts != nil), pinned=\(isPinned), importance=\(String(format: "%.2f", importance))")
        return id
    }

    /// Update streaming message (real-time content updates)
    /// Update specific streaming message content (delta sync - avoids copying entire message array)
    public func updateStreamingMessage(id: UUID, content: String) {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("MessageBus.updateStreamingMessage",
                                            duration: CFAbsoluteTimeGetCurrent() - perfStart)
        }

        logger.debug("UPDATE_STREAMING: id=\(id.uuidString.prefix(8)), found=\(messageCache[id] != nil)")

        guard let index = messageCache[id] else {
            logger.error("ERROR: UPDATE_STREAMING message not found id=\(id.uuidString.prefix(8))")
            logger.error("ERROR: Cache keys: \(messageCache.keys.map { $0.uuidString.prefix(8) }.joined(separator: ", "))")
            logger.error("STREAMING: Message not found id=\(id.uuidString.prefix(8))")
            return
        }

        /// Create updated message (preserve all metadata)
        let current = messages[index]
        let updated = EnhancedMessage(
            id: current.id,
            type: current.type,
            content: content, // Only content changes
            contentParts: current.contentParts,
            isFromUser: current.isFromUser,
            timestamp: current.timestamp,
            toolName: current.toolName,
            toolStatus: current.toolStatus,
            toolDisplayData: current.toolDisplayData,
            toolDetails: current.toolDetails,
            toolDuration: current.toolDuration,
            toolIcon: current.toolIcon,
            toolCategory: current.toolCategory,
            parentToolName: current.parentToolName,
            toolMetadata: current.toolMetadata,
            toolCalls: current.toolCalls,
            toolCallId: current.toolCallId,
            processingTime: current.processingTime,
            reasoningContent: current.reasoningContent,
            showReasoning: current.showReasoning,
            performanceMetrics: current.performanceMetrics,
            isStreaming: current.isStreaming,
            isToolMessage: current.isToolMessage,
            githubCopilotResponseId: current.githubCopilotResponseId,
            isPinned: current.isPinned,
            importance: current.importance,
            lastModified: Date()
        )

        messages[index] = updated
        scheduleSave() // Debounced - won't save every chunk

        /// DELTA SYNC: Notify conversation with specific message ID
        /// Conversation updates only this message, not entire array
        notifyConversationOfMessageUpdate(id: id, index: index, message: updated)
    }

    /// Complete streaming message (marks as no longer streaming)
    public func completeStreamingMessage(
        id: UUID,
        performanceMetrics: MessagePerformanceMetrics? = nil,
        processingTime: TimeInterval? = nil
    ) {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("MessageBus.completeStreamingMessage",
                                            duration: CFAbsoluteTimeGetCurrent() - perfStart)
        }

        logger.debug("COMPLETE_STREAMING: id=\(id.uuidString.prefix(8)), found=\(messageCache[id] != nil)")

        guard let index = messageCache[id] else {
            logger.error("ERROR: COMPLETE_STREAMING message not found id=\(id.uuidString.prefix(8))")
            logger.error("ERROR: Cache keys: \(messageCache.keys.map { $0.uuidString.prefix(8) }.joined(separator: ", "))")
            logger.error("COMPLETE_STREAMING: Message not found id=\(id.uuidString.prefix(8))")
            return
        }

        let current = messages[index]

        /// Recalculate importance with final content (may have changed during streaming)
        let finalImportance = calculateMessageImportance(text: current.content, isUser: current.isFromUser)

        let updated = EnhancedMessage(
            id: current.id,
            type: current.type,
            content: current.content.trimmingCharacters(in: .whitespacesAndNewlines), // Trim on completion
            contentParts: current.contentParts,
            isFromUser: current.isFromUser,
            timestamp: current.timestamp,
            toolName: current.toolName,
            toolStatus: current.toolStatus,
            toolDisplayData: current.toolDisplayData,
            toolDetails: current.toolDetails,
            toolDuration: current.toolDuration,
            toolIcon: current.toolIcon,
            toolCategory: current.toolCategory,
            parentToolName: current.parentToolName,
            toolMetadata: current.toolMetadata,
            toolCalls: current.toolCalls,
            toolCallId: current.toolCallId,
            processingTime: processingTime ?? current.processingTime,
            reasoningContent: current.reasoningContent,
            showReasoning: current.showReasoning,
            performanceMetrics: performanceMetrics ?? current.performanceMetrics,
            isStreaming: false, // Mark as complete
            isToolMessage: current.isToolMessage,
            githubCopilotResponseId: current.githubCopilotResponseId,
            isPinned: current.isPinned,
            importance: finalImportance, // Use recalculated importance
            lastModified: Date()
        )

        messages[index] = updated
        scheduleSave()

        /// PERFORMANCE: Use delta sync instead of full sync
        /// Completing message doesn't add/remove messages, just updates one
        notifyConversationOfMessageUpdate(id: id, index: index, message: updated)

        logger.debug("COMPLETE_STREAMING: id=\(id.uuidString.prefix(8)), metrics=\(performanceMetrics != nil)")
    }

    /// Update non-streaming message (for tool completions, status changes, content parts, tool calls)
    /// Use this for updating tool messages after execution completes or adding images/tool calls to messages
    public func updateMessage(
        id: UUID,
        content: String? = nil,
        contentParts: [MessageContentPart]? = nil,
        toolCalls: [SimpleToolCall]? = nil,
        status: ToolStatus? = nil,
        duration: TimeInterval? = nil
    ) {
        guard let index = messageCache[id] else {
            logger.error("UPDATE_MESSAGE: Message not found id=\(id.uuidString.prefix(8))")
            return
        }

        let current = messages[index]
        let updated = EnhancedMessage(
            id: current.id,
            type: current.type,
            content: content ?? current.content,
            contentParts: contentParts ?? current.contentParts,
            isFromUser: current.isFromUser,
            timestamp: current.timestamp,
            toolName: current.toolName,
            toolStatus: status ?? current.toolStatus,
            toolDisplayData: current.toolDisplayData,
            toolDetails: current.toolDetails,
            toolDuration: duration ?? current.toolDuration,
            toolIcon: current.toolIcon,
            toolCategory: current.toolCategory,
            parentToolName: current.parentToolName,
            toolMetadata: current.toolMetadata,
            toolCalls: toolCalls ?? current.toolCalls,
            toolCallId: current.toolCallId,
            processingTime: current.processingTime,
            reasoningContent: current.reasoningContent,
            showReasoning: current.showReasoning,
            performanceMetrics: current.performanceMetrics,
            isStreaming: current.isStreaming,
            isToolMessage: current.isToolMessage,
            githubCopilotResponseId: current.githubCopilotResponseId,
            isPinned: current.isPinned,
            importance: current.importance,
            lastModified: Date()
        )

        messages[index] = updated
        scheduleSave()

        /// PERFORMANCE: Use delta sync for single message update
        notifyConversationOfMessageUpdate(id: id, index: index, message: updated)

        logger.debug("UPDATE_MESSAGE: id=\(id.uuidString.prefix(8)) status=\(status?.rawValue ?? "nil") duration=\(duration != nil ? String(format: "%.2f", duration!) : "nil") hasParts=\(contentParts != nil) toolCalls=\(toolCalls?.count ?? 0)")
    }

    /// Remove a message by ID
    /// Used for cleaning up placeholders on error/cancellation
    public func removeMessage(id: UUID) {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("MessageBus.removeMessage",
                                                   duration: CFAbsoluteTimeGetCurrent() - perfStart)
        }

        logger.debug("REMOVE_MESSAGE: id=\(id.uuidString.prefix(8))")

        guard let index = messageCache[id] else {
            logger.warning("Cannot remove message - not found: \(id.uuidString.prefix(8))")
            return
        }

        messages.remove(at: index)
        messageCache.removeValue(forKey: id)

        // Rebuild cache indices (all indices after removed message shifted down)
        for (idx, msg) in messages.enumerated() {
            messageCache[msg.id] = idx
        }

        scheduleSave()
        notifyConversationOfChanges()

        logger.debug("REMOVED_MESSAGE: id=\(id.uuidString.prefix(8)), remaining=\(messages.count)")
    }

    /// Toggle message pin status
    public func togglePin(id: UUID) {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("MessageBus.togglePin",
                                                   duration: CFAbsoluteTimeGetCurrent() - perfStart)
        }

        logger.debug("TOGGLE_PIN: id=\(id.uuidString.prefix(8))")

        guard let index = messageCache[id] else {
            logger.warning("Cannot toggle pin - message not found: \(id.uuidString.prefix(8))")
            return
        }

        let current = messages[index]
        let updated = EnhancedMessage(
            id: current.id,
            type: current.type,
            content: current.content,
            contentParts: current.contentParts,
            isFromUser: current.isFromUser,
            timestamp: current.timestamp,
            toolName: current.toolName,
            toolStatus: current.toolStatus,
            toolDisplayData: current.toolDisplayData,
            toolDetails: current.toolDetails,
            toolDuration: current.toolDuration,
            toolIcon: current.toolIcon,
            toolCategory: current.toolCategory,
            parentToolName: current.parentToolName,
            toolMetadata: current.toolMetadata,
            toolCalls: current.toolCalls,
            toolCallId: current.toolCallId,
            processingTime: current.processingTime,
            reasoningContent: current.reasoningContent,
            showReasoning: current.showReasoning,
            performanceMetrics: current.performanceMetrics,
            isStreaming: current.isStreaming,
            isToolMessage: current.isToolMessage,
            githubCopilotResponseId: current.githubCopilotResponseId,
            isPinned: !current.isPinned,  // TOGGLE
            importance: current.importance,
            lastModified: Date()
        )

        messages[index] = updated
        scheduleSave()
        notifyConversationOfChanges()

        logger.debug("TOGGLED_PIN: id=\(id.uuidString.prefix(8)), isPinned=\(updated.isPinned)")
    }

    /// Update message importance
    public func updateImportance(id: UUID, importance: Double) {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("MessageBus.updateImportance",
                                                   duration: CFAbsoluteTimeGetCurrent() - perfStart)
        }

        logger.debug("UPDATE_IMPORTANCE: id=\(id.uuidString.prefix(8)), importance=\(String(format: "%.2f", importance))")

        guard let index = messageCache[id] else {
            logger.warning("Cannot update importance - message not found: \(id.uuidString.prefix(8))")
            return
        }

        let current = messages[index]
        let updated = EnhancedMessage(
            id: current.id,
            type: current.type,
            content: current.content,
            contentParts: current.contentParts,
            isFromUser: current.isFromUser,
            timestamp: current.timestamp,
            toolName: current.toolName,
            toolStatus: current.toolStatus,
            toolDisplayData: current.toolDisplayData,
            toolDetails: current.toolDetails,
            toolDuration: current.toolDuration,
            toolIcon: current.toolIcon,
            toolCategory: current.toolCategory,
            parentToolName: current.parentToolName,
            toolMetadata: current.toolMetadata,
            toolCalls: current.toolCalls,
            toolCallId: current.toolCallId,
            processingTime: current.processingTime,
            reasoningContent: current.reasoningContent,
            showReasoning: current.showReasoning,
            performanceMetrics: current.performanceMetrics,
            isStreaming: current.isStreaming,
            isToolMessage: current.isToolMessage,
            githubCopilotResponseId: current.githubCopilotResponseId,
            isPinned: current.isPinned,
            importance: importance,  // UPDATE
            lastModified: Date()
        )

        messages[index] = updated
        scheduleSave()
        notifyConversationOfChanges()

        logger.debug("UPDATED_IMPORTANCE: id=\(id.uuidString.prefix(8)), importance=\(String(format: "%.2f", importance))")
    }

    /// Add tool message
    @discardableResult
    public func addToolMessage(
        name: String,
        status: ToolStatus,
        details: String? = nil,
        detailsArray: [String]? = nil,
        category: String? = nil,
        icon: String? = nil,
        duration: TimeInterval? = nil,
        parentToolName: String? = nil,
        toolDisplayData: ToolDisplayData? = nil,
        toolCallId: String? = nil
    ) -> UUID {
        let messageId = UUID()
        let message = EnhancedMessage(
            id: messageId,
            type: .toolExecution,
            content: details ?? detailsArray?.joined(separator: "\n") ?? "",
            isFromUser: false,
            timestamp: Date(),
            toolName: name,
            toolStatus: status,
            toolDisplayData: toolDisplayData,
            toolDetails: detailsArray,
            toolDuration: duration,
            toolIcon: icon,
            toolCategory: category,
            parentToolName: parentToolName,
            toolCallId: toolCallId,
            processingTime: nil,
            reasoningContent: nil,
            showReasoning: false,
            performanceMetrics: nil,
            isStreaming: false,
            isToolMessage: true
        )

        appendMessage(message)
        scheduleSave()

        logger.debug("TOOL_MESSAGE: name=\(name), status=\(status)")
        return messageId
    }

    /// Add tool message with specific ID (for streaming compatibility)
    @discardableResult
    public func addToolMessage(
        id: UUID,
        name: String,
        status: ToolStatus,
        details: String? = nil,
        detailsArray: [String]? = nil,
        category: String? = nil,
        icon: String? = nil,
        duration: TimeInterval? = nil,
        parentToolName: String? = nil,
        toolDisplayData: ToolDisplayData? = nil,
        toolCallId: String? = nil
    ) -> UUID {
        let message = EnhancedMessage(
            id: id,
            type: .toolExecution,
            content: details ?? detailsArray?.joined(separator: "\n") ?? "",
            isFromUser: false,
            timestamp: Date(),
            toolName: name,
            toolStatus: status,
            toolDisplayData: toolDisplayData,
            toolDetails: detailsArray,
            toolDuration: duration,
            toolIcon: icon,
            toolCategory: category,
            parentToolName: parentToolName,
            toolCallId: toolCallId,
            processingTime: nil,
            reasoningContent: nil,
            showReasoning: false,
            performanceMetrics: nil,
            isStreaming: false,
            isToolMessage: true
        )

        /// DIAGNOSTIC: Track isToolMessage flag at creation
        let contentPrefix = message.content.prefix(60).replacingOccurrences(of: "\n", with: " ")
        logger.debug("TOOL_MESSAGE_CREATED: id=\(message.id), isToolMessage=\(message.isToolMessage), contentPrefix=[\(contentPrefix)]")

        appendMessage(message)
        scheduleSave()

        logger.debug("TOOL_MESSAGE: id=\(id.uuidString.prefix(8)), name=\(name), status=\(status)")
        return id
    }

    /// Update tool status (for tool lifecycle: running → success/error)
    public func updateToolStatus(
        id: UUID,
        status: ToolStatus,
        duration: TimeInterval? = nil,
        details: String? = nil,
        detailsArray: [String]? = nil
    ) {
        guard let index = messageCache[id] else {
            logger.error("TOOL_UPDATE: Message not found id=\(id.uuidString.prefix(8))")
            return
        }

        let current = messages[index]

        /// Update content if details provided
        let newContent = details ?? (detailsArray?.joined(separator: "\n")) ?? current.content

        let updated = EnhancedMessage(
            id: current.id,
            type: current.type,
            content: newContent,
            contentParts: current.contentParts,
            isFromUser: current.isFromUser,
            timestamp: current.timestamp,
            toolName: current.toolName,
            toolStatus: status, // Status changes
            toolDisplayData: current.toolDisplayData,
            toolDetails: detailsArray ?? current.toolDetails,
            toolDuration: duration ?? current.toolDuration,
            toolIcon: current.toolIcon,
            toolCategory: current.toolCategory,
            parentToolName: current.parentToolName,
            toolMetadata: current.toolMetadata,
            toolCalls: current.toolCalls,
            toolCallId: current.toolCallId,
            processingTime: current.processingTime,
            reasoningContent: current.reasoningContent,
            showReasoning: current.showReasoning,
            performanceMetrics: current.performanceMetrics,
            isStreaming: current.isStreaming,
            isToolMessage: current.isToolMessage,
            githubCopilotResponseId: current.githubCopilotResponseId,
            isPinned: current.isPinned,
            importance: current.importance,
            lastModified: Date()
        )

        messages[index] = updated
        scheduleSave()
    }

    /// Add reasoning/thinking message
    @discardableResult
    public func addThinkingMessage(
        reasoningContent: String,
        showReasoning: Bool = false
    ) -> UUID {
        let messageId = UUID()
        let message = EnhancedMessage(
            id: messageId,
            type: .thinking,
            content: "",
            isFromUser: false,
            timestamp: Date(),
            toolIcon: "brain.head.profile",
            reasoningContent: reasoningContent,
            showReasoning: showReasoning,
            isToolMessage: true
        )

        appendMessage(message)
        scheduleSave()

        logger.debug("THINKING_MESSAGE: id=\(messageId.uuidString.prefix(8))")
        return messageId
    }

    /// Add reasoning/thinking message with specific ID (for streaming compatibility)
    @discardableResult
    public func addThinkingMessage(
        id: UUID,
        reasoningContent: String,
        showReasoning: Bool = false
    ) -> UUID {
        let message = EnhancedMessage(
            id: id,
            type: .thinking,
            content: "",
            isFromUser: false,
            timestamp: Date(),
            toolIcon: "brain.head.profile",
            reasoningContent: reasoningContent,
            showReasoning: showReasoning,
            isToolMessage: true
        )

        appendMessage(message)
        scheduleSave()

        logger.debug("THINKING_MESSAGE: id=\(id.uuidString.prefix(8))")
        return id
    }

    // MARK: - Message Retrieval

    /// Get messages for API requests (filtered for API consumption)
    /// Returns ChatMessage to avoid circular dependency with APIFramework
    public func getMessagesForAPI(limit: Int? = nil) -> [ChatMessage] {
        let subset = limit.map { Array(messages.suffix($0)) } ?? messages

        return subset.compactMap { message in
            /// Filter out tool messages (API doesn't need them)
            guard !message.isToolMessage else { return nil }

            /// Filter out thinking messages
            guard message.type != .thinking else { return nil }

            let role = message.isFromUser ? "user" : "assistant"
            return ChatMessage(role: role, content: message.content)
        }
    }

    /// Get all messages for agent context (no filtering)
    public func getMessagesForAgent() -> [EnhancedMessage] {
        return messages
    }

    /// Get tool messages only (for tool hierarchy rendering)
    public func getToolMessages() -> [EnhancedMessage] {
        return messages.filter { $0.isToolMessage }
    }

    /// Clear all messages (for new conversations)
    public func clearMessages() {
        messages.removeAll()
        messageCache.removeAll()
        logger.debug("CLEAR: All messages removed")
    }

    /// Get message by ID
    public func getMessage(id: UUID) -> EnhancedMessage? {
        guard let index = messageCache[id] else { return nil }
        return messages[index]
    }

    // MARK: - Private Implementation

    private func appendMessage(_ message: EnhancedMessage) {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("MessageBus.appendMessage",
                                            duration: CFAbsoluteTimeGetCurrent() - perfStart)
        }

        messages.append(message)
        messageCache[message.id] = messages.count - 1

        /// CRITICAL FIX: Force SwiftUI update for tool messages
        /// Problem: @Published doesn't always trigger on array.append() mutations
        /// Solution: Reassign array to force @Published to fire objectWillChange
        if message.isToolMessage {
            messages = messages  // Force @Published to trigger
            logger.debug("IMMEDIATE_RENDER: Forced array reassignment for tool message id=\(message.id.uuidString.prefix(8))")
        }

        /// Sync to ConversationModel for persistence
        /// CRITICAL: User messages and tool messages sync IMMEDIATELY to prevent race conditions
        /// Assistant messages (streaming chunks) use throttled sync for performance
        /// FIX: User messages MUST sync immediately before AgentOrchestrator reads conversation.messages
        if message.isToolMessage || message.isFromUser {
            logger.debug("IMMEDIATE_SYNC: Critical message appended, syncing synchronously id=\(message.id.uuidString.prefix(8)), isUser=\(message.isFromUser), isTool=\(message.isToolMessage)")
            conversation?.syncMessagesFromMessageBus()
        } else {
            /// Assistant streaming messages use throttled sync (performance optimization)
            notifyConversationOfChanges()
        }
    }

    private func loadInitialMessages() {
        guard let conversation = conversation else {
            logger.warning("LOAD: No conversation reference")
            return
        }

        /// Load and sort by lastModified (or timestamp fallback)
        messages = conversation.messages.sorted {
            ($0.lastModified ?? $0.timestamp) < ($1.lastModified ?? $1.timestamp)
        }

        /// Rebuild cache for fast lookups
        rebuildCache()

        logger.debug("LOAD: Loaded \(messages.count) messages")
    }

    /// Load messages directly during initialization (bypasses subscription triggers)
    public func loadMessagesDirectly(_ messagesToLoad: [EnhancedMessage]) {
        messages = messagesToLoad.sorted {
            ($0.lastModified ?? $0.timestamp) < ($1.lastModified ?? $1.timestamp)
        }
        rebuildCache()
        logger.debug("LOAD_DIRECT: Loaded \(messages.count) messages without triggering subscriptions")
    }

    private func rebuildCache() {
        messageCache.removeAll()
        for (index, message) in messages.enumerated() {
            messageCache[message.id] = index
        }
    }

    private func scheduleSave() {
        /// Debounce to avoid saving every streaming chunk
        /// 500ms delay means ~2 saves per second max during rapid streaming
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(
            withTimeInterval: saveDebounceDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveMessages()
            }
        }
    }

    private func saveMessages() {
        guard let conversation = conversation,
              let conversationManager = conversationManager else {
            logger.warning("SAVE: Missing references")
            return
        }

        /// Capture messages on MainActor before dispatching
        let messagesToSave = self.messages

        /// Non-blocking async save (never blocks UI)
        persistenceQueue.async { [weak self, conversation, conversationManager] in
            guard let self = self else { return }

            /// Filter empty messages before persisting
            let nonEmptyMessages = messagesToSave.filter { message in
                /// Always keep user messages
                if message.isFromUser {
                    return true
                }

                let contentIsEmpty = message.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty

                /// Filter empty streaming artifacts
                if message.isStreaming && contentIsEmpty {
                    self.logger.warning("SAVE_FILTER: Removing empty streaming message id=\(message.id.uuidString.prefix(8)), isStreaming=\(message.isStreaming)")
                    return false
                }

                /// Keep messages with reasoning or tool metadata
                if message.hasReasoning || message.isToolMessage {
                    return true
                }

                /// CRITICAL: Keep messages with contentParts (images, videos, etc.)
                if let parts = message.contentParts, !parts.isEmpty {
                    return true
                }

                /// Filter empty assistant messages
                if contentIsEmpty {
                    self.logger.warning("SAVE_FILTER: Removing empty assistant message id=\(message.id.uuidString.prefix(8)), isStreaming=\(message.isStreaming), contentLength=0")
                    return false
                }
                
                return true
            }

            /// Update on main thread (ConversationModel is @MainActor)
            Task { @MainActor in
                let beforeCount = conversation.messages.count
                conversation.messages = nonEmptyMessages

                /// CRITICAL FIX: Use saveConversationsImmediately() instead of saveConversations()
                /// to avoid double debounce (MessageBus already has 500ms debounce).
                /// Double debounce was causing 1000ms total delay, risking message loss on crash.
                conversationManager.saveConversationsImmediately()

                if beforeCount != nonEmptyMessages.count {
                    self.logger.warning("SAVE: Message count changed from \(beforeCount) to \(nonEmptyMessages.count) - FILTERED OUT \(beforeCount - nonEmptyMessages.count) messages")
                }
                self.logger.debug("SAVE: Persisted \(nonEmptyMessages.count) messages")
            }
        }
    }

    /// Notify conversation to sync messages from MessageBus (with throttling for streaming)
    private func notifyConversationOfChanges() {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("MessageBus.notifyConversationOfChanges",
                                            duration: CFAbsoluteTimeGetCurrent() - perfStart)
        }

        /// Throttle syncs to prevent excessive UI updates during streaming
        /// 5ms = max 200 updates/sec, supports 50+ tps inference speed
        let now = Date()
        if let last = lastSyncTime, now.timeIntervalSince(last) < syncThrottleInterval {
            return // Skip this sync, too soon since last one
        }

        lastSyncTime = now

        Task { @MainActor in
            conversation?.syncMessagesFromMessageBus()
        }
    }

    /// DELTA SYNC: Notify conversation of specific message update
    /// This avoids copying entire message array - just update one message
    private func notifyConversationOfMessageUpdate(id: UUID, index: Int, message: EnhancedMessage) {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("MessageBus.notifyConversationOfMessageUpdate",
                                            duration: CFAbsoluteTimeGetCurrent() - perfStart)
        }

        /// CRITICAL: Throttle delta syncs during streaming to prevent SwiftUI churn
        /// At 40+ TPS, we get 40+ delta syncs per second
        /// SwiftUI re-renders on each objectWillChange.send()
        /// 30 FPS (33ms) is ideal balance between responsiveness and performance
        let now = Date()
        if let last = lastDeltaSyncTime, now.timeIntervalSince(last) < deltaSyncThrottleInterval {
            return // Skip this sync, too soon since last one
        }

        lastDeltaSyncTime = now

        Task { @MainActor in
            conversation?.updateMessage(at: index, with: message)
        }
    }

    // MARK: - Intelligent Importance Scoring

    /// Calculate importance score for message based on content and type
    /// Higher scores (closer to 1.0) = more important, more likely to be retrieved.
    private func calculateMessageImportance(text: String, isUser: Bool) -> Double {
        let lowercased = text.lowercased()

        /// BASE IMPORTANCE: User messages more important than assistant messages.
        var importance = isUser ? 0.7 : 0.5

        /// QUESTIONS FROM ASSISTANT (0.85 importance) - Agent needs to remember what it asked!
        if !isUser && (text.contains("?") || lowercased.contains("what") || lowercased.contains("which") || lowercased.contains("how")) {
            importance = max(importance, 0.85)
        }

        /// CONSTRAINT/REQUIREMENT INDICATORS (0.9 importance).
        let constraintKeywords = ["must", "require", "need to", "budget", "limit", "maximum", "minimum", "within", "miles", "radius", "constraint"]
        if constraintKeywords.contains(where: { lowercased.contains($0) }) {
            importance = max(importance, 0.9)
        }

        /// DECISION/CONFIRMATION INDICATORS (0.85 importance).
        let decisionKeywords = ["yes", "proceed", "approved", "confirmed", "agree", "correct", "exactly", "that's right", "go ahead"]
        if decisionKeywords.contains(where: { lowercased.contains($0) }) && text.count < 200 {
            importance = max(importance, 0.85)
        }

        /// PRIORITY/FOCUS SHIFT INDICATORS (0.85 importance).
        let priorityKeywords = ["focus on", "prioritize", "most important", "critical", "priority", "key requirement"]
        if priorityKeywords.contains(where: { lowercased.contains($0) }) {
            importance = max(importance, 0.85)
        }

        /// SMALL TALK / LOW VALUE (0.3 importance).
        let smallTalkPhrases = ["thanks", "thank you", "ok", "okay", "got it", "sounds good", "perfect", "great"]
        if text.count < 50 && smallTalkPhrases.contains(where: { lowercased == $0 || lowercased == $0 + "!" || lowercased == $0 + "." }) {
            importance = 0.3
        }

        /// BOOST FOR LONGER USER MESSAGES (more substance = more important).
        if isUser && text.count > 300 {
            importance = min(importance + 0.1, 1.0)
        }

        return importance
    }
}
