// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging
import MCPFramework
import ConfigurationSystem

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a conversation is updated (messages added, edited, etc.) Object contains the conversation UUID.
    public static let conversationDidUpdate = Notification.Name("conversationDidUpdate")
    
    /// Posted when a conversation's working directory changes. Object contains the conversation ID, userInfo contains new path.
    public static let conversationWorkingDirectoryDidChange = Notification.Name("conversationWorkingDirectoryDidChange")
}

// MARK: - Logging

/// Local logger for ConversationEngine to avoid circular dependencies with APIFramework.
private let logger = Logger(label: "com.sam.conversation.ConversationManager")

// MARK: - Protocol Conformance

/// Protocol for AI providers to avoid importing APIFramework.
public protocol AIProviderProtocol: AnyObject {
    func processStreamingChatCompletion(_ messages: [ChatMessage], model: String, temperature: Double, sessionId: String?) async throws -> AsyncThrowingStream<ChatResponseChunk, Error>
}

/// Chat message structure (local to avoid circular dependencies).
public struct ChatMessage: Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Chat response chunk (local to avoid circular dependencies).
public struct ChatResponseChunk: Sendable {
    public let content: String?

    public init(content: String?) {
        self.content = content
    }
}

@MainActor
public class ConversationManager: ObservableObject {
    @Published public var conversations: [ConversationModel] = []
    @Published public var activeConversation: ConversationModel?

    /// Terminal managers for each conversation (stored as AnyObject to avoid module dependency) Key: Conversation UUID, Value: TerminalManager instance Persists across view recreations, maintaining terminal history per conversation.
    private var terminalManagers: [UUID: AnyObject] = [:]
    @Published public var isReady = true

    private let logger = Logger(label: "com.syntheticautonomicmind.sam.ConversationManager")
    private let conversationConfig = ConversationConfigurationManager()

    /// Runtime state management for all conversations
    /// Tracks ephemeral state (processing status, active tools, etc.) that persists across conversation switches
    public let stateManager = ConversationStateManager()

    /// Memory management integration.
    public let memoryManager = MemoryManager()
    @Published public var memoryInitialized = false

    /// Enhanced memory capabilities - Vector RAG Service.
    public let vectorRAGService: VectorRAGService
    @Published public var ragServiceInitialized = false

    /// Context management - YaRN Context Processor.
    public let yarnContextProcessor: YaRNContextProcessor
    @Published public var contextProcessorInitialized = false

    /// MCP framework integration for agent-tool communication.
    public let mcpManager = MCPManager()
    @Published public var mcpInitialized = false

    /// Context Archive Manager for long-term memory (stores rolled-off context).
    public let contextArchiveManager = ContextArchiveManager()
    @Published public var contextArchiveInitialized = false

    /// AI Provider for real AI calls with MCP integration.
    private var aiProvider: AIProviderProtocol?

    /// System Prompt Manager for retrieving selected system prompts.
    private var systemPromptManager: SystemPromptManager?

    // MARK: - Bug #3: Message Buffer Architecture (Debounced Persistence)

    /// Tracks whether conversations have unsaved changes.
    private var isDirty = false

    /// Debounce task for batching saves (prevents excessive disk I/O).
    private var saveTask: Task<Void, Never>?

    /// Debounce delay in seconds (wait this long after last change before saving).
    private let saveDebounceDelay: TimeInterval = 0.5

    public init(aiProvider: AIProviderProtocol? = nil) {
        self.aiProvider = aiProvider

        /// Initialize Vector RAG Service.
        self.vectorRAGService = VectorRAGService(memoryManager: memoryManager)

        /// Initialize YaRN Context Processor with default configuration.
        /// Fallback token estimator: ~4 characters per token (standard approximation).
        self.yarnContextProcessor = YaRNContextProcessor(
            memoryManager: memoryManager,
            tokenEstimator: { text in text.count / 4 }
        )

        logger.debug("ConversationManager initializing")
        logger.debug("ConversationManager: Initializing conversation system")

        if aiProvider != nil {
            logger.debug("ConversationManager initialized with AI provider integration")
        } else {
            logger.warning("ConversationManager initialized without AI provider - will use placeholder responses")
        }

        /// Load saved conversations first.
        loadConversations()

        /// Restore active conversation if any exist.
        /// Don't auto-create conversation - let Welcome panel handle initial creation.
        if !conversations.isEmpty {
            restoreActiveConversation()
        }

        /// Initialize systems.
        Task {
            await initializeMemorySystem()
            await initializeVectorRAGSystem()
            await initializeYaRNContextProcessor()
            await initializeContextArchiveSystem()
            await initializeMCPSystem()
        }

        logger.debug("ConversationManager initialized with \(self.conversations.count) conversations")
        logger.debug("ConversationManager: Ready with \(self.conversations.count) conversations")
    }

    /// Inject AI provider after initialization to resolve circular dependency.
    public func injectAIProvider(_ aiProvider: AIProviderProtocol) {
        self.aiProvider = aiProvider
        logger.debug("AI provider injected into ConversationManager - real AI responses now available")
        logger.debug("ConversationManager: AI provider integration enabled")
    }

    /// Inject System Prompt Manager after initialization to resolve circular dependency.
    public func injectSystemPromptManager(_ manager: SystemPromptManager) {
        self.systemPromptManager = manager
        logger.debug("SystemPromptManager injected into ConversationManager - selected prompts now available")
    }

    public func createNewConversation() {
        /// Generate sequential name for conversation
        let baseName = "New Conversation"
        let uniqueTitle = generateUniqueConversationTitle(baseName: baseName)

        let conversation = ConversationModel(title: uniqueTitle)

        /// Set manager reference for change propagation (enables real-time streaming)
        conversation.manager = self

        /// Initialize MessageBus for new conversation
        conversation.initializeMessageBus(conversationManager: self)

        /// Use user's preferred default system prompt (or SAM Default if not set)
        let promptManager = SystemPromptManager.shared
        let defaultPromptUUID = UUID(uuidString: promptManager.defaultSystemPromptId)
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        conversation.settings.selectedSystemPromptId = defaultPromptUUID
        logger.debug("Set new conversation to use default system prompt: \(defaultPromptUUID)")

        /// Insert at beginning since we sort by created date (newest first)
        conversations.insert(conversation, at: 0)
        activeConversation = conversation

        /// Save conversations to persistence.
        saveConversations()

        logger.debug("Created new conversation: \(conversation.id)")
        logger.debug("New conversation created: \(conversation.title)")
    }

    /// Generate unique conversation title with sequential numbering
    private func generateUniqueConversationTitle(baseName: String) -> String {
        /// Check if base name is already used
        let existingTitles = Set(conversations.map { $0.title })

        if !existingTitles.contains(baseName) {
            return baseName
        }

        /// Find next available number
        var number = 2
        while existingTitles.contains("\(baseName) (\(number))") {
            number += 1
        }

        return "\(baseName) (\(number))"
    }

    public func selectConversation(_ conversation: ConversationModel) {
        activeConversation = conversation

        /// Save active conversation to persistence.
        saveConversations()

        logger.debug("Selected conversation: \(conversation.title)")
        logger.debug("Selected: \(conversation.title) (\(conversation.messages.count) messages)")
    }

    /// Delete a conversation - Parameters: - conversation: The conversation to delete - deleteWorkingDirectory: Whether to also delete the working directory (default: true) - Returns: Information about the working directory deletion (path, isEmpty, deleted).
    @discardableResult
    public func deleteConversation(_ conversation: ConversationModel, deleteWorkingDirectory: Bool = true) -> (workingDirectoryPath: String, isEmpty: Bool, deleted: Bool) {
        /// Clear runtime state before deleting conversation
        stateManager.clearState(conversationId: conversation.id)

        conversations.removeAll { $0.id == conversation.id }
        if activeConversation?.id == conversation.id {
            activeConversation = conversations.first
        }

        /// Delete per-file storage for this conversation
        try? conversationConfig.deleteConversationFile(conversation.id)

        /// SUCCESS: MEMORY_ISOLATION: Delete conversation's isolated database Location: ~/Library/Application Support/SAM/conversations/{UUID}/.
        do {
            try memoryManager.deleteConversationDatabase(conversationId: conversation.id)
        } catch {
            logger.error("Failed to delete database for conversation \(conversation.id): \(error)")
        }

        /// Delete working directory if requested Location: conversation.workingDirectory (default: {basePath}/{title}/, but user-configurable).
        let workingDirPath = conversation.workingDirectory
        var isEmpty = false
        var deleted = false

        if deleteWorkingDirectory {
            let fileManager = FileManager.default
            let workingDirURL = URL(fileURLWithPath: conversation.workingDirectory)

            /// Check if directory exists.
            if fileManager.fileExists(atPath: conversation.workingDirectory) {
                do {
                    /// Check if directory is empty.
                    let contents = try fileManager.contentsOfDirectory(atPath: conversation.workingDirectory)
                    isEmpty = contents.isEmpty

                    if isEmpty {
                        /// Empty directory - delete automatically.
                        try fileManager.removeItem(at: workingDirURL)
                        deleted = true
                        logger.debug("Deleted empty working directory: \(conversation.workingDirectory)")
                    } else {
                        /// Non-empty directory - caller should prompt user.
                        logger.debug("Working directory not empty (\(contents.count) items): \(conversation.workingDirectory)")
                    }
                } catch {
                    logger.error("Failed to check/delete working directory: \(error)")
                }
            } else {
                logger.debug("Working directory does not exist: \(conversation.workingDirectory)")
                isEmpty = true
                deleted = true
            }
        }

        /// Save conversations after deletion.
        saveConversations()

        logger.debug("Deleted conversation: \(conversation.title)")

        return (workingDirPath, isEmpty, deleted)
    }

    /// Force delete a working directory (when user confirms deletion of non-empty directory) - Parameter path: The directory path to delete - Returns: True if successfully deleted, false otherwise.
    public func forceDeleteWorkingDirectory(path: String) -> Bool {
        let fileManager = FileManager.default
        let directoryURL = URL(fileURLWithPath: path)

        guard fileManager.fileExists(atPath: path) else {
            logger.debug("Directory does not exist: \(path)")
            return true
        }

        do {
            try fileManager.removeItem(at: directoryURL)
            logger.debug("Force deleted working directory: \(path)")
            return true
        } catch {
            logger.error("Failed to force delete working directory: \(error)")
            return false
        }
    }

    /// Delete all conversations with optional directory cleanup
    /// - Parameter deleteDirectories: If true, also deletes working directories for non-shared conversations
    public func deleteAllConversations(deleteDirectories: Bool = false) {
        let conversationCount = conversations.count
        let pinnedConversations = conversations.filter { $0.isPinned }
        let unpinnedConversations = conversations.filter { !$0.isPinned }

        /// Separate shared and isolated conversations
        let isolatedConversations = unpinnedConversations.filter { !$0.settings.useSharedData }
        let sharedConversations = unpinnedConversations.filter { $0.settings.useSharedData }

        /// Clear runtime state for all unpinned conversations before deleting
        for conversation in unpinnedConversations {
            stateManager.clearState(conversationId: conversation.id)
        }

        /// Delete memory databases for all unpinned conversations
        for conversation in unpinnedConversations {
            do {
                try memoryManager.deleteConversationDatabase(conversationId: conversation.id)
                logger.debug("Deleted memory database for conversation \(conversation.id)")
            } catch {
                logger.error("Failed to delete memory database for conversation \(conversation.id): \(error)")
            }
        }

        /// Remove only unpinned conversations
        conversations.removeAll { !$0.isPinned }

        /// If active conversation was deleted, clear it
        if let active = activeConversation, !active.isPinned {
            activeConversation = pinnedConversations.first
        }

        /// Delete directories for isolated conversations if requested
        var deletedDirectoryCount = 0
        if deleteDirectories {
            for conversation in isolatedConversations {
                let directory = conversation.workingDirectory

                /// Safety check: Path must contain conversation UUID
                guard directory.contains(conversation.id.uuidString) else {
                    logger.warning("Skipping directory deletion: \(directory) (safety check failed)")
                    continue
                }

                /// Additional safety: Never delete shared topic directories
                guard !conversation.settings.useSharedData else {
                    logger.warning("Skipping shared topic directory: \(directory)")
                    continue
                }

                do {
                    let fileManager = FileManager.default
                    if fileManager.fileExists(atPath: directory) {
                        try fileManager.removeItem(atPath: directory)
                        deletedDirectoryCount += 1
                        logger.info("Deleted directory: \(directory)")
                    }
                } catch {
                    logger.error("Failed to delete directory \(directory): \(error)")
                    /// Continue with next directory - don't fail entire operation
                }
            }
        }

        /// Save updated conversations list
        saveConversations()

        let deletedCount = conversationCount - pinnedConversations.count
        logger.info("""
            Deleted \(deletedCount) conversations (\(pinnedConversations.count) pinned protected)
            - Isolated: \(isolatedConversations.count)
            - Shared: \(sharedConversations.count)
            - Directories deleted: \(deletedDirectoryCount)
            """)
    }

    /// Get count of conversations that would be deleted
    public func getDeleteAllConversationsInfo() -> (totalToDelete: Int, withDirectories: Int, pinned: Int) {
        let pinnedCount = conversations.filter { $0.isPinned }.count
        let unpinned = conversations.filter { !$0.isPinned }
        let isolated = unpinned.filter { !$0.settings.useSharedData }

        return (totalToDelete: unpinned.count, withDirectories: isolated.count, pinned: pinnedCount)
    }

    public func renameConversation(_ conversation: ConversationModel, to newName: String) {
        let oldTitle = conversation.title
        let oldWorkingDir = conversation.workingDirectory

        conversation.title = newName
        conversation.updated = Date()

        /// Rename working directory to match new name (only for non-shared-data conversations)
        if !conversation.settings.useSharedData {
            let safeName = newName.replacingOccurrences(of: "/", with: "-")
            let newWorkingDir = NSString(string: "~/SAM/\(safeName)/").expandingTildeInPath

            /// Check if old directory exists and new directory doesn't
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: oldWorkingDir) && !fileManager.fileExists(atPath: newWorkingDir) {
                do {
                    try fileManager.moveItem(atPath: oldWorkingDir, toPath: newWorkingDir)
                    conversation.workingDirectory = newWorkingDir
                    logger.debug("Renamed working directory: \(oldWorkingDir) -> \(newWorkingDir)")

                    /// Reset terminal session for new directory
                    resetTerminalForWorkingDirectoryChange(conversation: conversation, newPath: newWorkingDir)
                } catch {
                    logger.error("Failed to rename working directory: \(error)")
                    /// Continue anyway - conversation rename should still work
                }
            } else if fileManager.fileExists(atPath: newWorkingDir) {
                /// Directory with new name already exists - make unique
                var counter = 2
                var uniqueWorkingDir = NSString(string: "~/SAM/\(safeName) (\(counter))/").expandingTildeInPath
                while fileManager.fileExists(atPath: uniqueWorkingDir) {
                    counter += 1
                    uniqueWorkingDir = NSString(string: "~/SAM/\(safeName) (\(counter))/").expandingTildeInPath
                }

                do {
                    try fileManager.moveItem(atPath: oldWorkingDir, toPath: uniqueWorkingDir)
                    conversation.workingDirectory = uniqueWorkingDir
                    conversation.title = "\(newName) (\(counter))"
                    logger.debug("Renamed working directory with unique suffix: \(oldWorkingDir) -> \(uniqueWorkingDir)")

                    /// Reset terminal session for new directory
                    resetTerminalForWorkingDirectoryChange(conversation: conversation, newPath: uniqueWorkingDir)
                } catch {
                    logger.error("Failed to rename working directory: \(error)")
                }
            }
        }

        /// Trigger view update for sorting recalculation.
        objectWillChange.send()

        /// Save conversations after rename.
        saveConversations()

        logger.debug("Renamed conversation to: \(newName)")
        logger.debug("Renamed conversation from '\(oldTitle)' to '\(newName)'")
    }

    // MARK: - Shared Topic Helpers

    /// Attach a shared topic to the active conversation (enable shared data and set topic id).
    public func attachSharedTopic(topicId: UUID?, topicName: String? = nil) {
        guard let conversation = activeConversation else {
            logger.warning("No active conversation to attach shared topic")
            return
        }

        /// Save old effective working directory BEFORE changing settings
        let oldEffectiveDir = getEffectiveWorkingDirectory(for: conversation)
        logger.debug("attachSharedTopic: old effective dir = \(oldEffectiveDir)")

        if let topicId = topicId {
            conversation.settings.useSharedData = true
            conversation.settings.sharedTopicId = topicId
            conversation.settings.sharedTopicName = topicName
            logger.debug("Attached shared topic \(topicId) (\(topicName ?? "unknown")) to conversation \(conversation.id)")
        } else {
            conversation.settings.useSharedData = false
            conversation.settings.sharedTopicId = nil
            conversation.settings.sharedTopicName = nil
            logger.debug("Detached shared topic from conversation \(conversation.id)")
        }

        conversation.updated = Date()
        saveConversations()
        objectWillChange.send()

        /// Check if effective working directory changed and notify terminal
        let newEffectiveDir = getEffectiveWorkingDirectory(for: conversation)
        logger.debug("attachSharedTopic: new effective dir = \(newEffectiveDir)")
        
        if newEffectiveDir != oldEffectiveDir {
            logger.info("Effective working directory changed from \(oldEffectiveDir) to \(newEffectiveDir), triggering terminal reset")
            resetTerminalForWorkingDirectoryChange(conversation: conversation, newPath: newEffectiveDir)
        } else {
            logger.debug("Effective working directory unchanged: \(newEffectiveDir)")
        }
    }

    /// Detach shared topic from active conversation.
    public func detachSharedTopic() {
        attachSharedTopic(topicId: nil)
    }

    /// Restart terminal session for a conversation when working directory changes
    /// This ensures the terminal uses the correct working directory after shared topic changes
    public func restartTerminalSession(for conversationId: UUID) {
        // Close existing PTY session if it exists
        // The session ID is the conversation ID (per PTYSessionManager design)
        let sessionId = conversationId.uuidString

        do {
            // Import PTYSessionManager to access the shared instance
            try PTYSessionManager.shared.closeSession(sessionId: sessionId)
            logger.debug("Closed terminal session for conversation \(conversationId) - will recreate with new working directory on next use")
        } catch {
            // Session might not exist, which is fine
            logger.debug("No existing terminal session to close for conversation \(conversationId): \(error)")
        }
    }

    // MARK: - Working Directory Management

    /// Get the working directory for the active conversation.
    public var currentWorkingDirectory: String? {
        return activeConversation?.workingDirectory
    }

    /// Update the working directory for the active conversation - Parameter newPath: The new working directory path.
    public func updateWorkingDirectory(_ newPath: String) {
        guard let conversation = activeConversation else {
            logger.warning("No active conversation to update working directory")
            return
        }

        /// Validate path exists or create it.
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if !fileManager.fileExists(atPath: newPath, isDirectory: &isDirectory) {
            /// Create directory if it doesn't exist.
            do {
                try fileManager.createDirectory(
                    atPath: newPath,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                logger.debug("Created working directory: \(newPath)")
            } catch {
                logger.error("Failed to create working directory: \(error)")
                return
            }
        } else if !isDirectory.boolValue {
            logger.error("Working directory path exists but is not a directory: \(newPath)")
            return
        }

        /// Update conversation working directory.
        conversation.workingDirectory = newPath
        conversation.updated = Date()

        /// Save conversations after update.
        saveConversations()

        logger.debug("Updated working directory for conversation '\(conversation.title)' to: \(newPath)")
    }

    /// Get working directory for a specific conversation ID - Parameter conversationId: The conversation UUID - Returns: Working directory path, or nil if conversation not found.
    public func getWorkingDirectory(for conversationId: UUID) -> String? {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            logger.warning("Conversation not found for ID: \(conversationId)")
            return nil
        }
        return conversation.workingDirectory
    }

    /// Get the effective working directory for a conversation
    /// If shared data is enabled and a topic is assigned, returns the topic's files directory
    /// Otherwise returns the conversation's default working directory
    public func getEffectiveWorkingDirectory(for conversation: ConversationModel) -> String {
        // Check if shared data is enabled and topic is assigned
        if conversation.settings.useSharedData,
           conversation.settings.sharedTopicId != nil,
           let topicName = conversation.settings.sharedTopicName {
            // Build path to topic directory using topic name
            // Format: ~/SAM/{topicName}/
            let safeName = topicName.replacingOccurrences(of: "/", with: "-")
            let topicDirPath = NSString(string: "~/SAM/\(safeName)/").expandingTildeInPath
            return topicDirPath
        }

        // Use conversation-specific working directory
        return conversation.workingDirectory
    }

    /// Get effective scope ID for memory/data operations
    /// When shared data enabled: returns sharedTopicId (conversations share memory)
    /// Otherwise returns conversationId (isolated memory)
    public func getEffectiveScopeId(for conversation: ConversationModel) -> UUID {
        if conversation.settings.useSharedData,
           let topicId = conversation.settings.sharedTopicId {
            return topicId
        }
        return conversation.id
    }

    /// Ensure working directory exists for a conversation - Parameter conversation: The conversation to check.
    private func ensureWorkingDirectoryExists(for conversation: ConversationModel) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if !fileManager.fileExists(atPath: conversation.workingDirectory, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(
                    atPath: conversation.workingDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                logger.debug("Created working directory: \(conversation.workingDirectory)")
            } catch {
                logger.error("Failed to create working directory: \(error)")
            }
        }
    }

    // MARK: - Management

    /// Update working directory with security-scoped bookmark - Parameters: - url: The selected directory URL - conversation: The conversation to update (defaults to active).
    public func updateWorkingDirectoryWithBookmark(_ url: URL, for conversation: ConversationModel? = nil) {
        let targetConversation = conversation ?? activeConversation
        guard let conversation = targetConversation else {
            logger.warning("No conversation to update working directory")
            return
        }

        /// Store old path to check if it changed
        let oldPath = conversation.workingDirectory

        /// Create security-scoped bookmark.
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            /// Update conversation.
            conversation.workingDirectory = url.path
            conversation.workingDirectoryBookmark = bookmarkData
            conversation.updated = Date()

            /// Save conversations.
            saveConversations()

            logger.debug("Updated working directory with bookmark: \(url.path)")

            /// Scan workspace for AI instruction files (copilot-instructions.md, .cursorrules, etc.).
            SystemPromptManager.shared.scanWorkspaceForAIInstructions(at: url.path)

            /// Reset terminal session if path changed
            /// This ensures terminal starts in new directory without cd injection
            if oldPath != url.path {
                resetTerminalForWorkingDirectoryChange(conversation: conversation, newPath: url.path)
            }
        } catch {
            logger.error("Failed to create security-scoped bookmark: \(error)")
        }
    }

    /// Reset terminal session when working directory changes
    /// Shared helper to avoid code duplication
    private func resetTerminalForWorkingDirectoryChange(conversation: ConversationModel, newPath: String) {
        /// DEADLOCK FIX: Removed synchronous performSelector call that blocked main thread.
        /// Terminal will auto-update working directory from conversation.workingDirectory
        /// when next accessed. PTYSessionManager already uses conversation's working directory.
        ///
        /// Previous implementation caused deadlock:
        /// 1. ConversationManager (@MainActor) runs on main thread
        /// 2. perform(selector:with:) is SYNCHRONOUS - blocks until complete
        /// 3. resetSessionForNewDirectory is async and waits for terminal response
        /// 4. Terminal can't respond because main thread is blocked
        /// 5. Result: CLASSIC DEADLOCK
        ///
        /// NEW FIX: Post notification for terminal to observe and react to
        logger.info("Working directory changed to: \(newPath), posting notification for conversation \(conversation.id.uuidString.prefix(8))")
        
        NotificationCenter.default.post(
            name: .conversationWorkingDirectoryDidChange,
            object: conversation.id,
            userInfo: ["newPath": newPath]
        )
    }

    /// Start accessing security-scoped resource for conversation - Parameter conversation: The conversation (defaults to active) - Returns: True if access started successfully.
    @discardableResult
    public func startAccessingWorkingDirectory(for conversation: ConversationModel? = nil) -> Bool {
        let targetConversation = conversation ?? activeConversation
        guard let conversation = targetConversation,
              let bookmarkData = conversation.workingDirectoryBookmark else {
            /// No bookmark - directory uses configured base path (has entitlement) or will fail.
            return true
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                logger.warning("Security-scoped bookmark is stale, needs refresh")
                /// FUTURE FEATURE: Request user to re-select directory **Current behavior**: Log warning, continue with stale bookmark **Desired behavior**: Show UI dialog requesting user re-select working directory **Why not implemented**: Requires UI layer integration - ConversationManager is model/business logic layer - UI prompts should come from view layer - Need ConversationManagerProtocol extension for UI callbacks **Implementation approach**: 1.
            }

            /// Start accessing the resource.
            let accessGranted = url.startAccessingSecurityScopedResource()
            if accessGranted {
                logger.debug("Started accessing security-scoped directory: \(url.path)")
            } else {
                logger.warning("Failed to start accessing security-scoped directory: \(url.path)")
            }

            return accessGranted
        } catch {
            logger.error("Failed to resolve security-scoped bookmark: \(error)")
            return false
        }
    }

    /// Stop accessing security-scoped resource for conversation - Parameter conversation: The conversation (defaults to active).
    public func stopAccessingWorkingDirectory(for conversation: ConversationModel? = nil) {
        let targetConversation = conversation ?? activeConversation
        guard let conversation = targetConversation,
              let bookmarkData = conversation.workingDirectoryBookmark else {
            /// No bookmark - nothing to stop.
            return
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            url.stopAccessingSecurityScopedResource()
            logger.debug("Stopped accessing security-scoped directory: \(url.path)")
        } catch {
            logger.error("Failed to resolve security-scoped bookmark for stop: \(error)")
        }
    }

    // MARK: - Terminal Manager Storage

    /// Get terminal manager for a conversation (creates if doesn't exist) - Parameter conversationId: The conversation UUID - Returns: Terminal manager instance (AnyObject - cast to TerminalManager in UserInterface).
    public func getTerminalManager(for conversationId: UUID) -> AnyObject? {
        logger.debug("TERMINAL_STORAGE: Getting manager for conversation \(conversationId)")

        if let existing = terminalManagers[conversationId] {
            logger.debug("TERMINAL_STORAGE: Found existing manager")
            return existing
        } else {
            logger.debug("TERMINAL_STORAGE: No existing manager found")
            return nil
        }
    }

    /// Store terminal manager for a conversation - Parameters: - manager: Terminal manager instance - conversationId: The conversation UUID.
    public func setTerminalManager(_ manager: AnyObject, for conversationId: UUID) {
        logger.debug("TERMINAL_STORAGE: Storing manager for conversation \(conversationId)")
        terminalManagers[conversationId] = manager
    }

    /// Remove terminal manager for a conversation (cleanup) - Parameter conversationId: The conversation UUID.
    public func removeTerminalManager(for conversationId: UUID) {
        logger.debug("TERMINAL_STORAGE: Removing manager for conversation \(conversationId)")
        terminalManagers.removeValue(forKey: conversationId)
    }

    // MARK: - Session Management (Task 19: Prevent State Leakage)

    /// Create a conversation session for safe async operations
    /// Sessions snapshot conversation context preventing data leakage when user switches conversations
    /// - Parameter conversationId: UUID of conversation to create session for
    /// - Returns: Conversation session, or nil if conversation not found
    public func createSession(for conversationId: UUID) -> ConversationSession? {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            logger.warning("Cannot create session: Conversation \(conversationId) not found")
            return nil
        }

        let workingDirectory = getEffectiveWorkingDirectory(for: conversation)
        let terminalManager = getTerminalManager(for: conversationId)

        let session = ConversationSession(
            conversationId: conversationId,
            workingDirectory: workingDirectory,
            terminalManager: terminalManager
        )

        // Register session with state manager
        stateManager.registerSession(session, for: conversationId)

        logger.debug("Created session for conversation \(conversationId)")
        return session
    }

    /// Get active session for a conversation
    /// - Parameter conversationId: UUID of conversation
    /// - Returns: Active session if exists and valid
    public func getSession(for conversationId: UUID) -> ConversationSession? {
        return stateManager.getSession(for: conversationId)
    }

    /// Invalidate session for a conversation
    /// Called when conversation is deleted or operations should be cancelled
    /// - Parameter conversationId: UUID of conversation
    public func invalidateSession(for conversationId: UUID) {
        stateManager.invalidateSession(for: conversationId)
        logger.debug("Invalidated session for conversation \(conversationId)")
    }

    public func duplicateConversation(_ conversation: ConversationModel) -> ConversationModel {
        let uniqueTitle = generateUniqueConversationTitle(baseName: "\(conversation.title) Copy")
        let duplicatedConversation = ConversationModel(title: uniqueTitle)

        /// Set manager reference for change propagation (enables real-time streaming)
        duplicatedConversation.manager = self

        /// Initialize MessageBus for duplicated conversation
        duplicatedConversation.initializeMessageBus(conversationManager: self)

        /// Copy all messages using MessageBus
        guard let messageBus = duplicatedConversation.messageBus else {
            logger.error("Cannot duplicate messages - MessageBus not initialized")
            return duplicatedConversation
        }
        for message in conversation.messages {
            if message.isFromUser {
                _ = messageBus.addUserMessage(content: message.content, timestamp: message.timestamp)
            } else {
                _ = messageBus.addAssistantMessage(content: message.content, timestamp: message.timestamp)
            }
        }

        conversations.append(duplicatedConversation)

        /// Save conversations after duplication.
        saveConversations()

        logger.debug("Duplicated conversation: \(conversation.title)")
        logger.debug("Duplicated conversation: \(conversation.title)")

        return duplicatedConversation
    }

    /// Estimate token count for text (simplified approximation).
    private func estimateTokenCount(_ text: String) -> Int {
        return max(1, text.count / 4)
    }

    // MARK: - Persistence Methods

    private func loadConversations() {
        do {
            self.conversations = try conversationConfig.loadConversationsWithMigration()

            /// Sort conversations by created date (newest first) for consistent ordering
            self.conversations.sort { $0.created > $1.created }

            logger.debug("Loaded \(self.conversations.count) conversations from storage")

            /// Initialize MessageBus for all loaded conversations
            for conversation in self.conversations {
                conversation.manager = self  // Set manager reference for change propagation
                conversation.initializeMessageBus(conversationManager: self)
            }
            logger.debug("Initialized MessageBus for \(self.conversations.count) conversations")

            /// MIGRATION: Auto-pin first 3 user messages in conversations that don't have pinning
            /// This ensures context retrieval works for conversations created before auto-pinning feature
            var pinnedMigrationCount = 0
            for conversation in self.conversations {
                var userMessageCount = 0
                var needsSave = false

                for i in 0..<conversation.messages.count {
                    let message = conversation.messages[i]
                    if message.isFromUser {
                        userMessageCount += 1
                        /// Pin first 3 user messages if not already pinned
                        if userMessageCount <= 3 && !message.isPinned {
                            /// Create updated message with isPinned = true
                            let updatedMessage = ConfigurationSystem.EnhancedMessage(
                                id: message.id,
                                type: message.type,
                                content: message.content,
                                contentParts: message.contentParts,
                                isFromUser: message.isFromUser,
                                timestamp: message.timestamp,
                                toolName: message.toolName,
                                toolStatus: message.toolStatus,
                                toolDisplayData: message.toolDisplayData,
                                toolDetails: message.toolDetails,
                                toolDuration: message.toolDuration,
                                toolIcon: message.toolIcon,
                                toolCategory: message.toolCategory,
                                parentToolName: message.parentToolName,
                                toolMetadata: message.toolMetadata,
                                toolCalls: message.toolCalls,
                                toolCallId: message.toolCallId,
                                processingTime: message.processingTime,
                                reasoningContent: message.reasoningContent,
                                showReasoning: message.showReasoning,
                                performanceMetrics: message.performanceMetrics,
                                isStreaming: message.isStreaming,
                                isToolMessage: message.isToolMessage,
                                githubCopilotResponseId: message.githubCopilotResponseId,
                                isPinned: true, // AUTO-PIN
                                importance: message.importance > 0 ? message.importance : 0.7, // Ensure importance
                                lastModified: message.lastModified
                            )
                            /// MIGRATION: Direct array mutation is acceptable here because:
                            /// 1. This is a one-time migration (runs only once per conversation)
                            /// 2. We reload MessageBus immediately after with loadMessagesDirectly()
                            /// 3. Normal code should use messageBus?.updateMessage() instead
                            conversation.messages[i] = updatedMessage
                            needsSave = true
                            pinnedMigrationCount += 1
                        }
                    }
                }

                if needsSave {
                    /// Reload MessageBus with migrated messages
                    conversation.messageBus?.loadMessagesDirectly(conversation.messages)
                }
            }

            if pinnedMigrationCount > 0 {
                logger.info("MIGRATION: Auto-pinned \(pinnedMigrationCount) user messages across \(self.conversations.count) conversations")
                /// Save conversations with migrated pinning
                saveConversations()
            }

            /// MIGRATION: Update working directories for conversations using old UUID-based paths
            /// New conversations use ~/SAM/{title}/, but old ones used ~/SAM/{UUID}/
            /// This migrates old conversations to the new format
            var migrationCount = 0
            let samBasePath = NSString(string: "~/SAM/").expandingTildeInPath

            /// CRITICAL SAFETY: Helper to validate paths are in ~/SAM/ directory
            func isSafeSAMPath(_ path: String) -> Bool {
                let expandedPath = (path as NSString).expandingTildeInPath
                return expandedPath.hasPrefix(samBasePath) && expandedPath != samBasePath
            }

            /// Use indices to safely modify conversations during iteration
            for index in self.conversations.indices {
                let conversation = self.conversations[index]
                let safeName = conversation.title.replacingOccurrences(of: "/", with: "-")
                let expectedPath = NSString(string: "~/SAM/\(safeName)/").expandingTildeInPath

                /// CRITICAL SAFETY: Validate old working directory is in ~/SAM/
                guard isSafeSAMPath(conversation.workingDirectory) else {
                    logger.warning("MIGRATION SKIP: Working directory '\(conversation.workingDirectory)' is not in ~/SAM/ - refusing to migrate for safety")
                    continue
                }

                /// Check if this conversation needs migration (UUID-based path → title-based path)
                if conversation.workingDirectory != expectedPath {
                    logger.debug("MIGRATION: Updating working directory for '\(conversation.title)' from '\(conversation.workingDirectory)' to '\(expectedPath)'")

                    /// Create new directory
                    try? FileManager.default.createDirectory(atPath: expectedPath, withIntermediateDirectories: true, attributes: nil)

                    /// Move files from old directory to new directory (if old directory exists and has content)
                    if FileManager.default.fileExists(atPath: conversation.workingDirectory) {
                        if let contents = try? FileManager.default.contentsOfDirectory(atPath: conversation.workingDirectory), !contents.isEmpty {
                            logger.debug("MIGRATION: Moving \(contents.count) files from old directory to new directory")
                            for item in contents {
                                let oldPath = (conversation.workingDirectory as NSString).appendingPathComponent(item)
                                let newPath = (expectedPath as NSString).appendingPathComponent(item)
                                do {
                                    try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
                                } catch {
                                    logger.warning("MIGRATION: Failed to move \(item): \(error)")
                                }
                            }

                            /// CRITICAL SAFETY: Only delete old directory if:
                            /// 1. It's in ~/SAM/ (double-check!)
                            /// 2. It's now empty
                            /// 3. It's different from new path
                            if isSafeSAMPath(conversation.workingDirectory),
                               let remainingContents = try? FileManager.default.contentsOfDirectory(atPath: conversation.workingDirectory),
                               remainingContents.isEmpty,
                               conversation.workingDirectory != expectedPath {
                                logger.debug("MIGRATION: Removing old empty directory: \(conversation.workingDirectory)")
                                try? FileManager.default.removeItem(atPath: conversation.workingDirectory)
                            }
                        }
                    }

                    /// Update conversation's working directory to new path
                    self.conversations[index].workingDirectory = expectedPath
                    migrationCount += 1
                }
            }

            if migrationCount > 0 {
                logger.info("MIGRATION: Updated working directories for \(migrationCount) conversation(s)")
                /// Save conversations with updated paths
                saveConversations()
            }

            logger.debug("Loaded \(self.conversations.count) conversations from storage")
        } catch {
            logger.error("Failed to load conversations: \(error)")
            logger.error("Failed to load conversations: \(error)")
            /// Keep empty array if loading fails.
            self.conversations = []
        }
    }

    // MARK: - Bug #3: Debounced Save Architecture

    /// Schedule a debounced save (batches rapid changes to reduce disk I/O).
    /// Call this after making changes to conversations - it will save after 500ms of inactivity.
    public func saveConversations() {
        /// Mark as dirty (has unsaved changes).
        isDirty = true

        /// Cancel any existing save task.
        saveTask?.cancel()

        /// Schedule new save task with debounce delay.
        saveTask = Task { [weak self] in
            guard let self = self else { return }

            /// Wait for debounce delay.
            try? await Task.sleep(nanoseconds: UInt64(self.saveDebounceDelay * 1_000_000_000))

            /// Check if task was cancelled during sleep.
            guard !Task.isCancelled else { return }

            /// Perform actual save on main actor.
            await self.performSave()
        }
    }

    /// Immediately save conversations to disk (bypasses debouncing).
    /// Use this for critical operations like app termination.
    public func saveConversationsImmediately() {
        /// Cancel any pending debounced save.
        saveTask?.cancel()

        /// Perform save synchronously.
        Task {
            await performSave()
        }
    }

    /// Reload conversations from disk (for API when conversation_id not found in memory).
    /// This allows API to use conversations created in UI that haven't been synced yet.
    /// CRITICAL BUG FIX: This was destroying all MessageBus instances and breaking the UI.
    /// NEW BEHAVIOR: Only load the SINGLE missing conversation, don't reload everything.
    public func loadConversationsFromDisk() {
        /// This method should no longer be used for bulk reloads - only for finding missing conversations
        /// The caller should handle finding the specific conversation they need
        logger.warning("loadConversationsFromDisk() called - this method is deprecated for bulk reloads")
        logger.warning("Consider using loadSingleConversation(id:) instead for better performance and UI stability")
    }
    
    /// Load a single conversation from disk without disturbing existing conversations
    public func loadSingleConversation(id: UUID) -> ConversationModel? {
        do {
            let allConversationsOnDisk = try conversationConfig.loadConversationsWithMigration()
            
            guard let foundConversation = allConversationsOnDisk.first(where: { $0.id == id }) else {
                logger.debug("Conversation \(id.uuidString.prefix(8)) not found on disk")
                return nil
            }
            
            /// Add to conversations array
            foundConversation.manager = self
            foundConversation.initializeMessageBus(conversationManager: self)
            conversations.append(foundConversation)
            
            /// Re-sort conversations by created date
            conversations.sort { $0.created > $1.created }
            
            logger.debug("Loaded single conversation \(id.uuidString.prefix(8)) from disk")
            return foundConversation
        } catch {
            logger.error("Failed to load single conversation \(id): \(error)")
            return nil
        }
    }

    /// Internal save implementation (called by debounced or immediate save).
    @MainActor
    private func performSave() {
        /// Only save if there are unsaved changes.
        guard isDirty else {
            logger.debug("SAVE_SKIP: No unsaved changes, skipping disk write")
            return
        }

        do {
            /// Save each conversation to its own file (per-file storage)
            for conversation in conversations {
                try conversationConfig.saveConversation(conversation)
            }

            /// Also save active conversation ID.
            if let activeConversation = activeConversation {
                try conversationConfig.saveActiveConversationId(activeConversation.id)
            }

            /// Mark as clean (saved).
            isDirty = false

            logger.debug("SAVE_SUCCESS: Saved \(self.conversations.count) conversations to per-file storage (debounced)")
        } catch {
            logger.error("SAVE_ERROR: Failed to save conversations: \(error)")
        }
    }

    /// Cleanup method to call on app termination (ensures pending saves complete).
    public func cleanup() {
        logger.debug("CLEANUP: Ensuring all conversations are saved before termination")

        /// Cancel debounce and save immediately.
        saveTask?.cancel()

        /// Synchronous save on termination.
        do {
            if isDirty {
                /// Save each conversation to its own file (per-file storage)
                for conversation in conversations {
                    try conversationConfig.saveConversation(conversation)
                }
                if let activeConversation = activeConversation {
                    try conversationConfig.saveActiveConversationId(activeConversation.id)
                }
                isDirty = false
                logger.debug("CLEANUP_SUCCESS: Final save completed")
            } else {
                logger.debug("CLEANUP_SKIP: No unsaved changes")
            }
        } catch {
            logger.error("CLEANUP_ERROR: Failed to save on termination: \(error)")
        }
    }

    private func restoreActiveConversation() {
        guard let activeId = conversationConfig.loadActiveConversationId() else {
            /// No saved active conversation, select first one.
            activeConversation = conversations.first
            return
        }

        /// Find and restore the active conversation.
        if let restoredConversation = conversations.first(where: { $0.id == activeId }) {
            activeConversation = restoredConversation
            logger.debug("Restored active conversation: \(restoredConversation.title)")
            logger.debug("Restored active conversation: \(restoredConversation.title)")

            /// Scan workspace for AI instruction files on startup.
            SystemPromptManager.shared.scanWorkspaceForAIInstructions(at: restoredConversation.workingDirectory)
        } else {
            /// Active conversation not found, select first one.
            activeConversation = conversations.first

            /// Scan workspace for first conversation.
            if let firstConv = conversations.first {
                SystemPromptManager.shared.scanWorkspaceForAIInstructions(at: firstConv.workingDirectory)
            }
        }
    }

    // MARK: - Memory Management Methods

    private func initializeMemorySystem() async {
        do {
            try await memoryManager.initialize()
            memoryInitialized = true
            logger.debug("Memory system initialized successfully")
            logger.debug("Memory system: Initialized and ready")
        } catch {
            logger.error("Failed to initialize memory system: \(error)")
            logger.error("Memory system: Failed to initialize - \(error.localizedDescription)")
            memoryInitialized = false
        }
    }

    private func initializeVectorRAGSystem() async {
        do {
            try await vectorRAGService.initialize()
            ragServiceInitialized = true
            logger.debug("SUCCESS: Vector RAG service initialized successfully")
        } catch {
            logger.error("ERROR: Failed to initialize Vector RAG service: \(error)")
            ragServiceInitialized = false
        }
    }

    private func initializeYaRNContextProcessor() async {
        do {
            try await yarnContextProcessor.initialize()
            contextProcessorInitialized = true
            logger.debug("SUCCESS: YaRN context processor initialized successfully")
        } catch {
            logger.error("ERROR: Failed to initialize YaRN context processor: \(error)")
            contextProcessorInitialized = false
        }
    }

    private func initializeContextArchiveSystem() async {
        /// Create adapter that wraps ContextArchiveManager for RecallHistoryTool.
        let archiveAdapter = ContextArchiveProviderAdapter(manager: contextArchiveManager)

        /// Wire up the conversation lookup callback for topic-wide search.
        archiveAdapter.getConversationsInTopicCallback = { [weak self] topicId in
            guard let self = self else { return [] }
            /// Find all conversations that belong to this shared topic.
            return self.conversations
                .filter { $0.settings.sharedTopicId == topicId }
                .map { $0.id }
        }

        /// Set the shared archive provider for RecallHistoryTool.
        RecallHistoryTool.sharedArchiveProvider = archiveAdapter

        contextArchiveInitialized = true
        logger.debug("Context Archive system initialized successfully")
    }

    private func initializeMCPSystem() async {
        do {
            /// Inject MemoryManager and VectorRAGService into MCPManager using enhanced adapter.
            let memoryAdapter = MemoryManagerAdapter(
                memoryManager: memoryManager,
                vectorRAGService: ragServiceInitialized ? vectorRAGService : nil
            )
            mcpManager.setMemoryManager(memoryAdapter)

            /// Advanced tools factory is injected externally by main.swift to avoid circular dependencies No need to inject here as it would override the proper factory.

            try await mcpManager.initialize()
            mcpInitialized = true
            logger.debug("MCP system initialized successfully with \(self.mcpManager.getAvailableTools().count) tools")
            logger.debug("MCP system: Initialized with \(self.mcpManager.getAvailableTools().count) tools")
        } catch {
            logger.error("Failed to initialize MCP system: \(error)")
            logger.error("MCP system: Failed to initialize - \(error.localizedDescription)")
            mcpInitialized = false
        }
    }

    /// Refresh Stable Diffusion tool registration dynamically Called when a new SD model is downloaded without restart Uses closure-based injection to avoid cyclic dependencies.
    public var stableDiffusionToolRefreshHandler: (() async -> Void)?

    public func refreshStableDiffusionTool() {
        logger.info("SD_REFRESH: Triggering Stable Diffusion tool refresh")
        Task {
            await stableDiffusionToolRefreshHandler?()
        }
    }

    private func storeMessageInMemory(content: String, conversationId: UUID, contentType: MemoryContentType) async {
        guard memoryInitialized else { return }

        do {
            let importance = contentType == .userInput ? 0.8 : 0.6
            let memoryId = try await memoryManager.storeMemory(
                content: content,
                conversationId: conversationId,
                contentType: contentType,
                importance: importance
            )
            logger.debug("Stored memory \(memoryId) for conversation \(conversationId)")
        } catch {
            logger.error("Failed to store memory: \(error)")
            logger.error("Memory error: Failed to store - \(error.localizedDescription)")
        }
    }

    private func getRelevantMemories(for query: String, conversationId: UUID) async -> [ConversationMemory] {
        guard memoryInitialized else { return [] }

        do {
            let memories = try await memoryManager.retrieveRelevantMemories(
                for: query,
                conversationId: conversationId,
                limit: 5,
                similarityThreshold: 0.4
            )
            logger.debug("MEMORY_TOOL_CALL: Retrieved \(memories.count) relevant memories for query: \(query.prefix(50)) (ACTUAL TOOL CALL EXECUTION)")
            
            // Track memory retrieval in telemetry
            incrementMemoryRetrieval(for: conversationId)
            
            return memories
        } catch {
            logger.error("Failed to retrieve memories: \(error)")
            return []
        }
    }

    /// Get memory statistics for the active conversation.
    public func getActiveConversationMemoryStats() async -> MemoryStatistics? {
        guard memoryInitialized, let conversation = activeConversation else { return nil }

        do {
            /// Use effective scope ID (topic ID if shared data enabled, conversation ID otherwise)
            let scopeId = getEffectiveScopeId(for: conversation)
            return try await memoryManager.getMemoryStatistics(for: scopeId)
        } catch {
            logger.error("Failed to get memory statistics: \(error)")
            return nil
        }
    }

    /// Clear all memories for a specific conversation.
    public func clearConversationMemories(_ conversation: ConversationModel) async {
        guard memoryInitialized else { return }

        do {
            /// Use effective scope ID (topic ID if shared data enabled, conversation ID otherwise)
            let scopeId = getEffectiveScopeId(for: conversation)
            try await memoryManager.clearMemories(for: scopeId)
            logger.debug("Cleared memories for conversation: \(conversation.title)")
            logger.debug("Cleared memories for: \(conversation.title)")
        } catch {
            logger.error("Failed to clear memories: \(error)")
            logger.error("Failed to clear memories: \(error.localizedDescription)")
        }
    }

    /// Get all memories for a conversation (for debugging/management).
    public func getConversationMemories(_ conversation: ConversationModel) async -> [ConversationMemory] {
        guard memoryInitialized else { return [] }

        do {
            return try await memoryManager.getAllMemories(for: conversation.id)
        } catch {
            logger.error("Failed to get conversation memories: \(error)")
            return []
        }
    }

    /// Get memory context for partial context implementation (SAM 1.0 style).
    public func getMemoryContext(for query: String, conversationId: UUID) async -> String {
        guard memoryInitialized else {
            return ""
        }

        do {
            /// Retrieve relevant memories for current conversation.
            let relevantMemories = try await memoryManager.retrieveRelevantMemories(
                for: query,
                conversationId: conversationId,
                limit: 5,
                similarityThreshold: 0.3
            )
            
            // Track memory retrieval in telemetry
            incrementMemoryRetrieval(for: conversationId)

            if relevantMemories.isEmpty {
                return ""
            }

            /// Format memory context for system prompt - SAM 1.0 style.
            var contextLines: [String] = []
            contextLines.append("RELEVANT MEMORY CONTEXT:")

            for memory in relevantMemories {
                let relevanceScore = String(format: "%.0f%%", memory.similarity * 100)
                contextLines.append("- [\(relevanceScore)] \(memory.content)")
            }

            return contextLines.joined(separator: "\n")

        } catch {
            logger.error("Failed to retrieve memory context: \(error)")
            return ""
        }
    }

    /// Get archive statistics for active conversation (for Session Intelligence UI).
    public func getActiveConversationArchiveStats() async -> MemoryMap? {
        guard let conversation = activeConversation else { return nil }

        do {
            return try await contextArchiveManager.getMemoryMap(conversationId: conversation.id)
        } catch {
            logger.debug("No archive data for conversation: \(error.localizedDescription)")
            return nil
        }
    }

    /// Get YaRN context statistics (for Session Intelligence UI).
    public func getYaRNContextStats() -> ContextStatistics {
        return yarnContextProcessor.getContextStatistics()
    }

    /// Get context statistics for a specific conversation.
    /// This calculates the actual token count from the conversation's messages.
    public func getContextStats(for conversation: ConversationModel) -> ContextStatistics {
        /// Calculate total tokens from all messages in conversation
        let totalTokens = conversation.messages.reduce(0) { sum, message in
            sum + estimateTokenCount(message.content)
        }

        /// Get context window size from YaRN processor
        let globalStats = yarnContextProcessor.getContextStatistics()

        /// Return conversation-specific stats
        return ContextStatistics(
            cacheSize: globalStats.cacheSize,
            currentTokenCount: totalTokens,
            contextWindowSize: globalStats.contextWindowSize,
            compressionRatio: globalStats.compressionRatio,
            attentionScalingFactor: globalStats.attentionScalingFactor,
            isCompressionActive: globalStats.isCompressionActive
        )
    }
    
    // MARK: - Telemetry Tracking
    
    /// Increment archive recall telemetry for a conversation.
    public func incrementArchiveRecall(for conversationId: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else { return }
        conversation.settings.telemetry.archiveRecallCount += 1
        conversation.settings.telemetry.lastUpdated = Date()
    }
    
    /// Increment memory retrieval telemetry for a conversation.
    public func incrementMemoryRetrieval(for conversationId: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else { return }
        conversation.settings.telemetry.memoryRetrievalCount += 1
        conversation.settings.telemetry.lastUpdated = Date()
    }
    
    /// Increment compression event telemetry for a conversation.
    public func incrementCompressionEvent(for conversationId: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else { return }
        conversation.settings.telemetry.compressionEventCount += 1
        conversation.settings.telemetry.lastUpdated = Date()
    }
    
    /// Increment context overflow telemetry for a conversation.
    public func incrementContextOverflow(for conversationId: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else { return }
        conversation.settings.telemetry.contextOverflowCount += 1
        conversation.settings.telemetry.lastUpdated = Date()
    }

    // MARK: - MCP Tool Methods

    /// Execute an MCP tool in the context of the active conversation.
    public func executeMCPTool(name: String, parameters: [String: Any], toolCallId: String? = nil, conversationId: UUID? = nil, isExternalAPICall: Bool = false, isUserInitiated: Bool = false, terminalManager: AnyObject? = nil, iterationController: IterationController? = nil) async -> MCPToolResult? {
        guard mcpInitialized else {
            logger.warning("MCP system not initialized, cannot execute tool: \(name)")
            return nil
        }

        /// CRITICAL: Use provided conversationId instead of activeConversation to prevent data leakage (Task 19)
        /// When conversationId is provided (from session), use it explicitly
        /// When nil, fall back to activeConversation (legacy behavior for non-session calls)
        let conversation: ConversationModel?
        if let conversationId = conversationId {
            conversation = conversations.first(where: { $0.id == conversationId })
            logger.debug("Using explicit conversationId: \(conversationId.uuidString)")
        } else {
            conversation = activeConversation
            logger.debug("Using activeConversation (legacy mode)")
        }

        guard let conversation = conversation else {
            logger.warning("No conversation found (id: \(conversationId?.uuidString ?? "nil")), cannot execute tool: \(name)")
            return nil
        }

        /// Start accessing security-scoped resource before file operations This grants macOS sandbox permission to access files in the working directory.
        let accessGranted = startAccessingWorkingDirectory(for: conversation)
        defer {
            /// ALWAYS stop accessing after tool execution completes (success or failure) This releases the security-scoped resource and prevents leak.
            if accessGranted {
                stopAccessingWorkingDirectory(for: conversation)
            }
        }

        /// Use effective working directory (topic directory if shared data enabled)
        let effectiveWorkingDir = getEffectiveWorkingDirectory(for: conversation)
        logger.debug("WORKING_DIR_DEBUG: conversation.workingDirectory=\(conversation.workingDirectory)")
        logger.debug("WORKING_DIR_DEBUG: effectiveWorkingDir=\(effectiveWorkingDir)")
        logger.debug("WORKING_DIR_DEBUG: conversationTitle=\(conversation.title)")

        /// Use effective scope ID for memory operations
        /// When shared data enabled: use sharedTopicId (all conversations in topic share memories)
        /// When shared data disabled: use conversationId (memories isolated per conversation)
        let effectiveScopeId: UUID? = {
            if conversation.settings.useSharedData,
               let topicId = conversation.settings.sharedTopicId {
                return topicId
            }
            return conversation.id
        }()

        let context = MCPExecutionContext(
            conversationId: conversation.id,
            userId: "user",
            metadata: ["conversationTitle": conversation.title],
            toolCallId: toolCallId,
            isExternalAPICall: isExternalAPICall,
            isUserInitiated: isUserInitiated,
            workingDirectory: effectiveWorkingDir,
            terminalManager: terminalManager,
            iterationController: iterationController,
            effectiveScopeId: effectiveScopeId
        )

        do {
            let result = try await mcpManager.executeTool(name: name, parameters: parameters, context: context)
            logger.debug("Executed MCP tool \(name): success=\(result.success), toolCallId=\(toolCallId ?? "none")")
            
            // Track telemetry for specific tools
            if result.success {
                if name == "recall_history" || name == "recall_history_by_time" {
                    incrementArchiveRecall(for: conversation.id)
                }
            }
            
            return result
        } catch {
            logger.error("Failed to execute MCP tool \(name): \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Tool execution failed: \(error.localizedDescription)")
            )
        }
    }

    /// Get available MCP tools.
    public func getAvailableMCPTools() -> [any MCPTool] {
        guard mcpInitialized else { return [] }
        return mcpManager.getAvailableTools()
    }

    /// Check if a specific MCP tool is available.
    public func isMCPToolAvailable(_ name: String) -> Bool {
        guard mcpInitialized else { return false }
        return mcpManager.getToolByName(name) != nil
    }
}

// MARK: - Protocol Conformance

extension ConversationManager: ConversationManagerProtocol {
    public func getConversationCount() -> Int {
        return conversations.count
    }

    public func hasActiveConversation() -> Bool {
        return activeConversation != nil
    }

    public func getConversationInfo() -> [[String: Any]] {
        return conversations.map { conversation in
            [
                "id": conversation.id.uuidString,
                "title": conversation.title,
                "createdAt": ISO8601DateFormatter().string(from: conversation.created),
                "updatedAt": ISO8601DateFormatter().string(from: conversation.updated),
                "messageCount": conversation.messages.count,
                "isActive": conversation.id == activeConversation?.id
            ]
        }
    }

    public func exportConversationToFile(conversationId: String?, format: String, outputPath: String) -> (success: Bool, error: String?) {
        /// Determine which conversation to export.
        let conversation: ConversationModel?
        if let conversationId = conversationId, let uuid = UUID(uuidString: conversationId) {
            conversation = conversations.first { $0.id == uuid }
            if conversation == nil {
                return (false, "Conversation not found: \(conversationId)")
            }
        } else {
            /// Export active conversation if no ID provided.
            conversation = activeConversation
            if conversation == nil {
                return (false, "No active conversation to export")
            }
        }

        guard let conv = conversation else {
            return (false, "No conversation available for export")
        }

        /// Format conversation based on requested format.
        let exportData: String
        switch format.lowercased() {
        case "json":
            exportData = formatConversationAsJSON(conv)

        case "text":
            exportData = formatConversationAsText(conv)

        case "markdown":
            exportData = formatConversationAsMarkdown(conv)

        default:
            return (false, "Unsupported format: \(format)")
        }

        /// Write to file.
        do {
            let url = URL(fileURLWithPath: outputPath)
            try exportData.write(to: url, atomically: true, encoding: .utf8)
            logger.debug("Exported conversation \(conv.id) to: \(outputPath)")
            return (true, nil)
        } catch {
            logger.error("Failed to export conversation: \(error)")
            return (false, "File write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Methods

    private func formatConversationAsJSON(_ conversation: ConversationModel) -> String {
        /// Use proper Codable encoding to preserve ALL EnhancedMessage fields Previous implementation manually picked only 4 fields, losing all tool metadata!.
        let conversationData = ConversationData(
            id: conversation.id,
            title: conversation.title,
            created: conversation.created,
            updated: conversation.updated,
            messages: conversation.messages,
            settings: conversation.settings,
            sessionId: conversation.sessionId,
            lastGitHubCopilotResponseId: conversation.lastGitHubCopilotResponseId,
            contextMessages: conversation.contextMessages,
            isPinned: conversation.isPinned,
            workingDirectory: conversation.workingDirectory,
            workingDirectoryBookmark: conversation.workingDirectoryBookmark
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let jsonData = try? encoder.encode(conversationData),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "{\"error\": \"Failed to encode conversation\"}"
        }

        return jsonString
    }

    private func formatConversationAsText(_ conversation: ConversationModel) -> String {
        var text = "Conversation: \(conversation.title)\n"
        text += "Created: \(conversation.created.formatted())\n"
        text += "Updated: \(conversation.updated.formatted())\n\n"
        text += String(repeating: "=", count: 80) + "\n\n"

        for message in conversation.messages {
            let sender = message.isFromUser ? "User" : "Assistant"
            let timestamp = message.timestamp.formatted(date: .abbreviated, time: .shortened)
            text += "[\(timestamp)] \(sender):\n"
            text += message.content + "\n\n"
            text += String(repeating: "-", count: 80) + "\n\n"
        }

        return text
    }

    private func formatConversationAsMarkdown(_ conversation: ConversationModel) -> String {
        var markdown = "# \(conversation.title)\n\n"
        markdown += "**Created:** \(conversation.created.formatted())\n"
        markdown += "**Updated:** \(conversation.updated.formatted())\n"
        markdown += "**Messages:** \(conversation.messages.count)\n\n"
        markdown += "---\n\n"

        for message in conversation.messages {
            let sender = message.isFromUser ? "**User**" : "**Assistant**"
            let timestamp = message.timestamp.formatted(date: .abbreviated, time: .shortened)
            markdown += "## \(sender) — \(timestamp)\n\n"
            markdown += message.content + "\n\n"
            markdown += "---\n\n"
        }

        return markdown
    }

    // MARK: - Folder Organization

    /// Get conversations for a specific folder
    public func conversationsForFolder(_ folderId: String?) -> [ConversationModel] {
        let folderConversations = conversations.filter { $0.folderId == folderId }

        /// Filter out API conversations if preference is enabled
        let hideAPIConversations = UserDefaults.standard.bool(forKey: "apiHideConversationsFromUI")
        let hasPreferenceKey = UserDefaults.standard.object(forKey: "apiHideConversationsFromUI") != nil
        /// Default to true if never set
        let shouldHideAPI = hasPreferenceKey ? hideAPIConversations : true

        if shouldHideAPI {
            return folderConversations.filter { !$0.isFromAPI }
        } else {
            return folderConversations
        }
    }

    /// Assign a folder to one or more conversations
    public func assignFolder(_ folderId: String?, to conversationIds: [UUID]) {
        for conversationId in conversationIds {
            guard let index = conversations.firstIndex(where: { $0.id == conversationId })
            else { continue }
            conversations[index].folderId = folderId
        }
        /// Trigger SwiftUI to re-render the conversation list
        objectWillChange.send()
        /// Trigger debounced save for all updated conversations
        saveConversations()
        logger.info("Assigned folder \(folderId ?? "nil") to \(conversationIds.count) conversation(s)")
    }

    /// Delete a folder and move all its conversations to uncategorized
    public func deleteFolder(_ folderId: String) {
        /// Find all conversations with this folder
        let affectedConversations = conversations.filter { $0.folderId == folderId }

        /// Move them to uncategorized
        for conversation in affectedConversations {
            conversation.folderId = nil
        }

        /// Trigger UI update
        objectWillChange.send()
        /// Save changes
        saveConversations()

        logger.info("Deleted folder \(folderId), moved \(affectedConversations.count) conversation(s) to uncategorized")
    }
}
